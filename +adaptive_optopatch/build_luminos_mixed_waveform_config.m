function [globalProps,wfmData,summary]=build_luminos_mixed_waveform_config( ...
        activeGlobalProps,activeWfmData,protocol,options)
%BUILD_LUMINOS_MIXED_WAVEFORM_CONFIG Own every AO stimulation output.
%   The resolved event table is flattened exactly once and then partitioned
%   by its explicit stimulation_source. Ambient records on AO-owned
%   terminals are removed before complete 1P and 2P waveforms are installed.
%
%   An output whose modality contributes no events is SUPPRESSED rather
%   than held at a constant: the ambient record is removed and nothing is
%   installed in its place. That keeps a 1P-only acquisition off the galvo
%   card entirely, so Luminos builds no Dev2 AO task for it. The 488
%   shutter is the same decision for the same reason - a 1P run owns it
%   imperatively - and the Blue DMD advance line is the deliberate
%   exception, because an advance line that nothing commands must be held
%   low rather than left to an ambient record.
arguments
    activeGlobalProps (1,1) struct
    activeWfmData (1,1) struct
    protocol (1,1) struct
    options.DmdSequencePlan = struct([])
    options.TwoPhotonWaveforms = struct([])
    options.OnePhotonProfile (1,1) struct = adaptive_optopatch.virtual_upright_1p_profile()
    options.TwoPhotonProfile (1,1) struct = adaptive_optopatch.virtual_upright_2p_profile()
    options.Manifest (1,1) struct = adaptive_optopatch.virtual_upright_stimulation_manifest()
end
required=["rate","clock_source","trigger_source","daq_master"];
if ~all(isfield(activeGlobalProps,required))
    error("adaptive_optopatch:IncompleteActiveWaveformSettings", ...
        "The active Luminos waveform lacks rate, clock, trigger, or DAQ-master settings.");
end
pulses=adaptive_optopatch.flatten_pulse_schedule(protocol);
onePhoton=pulses(pulses.stimulation_source=="1p_dmd",:);
twoPhoton=pulses(pulses.stimulation_source=="2p_spiral",:);
has1p=~isempty(onePhoton); has2p=~isempty(twoPhoton);
one=options.OnePhotonProfile; two=options.TwoPhotonProfile;
rate=double(activeGlobalProps.rate);
duration=double(protocol.acquisition_duration_s);
if has2p
    if isempty(options.TwoPhotonWaveforms)
        error("adaptive_optopatch:TwoPhotonWaveformsRequired", ...
            "A mixed acquisition containing 2p_spiral events requires planned 2P waveforms.");
    end
    if abs(rate-double(options.TwoPhotonWaveforms.sample_rate_hz))>1e-9
        error("adaptive_optopatch:TwoPhotonSampleRateMismatch", ...
            "Planned 2P waveforms are at %.0f Hz but Luminos is configured for %.0f Hz.", ...
            options.TwoPhotonWaveforms.sample_rate_hz,rate);
    end
    if abs(rate-double(two.scanner.sample_rate_hz))>1e-9
        error("adaptive_optopatch:TwoPhotonSampleRateMismatch", ...
            "2P acquisitions on this rig require the declared %.0f Hz sample rate.", ...
            two.scanner.sample_rate_hz);
    end
    duration=numel(options.TwoPhotonWaveforms.x_v)/rate;
end
globalProps=activeGlobalProps; globalProps.total_time=duration;
if ~isfield(globalProps,"completion_trigger"), globalProps.completion_trigger="None"; end
wfmData=ensure_fields(activeWfmData);
wfmData=adaptive_optopatch.drop_ao_script_waveforms(wfmData);
manifest=options.Manifest; aliases=manifest.alias_list;

% Remove every ambient spelling of all six AO-owned stimulation outputs.
wfmData.ao=adaptive_optopatch.remove_output_records(wfmData.ao, ...
    [one.modulator.name one.modulator.port "Adaptive2P_X" two.scanner.x_port ...
     "Adaptive2P_Y" two.scanner.y_port two.modulator.name two.modulator.port],aliases);
wfmData.do=adaptive_optopatch.remove_output_records(wfmData.do, ...
    [one.shutter.name one.shutter.port "AdaptiveOptopatch DMD trigger" ...
     one.dmd.trigger_alias one.dmd.trigger_port],aliases);

if has1p
    validate_one_photon(onePhoton,one,rate);
    wfmData.ao=append_record(wfmData.ao,event_record(one.modulator.name, ...
        one.modulator.name,onePhoton.onset_s,onePhoton.offset_s, ...
        onePhoton.command_voltage_v,one.modulator.dark_v));
else
    wfmData.ao=append_record(wfmData.ao,constant_record( ...
        one.modulator.name,one.modulator.name,one.modulator.dark_v));
end
wfmData.do=append_record(wfmData.do,dmd_record(options.DmdSequencePlan, ...
    one,manifest,rate,duration,onePhoton));

if has2p
    wave=options.TwoPhotonWaveforms;
    n=numel(wave.x_v);
    if numel(wave.y_v)~=n || numel(wave.pockels_v)~=n
        error("adaptive_optopatch:TwoPhotonWaveformSizeMismatch", ...
            "Galvo X, galvo Y, and Pockels vectors must have equal lengths.");
    end
    wfmData.ao=append_record(wfmData.ao,sampled_record( ...
        "Adaptive2P_X",two.scanner.x_port,rate,wave.x_v,wave.x_v(end)));
    wfmData.ao=append_record(wfmData.ao,sampled_record( ...
        "Adaptive2P_Y",two.scanner.y_port,rate,wave.y_v,wave.y_v(end)));
    wfmData.ao=append_record(wfmData.ao,sampled_record( ...
        two.modulator.name,two.modulator.name,rate,wave.pockels_v,two.modulator.dark_v));
