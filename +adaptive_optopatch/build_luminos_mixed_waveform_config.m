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
if string(options.OnePhotonProfile.rig_name)=="Spinning_Upright" && has2p
    error("adaptive_optopatch:UnsupportedRigModality", ...
        "Spinning_Upright has no declared 2P scanner or modulator path.");
end
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
[wfmData.ai,auxiliaryInput]=adaptive_optopatch.ensure_auxiliary_input( ...
    wfmData.ai,options.OnePhotonProfile);

% Remove every ambient spelling of all six AO-owned stimulation outputs.
ownedAnalog=[one.modulator.name one.modulator.port];
if string(one.rig_name)=="Virtual_Upright"
    ownedAnalog=[ownedAnalog "Adaptive2P_X" two.scanner.x_port ...
        "Adaptive2P_Y" two.scanner.y_port two.modulator.name two.modulator.port];
end
wfmData.ao=adaptive_optopatch.remove_output_records(wfmData.ao, ...
    ownedAnalog,aliases);
wfmData.do=adaptive_optopatch.remove_output_records(wfmData.do, ...
    [one.shutter.name one.shutter.port "AdaptiveOptopatch DMD trigger" ...
     one.dmd.trigger_alias one.dmd.trigger_port],aliases);

% ORANGE RECORDING ILLUMINATION, on a rig whose profile declares it.
%
% 594 nm is what the voltage indicator is read out with, not something the
% protocol stimulates with, so it carries no events and takes no part in the
% pulse arithmetic above: it is one constant held across the acquisition
% window at the Orange recording voltage the operator chose against the live
% view. That is a faithful replacement for what it displaces - a saved VU
% Waveforms protocol drives mod594 with an awfm_constant and nothing else,
% with no blanking, ramp or within-acquisition modulation to preserve.
%
% The ambient record goes first, every spelling of it, for the same reason
% the mod488 one does: Luminos COMBINES two records that resolve to one
% terminal, so leaving the operator's constant beside AO's would record at
% the sum of two voltages. shutter594 is cleared from the buffer entirely
% rather than replaced, because the runner opens and closes it imperatively
% and one line cannot have two runtime owners.
orangeSummary=struct("owned",false);
if isfield(one,"orange_modulator")
    wfmData.ao=adaptive_optopatch.remove_output_records(wfmData.ao, ...
        [one.orange_modulator.name one.orange_modulator.port],aliases);
    level=adaptive_optopatch.orange_recording_voltage(one);
    wfmData.ao=append_record(wfmData.ao,constant_record( ...
        one.orange_modulator.name,one.orange_modulator.name,level));
    orangeSummary=struct("owned",true, ...
        "modulator_name",string(one.orange_modulator.name), ...
        "modulator_port",string(one.orange_modulator.port), ...
        "recording_voltage_v",level, ...
        "waveform","constant", ...
        "duration_s",duration, ...
        "shutter_runtime_owner","imperative");
end
if isfield(one,"orange_shutter")
    wfmData.do=adaptive_optopatch.remove_output_records(wfmData.do, ...
        [one.orange_shutter.name one.orange_shutter.port],aliases);
end

% A blanket-depolarization plan carries its own sample-exact state table,
% and both Blue outputs are expanded from it instead of from the pulse list.
blanketPlan=~isempty(options.DmdSequencePlan) && ...
    isfield(options.DmdSequencePlan,"state_table");
if blanketPlan && has2p
    error("adaptive_optopatch:InvalidBlanketAcquisition", ...
        "A blanket-depolarization plan requires a 1P-only acquisition.");
end
if blanketPlan
    % Both Blue outputs come from the one state table, whether or not the
    % acquisition targets a cell: a blanket recruitment sweep has only null
    % logical segments and still emits blanket light on every cycle.
    [blanketMod488,blanketTrigger,blanketSummary]=blanket_records( ...
        options.DmdSequencePlan,one,manifest,rate,duration);
    if has1p, validate_one_photon(onePhoton,one,rate); end
    wfmData.ao=append_record(wfmData.ao,blanketMod488);
    wfmData.do=append_record(wfmData.do,blanketTrigger);
