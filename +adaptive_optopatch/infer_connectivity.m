function result = infer_connectivity(traces, tvec, epochs, options)
%INFER_CONNECTIVITY Fast directed connectivity scoring from extracted traces.
% traces is frames x cells. epochs requires target_index, is_null, stim_time.
arguments
    traces double
    tvec (:,1) double
    epochs table
    options.BaselineWindow (1,2) double = [-0.5 -0.05]
    options.ResponseWindow (1,2) double = [0.01 0.5]
    options.Direction (1,1) double {mustBeMember(options.Direction,[-1 1])} = 1
    options.MinimumTargetResponseZ (1,1) double = 2
    options.EdgeThresholdZ (1,1) double = 2
    options.MinimumConsistency (1,1) double = 0.6
end

if size(traces,1) ~= numel(tvec)
    error("adaptive_optopatch:TraceTimeMismatch", ...
        "Trace rows must match tvec length.");
end
required = ["target_index","is_null","stim_time"];
if ~all(ismember(required,string(epochs.Properties.VariableNames)))
    error("adaptive_optopatch:InvalidEpochTable", ...
        "epochs must contain target_index, is_null, and stim_time.");
end

nCells = size(traces,2);
nEpochs = height(epochs);
responses = nan(nEpochs,nCells);
baselineNoise = nan(nEpochs,nCells);
for e = 1:nEpochs
    rel = tvec - epochs.stim_time(e);
    b = rel >= options.BaselineWindow(1) & rel <= options.BaselineWindow(2);
    r = rel >= options.ResponseWindow(1) & rel <= options.ResponseWindow(2);
    if ~any(b) || ~any(r), continue; end
    base = mean(traces(b,:),1,"omitnan");
    responses(e,:) = options.Direction * (mean(traces(r,:),1,"omitnan")-base);
    baselineNoise(e,:) = std(traces(b,:),0,1,"omitnan");
end

nullRows = epochs.is_null;
if any(nullRows)
    nullMu = mean(responses(nullRows,:),1,"omitnan");
    nullSigma = std(responses(nullRows,:),0,1,"omitnan");
else
    nullMu=zeros(1,nCells);
    nullSigma=nan(1,nCells);
end
fallbackSigma = median(baselineNoise,1,"omitnan");
nullSigma(~isfinite(nullSigma) | nullSigma<=0) = fallbackSigma(~isfinite(nullSigma) | nullSigma<=0);
nullSigma(~isfinite(nullSigma) | nullSigma<=0) = eps;

effect = nan(nCells,nCells);
zscore = nan(nCells,nCells);
consistency = nan(nCells,nCells);
targetActivationZ = nan(nCells,1);
edge = false(nCells,nCells);
for source = 1:nCells
    rows = ~epochs.is_null & epochs.target_index == source;
    if ~any(rows), continue; end
    effect(source,:) = mean(responses(rows,:),1,"omitnan")-nullMu;
    zscore(source,:) = effect(source,:)./nullSigma;
    consistency(source,:) = mean(responses(rows,:) > nullMu,1,"omitnan");
    targetActivationZ(source) = zscore(source,source);
    edge(source,:) = zscore(source,:) >= options.EdgeThresholdZ & ...
        consistency(source,:) >= options.MinimumConsistency & ...
        targetActivationZ(source) >= options.MinimumTargetResponseZ;
    edge(source,source) = false;
end

result = struct;
result.schema_version = "0.1.0";
result.response_by_epoch = responses;
result.effect = effect;
result.zscore = zscore;
result.consistency = consistency;
result.target_activation_z = targetActivationZ;
result.candidate_edge = edge;
result.null_mean = nullMu;
result.null_std = nullSigma;
end
