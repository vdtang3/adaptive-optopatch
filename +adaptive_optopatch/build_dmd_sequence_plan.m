function plan=build_dmd_sequence_plan(protocol,targets)
%BUILD_DMD_SEQUENCE_PLAN Map resolved events to unique physical DMD masks.
arguments
    protocol (1,1) struct
    targets (1,1) struct
end
protocol=adaptive_optopatch.normalize_protocol(protocol); events=protocol.events;
required=["target_cell_id","target_index","dmd_pattern_index", ...
    "blue_mask_adjustment_pixels"];
if ~all(ismember(required,string(events.Properties.VariableNames)))
    error("adaptive_optopatch:UnresolvedDmdSequence", ...
        "Resolved target IDs and DMD pattern indices are required.");
end
n=height(events);
candidateMasks=false([size(targets.blank_dmd_mask),0]);
candidateKey=strings(0,1);
eventCandidate=zeros(n,1);
for k=1:n
    index=double(events.target_index(k)); adjustment=double(events.blue_mask_adjustment_pixels(k));
    if events.is_null(k)
        if index~=0, error("adaptive_optopatch:NullDmdPattern","Null pulses must use blank pattern index zero."); end
        key="blank";
    elseif index<1 || index>size(targets.dmd_camera_masks,3) || fix(index)~=index
        error("adaptive_optopatch:DmdPatternIndexMismatch", ...
            "Pulse %s has invalid DMD pattern index %g.",string(events.pulse_id(k)),index);
    else
        if string(targets.targets(index).cell_id)~=events.target_cell_id(k)
            error("adaptive_optopatch:DmdPatternTargetMismatch", ...
                "Pulse %s target does not match its DMD pattern.",string(events.pulse_id(k)));
        end
        key=string(index)+"|"+string(adjustment);
    end
    candidate=find(candidateKey==key,1);
    if isempty(candidate)
        if events.is_null(k)
            mask=logical(targets.blank_dmd_mask);
        else
            mask=adaptive_optopatch.apply_blue_mask_adjustment( ...
                targets.canonical_roi_masks(:,:,index),adjustment,"Context", ...
                sprintf("pulse %s, target %s",string(events.pulse_id(k)), ...
                events.target_cell_id(k)));
        end
        candidateKey(end+1,1)=key; %#ok<AGROW>
        candidateMasks(:,:,end+1)=logical(mask); %#ok<AGROW>
        candidate=numel(candidateKey);
    end
    eventCandidate(k)=candidate;
end

% Distinct target/adjustment pairs can still produce identical pixels. Slots
% are assigned from the actual final camera-space masks, not biological IDs.
uniqueMasks=false([size(targets.blank_dmd_mask),0]);
candidateSlot=zeros(numel(candidateKey),1);
for candidate=1:numel(candidateKey)
    slot=0;
    for existing=1:size(uniqueMasks,3)
        if isequal(candidateMasks(:,:,candidate),uniqueMasks(:,:,existing))
            slot=existing; break
        end
    end
    if slot==0
        uniqueMasks(:,:,end+1)=candidateMasks(:,:,candidate); %#ok<AGROW>
        slot=size(uniqueMasks,3);
    end
    candidateSlot(candidate)=slot;
end
eventSlots=candidateSlot(eventCandidate);
playlistSlots=eventSlots;
diagnostic=struct([]);
if isfield(protocol,"dmd_diagnostic")
    diagnostic=validate_dmd_diagnostic(protocol.dmd_diagnostic,events,eventSlots, ...
        size(uniqueMasks,3));
    playlistSlots=diagnostic.base_playlist_slots;
end
% Slave playback is armed before acquisition. Every playlist entry, including
% entry 1, is therefore selected by an explicit rising edge.
activationS=[0;events.offset_s(1:end-1)];
plan=struct("schema_version","2.0.0","unique_camera_masks",uniqueMasks, ...
    "reference_camera",targets.reference_camera, ...
    "pattern_count",n,"event_count",n,"unique_mask_count",size(uniqueMasks,3), ...
    "pulse_id",events.pulse_id,"event_slot_indices",eventSlots, ...
    "programmed_playlist_slots",playlistSlots, ...
    "programmed_playlist_length",numel(playlistSlots), ...
    "stack_pattern_number",eventSlots, ...
    "target_cell_id",events.target_cell_id, ...
    "dmd_pattern_index",events.dmd_pattern_index, ...
    "pattern_activation_s",activationS, ...
    "dmd_trigger_s",activationS, ...
    "trigger_associated_pulse_id",events.pulse_id, ...
    "trigger_target_cell_id",events.target_cell_id, ...
    "initialization_trigger_s",activationS(1), ...
    "advance_onset_s",events.offset_s(1:end-1), ...
    "no_artificial_settle_interval",true);
if ~isempty(diagnostic)
    plan.dmd_diagnostic=diagnostic;
end
end

function diagnostic=validate_dmd_diagnostic(value,events,eventSlots,uniqueCount)
required=["diagnostic_name","base_playlist_slots","base_playlist_length", ...
    "dmd_trigger_count","expected_wrapped_slots"];
if ~isstruct(value) || ~isscalar(value) || ...
        ~all(isfield(value,cellstr(required))) || ...
        string(value.diagnostic_name)~="dmd_flut_wrap"
    error("adaptive_optopatch:InvalidDmdDiagnostic", ...
        "The DMD diagnostic descriptor is missing or unsupported.");
end
base=double(value.base_playlist_slots(:));
expected=double(value.expected_wrapped_slots(:));
if uniqueCount~=3 || ~isequal(base,(1:3)') || ...
        double(value.base_playlist_length)~=3 || ...
        double(value.dmd_trigger_count)~=height(events) || ...
        ~isequal(expected,eventSlots) || numel(expected)~=height(events)
    error("adaptive_optopatch:InvalidDmdFlutWrapDiagnostic", ...
        ["The dmd_flut_wrap diagnostic requires three distinct masks, base " ...
         "playlist [1 2 3], and one expected wrapped slot per event."]);
end
slotTargets=strings(3,1);
for slot=1:3
    event=find(eventSlots==slot,1);
    slotTargets(slot)=events.target_cell_id(event);
end
diagnostic=value;
diagnostic.base_playlist_slots=base;
diagnostic.expected_wrapped_slots=expected;
diagnostic.slot_target_cell_ids=slotTargets;
diagnostic.event_onset_s=double(events.onset_s(:));
diagnostic.pulse_duration_s=unique(double(events.duration_s));
diagnostic.command_voltage_v=unique(double(events.command_voltage_v));
end
