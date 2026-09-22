function route=manifest_execution_route(trials)
%MANIFEST_EXECUTION_ROUTE Which runner executes this manifest, and where it checkpoints.
%   ONE ANSWER TO ONE QUESTION, because two places need it and they must not
%   disagree. run_mixed_manifest chooses a runner from it, and the controller
%   finds that runner's checkpoint from it.
%
%   They disagreed before this function existed, and the disagreement was
%   silent. run_mixed_manifest routes on the EVENTS - any 1P event anywhere in
%   the manifest sends the whole batch to run_1p_manifest, which writes
%   run_checkpoint.mat. The controller routed on the per-trial
%   `stimulation_mode` STRING and required every trial to carry the same one of
%   exactly two values. build_manifest also emits "mixed" and "none", so a
%   perfectly ordinary manifest - a 1P protocol with a null control acquisition
%   - produced no checkpoint path at all. The controller then reported the
%   FROZEN trials as the current ones, so:
%
%     - completed_acquisitions stayed 0 for the whole run and afterwards,
%     - batch_is_complete was never true, so Start new batch never enabled, and
%     - runPreparedPlan skipped its startNewBatch, so pressing Run a second
%       time resumed an already-complete checkpoint and silently did nothing.
%
%   The route is therefore derived from the same thing the runner derives it
%   from: whether any 1P event exists.
%
%   `onephoton_event_count` and `twophoton_event_count` are read in preference
%   to walking every trial's pulse_schedule. build_manifest computes those
%   columns as exactly the sums this would otherwise recount
%   (sum(events.stimulation_source=="1p_dmd")), and this is reached from
%   getState, which a frontend polls. The pulse_schedule walk remains as the
%   fallback for a trials table that predates those columns.
%
%   route.runner            "1p_dmd" or "2p_spiral" - which runner executes it
%   route.checkpoint_file   the file that runner writes its progress to
%   route.has_one_photon    whether any trial schedules a 1P event
%   route.has_two_photon    whether any trial schedules a 2P event
%
%   An empty manifest routes to 1P with an empty checkpoint_file: there is
%   nothing to execute and nothing to find.
%
%   See also RUN_MIXED_MANIFEST, ADAPTIVEOPTOPATCHCONTROLLER/CURRENTBATCHTRIALS.
arguments
    trials table
end
route=struct("schema_version","1.0.0","runner","1p_dmd", ...
    "checkpoint_file","","has_one_photon",false,"has_two_photon",false);
if height(trials)==0, return; end

route.has_one_photon=any_source(trials,"onephoton_event_count","1p_dmd");
route.has_two_photon=any_source(trials,"twophoton_event_count","2p_spiral");

% The runner's own rule, verbatim: any 1P event sends the batch to the 1P
% runner, which is also what executes the 2P events of a mixed manifest.
if route.has_one_photon
    route.runner="1p_dmd";
    route.checkpoint_file="run_checkpoint.mat";
else
    route.runner="2p_spiral";
    route.checkpoint_file="run_2p_checkpoint.mat";
end
end

function tf=any_source(trials,countColumn,source)
names=string(trials.Properties.VariableNames);
if any(names==countColumn)
    tf=any(double(trials.(countColumn))>0);
    return
end
% No count column: this manifest predates them, so recount from the schedules.
if ~any(names=="pulse_schedule")
    tf=false;
    return
end
tf=any(cellfun(@(p)any(p.events.stimulation_source==source), ...
    trials.pulse_schedule));
end
