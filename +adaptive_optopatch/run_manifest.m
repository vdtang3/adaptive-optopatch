function run = run_manifest(manifest, targets, options)
%RUN_MANIFEST Execute a resumable dry run; live branch intentionally locked.
arguments
    manifest (1,1) struct
    targets (1,1) struct
    options.App = []
    options.OutputDirectory (1,1) string = ""
    options.Resume (1,1) logical = true
    options.Live (1,1) logical = false
    options.ConfirmLiveOutput (1,1) logical = false
    options.ModulatorVoltageOverride (1,1) double = NaN
    options.LaserPowerW (1,1) double = NaN
    options.OutputRoot (1,1) string = ""
    options.StopAfterTrial (1,1) double {mustBeNonnegative,mustBeInteger} = 0
    options.TwoPhotonReleaseLevel (1,1) string {mustBeMember(options.TwoPhotonReleaseLevel, ...
        ["blocked_test","attenuated_test","experimental"])} = "blocked_test"
    options.ConfirmTrajectoryTest (1,1) logical = false
    options.HardwareValidationRecord (1,1) string = ""
end
if options.Live
    modes=unique(string(manifest.trials.stimulation_mode));
    if isequal(modes,"1p_dmd")
        run=adaptive_optopatch.run_1p_manifest(manifest,targets,options.App, ...
            "OutputDirectory",options.OutputDirectory, ...
            "OutputRoot",options.OutputRoot, ...
            "Resume",options.Resume, ...
            "StopAfterTrial",options.StopAfterTrial, ...
            "ConfirmLiveOutput",options.ConfirmLiveOutput, ...
            "ModulatorVoltageOverride",options.ModulatorVoltageOverride, ...
            "LaserPowerW",options.LaserPowerW);
        return
    end
    if isequal(modes,"2p_spiral")
        run=adaptive_optopatch.run_2p_manifest(manifest,targets,options.App, ...
            "ReleaseLevel",options.TwoPhotonReleaseLevel, ...
            "OutputDirectory",options.OutputDirectory, ...
            "OutputRoot",options.OutputRoot, ...
            "Resume",options.Resume, ...
            "ConfirmTrajectoryTest",options.ConfirmTrajectoryTest, ...
            "ConfirmLiveOutput",options.ConfirmLiveOutput, ...
            "ModulatorVoltageOverride",options.ModulatorVoltageOverride, ...
            "HardwareValidationRecord",options.HardwareValidationRecord);
        return
    end
    error("adaptive_optopatch:LiveRunnerLocked", ...
        "Live execution remains locked for non-1p_dmd manifests.");
end
trials=manifest.trials;
n=height(trials);
trials=ensure_column(trials,"preflight_report",cell(n,1));
trials=ensure_column(trials,"target_configuration",cell(n,1));
trials=ensure_column(trials,"settings_snapshot",cell(n,1));
trials=ensure_column(trials,"error_message",repmat("",n,1));

checkpoint="";
if strlength(options.OutputDirectory)>0
    if ~isfolder(options.OutputDirectory), mkdir(options.OutputDirectory); end
    checkpoint=fullfile(options.OutputDirectory,"run_checkpoint.mat");
    if options.Resume && isfile(checkpoint)
        saved=load(checkpoint,"run");
        if isfield(saved,"run") && height(saved.run.trials)==n
            trials=saved.run.trials;
        end
    end
end

initialSnapshot=[];
if ~isempty(options.App)
    initialSnapshot=adaptive_optopatch.snapshot_luminos_settings(options.App);
end
run=struct("schema_version","0.2.0","mode","dry_run", ...
    "started_at",string(datetime("now","TimeZone","local")), ...
    "initial_settings_snapshot",initialSnapshot,"trials",trials);

completed=0;
for k=1:n
    status=string(run.trials.acquisition_status(k));
    if options.Resume && ismember(status,["dry_run_complete","completed","analyzed"])
        continue
    end
    try
        row=run.trials(k,:);
        preflight=adaptive_optopatch.preflight_trial(targets,row);
        run.trials.preflight_report{k}=preflight;
        if ~preflight.passed
            error("adaptive_optopatch:PreflightFailed", ...
                "%s",strjoin(preflight.issues,newline));
        end
        run.trials.acquisition_status(k)="preflight_passed";
        if ~isempty(options.App)
            run.trials.settings_snapshot{k}= ...
                adaptive_optopatch.snapshot_luminos_settings(options.App);
        end
        config=adaptive_optopatch.prepare_luminos_target( ...
            options.App,targets,row,"DryRun",true);
        run.trials.target_configuration{k}=config;
        run.trials.acquisition_status(k)="dry_run_complete";
        run.trials.error_message(k)="";
    catch exception
        run.trials.acquisition_status(k)="failed";
        run.trials.error_message(k)=string(exception.message);
    end
    run.updated_at=string(datetime("now","TimeZone","local"));
    if strlength(checkpoint)>0, save(checkpoint,"run"); end
    completed=completed+1;
    if options.StopAfterTrial>0 && completed>=options.StopAfterTrial, break; end
end
run.finished_at=string(datetime("now","TimeZone","local"));
if strlength(checkpoint)>0, save(checkpoint,"run"); end
end

function trials=ensure_column(trials,name,value)
if ~ismember(name,string(trials.Properties.VariableNames))
    trials.(name)=value;
end
end