elseif has1p
    validate_one_photon(onePhoton,one,rate);
    wfmData.ao=append_record(wfmData.ao,event_record(one.modulator.name, ...
        one.modulator.name,onePhoton.onset_s,onePhoton.offset_s, ...
        onePhoton.command_voltage_v,one.modulator.dark_v));
    wfmData.do=append_record(wfmData.do,dmd_record(options.DmdSequencePlan, ...
        one,manifest,rate,duration,onePhoton));
else
    wfmData.ao=append_record(wfmData.ao,constant_record( ...
        one.modulator.name,one.modulator.name,one.modulator.dark_v));
    wfmData.do=append_record(wfmData.do,dmd_record(options.DmdSequencePlan, ...
        one,manifest,rate,duration,onePhoton));
end

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

% Any acquisition that emits 488 nm light uses the runner's imperative
% shutter owner - including a blanket recruitment sweep, whose logical
% segments are null but whose blanket phase is lit. Otherwise the buffered
% line explicitly owns the closed state.
if ~has1p && ~blanketPlan
    shutter=two.inactive_one_photon.shutter;
    wfmData.do=append_record(wfmData.do,constant_record( ...
        shutter.name,shutter.port,shutter.closed_state));
end
summary=struct("schema_version","1.0.0","sample_rate_hz",rate, ...
    "sample_count",round(rate*duration),"duration_s",duration, ...
    "pulses",pulses,"onephoton_event_count",height(onePhoton), ...
    "twophoton_event_count",height(twoPhoton),"has_mixed_sources",has1p&&has2p, ...
    "blue_shutter_runtime_owner", ...
        string(ternary(has1p||blanketPlan,"imperative","buffered")), ...
    "script_owner",adaptive_optopatch.script_owner_tag());
summary.auxiliary_input=auxiliaryInput;
summary.orange_recording_illumination=orangeSummary;
if blanketPlan
    summary.blanket_depolarization=blanketSummary;
    summary.pulses=describe_blanket_delivery(summary.pulses, ...
        options.DmdSequencePlan.state_table,blanketSummary);
end
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
if isempty(onset)
    record=constant_record("AdaptiveOptopatch DMD trigger", ...
        profile.dmd.trigger_port,neutral);
    return
end
if isfield(plan,"projection_mode") && string(plan.projection_mode)=="master"
    laterOnsets=double(pulses.onset_s(2:end));
    if numel(onset)~=numel(laterOnsets) || any(offset>=laterOnsets)
        error("adaptive_optopatch:DmdTriggerNotBeforePulse", ...
            "Each DMD trigger must finish before its corresponding blue pulse.");
    end
elseif offset(1)>min(pulses.onset_s)
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

