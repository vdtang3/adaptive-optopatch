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
