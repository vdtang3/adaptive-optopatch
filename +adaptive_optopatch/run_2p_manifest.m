function run=run_2p_manifest(manifest,targets,app,options)
%RUN_2P_MANIFEST Execute guarded Chameleon spiral acquisitions through Luminos.
%   The manifest passed in is immutable acquisition truth and is never
%   rewritten here. A staged or pilot release level selects which subset of it
%   is exercised right now and which command voltage that commissioning
%   acquisition uses; that selection lives in run.staging and in the per-trial
%   executed_pulse_schedule beside the unchanged frozen pulse_schedule.
arguments
    manifest (1,1) struct
    targets (1,1) struct
    app
    options.ReleaseLevel (1,1) string {mustBeMember(options.ReleaseLevel, ...
        ["blocked_test","attenuated_test","pilot_single", ...
        "pilot_mixed_trains","experimental","standard"])} = "blocked_test"
    options.OutputDirectory (1,1) string = ""
    options.OutputRoot (1,1) string = ""
    options.Resume (1,1) logical = true
    options.StopAfterTrial (1,1) double {mustBeNonnegative,mustBeInteger} = 0
    options.ConfirmTrajectoryTest (1,1) logical = false
    options.ConfirmLiveOutput (1,1) logical = false
    options.ModulatorVoltageOverride (1,1) double = NaN
    options.MaximumVelocityVPerS (1,1) double {mustBePositive} = 1000
    options.MaximumAccelerationVPerS2 (1,1) double {mustBePositive} = 6e6
    options.HardwareValidationRecord (1,1) string = ""
    options.TimeoutMarginS (1,1) double {mustBePositive} = 30
    options.TestPulseCount (1,1) double {mustBePositive,mustBeInteger} = 1
    options.AllowCalibrationExtrapolation (1,1) logical = false
    options.AllowCameraRateOverride (1,1) logical = false
    options.StopRequestedFcn = []
    options.ScannerCalibration struct = struct([])
