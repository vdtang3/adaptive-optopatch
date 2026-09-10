function [globalProps,wfmData,summary] = build_luminos_1p_waveform_config( ...
        activeGlobalProps,activeWfmData,protocol,profile,options)
%BUILD_LUMINOS_1P_WAVEFORM_CONFIG Preserve active timing and inject mod488.
arguments
    activeGlobalProps (1,1) struct
    activeWfmData (1,1) struct
    protocol (1,1) struct
    profile (1,1) struct = adaptive_optopatch.virtual_upright_1p_profile()
    options.ModulatorVoltageOverride (1,1) double = NaN
    options.DmdSequencePlan = struct([])
end
required=["rate","clock_source","trigger_source","daq_master"];
if ~all(isfield(activeGlobalProps,required))
    error("adaptive_optopatch:IncompleteActiveWaveformSettings", ...
        "Load a Luminos waveform protocol containing rate, clock, trigger, and DAQ-master settings.");
end
rate=double(activeGlobalProps.rate);
if ~isscalar(rate) || ~isfinite(rate) || rate<=0
    error("adaptive_optopatch:InvalidWaveformRate", ...
        "The active Luminos waveform sample rate must be positive.");
end

pulses=adaptive_optopatch.flatten_pulse_schedule(protocol, ...
    "ConfiguredVoltage",options.ModulatorVoltageOverride);
minV=double(profile.modulator.minimum_v); maxV=double(profile.modulator.maximum_v);
if any(pulses.modulator_voltage<minV | pulses.modulator_voltage>maxV)
    error("adaptive_optopatch:ModulatorVoltageOutOfRange", ...
        "A mod488 command lies outside the declared %.3g-%.3g V range.",minV,maxV);
end
realization=validate_pulse_realization(pulses,rate);

globalProps=activeGlobalProps;
globalProps.total_time=double(protocol.acquisition_duration_s);
if ~isfield(globalProps,"completion_trigger")
    globalProps.completion_trigger="None";
end
wfmData=ensure_wfm_fields(activeWfmData);
wfmData.ao=remove_output(wfmData.ao,profile.modulator.name,profile.modulator.port);
record=struct("name",char(profile.modulator.name), ...
    "port",char(profile.modulator.name), ...
    "wavefile","adaptive_optopatch.luminos_event_waveform", ...
    "params",{{pulses.onset_s,pulses.offset_s, ...
        pulses.modulator_voltage,double(profile.modulator.dark_v)}}, ...
    "operation","Multiplication","concatTime",[]);
wfmData.ao=append_compatible(wfmData.ao,record);
if ~isempty(options.DmdSequencePlan)
    wfmData.do=remove_output(wfmData.do,"AdaptiveOptopatch DMD trigger", ...
        profile.dmd.trigger_port);
    if isfield(options.DmdSequencePlan,"dmd_trigger_s")
        triggerOnset=double(options.DmdSequencePlan.dmd_trigger_s(:));
    else
        % Backward compatibility for previously constructed in-memory plans.
        triggerOnset=[0;double(options.DmdSequencePlan.advance_onset_s(:))];
    end
    triggerWidth=max(3/rate,20e-6);
    triggerOffset=triggerOnset+triggerWidth;
    firstLightOnset=min(pulses.onset_s(~pulses.is_null));
    if ~isempty(firstLightOnset) && triggerOffset(1)>firstLightOnset
        error("adaptive_optopatch:DmdInitializationNotDark", ...
            "The first optical pulse begins before the DMD initialization trigger ends. Add protocol pre-delay.");
    end
    % A pattern-advance trigger selects the mask for the pulse that follows
    % it, so it must complete while mod488 is dark. The trigger is at least
    % three samples wide, so a low live sample rate can push a later advance
    % into its own pulse and illuminate the previous mask.
    overlap=first_trigger_light_overlap(triggerOnset,triggerOffset,pulses);
    if overlap>0
        error("adaptive_optopatch:DmdAdvanceOverlapsLight", ...
            ['DMD advance trigger %d ends %.4f ms after it starts, at the ' ...
             '%.0f Hz active Luminos sample rate, and overlaps an optical ' ...
             'pulse. Lengthen the preceding dark interval or raise the ' ...
             'waveform sample rate.'],overlap,1000*triggerWidth,rate);
    end
    if ~isempty(triggerOffset) && triggerOffset(end)>globalProps.total_time
        error("adaptive_optopatch:DmdAdvanceOutsideAcquisition", ...
            "The final DMD advance trigger exceeds the acquisition duration.");
    end
    triggerRecord=struct("name","AdaptiveOptopatch DMD trigger", ...
        "port",char(profile.dmd.trigger_port), ...
        "wavefile","adaptive_optopatch.luminos_event_waveform", ...
        "params",{{triggerOnset,triggerOffset,ones(size(triggerOnset)),0}}, ...
        "operation","Multiplication","concatTime",[]);
    wfmData.do=append_compatible(wfmData.do,triggerRecord);
end

sampleCount=round(rate*globalProps.total_time);
onsetSample=floor(pulses.onset_s*rate)+1;
offsetSample=ceil(pulses.offset_s*rate);
summary=struct("schema_version","0.2.0", ...
    "sample_rate_hz",rate, ...
    "sample_count",sampleCount, ...
    "duration_s",globalProps.total_time, ...
    "daq_master",logical(globalProps.daq_master), ...
    "modulator_name",string(profile.modulator.name), ...
    "modulator_port",string(profile.modulator.port), ...
    "pulse_count",height(pulses), ...
    "onset_sample",onsetSample, ...
    "offset_sample",offsetSample, ...
    "pulse_realization",realization, ...
    "pulses",pulses);
