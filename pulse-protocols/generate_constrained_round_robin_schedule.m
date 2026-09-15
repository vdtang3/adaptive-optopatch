function [events,metadata]=generate_constrained_round_robin_schedule( ...
        targetCellIds,pulsesPerCell,pulseDurationS,preferredGlobalSpacingS, ...
        minimumSameCellPostPulseGapS,commandVoltageV,options)
%GENERATE_CONSTRAINED_ROUND_ROBIN_SCHEDULE Realize a balanced event schedule.
arguments
    targetCellIds (:,1) string
    pulsesPerCell (1,1) double {mustBePositive,mustBeInteger}
    pulseDurationS (1,1) double {mustBePositive}
    preferredGlobalSpacingS (1,1) double {mustBePositive}
    minimumSameCellPostPulseGapS (1,1) double {mustBeNonnegative}
    commandVoltageV double
    options.PreDelayS (1,1) double {mustBeNonnegative} = 0.1
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
if isscalar(commandVoltageV)
    commandVoltageV=repmat(double(commandVoltageV),numel(targetCellIds),1);
else
    commandVoltageV=double(commandVoltageV(:));
end
if numel(commandVoltageV)~=numel(targetCellIds) || ...
        any(~isfinite(commandVoltageV) | commandVoltageV<=0)
    error("adaptive_optopatch:InvalidRoundRobinVoltage", ...
        "CommandVoltageV must be one positive value per target, or one shared value.");
end
if isfinite(options.RandomSeed) && ...
        (options.RandomSeed<0 || fix(options.RandomSeed)~=options.RandomSeed)
    error("adaptive_optopatch:InvalidRandomSeed", ...
        "RandomSeed must be a nonnegative integer or NaN for fresh randomness.");
end

nTargets=numel(targetCellIds); nEvents=nTargets*pulsesPerCell;
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
condition_id=repmat("round_robin",nEvents,1);
target_cell_id=targetCellIds(targetIndex);
duration_s=repmat(pulseDurationS,nEvents,1);
pulse_duration_s=duration_s;
offset_s=onsetS+duration_s;
onset_s=onsetS;
is_null=false(nEvents,1);
command_voltage_v=commandVoltageV(targetIndex);
blue_mask_adjustment_pixels=NaN(nEvents,1);
events=table(event_index,pulse_id,condition_id,target_cell_id,onset_s, ...
    pulse_duration_s,duration_s,offset_s,is_null,command_voltage_v, ...
    blue_mask_adjustment_pixels);

spacing=diff(onsetS);
extraIdle=max(0,spacing-preferredGlobalSpacingS);
metadata=struct( ...
    "requested_preferred_global_spacing_s",preferredGlobalSpacingS, ...
    "pulse_duration_s",pulseDurationS, ...
    "minimum_same_cell_post_pulse_gap_s",minimumSameCellPostPulseGapS, ...
    "same_cell_minimum_onset_interval_s",sameCellInterval, ...
    "realized_mean_event_spacing_s",mean(spacing), ...
    "realized_min_event_spacing_s",min([spacing;NaN],[],"omitmissing"), ...
    "realized_max_event_spacing_s",max([spacing;NaN],[],"omitmissing"), ...
    "idle_gap_count",sum(extraIdle>1e-12), ...
    "total_idle_time_s",sum(extraIdle), ...
    "pulses_per_cell",pulsesPerCell, ...
    "target_count",nTargets,"total_event_count",nEvents);
end
