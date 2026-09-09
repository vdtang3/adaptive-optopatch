function target=resolve_trial_target(targets,trialRow)
%RESOLVE_TRIAL_TARGET Apply frozen acquisition-scoped spatial parameters.
index=double(trialRow.target_index);
if ~ismember("acquisition_parameters",string(trialRow.Properties.VariableNames))
    target=targets.targets(index);
    return
end
resolvedTargets=adaptive_optopatch.apply_acquisition_parameters( ...
    targets,trialRow.pulse_schedule{1});
target=resolvedTargets.targets(index);
end
