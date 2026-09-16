function [globalProps,wfmData,summary] = build_luminos_1p_waveform_config( ...
        activeGlobalProps,activeWfmData,protocol,profile,options)
%BUILD_LUMINOS_1P_WAVEFORM_CONFIG Preserve active timing and inject mod488.
arguments
    activeGlobalProps (1,1) struct
    activeWfmData (1,1) struct
    protocol (1,1) struct
    profile (1,1) struct = adaptive_optopatch.virtual_upright_1p_profile()
    options.DmdSequencePlan = struct([])
    options.Manifest (1,1) struct = ...
        adaptive_optopatch.virtual_upright_stimulation_manifest()
end
aliasList=options.Manifest.alias_list;
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

pulses=adaptive_optopatch.flatten_pulse_schedule(protocol);
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
wfmData=adaptive_optopatch.drop_ao_script_waveforms(wfmData);
wfmData=neutralize_two_photon_outputs(wfmData,profile.inactive_two_photon,aliasList);
% The 488 shutter has one runtime owner during a 1P acquisition, and it is
% the runner's imperative open/close around the armed window - which is
% where the shutter has always been driven from, and moving it into the
% buffer would change when light reaches the preparation. So no buffered
% record may own the line: an ambient one is removed rather than left to
% contend with those writes. The manifest records the same decision as
% owner="imperative".
wfmData.do=adaptive_optopatch.remove_output_records(wfmData.do, ...
    [profile.shutter.name profile.shutter.port],aliasList);
wfmData.ao=adaptive_optopatch.remove_output_records(wfmData.ao, ...
    [profile.modulator.name profile.modulator.port],aliasList);
record=struct("name",char(profile.modulator.name), ...
    "port",char(profile.modulator.name), ...
    "wavefile","adaptive_optopatch.luminos_event_waveform", ...
    "params",{{pulses.onset_s,pulses.offset_s, ...
        pulses.modulator_voltage,double(profile.modulator.dark_v)}}, ...
    "operation","Multiplication","concatTime",[], ...
    "script_owner",char(adaptive_optopatch.script_owner_tag()));
wfmData.ao=append_compatible(wfmData.ao,record);
% Every spelling of the Blue DMD advance line, including the rig alias
% "DMD Trigger" that Waveforms actually stores. A stale record there
% de-aliases onto exactly this terminal inside Luminos and combines with
% whatever AO puts on it, so removing it by name alone left the hole this
% pass exists to close. Unconditional, because a trial that advances no
% patterns still owns the line: it previously left an ambient record in
% place, and an AO-owned stimulation terminal that nothing commands has to
% carry its declared neutral rather than somebody else's waveform.
wfmData.do=adaptive_optopatch.remove_output_records(wfmData.do, ...
    ["AdaptiveOptopatch DMD trigger" string(profile.dmd.trigger_alias) ...
     string(profile.dmd.trigger_port)],aliasList);
if isempty(options.DmdSequencePlan)
    wfmData.do=append_compatible(wfmData.do,constant_record( ...
        "AdaptiveOptopatch DMD trigger",profile.dmd.trigger_port, ...
        dmd_trigger_neutral(options.Manifest)));
else
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
    % The ALP advances on the rising edge. The digital pulse may remain high
    % after a back-to-back optical event begins; requiring its full width to
    % fit in darkness would add a biological gap that the protocol did not
    % request. The initial edge remains fully dark so entry 1 is selected
    % before any illumination.
    if ~isempty(triggerOffset) && triggerOffset(end)>globalProps.total_time
        error("adaptive_optopatch:DmdAdvanceOutsideAcquisition", ...
            "The final DMD advance trigger exceeds the acquisition duration.");
    end
    triggerRecord=struct("name","AdaptiveOptopatch DMD trigger", ...
        "port",char(profile.dmd.trigger_port), ...
        "wavefile","adaptive_optopatch.luminos_event_waveform", ...
        "params",{{triggerOnset,triggerOffset,ones(size(triggerOnset)),0}}, ...
        "operation","Multiplication","concatTime",[], ...
        "script_owner",char(adaptive_optopatch.script_owner_tag()));
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
    summary.dmd_sequence=rmfield(options.DmdSequencePlan,"unique_camera_masks");
    summary.dmd_trigger_port=string(profile.dmd.trigger_port);
end
summary.clock_source=reshape(string(globalProps.clock_source),1,[]);
summary.trigger_source=reshape(string(globalProps.trigger_source),1,[]);
summary.expected_clock_bridge=reshape(string(profile.daq.clock_bridge),1,[]);
summary.expected_start_triggers=reshape(string(profile.daq.default_trigger),1,[]);
summary.blue_shutter_runtime_owner= ...
    manifest_owner(options.Manifest,"blue_shutter").one_photon;
summary.script_owner=adaptive_optopatch.script_owner_tag();
summary.inactive_two_photon_outputs=struct( ...
    "galvo_x_port",string(profile.inactive_two_photon.scanner.x_port), ...
    "galvo_y_port",string(profile.inactive_two_photon.scanner.y_port), ...
    "galvo_stationary_v",double(profile.inactive_two_photon.scanner.stationary_v), ...
    "pockels_port",string(profile.inactive_two_photon.modulator.port), ...
    "pockels_dark_v",double(profile.inactive_two_photon.modulator.dark_v), ...
    "safe_value_source",string(profile.inactive_two_photon.safe_value_source));
end

function data=neutralize_two_photon_outputs(data,outputs,aliasList)
scanner=outputs.scanner; modulator=outputs.modulator;
data.ao=adaptive_optopatch.remove_output_records(data.ao, ...
    [scanner.x_name scanner.x_port],aliasList);
data.ao=append_compatible(data.ao,constant_record( ...
    scanner.x_name,scanner.x_port,scanner.stationary_v(1)));
data.ao=adaptive_optopatch.remove_output_records(data.ao, ...
    [scanner.y_name scanner.y_port],aliasList);
data.ao=append_compatible(data.ao,constant_record( ...
    scanner.y_name,scanner.y_port,scanner.stationary_v(2)));
data.ao=adaptive_optopatch.remove_output_records(data.ao, ...
    [modulator.name modulator.port],aliasList);
data.ao=append_compatible(data.ao,constant_record( ...
    modulator.name,modulator.name,modulator.dark_v));
end

function record=constant_record(name,port,value)
record=struct("name",char(name),"port",char(port), ...
    "wavefile","awfm_constant","params",{{double(value)}}, ...
    "operation","Multiplication","concatTime",[], ...
    "script_owner",char(adaptive_optopatch.script_owner_tag()));
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

function value=dmd_trigger_neutral(manifest)
% The low state is a rig safety declaration, read from the manifest rather
% than assumed here. Nothing in a waveform builder decides what is safe.
value=manifest.outputs( ...
    string({manifest.outputs.role})=="blue_dmd_advance_trigger").neutral_value;
end

function value=manifest_owner(manifest,role)
value=manifest.outputs(string({manifest.outputs.role})==string(role)).owner;
end

function data=ensure_wfm_fields(data)
for name=["ao","do","ai","di","ctri","ao_camera_triggered","do_camera_triggered"]
    if ~isfield(data,name), data.(name)=[]; end
end
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
