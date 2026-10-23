function [events,metadata]=generate_blanket_sweep_schedule(schedule,scheduler,options)
%GENERATE_BLANKET_SWEEP_SCHEDULE Logical segments of a blanket calibration sweep.
%   [events,metadata]=GENERATE_BLANKET_SWEEP_SCHEDULE(schedule,scheduler)
%   realizes the logical segment table of one blanket calibration sweep. The
%   schedule is "recruitment_sweep" or "population_target_sweep"; the
%   scheduler is its normalized ACQUISITION_SCHEDULER_SPEC.
%
%   ONE ROW PER LOGICAL SEGMENT, never one per modulation cycle or DMD
%   state. BUILD_BLANKET_STATE_TABLE expands the 0.2/0.8 ms states for the
%   DMD and the DAQ, and analysis keeps seeing these rows.
%
%   recruitment_sweep. One NULL event per voltage step: the sweep delivers
%   no targeted stimulation at all, only the blanket phase, so no row may
%   claim a target or a stimulation command. The step's blanket level lives
%   in the archived sweep block, which is what the blanket state table and
%   the mod488 waveform are built from.
%
%       pre_dark_s dark, then levels_v(1) for step_duration_s, then
%       levels_v(2), ... and the acquisition ends with the last step.
%
%   population_target_sweep. One non-null event per target epoch, carrying
%   that epoch's target voltage. Its target is the union of the selected
%   cells' masks, which is a property of the acquisition rather than of one
%   cell, so the rows name the sentinel target "population" with target
%   index 0 - the same shape the simultaneous policy uses for "multiple".
%
%       pre_delay_s, then for each level, repetitions_per_level epochs of
%       epoch_duration_s separated and followed by inter_epoch_gap_s.
%
%   See also BUILD_BLANKET_STATE_TABLE, BLANKET_DEPOLARIZATION_SPEC.
arguments
    schedule (1,1) string {mustBeMember(schedule, ...
        ["recruitment_sweep","population_target_sweep"])}
    scheduler (1,1) struct
    options.ConditionId (1,1) string = "blanket_sweep"
end
levels=reshape(double(scheduler.levels_v),[],1);
nLevels=numel(levels);
if schedule=="recruitment_sweep"
    levelIndex=(1:nLevels)';
    repetition=ones(nLevels,1);
    segmentDuration=scheduler.step_duration_s;
    gap=0;
    start=scheduler.pre_dark_s;
else
    levelIndex=repelem((1:nLevels)',scheduler.repetitions_per_level);
    repetition=repmat((1:scheduler.repetitions_per_level)',nLevels,1);
    segmentDuration=scheduler.epoch_duration_s;
    gap=scheduler.inter_epoch_gap_s;
    start=scheduler.pre_delay_s;
end
n=numel(levelIndex);
onset_s=start+(0:n-1)'*(segmentDuration+gap);

event_index=(1:n)';
pulse_id=event_index;
condition_id=repmat(options.ConditionId,n,1);
duration_s=repmat(segmentDuration,n,1);
pulse_duration_s=duration_s;
offset_s=onset_s+duration_s;
blue_mask_adjustment_pixels=NaN(n,1);
level_index=levelIndex;
level_v=levels(levelIndex);
repetition_index=repetition;
if schedule=="recruitment_sweep"
    % Null: no target, no commanded stimulation voltage. The blanket level
    % is the sweep's, not this row's.
    stimulation_source=repmat("none",n,1);
    target_cell_id=repmat("",n,1);
    is_null=true(n,1);
    command_voltage_v=zeros(n,1);
else
    stimulation_source=repmat("1p_dmd",n,1);
    target_cell_id=repmat("population",n,1);
    is_null=false(n,1);
    command_voltage_v=level_v;
end
events=table(event_index,pulse_id,condition_id,stimulation_source,target_cell_id, ...
    onset_s,pulse_duration_s,duration_s,offset_s,is_null,command_voltage_v, ...
    blue_mask_adjustment_pixels,level_index,level_v,repetition_index);

metadata=struct( ...
    "schedule",schedule, ...
    "levels_v",levels, ...
    "level_count",nLevels, ...
    "segment_count",n, ...
    "segment_duration_s",segmentDuration, ...
    "inter_segment_gap_s",gap, ...
    "start_s",start, ...
    "schedule_end_s",offset_s(end), ...
    ... % Every segment is followed by its gap, including the last, so the
    ... % programmed unit is a whole number of identical slots and the DMD
    ... % playlist is one slot rather than the entire sweep.
    "program_end_s",start+n*(segmentDuration+gap), ...
    "pulses_per_cell",n);
end