function [mod488,trigger,summary]=blanket_records(plan,profile,manifest,rate,duration)
%BLANKET_RECORDS mod488 and the DMD trigger, from one state table.
%   Each state is one DMD trigger (high for the first
%   dmd_trigger_width_samples, at the state's first sample) and one mod488
%   level (0 V for mod488_guard_samples, then the state's voltage). The
%   round repeats round_count times; outside it mod488 sits at the rig's
%   dark_v and the trigger at its manifest neutral.
stateTable=plan.state_table; states=stateTable.states;
if abs(double(stateTable.sample_rate_hz)-rate)>1e-9
    error("adaptive_optopatch:BlanketSampleRateChanged", ...
        "The blanket state table was built for %.0f Hz, but Luminos is " + ...
        "configured for %.0f Hz.",stateTable.sample_rate_hz,rate);
end
totalSamples=round(rate*duration);
if stateTable.final_sample>totalSamples
    error("adaptive_optopatch:BlanketRoundsOutsideAcquisition", ...
        "The final blanket round ends after the acquisition.");
end
levels=states.mod488_v;
if any(levels<profile.modulator.minimum_v | levels>profile.modulator.maximum_v)
    error("adaptive_optopatch:ModulatorVoltageOutOfRange", ...
        "A blanket-mode mod488 command lies outside the declared range.");
end
guard=states.mod488_guard_samples;
modSamples=reshape([guard states.duration_samples-guard]',[],1);
modValues=reshape([zeros(height(states),1) levels]',[],1);
keep=modSamples>0;
mod488=base_record(profile.modulator.name,profile.modulator.name, ...
    "adaptive_optopatch.luminos_round_waveform", ...
    {rate,stateTable.round_start_sample,modSamples(keep),modValues(keep), ...
    stateTable.round_count,double(profile.modulator.dark_v)});

role=string({manifest.outputs.role});
neutral=manifest.outputs(role=="blue_dmd_advance_trigger").neutral_value;
width=stateTable.dmd_trigger_width_samples;
triggerSamples=reshape([repmat(width,height(states),1) ...
    states.duration_samples-width]',[],1);
triggerValues=repmat([1;0],height(states),1);
trigger=base_record("AdaptiveOptopatch DMD trigger",profile.dmd.trigger_port, ...
    "adaptive_optopatch.luminos_round_waveform", ...
    {rate,stateTable.round_start_sample,triggerSamples,triggerValues, ...
    stateTable.round_count,double(neutral)});

cycle=stateTable.cycle_samples;
summary=struct("schema_version","1.0.0", ...
    "state_table_source","dmd_sequence.state_table", ...
    "blanket_mod488_v",stateTable.blanket_mod488_v, ...
    "cycle_period_s",cycle/rate, ...
    "blanket_phase_s",stateTable.blanket_samples/rate, ...
    "target_phase_s",stateTable.target_samples/rate, ...
    "target_onset_guard_s",stateTable.target_onset_guard_samples/rate, ...
    ... % Zero for a recruitment sweep: its second state is the blank mask,
    ... % so no cycle delivers targeted light at all.
    "target_illuminated_fraction", ...
        any(states.state_type=="target")* ...
        (stateTable.target_samples-stateTable.target_onset_guard_samples)/cycle, ...
    "blanket_fraction",stateTable.blanket_samples/cycle, ...
    "schedule",string(stateTable.schedule), ...
    "epoch_cycles",stateTable.epoch_cycles, ...
    "gap_cycles",stateTable.gap_cycles, ...
    "states_per_round",stateTable.states_per_round, ...
    "round_count",stateTable.round_count, ...
    "expected_dmd_trigger_count",stateTable.expected_trigger_count, ...
    "round_start_sample",stateTable.round_start_sample, ...
    "final_sample",stateTable.final_sample, ...
    "dmd_trigger_lead_samples",stateTable.dmd_trigger_lead_samples);
end

function pulses=describe_blanket_delivery(pulses,stateTable,blanket)
% What each logical segment ACTUALLY delivered, measured from its own
% states, so nothing downstream can read a 20 ms row as a continuous 20 ms
% pulse - and so a recruitment sweep's segments say plainly that they
% delivered blanket light and no targeted light at all.
n=height(pulses);
states=stateTable.states;
rate=stateTable.sample_rate_hz;
lit=states.duration_samples-states.mod488_guard_samples;
% The table holds ONE programmed unit, which the DAQ repeats, so a round
% robin's later rounds have no states of their own: each logical segment
% takes the delivery of the unit segment at its own position. Pulses arrive
% sorted by onset, and the unit's segments are in that same order.
unitIds=unique(states.logical_pulse_id,"stable");
unitIds=unitIds(isfinite(unitIds));
if isempty(unitIds) || mod(n,numel(unitIds))~=0
    error("adaptive_optopatch:BlanketDeliveryMappingUnavailable", ...
        "The blanket state table describes %d logical segments, which does " + ...
        "not divide the acquisition's %d.",numel(unitIds),n);
end
unitTarget=zeros(numel(unitIds),1); unitBlanket=zeros(numel(unitIds),1);
unitLevel=nan(numel(unitIds),1);
for u=1:numel(unitIds)
    rows=states.logical_pulse_id==unitIds(u);
    unitTarget(u)=sum(lit(rows & states.state_type=="target"));
    unitBlanket(u)=sum(lit(rows & states.state_type=="blanket"));
    levels=unique(states.level_v(rows));
    if isscalar(levels), unitLevel(u)=levels; end
end
position=mod((0:n-1)',numel(unitIds))+1;
targetSamples=unitTarget(position);
blanketSamples=unitBlanket(position);
level=unitLevel(position);
pulses.blue_delivery=repmat("blanket_modulated",n,1);
pulses.target_illumination_s=targetSamples/rate;
pulses.blanket_illumination_s=blanketSamples/rate;
pulses.target_illuminated_fraction= ...
    repmat(blanket.target_illuminated_fraction,n,1);
pulses.blanket_mod488_v=repmat(blanket.blanket_mod488_v,n,1);
pulses.blanket_schedule=repmat(string(stateTable.schedule),n,1);
pulses.segment_level_v=level;
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
