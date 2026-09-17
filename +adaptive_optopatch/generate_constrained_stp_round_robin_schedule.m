function [events,metadata]=generate_constrained_stp_round_robin_schedule( ...
        targetCellIds,trainsPerCell,pulsesPerTrain,frequencyHz,pulseDurationS, ...
        preferredInterTrainGapS,minimumSameCellPostTrainGapS,commandVoltageV,options)
%GENERATE_CONSTRAINED_STP_ROUND_ROBIN_SCHEDULE Realize the 1P STP screen schedule.
%
%   This is the pure scheduling helper behind
%   pulse-protocols/create_stp_screen_protocol.m. It realizes one explicit
%   multi-target event table in which the unit of scheduling is a whole TRAIN.
%
%   DIFFERENT TARGETS ARE INTERLEAVED AT TRAIN GRANULARITY ONLY.
%
%   One target's complete P1..P5 train is emitted contiguously and no other
%   target may hold an event between that target's first and last pulse. The
%   schedule deliberately does NOT produce a pulse-level interleaving such as
%
%       ROI1-P1, ROI2-P1, ROI1-P2, ROI2-P2, ...
%
%   Pulse-level interleaving would repeat a millisecond-scale spike pairing
%   between the same two stimulated neurons hundreds of times, which is the
%   induction protocol for spike-timing-dependent plasticity. The screen
%   measures short-term facilitation or depression, so a long-term plasticity
%   confound deliberately engineered into the stimulus would be indefensible.
%   The code does not model STDP; it only preserves the whole-train decision.
%
%   Timing within a train is exact: pulse k starts at (k-1)/FREQUENCYHZ after
%   the train start, so the default 5-pulse 20 Hz 10 ms train spans
%   0 / 50 / 100 / 150 / 200 ms and ends at 210 ms.
%
%   Across trains the scheduler tries to start the next train
%   PREFERREDINTERTRAINGAPS after the previous train ends, and a target is
%   only given another train once
%
%       its previous train end + MINIMUMSAMECELLPOSTTRAINGAPS
%
%   has elapsed. Other targets' trains fill that recovery window; idle time is
%   inserted only when no target is eligible. The recovery rule is never
%   weakened.
%
%   COMMANDVOLTAGEV is normally NaN, which leaves the event voltage
%   unresolved so schema-4 1P resolution reaches the per-cell calibrated Blue
%   voltage stored in the FOV (fov_cell). A finite scalar, or one finite value
%   per target, is supported as an explicit override and must lie in (0,5] V.
%   NaN is never silently converted into a voltage.
%
%   Adaptive Optopatch executes the returned table literally.
arguments
    targetCellIds (:,1) string
    trainsPerCell (1,1) double {mustBePositive,mustBeInteger} = 300
    pulsesPerTrain (1,1) double {mustBePositive,mustBeInteger} = 5
    frequencyHz (1,1) double {mustBePositive} = 20
    pulseDurationS (1,1) double {mustBePositive} = 0.010
    preferredInterTrainGapS (1,1) double {mustBeNonnegative} = 0.020
    minimumSameCellPostTrainGapS (1,1) double {mustBeNonnegative} = 1.000
    commandVoltageV double = NaN
    options.PreDelayS (1,1) double {mustBeNonnegative} = 0.1
    options.ConditionId (1,1) string = ""
    options.RandomSeed (1,1) double = NaN
end
targetCellIds=strip(targetCellIds);
if isempty(targetCellIds) || any(strlength(targetCellIds)==0) || ...
        numel(unique(targetCellIds))~=numel(targetCellIds)
    error("adaptive_optopatch:InvalidStpTargets", ...
        "TargetCellIds must contain distinct, nonempty cell IDs.");
end
pulsePeriodS=1/frequencyHz;
if pulsesPerTrain>1 && pulseDurationS>=pulsePeriodS-1e-12
    error("adaptive_optopatch:OverlappingStpPulses", ...
        "Pulse duration must be shorter than the %.4g s pulse period.",pulsePeriodS);
end
nTargets=numel(targetCellIds);
commandVoltageV=normalize_target_voltage(commandVoltageV,nTargets);
if isfinite(options.RandomSeed) && ...
        (options.RandomSeed<0 || fix(options.RandomSeed)~=options.RandomSeed)
    error("adaptive_optopatch:InvalidRandomSeed", ...
        "RandomSeed must be a nonnegative integer or NaN for fresh randomness.");
end
conditionId=options.ConditionId;
if strlength(conditionId)==0
    conditionId=sprintf("stp_%ghz_%dpulse",frequencyHz,pulsesPerTrain);
end

