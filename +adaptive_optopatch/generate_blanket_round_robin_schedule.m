function [events,metadata]=generate_blanket_round_robin_schedule( ...
        targetCellIds,rounds,epochDurationS,interEpochGapS,commandVoltageV,options)
%GENERATE_BLANKET_ROUND_ROBIN_SCHEDULE One fixed round, repeated whole.
%   [events,metadata]=GENERATE_BLANKET_ROUND_ROBIN_SCHEDULE(ids,rounds,
%   epochS,gapS,commandV) realizes the blanket-depolarization round robin:
%
%       cell 1 epoch, gap, cell 2 epoch, gap, ..., cell N epoch, gap
%
%   repeated `rounds` times with no other pause, starting at PreDelayS. The
%   order is the order of targetCellIds - the FOV's own cell order, as
%   resolve_protocol passes it - and never changes between rounds, because
%   the DMD stores one round as its playlist and wraps it.
%
%   One row per TARGET EPOCH. The 0.2/0.8 ms modulation states inside an
%   epoch are not events; build_blanket_state_table expands them for the DMD
%   and the DAQ only, so analysis still sees one trial per epoch.
%
%   The trailing gap after cell N belongs to the round, so a round is
%   N x (epoch + gap) long and round r starts at PreDelayS + (r-1) x period.
%
%   See also BUILD_BLANKET_STATE_TABLE, BLANKET_DEPOLARIZATION_SPEC.
arguments
    targetCellIds (:,1) string
    rounds (1,1) double {mustBePositive,mustBeInteger}
    epochDurationS (1,1) double {mustBePositive}
    interEpochGapS (1,1) double {mustBePositive}
    commandVoltageV (1,1) double = NaN
    options.PreDelayS (1,1) double {mustBeNonnegative} = 0.1
    options.ConditionId (1,1) string = "blanket_round_robin"
end
targetCellIds=strip(targetCellIds);
if isempty(targetCellIds) || any(strlength(targetCellIds)==0) || ...
        numel(unique(targetCellIds))~=numel(targetCellIds)
    error("adaptive_optopatch:InvalidRoundRobinTargets", ...
        "TargetCellIds must contain distinct, nonempty cell IDs.");
end
nTargets=numel(targetCellIds);
nEvents=nTargets*rounds;
slotS=epochDurationS+interEpochGapS;
periodS=nTargets*slotS;
position=repmat((1:nTargets)',rounds,1);
round_index=reshape(repelem(1:rounds,nTargets),[],1);

event_index=(1:nEvents)';
pulse_id=event_index;
condition_id=repmat(options.ConditionId,nEvents,1);
stimulation_source=repmat("1p_dmd",nEvents,1);
target_cell_id=targetCellIds(position);
onset_s=options.PreDelayS+(round_index-1)*periodS+(position-1)*slotS;
duration_s=repmat(epochDurationS,nEvents,1);
pulse_duration_s=duration_s;
offset_s=onset_s+duration_s;
is_null=false(nEvents,1);
command_voltage_v=repmat(commandVoltageV,nEvents,1);
blue_mask_adjustment_pixels=NaN(nEvents,1);
position_in_round=position;
events=table(event_index,pulse_id,condition_id,stimulation_source,target_cell_id, ...
    onset_s,pulse_duration_s,duration_s,offset_s,is_null,command_voltage_v, ...
    blue_mask_adjustment_pixels,round_index,position_in_round);

metadata=struct( ...
    "pulses_per_cell",rounds, ...
    "target_count",nTargets, ...
    "total_event_count",nEvents, ...
    "pulse_duration_s",epochDurationS, ...
    "inter_epoch_gap_s",interEpochGapS, ...
    "round_period_s",periodS, ...
    "round_count",rounds, ...
    "pre_delay_s",options.PreDelayS, ...
    "schedule_end_s",options.PreDelayS+rounds*periodS, ...
    "cell_order",targetCellIds);
end
