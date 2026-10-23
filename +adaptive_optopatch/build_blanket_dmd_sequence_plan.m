function plan=build_blanket_dmd_sequence_plan(protocol,targets,stateTable)
%BUILD_BLANKET_DMD_SEQUENCE_PLAN One wrapping FLUT round from the state table.
%   plan=BUILD_BLANKET_DMD_SEQUENCE_PLAN(protocol,targets,stateTable) maps
%   every state of one blanket round onto a deduplicated camera-space mask
%   and returns a plan prepare_luminos_dmd_sequence programs exactly as it
%   programs any FLUT plan: unique masks uploaded once, one playlist entry
%   per state, slave mode, one DAQ trigger per entry.
%
%   THE PLAYLIST IS ONE ROUND AND IS MEANT TO WRAP (playlist_wraps=true).
%   Round r is the ALP replaying the same entries after wrapping, which the
%   VU FLUT diagnostics of 2026-09-17 and 2026-09-23 showed it does in slave
%   mode. Nothing expands the rounds into the playlist.
%
%   THE MASKS. Three kinds, all in the target bundle's camera coordinates so
%   they go through the one camera-to-DMD remapping every mask uses:
%     blanket  true over the whole camera grid (targets.blank_dmd_mask's
%              size): the full camera FOV, projected through the same
%              calibration as each soma mask
%     blank    targets.blank_dmd_mask, the existing null pattern
%     target   apply_blue_mask_adjustment of the canonical ROI, exactly as
%              the ordinary FLUT path builds it
%   and they are deduplicated by their pixels, as build_dmd_sequence_plan
%   does, so a repeated state reuses its slot.
%
%   See also BUILD_BLANKET_STATE_TABLE, BUILD_DMD_SEQUENCE_PLAN.
arguments
    protocol (1,1) struct
    targets (1,1) struct
    stateTable (1,1) struct
end
states=stateTable.states; L=height(states);
blanket=adaptive_optopatch.blanket_depolarization_spec(protocol);
keys=unique(states.mask_key,"stable");
candidateMasks=false([size(targets.blank_dmd_mask),numel(keys)]);
for k=1:numel(keys)
    candidateMasks(:,:,k)=mask_for_key(keys(k),states,targets,blanket);
end
uniqueMasks=false([size(targets.blank_dmd_mask),0]);
keySlot=zeros(numel(keys),1);
for k=1:numel(keys)
    slot=0;
    for existing=1:size(uniqueMasks,3)
        if isequal(candidateMasks(:,:,k),uniqueMasks(:,:,existing))
            slot=existing; break
        end
    end
    if slot==0
        uniqueMasks(:,:,end+1)=candidateMasks(:,:,k); %#ok<AGROW>
        slot=size(uniqueMasks,3);
    end
    keySlot(k)=slot;
end
[~,keyIndex]=ismember(states.mask_key,keys);
slotSequence=keySlot(keyIndex);
slotKeys=strings(size(uniqueMasks,3),1);
for slot=1:numel(slotKeys)
    slotKeys(slot)=strjoin(keys(keySlot==slot),",");
end

% THE PLAYLIST IS THE SHORTEST UNIT THE MASK SEQUENCE REPEATS, because the
% ALP wraps it. A round robin's masks change from cell to cell, so that unit
% is the whole round. A calibration sweep's do not change at all between
% levels - only mod488 does - so it is one cycle (recruitment) or one epoch
% plus its gap (population target), and a sweep of any length fits the FLUT.
% Period p must divide the programmed unit, or wrapping would not reproduce
% the sequence.
playlistPeriod=L;
for p=1:L
    if mod(L,p)~=0, continue; end
    if isequal(slotSequence,repmat(slotSequence(1:p),L/p,1))
        playlistPeriod=p; break
    end
end
playlist=slotSequence(1:playlistPeriod);

rate=stateTable.sample_rate_hz;
roundStart=stateTable.round_start_sample;
% The first round's trigger times plus the first trigger of the second
% round, so the wrap interval is checked against the ALP minimum picture
% time along with every other interval in prepare_luminos_dmd_sequence.
triggerSamples=[roundStart+states.start_sample; ...
    roundStart+stateTable.round_samples];
triggerPulse=[states.logical_pulse_id;states.logical_pulse_id(1)];
triggerTarget=[states.target_cell_id;states.target_cell_id(1)];
events=sortrows(protocol.events,"onset_s");