end
% An acquisition with no 2P events SUPPRESSES the 2P outputs instead of
% holding them at a constant. The ambient removal above is all of it: the
% three terminals are absent from wfm_data and no task is built for them.
% Appending constant galvo records put Dev2/ao0 and Dev2/ao1 into wfm_data,
% and a buffered record on a Dev2 terminal is what makes Luminos build a
% hardware-timed AO task on that card, which then has to be clocked and
% triggered from Dev1 - the routing conflict a 1P-only run hit. Nothing in
% a 1P acquisition commands these outputs, so nothing here installs a
% record to hold them - and nothing commands them imperatively instead,
% because neutralize_all_stimulation reads the same manifest declaration
% and skips what this modality suppresses.
% This is the has2p==false path only. A mixed acquisition takes the branch
% above and drives all three from the planned 2P waveforms as before.

% Any acquisition containing 1P uses the runner's imperative shutter owner.
% Otherwise the buffered line explicitly owns the closed state.
if ~has1p
    shutter=two.inactive_one_photon.shutter;
    wfmData.do=append_record(wfmData.do,constant_record( ...
        shutter.name,shutter.port,shutter.closed_state));
end
summary=struct("schema_version","1.0.0","sample_rate_hz",rate, ...
    "sample_count",round(rate*duration),"duration_s",duration, ...
    "pulses",pulses,"onephoton_event_count",height(onePhoton), ...
    "twophoton_event_count",height(twoPhoton),"has_mixed_sources",has1p&&has2p, ...
    "blue_shutter_runtime_owner",string(ternary(has1p,"imperative","buffered")), ...
    "script_owner",adaptive_optopatch.script_owner_tag());
if ~isempty(options.DmdSequencePlan)
    summary.dmd_sequence=options.DmdSequencePlan;
    if isfield(summary.dmd_sequence,"unique_camera_masks")
        summary.dmd_sequence=rmfield(summary.dmd_sequence,"unique_camera_masks");
    end
end
end

function validate_one_photon(pulses,profile,rate)
if any(pulses.command_voltage_v<profile.modulator.minimum_v | ...
        pulses.command_voltage_v>profile.modulator.maximum_v)
    error("adaptive_optopatch:ModulatorVoltageOutOfRange", ...
        "A mod488 command lies outside the declared range.");
end
ticks=ceil(pulses.offset_s*rate-1e-9)-ceil(pulses.onset_s*rate-1e-9);
if any(ticks<1)
    error("adaptive_optopatch:PulseShorterThanWaveformSample", ...
        "A 1P pulse is shorter than one active Luminos waveform sample.");
end
end

function record=dmd_record(plan,profile,manifest,rate,duration,pulses)
role=string({manifest.outputs.role});
neutral=manifest.outputs(role=="blue_dmd_advance_trigger").neutral_value;
if isempty(plan) || isempty(pulses)
    record=constant_record("AdaptiveOptopatch DMD trigger",profile.dmd.trigger_port,neutral);
    return
end
if isfield(plan,"dmd_trigger_s"), onset=double(plan.dmd_trigger_s(:));
else, onset=[0;double(plan.advance_onset_s(:))]; end
offset=onset+max(3/rate,20e-6);
if offset(1)>min(pulses.onset_s)
    error("adaptive_optopatch:DmdInitializationNotDark", ...
        "The first 1P pulse begins before DMD initialization ends.");
end
if offset(end)>duration
    error("adaptive_optopatch:DmdAdvanceOutsideAcquisition", ...
        "The final DMD advance trigger exceeds the acquisition duration.");
end
record=event_record("AdaptiveOptopatch DMD trigger",profile.dmd.trigger_port, ...
    onset,offset,ones(size(onset)),neutral);
end

function record=event_record(name,port,onset,offset,values,dark)
record=base_record(name,port,"adaptive_optopatch.luminos_event_waveform", ...
    {onset,offset,values,double(dark)});
end
function record=sampled_record(name,port,rate,values,finalValue)
record=base_record(name,port,"adaptive_optopatch.luminos_sampled_waveform", ...
    {rate,values(:),finalValue});
end
function record=constant_record(name,port,value)
record=base_record(name,port,"awfm_constant",{double(value)});
end
function record=base_record(name,port,wavefile,params)
record=struct("name",char(name),"port",char(port),"wavefile",wavefile, ...
    "params",{params},"operation","Multiplication","concatTime",[], ...
    "script_owner",char(adaptive_optopatch.script_owner_tag()));
end
function data=ensure_fields(data)
for name=["ao","do","ai","di","ctri","ao_camera_triggered","do_camera_triggered"]
    if ~isfield(data,name), data.(name)=[]; end
end
end
function values=append_record(values,record)
if isempty(values), values=record; return; end
fields=union(fieldnames(values),fieldnames(record),'stable');
for k=1:numel(fields)
    if ~isfield(values,fields{k}), [values.(fields{k})]=deal([]); end
    if ~isfield(record,fields{k}), record.(fields{k})=[]; end
end
values(end+1)=orderfields(record,values);
end
function value=ternary(condition,whenTrue,whenFalse)
if condition, value=whenTrue; else, value=whenFalse; end
end
