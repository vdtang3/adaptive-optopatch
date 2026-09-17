function [events,metadata]=generate_constrained_round_robin_schedule( ...
        targetCellIds,pulsesPerCell,pulseDurationS,preferredGlobalSpacingS, ...
        minimumSameCellPostPulseGapS,commandVoltageV,options)
%GENERATE_CONSTRAINED_ROUND_ROBIN_SCHEDULE Realize the 1P connectivity schedule.
%
%   This is the pure scheduling helper behind
%   pulse-protocols/create_connectivity_round_robin_protocol.m, the canonical
%   1P connectivity screen. It realizes one explicit multi-target event table:
%   every target receives exactly PULSESPERCELL pulses, the global cadence
%   tries to advance by PREFERREDGLOBALSPACINGS after every event, and a
%   target is only revisited once
%
%       previous offset + MINIMUMSAMECELLPOSTPULSEGAPS
%
%   has elapsed. With the canonical 10 ms pulse and 100 ms recovery that is a
%   110 ms minimum same-cell onset interval. While one target is refractory
%   the scheduler stimulates other eligible targets, and it inserts idle time
%   only when no target is eligible. The recovery rule is never weakened.
%
%   COMMANDVOLTAGEV is normally NaN, which leaves the event voltage
%   unresolved so schema-4 1P resolution reaches the per-cell calibrated Blue
%   voltage stored in the FOV (fov_cell). A finite scalar, or one finite value
%   per target, is supported as an explicit override and must lie in (0,5] V.
%   NaN is never silently converted into a voltage.
%
%   Adaptive Optopatch executes the returned table literally. It does not
%   reorder, retime, or recreate this schedule.
arguments
    targetCellIds (:,1) string
    pulsesPerCell (1,1) double {mustBePositive,mustBeInteger} = 1000
    pulseDurationS (1,1) double {mustBePositive} = 0.010
    preferredGlobalSpacingS (1,1) double {mustBePositive} = 0.020
    minimumSameCellPostPulseGapS (1,1) double {mustBeNonnegative} = 0.100
    commandVoltageV double = NaN
    options.PreDelayS (1,1) double {mustBeNonnegative} = 0.1
    options.ConditionId (1,1) string = "connectivity_round_robin"
    options.RandomSeed (1,1) double = NaN
end
targetCellIds=strip(targetCellIds);
if isempty(targetCellIds) || any(strlength(targetCellIds)==0) || ...
        numel(unique(targetCellIds))~=numel(targetCellIds)
    error("adaptive_optopatch:InvalidRoundRobinTargets", ...
        "TargetCellIds must contain distinct, nonempty cell IDs.");
end
if preferredGlobalSpacingS<pulseDurationS-1e-12
    error("adaptive_optopatch:OverlappingRoundRobinPulses", ...
        "Preferred global spacing must be at least the pulse duration.");
end
nTargets=numel(targetCellIds);
commandVoltageV=normalize_target_voltage(commandVoltageV,nTargets);
if isfinite(options.RandomSeed) && ...
        (options.RandomSeed<0 || fix(options.RandomSeed)~=options.RandomSeed)
    error("adaptive_optopatch:InvalidRandomSeed", ...
        "RandomSeed must be a nonnegative integer or NaN for fresh randomness.");
end

nEvents=nTargets*pulsesPerCell;
remaining=repmat(pulsesPerCell,nTargets,1);
lastOnset=-Inf(nTargets,1);
targetIndex=zeros(nEvents,1); onsetS=zeros(nEvents,1);
sameCellInterval=pulseDurationS+minimumSameCellPostPulseGapS;
if isfinite(options.RandomSeed)
    stream=RandStream("mt19937ar","Seed",options.RandomSeed);
else
    stream=RandStream.getGlobalStream();
end

candidateTime=options.PreDelayS;
for eventIndex=1:nEvents
    eligible=find(remaining>0 & ...
        lastOnset+sameCellInterval<=candidateTime+1e-12);
    if isempty(eligible)
        candidateTime=min(lastOnset(remaining>0)+sameCellInterval);
        eligible=find(remaining>0 & ...
            lastOnset+sameCellInterval<=candidateTime+1e-12);
    end
    % Choosing among the largest remaining quotas keeps the tail balanced.
    % Idle time makes the construction always feasible, so no biological
    % constraint is weakened when a target is temporarily ineligible.
    largest=max(remaining(eligible));
    balanced=eligible(remaining(eligible)==largest);
    selected=balanced(randi(stream,numel(balanced)));
    targetIndex(eventIndex)=selected;
    onsetS(eventIndex)=candidateTime;
    remaining(selected)=remaining(selected)-1;
    lastOnset(selected)=candidateTime;
    candidateTime=candidateTime+preferredGlobalSpacingS;
end

event_index=(1:nEvents)';
pulse_id=event_index;
condition_id=repmat(options.ConditionId,nEvents,1);
stimulation_source=repmat("1p_dmd",nEvents,1);
target_cell_id=targetCellIds(targetIndex);
duration_s=repmat(pulseDurationS,nEvents,1);
pulse_duration_s=duration_s;
onset_s=onsetS;
offset_s=onset_s+duration_s;
is_null=false(nEvents,1);
command_voltage_v=commandVoltageV(targetIndex);
blue_mask_adjustment_pixels=NaN(nEvents,1);
events=table(event_index,pulse_id,condition_id,stimulation_source,target_cell_id,onset_s, ...
    pulse_duration_s,duration_s,offset_s,is_null,command_voltage_v, ...
    blue_mask_adjustment_pixels);

spacing=diff(onsetS);
extraIdle=max(0,spacing-preferredGlobalSpacingS);
extraIdle(extraIdle<1e-9)=0;
metadata=struct( ...
    "pulses_per_cell",pulsesPerCell, ...
    "target_count",nTargets, ...
    "total_event_count",nEvents, ...
    "pulse_duration_s",pulseDurationS, ...
    "requested_preferred_global_spacing_s",preferredGlobalSpacingS, ...
    "minimum_same_cell_post_pulse_gap_s",minimumSameCellPostPulseGapS, ...
    "same_cell_minimum_onset_interval_s",sameCellInterval, ...
    "realized_mean_event_spacing_s",mean(spacing), ...
    "realized_min_event_spacing_s",min([spacing;NaN],[],"omitmissing"), ...
    "realized_max_event_spacing_s",max([spacing;NaN],[],"omitmissing"), ...
    "idle_gap_count",sum(extraIdle>0), ...
    "total_idle_time_s",sum(extraIdle), ...
    "pre_delay_s",options.PreDelayS, ...
    "schedule_end_s",offset_s(end), ...
    "random_seed",options.RandomSeed);
end

function voltage=normalize_target_voltage(voltage,nTargets)
% NaN means "no event-level opinion": schema-4 1P resolution then falls
% through to the per-cell calibrated Blue voltage (fov_cell). It is never
% replaced with a number here, and resolve_protocol keeps owning precedence.
if isscalar(voltage)
    voltage=repmat(double(voltage),nTargets,1);
else
    voltage=double(voltage(:));
end
if numel(voltage)~=nTargets
    error("adaptive_optopatch:InvalidRoundRobinVoltage", ...
        "CommandVoltageV must be one value per target, or one shared value.");
end
explicit=~isnan(voltage);
if any(explicit & (~isfinite(voltage) | voltage<=0 | voltage>5))
    error("adaptive_optopatch:InvalidRoundRobinVoltage", ...
        "CommandVoltageV entries must be NaN, which defers to the normal 1P "+ ...
        "resolver, or an explicit override in (0,5] V.");
end
end