plan=struct("schema_version","2.1.0","unique_camera_masks",uniqueMasks, ...
    "reference_camera",targets.reference_camera, ...
    "pattern_count",L,"event_count",height(events), ...
    "unique_mask_count",size(uniqueMasks,3), ...
    "pulse_id",events.pulse_id, ...
    "event_slot_indices",slotSequence, ...
    "programmed_playlist_slots",playlist, ...
    "programmed_playlist_length",playlistPeriod, ...
    "playlist_repeats_per_round",L/playlistPeriod, ...
    "stack_pattern_number",slotSequence, ...
    "slot_mask_keys",slotKeys, ...
    "target_cell_id",events.target_cell_id, ...
    "dmd_pattern_index",events.dmd_pattern_index, ...
    "pattern_activation_s",triggerSamples(1:L)/rate, ...
    "dmd_trigger_s",triggerSamples/rate, ...
    "dmd_trigger_scope","first_round_and_wrap", ...
    "trigger_associated_pulse_id",triggerPulse, ...
    "trigger_target_cell_id",triggerTarget, ...
    "initialization_trigger_s",roundStart/rate, ...
    "trigger_lead_s",0, ...
    "projection_mode","slave", ...
    "no_artificial_settle_interval",true, ...
    "playlist_wraps",true, ...
    "round_count",stateTable.round_count, ...
    "expected_trigger_count",stateTable.expected_trigger_count, ...
    "blanket_depolarization",blanket, ...
    "state_table",stateTable);
end

function mask=union_of_cells(cellIds,indices,adjustment,targets,context)
%UNION_OF_CELLS Union of the named cells' own stimulation masks.
%   Each is built with APPLY_BLUE_MASK_ADJUSTMENT, the primitive a targeted
%   pulse uses, and the union is carried through the one camera-to-DMD
%   transform in PREPARE_LUMINOS_DMD_SEQUENCE like every other mask. There
%   is no second coordinate path.
mask=false(size(targets.blank_dmd_mask));
for k=1:numel(indices)
    index=indices(k);
    if index<1 || index>size(targets.canonical_roi_masks,3) || fix(index)~=index
        error("adaptive_optopatch:DmdPatternIndexMismatch", ...
            "%s cell %s has invalid target index %g.",context,cellIds(k),index);
    end
    if string(targets.targets(index).cell_id)~=cellIds(k)
        error("adaptive_optopatch:DmdPatternTargetMismatch", ...
            "%s cell %s does not match its target geometry.",context,cellIds(k));
    end
    mask=mask | adaptive_optopatch.apply_blue_mask_adjustment( ...
        targets.canonical_roi_masks(:,:,index),adjustment,"Context", ...
        sprintf("%s cell %s",context,cellIds(k)));
end
if ~any(mask(:))
    error("adaptive_optopatch:EmptyBlanketUnionMask", ...
        "The %s union mask is empty.",context);
end
end

function mask=mask_for_key(key,states,targets,blanket)
if key=="blanket"
    % The union of the Stim-enabled cells' own masks. Every cell the
    % acquisition addresses keeps its depolarization through another cell's
    % pulse, and the tissue between them is not lit.
    mask=union_of_cells(blanket.mask.cell_ids,blanket.mask.target_indices, ...
        blanket.mask.blue_mask_adjustment_pixels,targets,"blanket");
    return
end
if key=="blank"
    mask=logical(targets.blank_dmd_mask);
    return
end
if key=="population"
    % The same union the blanket phase uses, at the sweep's target level
    % rather than the blanket level, so a population epoch is the blanket
    % geometry driven harder. Identical pixels deduplicate to one slot.
    sweep=blanket.sweep;
    mask=union_of_cells(sweep.population_cell_ids, ...
        sweep.population_target_indices,sweep.blue_mask_adjustment_pixels, ...
        targets,"population target");
    return
end
row=find(states.mask_key==key,1);
index=states.target_index(row);
adjustment=states.blue_mask_adjustment_pixels(row);
cellId=states.target_cell_id(row);
if index<1 || index>size(targets.canonical_roi_masks,3) || fix(index)~=index
    error("adaptive_optopatch:DmdPatternIndexMismatch", ...
        "Blanket target %s has invalid target index %g.",cellId,index);
end
if string(targets.targets(index).cell_id)~=cellId
    error("adaptive_optopatch:DmdPatternTargetMismatch", ...
        "Blanket target %s does not match its target geometry.",cellId);
end
mask=adaptive_optopatch.apply_blue_mask_adjustment( ...
    targets.canonical_roi_masks(:,:,index),adjustment,"Context", ...
    sprintf("blanket round target %s",cellId));
end
