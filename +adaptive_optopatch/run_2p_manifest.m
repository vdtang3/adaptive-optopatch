function run=run_2p_manifest(manifest,targets,app,options)
%RUN_2P_MANIFEST Execute guarded Chameleon spiral acquisitions through Luminos.
arguments
    manifest (1,1) struct
    targets (1,1) struct
    app
    options.ReleaseLevel (1,1) string {mustBeMember(options.ReleaseLevel, ...
        ["blocked_test","attenuated_test","pilot_single", ...
        "pilot_mixed_trains","experimental"])} = "blocked_test"
    options.OutputDirectory (1,1) string = ""
    options.OutputRoot (1,1) string = ""
    options.Resume (1,1) logical = true
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
end
bundleValidation=adaptive_optopatch.validate_2p_planning_bundle(targets);
if ~bundleValidation.passed
    details=char(strjoin(bundleValidation.issues(:)'," "));
    message=sprintf([ ...
        'This planning bundle cannot be run safely. Regenerate it from ' ...
        'the Camera 1 Snap using the updated planning GUI. Details: %s'],details);
    error('adaptive_optopatch:OutdatedTwoPhotonBundle','%s',message);
end
if ismember(options.ReleaseLevel,["blocked_test","attenuated_test"])
    manifest=make_staged_manifest(manifest,options.TestPulseCount,options.ReleaseLevel);
elseif ismember(options.ReleaseLevel,["pilot_single","pilot_mixed_trains"])
    manifest=make_pilot_manifest(manifest,options.ReleaseLevel);
end
release=adaptive_optopatch.validate_2p_release_level(manifest, ...
    options.ReleaseLevel,"ConfirmTrajectoryTest",options.ConfirmTrajectoryTest, ...
    "ConfirmLiveOutput",options.ConfirmLiveOutput, ...
    "ModulatorVoltageOverride",options.ModulatorVoltageOverride, ...
    "HardwareValidationRecord",options.HardwareValidationRecord);
if ~release.passed
    error("adaptive_optopatch:TwoPhotonReleaseRejected","%s", ...
        strjoin(release.issues,newline));
end
hardware=adaptive_optopatch.resolve_luminos_2p_hardware(app);
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
trials=ensure_column(trials,"error_message",repmat("",n,1));
checkpoint="";
if strlength(options.OutputDirectory)>0
    if ~isfolder(options.OutputDirectory), mkdir(options.OutputDirectory); end
    checkpoint=fullfile(options.OutputDirectory,"run_2p_checkpoint.mat");
    if options.Resume && isfile(checkpoint)
        saved=load(checkpoint,"run");
        if isfield(saved,"run") && height(saved.run.trials)==n
            trials=saved.run.trials;
        end
    end
end
simulation=isa(app,"adaptive_optopatch.testing.SimulatedLuminosApp");
run=struct("schema_version","0.1.0","mode","live_2p_spiral", ...
    "simulation",simulation,"backend",string(class(app)), ...
    "release_level",options.ReleaseLevel,"release_report",release, ...
    "hardware_profile",profile,"calibration",hardware.calibration, ...
    "initial_settings_snapshot",adaptive_optopatch.snapshot_luminos_settings(app), ...
    "started_at",string(datetime("now","TimeZone","local")),"trials",trials);
completedThisCall=0;
for k=1:n
    if options.Resume && ismember(string(run.trials.acquisition_status(k)), ...
            ["completed","analyzed"]), continue; end
    if options.ReleaseLevel~="experimental" && completedThisCall>=1, break; end
    try
        row=run.trials(k,:);
        targetIndex=row.target_index;
        if row.is_null || targetIndex<1, targetIndex=1; end
        target=targets.targets(targetIndex);
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
        protocol=row.pulse_schedule{1};
        voltage=options.ModulatorVoltageOverride;
        if options.ReleaseLevel=="blocked_test" || row.is_null, voltage=0; end
        protocol=override_protocol_voltage(protocol,voltage);
        minimumRadiusFraction=0.95;
        if options.ReleaseLevel=="blocked_test"
            minimumRadiusFraction=eps;
        end
        waveforms=adaptive_optopatch.build_2p_trial_waveforms( ...
            protocol,target,hardware.scanner.tform, ...
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
        run.trials.waveform_summary{k}=summary;
        app.acquisition_active=true;
        run.trials.acquisition_status(k)="acquiring"; save_checkpoint();
        bins=arrayfun(@(camera)camera.bin,hardware.cameras);
        if strlength(options.OutputRoot)>0
            adaptive_optopatch.execute_waveform_camera_sync( ...
                app,bins,"tag",char(row.output_tag), ...
                "fullpath",char(options.OutputRoot));
        else
            adaptive_optopatch.execute_waveform_camera_sync( ...
                app,bins,"tag",char(row.output_tag));
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
        record=struct("schema_version","0.1.0", ...
            "simulation",simulation,"backend",string(class(app)),"created_at", ...
            string(datetime("now","TimeZone","local")), ...
            "release_level",options.ReleaseLevel,"trial",row, ...
            "hardware_profile",profile,"calibration",hardware.calibration, ...
            "daq_synchronization",adaptive_optopatch.capture_luminos_daq_sync(hardware.daq), ...
            "waveform_summary",summary, ...
            "galvo_feedback_summary",galvo_feedback.summary, ...
            "galvo_feedback_passed",galvo_feedback.passed, ...
            "waveform_file",string(fullfile(folder,"adaptive_optopatch_2p_waveforms.mat")), ...
            "parking_v",waveforms.parking_v, ...
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

function manifest=make_staged_manifest(manifest,pulseCount,level)
trials=manifest.trials;
idx=find(~trials.is_null,1);
if isempty(idx), error("adaptive_optopatch:NoStimulatedTrial","No non-null 2P trial was found."); end
trials=trials(idx,:);
protocol=trials.pulse_schedule{1};
if ~isfield(protocol,"protocol_type") || ...
        string(protocol.protocol_type)~="connectivity_screen"
    error("adaptive_optopatch:StagedScreenProtocolRequired", ...
        "Blocked and attenuated tests currently require a connectivity-screen protocol.");
end
count=pulseCount;
if count>height(protocol.events)
    protocol=adaptive_optopatch.generate_screen_protocol( ...
        "PulseCount",count,"PulseDurationMs",protocol.pulse_duration_ms, ...
        "DarkIntervalMs",protocol.dark_interval_range_ms, ...
        "PreDelayMs",protocol.pre_delay_ms, ...
        "PostDelayMs",protocol.post_delay_ms, ...
        "ModulatorVoltage",protocol.modulator_voltage, ...
        "RandomSeed",protocol.random_seed);
else
    protocol.events=protocol.events(1:count,:);
    protocol.pulse_count=count;
    protocol.total_light_on_s=sum(protocol.events.duration_s);
end
postDelay=100;
if isfield(protocol,"post_delay_ms"), postDelay=protocol.post_delay_ms; end
protocol.acquisition_duration_s=protocol.events.offset_s(end)+postDelay/1000;
trials.pulse_schedule={protocol};
trials.acquisition_duration_s=protocol.acquisition_duration_s;
trials.output_tag=string(trials.output_tag)+"_"+level;
trials.acquisition_status="planned";
trials.experiment_directory="";
manifest.trials=trials;
manifest.staged_from_trial_id=trials.trial_id;
manifest.release_level=level;
end

function manifest=make_pilot_manifest(manifest,level)
trials=manifest.trials;
idx=find(~trials.is_null,1);
if isempty(idx)
    error("adaptive_optopatch:NoStimulatedTrial", ...
        "No non-null 2P trial was found.");
end
trials=trials(idx,:);
trials.output_tag=string(trials.output_tag)+"_"+level;
trials.acquisition_status="planned";
trials.experiment_directory="";
manifest.trials=trials;
manifest.staged_from_trial_id=trials.trial_id;
manifest.release_level=level;
end

function protocol=override_protocol_voltage(protocol,voltage)
if ~isfinite(voltage), return; end
protocol=adaptive_optopatch.normalize_protocol(protocol);
protocol.hardware_command_voltage=voltage;
protocol.events.command_voltage_v(~protocol.events.is_null)=voltage;
protocol.events.command_voltage_v(protocol.events.is_null)=0;
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