end
bundleValidation=adaptive_optopatch.validate_2p_planning_bundle(targets);
if ~bundleValidation.passed
    details=char(strjoin(bundleValidation.issues(:)'," "));
    message=sprintf([ ...
        'This planning bundle cannot be run safely. Regenerate it from ' ...
        'the Camera 1 Snap using the updated planning GUI. Details: %s'],details);
    error('adaptive_optopatch:OutdatedTwoPhotonBundle','%s',message);
end
staging=adaptive_optopatch.plan_staged_2p_execution(manifest, ...
    options.ReleaseLevel,"TestPulseCount",options.TestPulseCount, ...
    "ModulatorVoltageOverride",options.ModulatorVoltageOverride);
release=adaptive_optopatch.validate_2p_release_level(manifest, ...
    options.ReleaseLevel,"ConfirmTrajectoryTest",options.ConfirmTrajectoryTest, ...
    "ConfirmLiveOutput",options.ConfirmLiveOutput, ...
    "ModulatorVoltageOverride",options.ModulatorVoltageOverride, ...
    "HardwareValidationRecord",options.HardwareValidationRecord, ...
    "TrialIndex",staging.source_trial_index);
if ~release.passed
    error("adaptive_optopatch:TwoPhotonReleaseRejected","%s", ...
        strjoin(release.issues,newline));
end
% A frozen run supplies the exact targeting transform that was archived
% with it via ScannerCalibration; that transform, not whatever calibration
% happens to be active right now, is authoritative for physically pointing
% the galvos. Hardware resolution here only discovers/validates live
% devices, so it must not overwrite that frozen transform onto the scanner.
usingFrozenCalibration=~isempty(options.ScannerCalibration) && ...
    isfield(options.ScannerCalibration,"tform");
hardware=adaptive_optopatch.resolve_luminos_2p_hardware(app, ...
    "ApplyCalibration",~usingFrozenCalibration);
if usingFrozenCalibration
    targetingTform=options.ScannerCalibration.tform;
else
    targetingTform=hardware.calibration.calibration.tform;
end
profile=adaptive_optopatch.virtual_upright_2p_profile();
motionValidation=adaptive_optopatch.validate_provisional_2p_motion_limits( ...
    options.MaximumVelocityVPerS,options.MaximumAccelerationVPerS2);
if ~motionValidation.passed
    error("adaptive_optopatch:UnvalidatedGalvoMotionLimits","%s", ...
        strjoin(motionValidation.issues,newline));
end
original=capture_state(hardware);
cleanup=onCleanup(@()restore_state(app,hardware,original,profile));
hardware.modulator.level=profile.modulator.dark_v;
trials=manifest.trials; n=height(trials);
trials=ensure_column(trials,"settings_snapshot",cell(n,1));
trials=ensure_column(trials,"waveform_summary",cell(n,1));
trials=ensure_column(trials,"orange_configuration",cell(n,1));
trials=ensure_column(trials,"executed_pulse_schedule",cell(n,1));
trials=ensure_column(trials,"error_message",repmat("",n,1));
checkpoint="";
if strlength(options.OutputDirectory)>0
    if ~isfolder(options.OutputDirectory), mkdir(options.OutputDirectory); end
    % Commissioning execution state is kept in its own checkpoint so a staged
    % test never marks a real experimental acquisition as already completed.
    checkpointName="run_2p_checkpoint.mat";
    if staging.staged
        checkpointName="run_2p_checkpoint_"+options.ReleaseLevel+".mat";
    end
    checkpoint=fullfile(options.OutputDirectory,checkpointName);
    if options.Resume && isfile(checkpoint)
        saved=load(checkpoint,"run");
        if isfield(saved,"run") && height(saved.run.trials)==n
            trials=saved.run.trials;
        end
    end
end
simulation=isa(app,"adaptive_optopatch.testing.SimulatedLuminosApp");
calibrationMismatch=usingFrozenCalibration && isfield(hardware.calibration,"calibration_id") && ...
    isfield(options.ScannerCalibration,"calibration_id") && ...
    string(hardware.calibration.calibration_id)~=string(options.ScannerCalibration.calibration_id);
run=struct("schema_version","0.2.0","mode","live_2p_spiral", ...
    "simulation",simulation,"backend",string(class(app)), ...
    "release_level",options.ReleaseLevel,"release_report",release, ...
    "staging",staging, ...
    "hardware_profile",profile,"calibration",hardware.calibration, ...
    "targeting_calibration",options.ScannerCalibration, ...
    "used_frozen_targeting_calibration",usingFrozenCalibration, ...
    "targeting_calibration_mismatch",calibrationMismatch, ...
    "initial_settings_snapshot",adaptive_optopatch.snapshot_luminos_settings(app), ...
    "started_at",string(datetime("now","TimeZone","local")),"trials",trials);
completedThisCall=0;
for k=1:n
    if staging.staged && k~=staging.source_trial_index, continue; end
    if options.Resume && ismember(string(run.trials.acquisition_status(k)), ...
            ["completed","analyzed"]), continue; end
    if options.StopAfterTrial>0 && completedThisCall>=options.StopAfterTrial, break; end
    if staging.staged && completedThisCall>=1, break; end
    try
        row=run.trials(k,:);
        frozenProtocol=row.pulse_schedule{1};
        protocol=adaptive_optopatch.stage_2p_execution_protocol( ...
            frozenProtocol,staging,row.is_null);
        run.trials.executed_pulse_schedule{k}=protocol;
        if isfield(targets,"canonical_roi_masks")
            trialTargets=adaptive_optopatch.apply_acquisition_parameters( ...
                targets,protocol);
            run.trials.orange_configuration{k}= ...
                adaptive_optopatch.prepare_luminos_orange_mask(app,trialTargets, ...
                "DryRun",false);
        else
            trialTargets=targets;
        end
        targetIndex=row.target_index;
        if row.is_null || targetIndex<1, targetIndex=1; end
        target=trialTargets.targets(targetIndex);
        calibrationCoverage= ...
            adaptive_optopatch.validate_2p_calibration_coverage( ...
            target,hardware.calibration);
        if ~calibrationCoverage.passed && ~options.AllowCalibrationExtrapolation
            error("adaptive_optopatch:TargetOutsideGalvoCalibration", ...
                ['The target cannot be run without extrapolating the camera-to-galvo ' ...
                 'calibration. Acquire a wider calibration grid. Details: %s'], ...
                strjoin(calibrationCoverage.issues," "));
        end
        calibrationCoverage.extrapolation_allowed= ...
            options.AllowCalibrationExtrapolation;
        calibrationCoverage.extrapolation_used= ...
            ~calibrationCoverage.passed && options.AllowCalibrationExtrapolation;
        minimumRadiusFraction=0.95;
        if options.ReleaseLevel=="blocked_test"
            minimumRadiusFraction=eps;
        end
        waveforms=adaptive_optopatch.build_2p_trial_waveforms( ...
            protocol,target,targetingTform, ...
            "MaximumVelocityVPerS",options.MaximumVelocityVPerS, ...
            "MaximumAccelerationVPerS2",options.MaximumAccelerationVPerS2, ...
            "MinimumIlluminatedRadiusFraction",minimumRadiusFraction);
        [globalProps,wfmData,summary]= ...
            adaptive_optopatch.build_luminos_2p_waveform_config( ...
            original.global_props,original.wfm_data,waveforms);
        run.trials.settings_snapshot{k}= ...
            adaptive_optopatch.snapshot_luminos_settings(app);
        hardware.daq.global_props=globalProps;
        hardware.daq.wfm_data=wfmData;
        hardware.daq.waveforms_built=false;
        [hardware.cameras,cameraFramePlan]= ...
            adaptive_optopatch.set_camera_frames_for_duration( ...
            hardware.cameras,globalProps.total_time, ...
            "AllowRateLimitOverride",options.AllowCameraRateOverride);
        summary.camera_frame_plan=cameraFramePlan;
        summary.calibration_coverage=calibrationCoverage;
        summary.staging=staging;
        run.trials.waveform_summary{k}=summary;
        app.acquisition_active=true;
        run.trials.acquisition_status(k)="acquiring"; save_checkpoint();
        bins=arrayfun(@(camera)camera.bin,hardware.cameras);
        outputTag=char(string(row.output_tag)+staging.output_tag_suffix);
        if strlength(options.OutputRoot)>0
            adaptive_optopatch.execute_waveform_camera_sync( ...
                app,bins,"tag",outputTag, ...
                "fullpath",char(options.OutputRoot));
        else
            adaptive_optopatch.execute_waveform_camera_sync( ...
                app,bins,"tag",outputTag);
        end
        wait_for_completion(globalProps.total_time+options.TimeoutMarginS);
        hardware.modulator.level=profile.modulator.dark_v;
        folder=string(app.expfolder);
        if ~isfile(fullfile(folder,"output_data.mat"))
            error("adaptive_optopatch:MissingLuminosOutput", ...
                "Luminos did not create output_data.mat in %s.",folder);
        end
        waveformFile=fullfile(folder,"adaptive_optopatch_2p_waveforms.mat");
        actual_waveforms=waveforms;
        galvo_feedback=adaptive_optopatch.capture_galvo_feedback( ...
            hardware.daq,waveforms);
        save(waveformFile,"actual_waveforms","galvo_feedback","-v7.3");
        adaptive_optopatch_record=build_record(row,summary,waveforms,folder);
        save(fullfile(folder,"output_data.mat"), ...
            "adaptive_optopatch_record","-append");
        run.trials.experiment_directory(k)=folder;
        run.trials.acquisition_status(k)="completed";
        run.trials.error_message(k)="";
        completedThisCall=completedThisCall+1; save_checkpoint();
        if ~isempty(options.StopRequestedFcn) && logical(options.StopRequestedFcn())
            break
        end
    catch exception
        hardware.modulator.level=profile.modulator.dark_v;
        run.trials.acquisition_status(k)="failed";
        run.trials.error_message(k)=string(exception.message);
        save_checkpoint(); rethrow(exception)
    end
end
run.finished_at=string(datetime("now","TimeZone","local")); save_checkpoint();

    function wait_for_completion(timeout)
        started=tic;
        while ~logical(app.exp_complete)
            pause(0.05); drawnow;
            if toc(started)>timeout
                error("adaptive_optopatch:TwoPhotonAcquisitionTimeout", ...
                    "Luminos did not complete the 2P acquisition.");
            end
        end
    end
    function record=build_record(row,summary,waveforms,folder)
        pulses=adaptive_optopatch.flatten_pulse_schedule(protocol);
        frameRate=cameraFramePlan(hardware.voltage_camera_index).frame_rate_hz;
        if ~isfinite(frameRate)
            frameRate=double(hardware.voltage_camera.calculate_framerate());
        end
        record=struct("schema_version","0.2.0", ...
            "simulation",simulation,"backend",string(class(app)),"created_at", ...
            string(datetime("now","TimeZone","local")), ...
            "release_level",options.ReleaseLevel,"staging",staging,"trial",row, ...
            "hardware_profile",profile,"calibration",hardware.calibration, ...
            "targeting_tform",targetingTform, ...
            "used_frozen_targeting_calibration",usingFrozenCalibration, ...
            "daq_synchronization",adaptive_optopatch.capture_luminos_daq_sync(hardware.daq), ...
            "waveform_summary",summary, ...
            "galvo_feedback_summary",galvo_feedback.summary, ...
            "galvo_feedback_passed",galvo_feedback.passed, ...
            "waveform_file",string(fullfile(folder,"adaptive_optopatch_2p_waveforms.mat")), ...
            "parking_v",waveforms.parking_v, ...
            "frozen_pulse_schedule",row.pulse_schedule{1}, ...
            "pulse_schedule",protocol, ...
            "realized_pulses",pulses, ...
            "expected_frame_map",table(pulses.pulse_id,pulses.onset_s, ...
            floor(pulses.onset_s*frameRate)+1, ...
            'VariableNames',{'pulse_id','onset_s','expected_frame'}));
    end
    function save_checkpoint()
        run.updated_at=string(datetime("now","TimeZone","local"));
        if strlength(checkpoint)>0, save(checkpoint,"run","-v7.3"); end
    end
end

function original=capture_state(hardware)
original=struct("global_props",hardware.daq.global_props, ...
    "wfm_data",hardware.daq.wfm_data, ...
    "camera_frames",arrayfun(@(camera)camera.frames_requested,hardware.cameras));
end
function trials=ensure_column(trials,name,value)
if ~ismember(name,string(trials.Properties.VariableNames)), trials.(name)=value; end
end
function restore_state(app,hardware,original,profile)
try, hardware.modulator.level=profile.modulator.dark_v; catch, end
try
    if isprop(app,"acquisition_active") && logical(app.acquisition_active)
        for k=1:numel(hardware.cameras), try, hardware.cameras(k).Stop(); catch, end, end
        try, hardware.daq.Disconnect_Clock_Bridge(); catch, end
        try, hardware.daq.reset(); catch, end
        app.acquisition_active=false;
    end
catch
end
try
    hardware.daq.global_props=original.global_props;
    hardware.daq.wfm_data=original.wfm_data;
    hardware.daq.waveforms_built=false;
catch
end
for k=1:numel(hardware.cameras)
    try, hardware.cameras(k).frames_requested=original.camera_frames(k); catch, end
end
end