if ~isempty(options.DmdSequencePlan)
    summary.dmd_sequence=rmfield(options.DmdSequencePlan,"camera_pattern_stack");
    summary.dmd_trigger_port=string(profile.dmd.trigger_port);
end
summary.clock_source=reshape(string(globalProps.clock_source),1,[]);
summary.trigger_source=reshape(string(globalProps.trigger_source),1,[]);
summary.expected_clock_bridge=reshape(string(profile.daq.clock_bridge),1,[]);
summary.expected_start_triggers=reshape(string(profile.daq.default_trigger),1,[]);
end

function report=validate_pulse_realization(pulses,rate)
%VALIDATE_PULSE_REALIZATION Confirm the live rate can realize frozen timing.
%   Frozen 1P timing is expressed in seconds and Luminos samples it at the
%   active waveform rate, so the rate is what decides whether the requested
%   pattern physically exists. A pulse whose window contains no sample emits
%   no light at all, and a dark interval that contains no sample fuses two
%   commanded pulses into one longer pulse. Both silently change the
%   experiment, so they fail here rather than being discovered in the data.
% Sample i is emitted at t=(i-1)/rate and luminos_event_waveform holds a
% pulse over [onset, offset), so the first sample index inside a boundary is
% its tick rounded up. Round up with a relative guard: a boundary that is a
% whole number of samples must not be pushed onto the next one by the
% floating-point product.
firstIndex=@(t)ceil(t*rate-1e-9*max(1,abs(t*rate)));
onsetTick=firstIndex(pulses.onset_s); offsetTick=firstIndex(pulses.offset_s);
sampleCount=offsetTick-onsetTick;
light=~pulses.is_null;
missing=find(light & sampleCount<1,1);
if ~isempty(missing)
    error("adaptive_optopatch:PulseShorterThanWaveformSample", ...
        ['Pulse %s is %.4f ms long, which is shorter than one sample of the ' ...
         '%.0f Hz active Luminos waveform, so it would emit no light. Use a ' ...
         'waveform rate of at least %.0f Hz or lengthen the pulse.'], ...
        string(pulses.pulse_id(missing)), ...
        1000*pulses.duration_s(missing),rate, ...
        ceil(1/pulses.duration_s(missing)));
end
gapSamples=nan(height(pulses)-1,1);
for k=1:height(pulses)-1
    gapSamples(k)=onsetTick(k+1)-offsetTick(k);
    requested=pulses.onset_s(k+1)-pulses.offset_s(k);
    if light(k) && light(k+1) && requested>1e-12 && gapSamples(k)<1
        error("adaptive_optopatch:DarkIntervalShorterThanWaveformSample", ...
            ['The %.4f ms dark interval between pulses %s and %s contains no ' ...
             'sample of the %.0f Hz active Luminos waveform, so the two ' ...
             'commanded pulses would be delivered as one. Use a waveform ' ...
             'rate of at least %.0f Hz or lengthen the interval.'], ...
            1000*requested,string(pulses.pulse_id(k)), ...
            string(pulses.pulse_id(k+1)),rate,ceil(1/requested));
    end
end
% Quantization to the live rate is bounded by one sample period and is
% recorded rather than corrected: the frozen schedule stays exactly as
% requested and the realized values travel with the acquisition.
realizedDuration=sampleCount/rate;
report=struct("schema_version","1.0.0","sample_rate_hz",rate, ...
    "pulse_sample_count",sampleCount, ...
    "realized_duration_s",realizedDuration, ...
    "maximum_duration_error_s", ...
        max([abs(realizedDuration(light)-pulses.duration_s(light));0]), ...
    "dark_interval_sample_count",gapSamples);
end

function index=first_trigger_light_overlap(triggerOnset,triggerOffset,pulses)
%FIRST_TRIGGER_LIGHT_OVERLAP Index of the first advance trigger during light.
index=0;
light=pulses(~pulses.is_null,:);
if isempty(light) || isempty(triggerOnset), return; end
onset=sort(light.onset_s); offset=sort(light.offset_s);
% Light pulses never overlap, so the number of them intersecting a trigger
% window is the number starting before it ends minus the number finished
% before it begins.
starting=arrayfun(@(value)sum(onset<value-1e-12),triggerOffset);
finished=arrayfun(@(value)sum(offset<=value+1e-12),triggerOnset);
overlapping=find(starting-finished>0,1);
if ~isempty(overlapping), index=overlapping; end
end

function data=ensure_wfm_fields(data)
for name=["ao","do","ai","di","ctri","ao_camera_triggered","do_camera_triggered"]
    if ~isfield(data,name), data.(name)=[]; end
end
end

function values=remove_output(values,name,port)
if isempty(values), return; end
keep=true(size(values));
for k=1:numel(values)
    recordName=""; recordPort="";
    if isfield(values,"name"), recordName=string(values(k).name); end
    if isfield(values,"port"), recordPort=string(values(k).port); end
    keep(k)=~(recordName==string(name) || recordPort==string(name) || ...
        recordPort==string(port));
end
values=values(keep);
end

function values=append_compatible(values,record)
if isempty(values), values=record; return; end
allFields=union(fieldnames(values),fieldnames(record),'stable');
values=add_fields(values,allFields);
record=add_fields(record,allFields);
values(end+1)=orderfields(record,values);
end

function values=add_fields(values,names)
for k=1:numel(names)
    if ~isfield(values,names{k}), [values.(names{k})]=deal([]); end
end
end
