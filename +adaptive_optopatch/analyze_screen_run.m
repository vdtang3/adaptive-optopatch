function analysis = analyze_screen_run(run, reference, options)
%ANALYZE_SCREEN_RUN Extract all completed screen movies and score connectivity.
arguments
    run (1,1) struct
    reference (1,1) struct
    options.BackgroundMode (1,1) string = "local_annulus"
    options.NullRoiMask = []
    options.MotionCorrection (1,1) string = "none"
    options.PhotobleachCorrection (1,1) string = "none"
    options.FrameRateHz (1,1) double = NaN
    options.Direction (1,1) double {mustBeMember(options.Direction,[-1 1])} = 1
    options.BaselineWindow (1,2) double = [-0.04 -0.005]
    options.ResponseWindow (1,2) double = [0.001 0.04]
end
allTraces=[]; allTime=[]; allEpochs=table;
extractions=cell(height(run.trials),1);
timeOffset=0;
for k=1:height(run.trials)
    folder=string(run.trials.experiment_directory(k));
    if strlength(folder)==0 || ~isfolder(folder), continue; end
    extraction=adaptive_optopatch.extract_roi_traces(folder,reference, ...
        "BackgroundMode",options.BackgroundMode, ...
        "NullRoiMask",options.NullRoiMask, ...
        "MotionCorrection",options.MotionCorrection, ...
        "PhotobleachCorrection",options.PhotobleachCorrection, ...
        "FrameRateHz",options.FrameRateHz);
    extractions{k}=extraction;
    localTime=extraction.tvec;
    if numel(localTime)>1
        dt=median(diff(localTime)); else, dt=1; end
    globalTime=localTime+timeOffset;
    allTime=[allTime;globalTime]; %#ok<AGROW>
    allTraces=[allTraces;extraction.corrected_traces]; %#ok<AGROW>
    protocol=run.trials.pulse_schedule{k};
    nPulses=height(protocol.events);
    target_index=repmat(run.trials.target_index(k),nPulses,1);
    is_null=repmat(run.trials.is_null(k),nPulses,1);
    stim_time=protocol.events.onset_s+timeOffset;
    acquisition_index=repmat(k,nPulses,1);
    localEpochs=table(target_index,is_null,stim_time,acquisition_index);
    allEpochs=[allEpochs;localEpochs]; %#ok<AGROW>
    timeOffset=globalTime(end)+10*dt;
end
if isempty(allTraces)
    error("adaptive_optopatch:NoCompletedAcquisitions", ...
        "No trial rows contain readable experiment directories.");
end
connectivity=adaptive_optopatch.infer_connectivity(allTraces,allTime,allEpochs, ...
    "Direction",options.Direction,"BaselineWindow",options.BaselineWindow, ...
    "ResponseWindow",options.ResponseWindow);
ranking=adaptive_optopatch.rank_connectivity_candidates(connectivity,reference);
analysis=struct("schema_version","0.2.0","created_at", ...
    string(datetime("now","TimeZone","local")),"connectivity",connectivity, ...
    "ranking",ranking,"epochs",allEpochs,"extractions",{extractions});
end