localOnsetS=(0:pulsesPerTrain-1)'*pulsePeriodS;
trainDurationS=localOnsetS(end)+pulseDurationS;
sameCellTrainInterval=trainDurationS+minimumSameCellPostTrainGapS;
nTrains=nTargets*trainsPerCell;
remaining=repmat(trainsPerCell,nTargets,1);
lastTrainEnd=-Inf(nTargets,1);
trainTarget=zeros(nTrains,1); trainStartS=zeros(nTrains,1);
trainRepeat=zeros(nTrains,1);
if isfinite(options.RandomSeed)
    stream=RandStream("mt19937ar","Seed",options.RandomSeed);
else
    stream=RandStream.getGlobalStream();
end

candidateTime=options.PreDelayS;
for trainIndex=1:nTrains
    eligible=find(remaining>0 & ...
        lastTrainEnd+minimumSameCellPostTrainGapS<=candidateTime+1e-12);
    if isempty(eligible)
        % Nobody has finished recovering. Jump to the earliest legal train
        % start rather than shortening anyone's recovery window.
        candidateTime=min(lastTrainEnd(remaining>0))+minimumSameCellPostTrainGapS;
        eligible=find(remaining>0 & ...
            lastTrainEnd+minimumSameCellPostTrainGapS<=candidateTime+1e-12);
    end
    % Choosing among the largest remaining quotas keeps the tail balanced;
    % the random tiebreak keeps train order unpredictable across targets.
    largest=max(remaining(eligible));
    balanced=eligible(remaining(eligible)==largest);
    selected=balanced(randi(stream,numel(balanced)));
    trainTarget(trainIndex)=selected;
    trainStartS(trainIndex)=candidateTime;
    trainRepeat(trainIndex)=trainsPerCell-remaining(selected)+1;
    remaining(selected)=remaining(selected)-1;
    lastTrainEnd(selected)=candidateTime+trainDurationS;
    candidateTime=candidateTime+trainDurationS+preferredInterTrainGapS;
end

% Emit every pulse of a train contiguously. Column-major expansion keeps all
% pulses of train j adjacent, which is what makes the whole-train decision
% visible in the frozen event table rather than only in this function.
nEvents=nTrains*pulsesPerTrain;
event_index=(1:nEvents)';
pulse_id=event_index;
condition_id=repmat(conditionId,nEvents,1);
stimulation_source=repmat("1p_dmd",nEvents,1);
targetIndex=repelem(trainTarget,pulsesPerTrain);
target_cell_id=targetCellIds(targetIndex);
onset_s=reshape(trainStartS'+localOnsetS,nEvents,1);
duration_s=repmat(pulseDurationS,nEvents,1);
pulse_duration_s=duration_s;
offset_s=onset_s+duration_s;
is_null=false(nEvents,1);
command_voltage_v=commandVoltageV(targetIndex);
blue_mask_adjustment_pixels=NaN(nEvents,1);
train_id=repelem((1:nTrains)',pulsesPerTrain);
pulse_in_train=repmat((1:pulsesPerTrain)',nTrains,1);
repeat_index=repelem(trainRepeat,pulsesPerTrain);
frequency_hz=repmat(frequencyHz,nEvents,1);
events=table(event_index,pulse_id,condition_id,stimulation_source,target_cell_id, ...
    onset_s,pulse_duration_s,duration_s,offset_s,is_null,command_voltage_v, ...
    blue_mask_adjustment_pixels,train_id,pulse_in_train,repeat_index,frequency_hz);

trainSpacing=diff(trainStartS);
extraIdle=max(0,trainSpacing-(trainDurationS+preferredInterTrainGapS));
extraIdle(extraIdle<1e-9)=0;
metadata=struct( ...
    "trains_per_cell",trainsPerCell, ...
    "pulses_per_train",pulsesPerTrain, ...
    "frequency_hz",frequencyHz, ...
    "pulse_duration_s",pulseDurationS, ...
    "train_duration_s",trainDurationS, ...
    "preferred_inter_train_gap_s",preferredInterTrainGapS, ...
    "minimum_same_cell_post_train_gap_s",minimumSameCellPostTrainGapS, ...
    "same_cell_minimum_train_onset_interval_s",sameCellTrainInterval, ...
    "target_count",nTargets, ...
    "total_train_count",nTrains, ...
    "total_event_count",nEvents, ...
    "pulses_per_cell",trainsPerCell*pulsesPerTrain, ...
    "realized_mean_train_start_spacing_s",mean(trainSpacing), ...
    "realized_min_train_start_spacing_s",min([trainSpacing;NaN],[],"omitmissing"), ...
    "realized_max_train_start_spacing_s",max([trainSpacing;NaN],[],"omitmissing"), ...
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
    error("adaptive_optopatch:InvalidStpVoltage", ...
        "CommandVoltageV must be one value per target, or one shared value.");
end
explicit=~isnan(voltage);
if any(explicit & (~isfinite(voltage) | voltage<=0 | voltage>5))
    error("adaptive_optopatch:InvalidStpVoltage", ...
        "CommandVoltageV entries must be NaN, which defers to the normal 1P "+ ...
        "resolver, or an explicit override in (0,5] V.");
end
end
