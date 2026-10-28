function run = run_1p_manifest(manifest,targets,app,options)
%RUN_1P_MANIFEST Execute DMD_Blue/mod488 trials through live Luminos.
arguments
    manifest (1,1) struct
    targets (1,1) struct
    app
    options.OutputDirectory (1,1) string = ""
    options.OutputRoot (1,1) string = ""
    options.Resume (1,1) logical = true
    options.StopAfterTrial (1,1) double {mustBeNonnegative,mustBeInteger} = 0
    options.Profile (1,1) struct = adaptive_optopatch.virtual_upright_1p_profile()
    options.StimulationManifest struct = struct([])
    options.LaserPowerW (1,1) double = NaN
    options.ConfirmLiveOutput (1,1) logical = false
    options.ManageLaserEmission (1,1) logical = true
    options.BlankDmdAfterTrial (1,1) logical = true
    options.ShutterSettleTimeS (1,1) double {mustBeNonnegative} = 0.05
    options.TimeoutMarginS (1,1) double {mustBePositive} = 30
    options.StopRequestedFcn = []
    % Called with one small progress record at each acquisition boundary, so
    % that an observer can follow the run without reading the checkpoint file
    % this also writes. Deliberately a plain function handle and deliberately
    % small: see report_progress below for what it carries and why.
    options.ProgressFcn = []
    options.AllowMixedSources (1,1) logical = false
    options.ScannerCalibration struct = struct([])
    options.MaximumVelocityVPerS (1,1) double {mustBePositive} = 1000
    options.MaximumAccelerationVPerS2 (1,1) double {mustBePositive} = 6e6
    options.AllowCameraRateOverride (1,1) logical = false
    options.TwoPhotonReleaseLevel (1,1) string {mustBeMember( ...
        options.TwoPhotonReleaseLevel,["blocked_test","attenuated_test","standard"])} = "standard"
    options.TwoPhotonVoltageOverride (1,1) double = NaN
    % Pass 3A rolls accounting out in report-only: a terminal AO cannot
    % classify is reported loudly but does not stop the rig, because the
    % VU's ambient configuration has not been surveyed yet. Violations the
    % code can prove unsafe block under either policy.
    options.StimulationAccountingPolicy (1,1) string {mustBeMember( ...
        options.StimulationAccountingPolicy, ...
        ["report_only","fail_closed"])} = "report_only"
end
if ~options.ConfirmLiveOutput
    error("adaptive_optopatch:LiveOutputNotConfirmed", ...
        "Live 488-nm output was not confirmed. Review the DMD mask, " + ...
        "illumination source, and mod488 voltage, then pass ConfirmLiveOutput=true.");
end
if ~isfield(manifest,"trials") || isempty(manifest.trials)
    error("adaptive_optopatch:EmptyManifest","The manifest has no trials.");
end
allowed="1p_dmd";
if options.AllowMixedSources, allowed=["1p_dmd","2p_spiral","mixed","none"]; end
if any(~ismember(string(manifest.trials.stimulation_mode),allowed))
    error("adaptive_optopatch:WrongRunnerMode", ...
        "run_1p_manifest accepts only 1p_dmd trials.");
end
profile=options.Profile;
stimulationManifest=options.StimulationManifest;
if isempty(stimulationManifest)
    stimulationManifest=adaptive_optopatch.stimulation_manifest_for_profile(profile);
end
if string(stimulationManifest.rig_name)~=string(profile.rig_name)
    error("adaptive_optopatch:RigManifestMismatch", ...
        "The stimulation output manifest must match the hardware profile.");
end
if profile.rig_name=="Spinning_Upright" && options.AllowMixedSources
    error("adaptive_optopatch:UnsupportedRigModality", ...
        "Spinning_Upright supports only 1P DMD stimulation.");
end
if strlength(string(profile.laser.name))==0 && isfinite(options.LaserPowerW)
    error("adaptive_optopatch:LaserPowerUnavailable", ...
        "This rig has no managed OBIS laser; set LaserPowerW=NaN.");
end
if isfinite(options.LaserPowerW) && ...
        (options.LaserPowerW<0 || options.LaserPowerW>profile.laser.max_power_w)
    error("adaptive_optopatch:LaserPowerOutOfRange", ...
        "Requested OBIS power must be between 0 and %.3g W.",profile.laser.max_power_w);
end

hardware=adaptive_optopatch.resolve_luminos_1p_hardware(app,profile);
hasAny2p=any(cellfun(@(p)any(p.events.stimulation_source=="2p_spiral"), ...
    manifest.trials.pulse_schedule));
% Which acquisition the run-level safety steps are making safe. Taken from
% the schedule rather than from the runner's name: run_1p_manifest accepts
% 2P and mixed trials under AllowMixedSources, and a run that will drive
% the galvos must still be able to park them. A run with no 2P event
% anywhere commands no 2P hardware at all - not through a waveform and not
% through an explicit device write.
runModality="1p_dmd";
if hasAny2p, runModality="mixed"; end
targetingTform=[];
if hasAny2p
    usingFrozenCalibration=~isempty(options.ScannerCalibration) && ...
        isfield(options.ScannerCalibration,"tform");
    twoPhotonHardware=adaptive_optopatch.resolve_luminos_2p_hardware(app, ...
        "ApplyCalibration",~usingFrozenCalibration);
    if usingFrozenCalibration, targetingTform=options.ScannerCalibration.tform;
    else, targetingTform=twoPhotonHardware.calibration.calibration.tform; end
    motion=adaptive_optopatch.validate_provisional_2p_motion_limits( ...
        options.MaximumVelocityVPerS,options.MaximumAccelerationVPerS2);
    if ~motion.passed
        error("adaptive_optopatch:UnvalidatedGalvoMotionLimits","%s", ...
            strjoin(motion.issues,newline));
    end
end
cameraGeometry=adaptive_optopatch.validate_camera_geometry( ...
    hardware.voltage_camera,targets);
adaptive_optopatch.validate_dmd_reference_geometry( ...
    hardware.dmd,targets.reference_camera,profile.dmd.name);
adaptive_optopatch.validate_dmd_reference_geometry( ...
    hardware.orange_dmd,targets.reference_camera,profile.orange_dmd.name);
% Which camera's calibration each DMD is actually projecting through. The
% per-trial prepare_* functions check this again at the moment they program,
% which is where the invariant belongs; doing it once here as well means a
% run with the wrong calibration selected fails before the OBIS is raised
% rather than after.
dmdCalibrationIdentity=struct( ...
    "blue",adaptive_optopatch.validate_dmd_calibration_identity( ...
        hardware.dmd,targets.reference_camera,profile.dmd.name), ...
    "orange",adaptive_optopatch.validate_dmd_calibration_identity( ...
        hardware.orange_dmd,targets.reference_camera,profile.orange_dmd.name));
dmdCalibration=adaptive_optopatch.capture_1p_dmd_calibration(hardware,targets);
dmdCalibration.identity=dmdCalibrationIdentity;
original=capture_original_state(hardware);
runnerStartedLaser=false;

trials=manifest.trials;
n=height(trials);
trials=ensure_column(trials,"preflight_report",cell(n,1));
trials=ensure_column(trials,"target_configuration",cell(n,1));
trials=ensure_column(trials,"orange_configuration",cell(n,1));
trials=ensure_column(trials,"settings_snapshot",cell(n,1));
trials=ensure_column(trials,"waveform_summary",cell(n,1));
trials=ensure_column(trials,"stimulation_accounting",cell(n,1));
trials=ensure_column(trials,"executed_pulse_schedule",cell(n,1));
trials=ensure_column(trials,"error_message",repmat("",n,1));
trials=ensure_column(trials,"cleanup_error_message",repmat("",n,1));
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

simulation=isa(app,"adaptive_optopatch.testing.SimulatedLuminosApp");
run=struct("schema_version","0.6.0","mode","live_1p_dmd", ...
    "simulation",simulation,"backend",string(class(app)), ...
    "hardware_profile",profile,"camera_geometry",cameraGeometry, ...
    "dmd_calibration",dmdCalibration, ...
    "started_at",string(datetime("now","TimeZone","local")), ...
    "initial_settings_snapshot",adaptive_optopatch.snapshot_luminos_settings(app), ...
    "trials",trials);

% Exclusive DMD programming for the length of this run, taken before
% anything writes a pattern. Luminos acquisition startup reloads a DMD's
% retained generic pattern_stack when auto_write_stack is set, which happens
% after AO has programmed and verified the device and before the first
% trigger; the claim suspends that and nothing else. Released in
% restore_1p_hardware, which runs on success, on error and on Ctrl-C.
dmdOwnership=adaptive_optopatch.claim_dmd_pattern_ownership( ...
    [hardware.dmd,hardware.orange_dmd]);
run.dmd_ownership=dmdOwnership.report;

% Neutral state first, source power second. The OBIS setpoint used to be
% raised before mod488 was known to be dark, so for the length of those two
% statements the laser was at experiment power behind a modulator holding
% whatever the previous run had left on it. Nothing downstream needs the
% power set that early.
try
    run.initial_neutralization=adaptive_optopatch.neutralize_all_stimulation( ...
        app,"Context","1p run start","Modality",runModality, ...
        "Manifest",stimulationManifest,"OnePhotonProfile",profile);
    warn_neutralization(run.initial_neutralization);
    if ~isempty(hardware.laser) && isfinite(options.LaserPowerW)
        hardware.laser.SetPower=options.LaserPowerW;
    end
    if ~isempty(hardware.laser) && options.ManageLaserEmission && ~hardware.laser_was_on
        hardware.laser.Start();
        runnerStartedLaser=true;
    end
catch exception
    % Explicitly, because the onCleanup guard below is not registered yet:
    % a failure here happens before app.acquisition_active is ever set, and
    % that used to be the one path out of this function that neutralised
    % nothing.
    restore_1p_hardware(app,hardware,original,profile, ...
        options.BlankDmdAfterTrial,isfinite(options.LaserPowerW), ...
        runnerStartedLaser,runModality,dmdOwnership,stimulationManifest);
    rethrow(exception)
end
cleanup=onCleanup(@()restore_1p_hardware(app,hardware,original,profile, ...
    options.BlankDmdAfterTrial,isfinite(options.LaserPowerW), ...
    runnerStartedLaser,runModality,dmdOwnership,stimulationManifest));

completedThisCall=0;
for k=1:n
    status=string(run.trials.acquisition_status(k));
    if options.Resume && ismember(status, ...
            ["completed","completed_cleanup_failed","analyzed"]), continue; end
    try
        row=run.trials(k,:);
        protocol=adaptive_optopatch.normalize_protocol(row.pulse_schedule{1});
        if profile.rig_name=="Spinning_Upright"
            % Keep the camera and recording waveform running while the disk
            % settles; all planned stimulation starts after this interval.
            protocol.events.onset_s=protocol.events.onset_s+2;
            protocol.events.offset_s=protocol.events.offset_s+2;
            protocol.acquisition_duration_s=protocol.acquisition_duration_s+2;
            protocol.startup_baseline_s=2;
        end
        twoPhotonCommandOverride=NaN;
        if any(protocol.events.stimulation_source=="2p_spiral")
            if options.TwoPhotonReleaseLevel=="blocked_test"
                twoPhotonCommandOverride=0;
                protocol.staging_command_voltage_v=0;
            elseif options.TwoPhotonReleaseLevel=="attenuated_test"
                twoPhotonCommandOverride=options.TwoPhotonVoltageOverride;
                if ~isfinite(twoPhotonCommandOverride) || twoPhotonCommandOverride<=0
                    error("adaptive_optopatch:MissingTestCommandVoltage", ...
                        "attenuated_test requires a positive explicit 2P voltage override.");
                end
                selected=protocol.events.stimulation_source=="2p_spiral";
                protocol.events.command_voltage_v(selected)=twoPhotonCommandOverride;
                protocol.events.command_voltage_source(selected)="release_attenuated_test";
            end
        end
        run.trials.executed_pulse_schedule{k}=protocol;
        run.trials.acquisition_duration_s(k)=protocol.acquisition_duration_s;
        row.acquisition_duration_s=protocol.acquisition_duration_s;
        row.pulse_schedule{1}=protocol;
        trialTargets=adaptive_optopatch.apply_acquisition_parameters(targets,protocol);
        preflight=adaptive_optopatch.preflight_trial(trialTargets,row, ...
            "RequireConfirmedLiveProtocol",false,"LiveProtocolConfirmed",true, ...
            "Advisories",row_advisories(row));
        run.trials.preflight_report{k}=preflight;
        if ~preflight.passed
            error("adaptive_optopatch:PreflightFailed","%s", ...
                strjoin(preflight.issues,newline));
        end
        run.trials.acquisition_status(k)="preflight_passed";
        run.trials.settings_snapshot{k}= ...
            adaptive_optopatch.snapshot_luminos_settings(app);

        % THE ACQUISITION'S TIMING, built from the rig profile for this
        % trial's duration. It used to be original.global_props - the
        % struct the Waveforms tab had been left on - with total_time
        % overwritten, which made the sample rate every pulse boundary is
        % quantised to a property of another tab.
        trialTiming=struct([]);
        trialGlobalProps=original.global_props;
        if hardware.owns_daq_timing
            [trialGlobalProps,trialTiming]= ...
                adaptive_optopatch.build_luminos_global_props( ...
                profile,protocol.acquisition_duration_s, ...
                "PreviousGlobalProps",original.global_props);
        end

        onePhotonRows=protocol.events.stimulation_source=="1p_dmd";
        twoPhotonRows=protocol.events.stimulation_source=="2p_spiral";
        pulseTargets=unique(protocol.events.target_cell_id(onePhotonRows),"stable");
        dmdSequencePlan=struct([]);
        config=struct("mode","no_1p_events");
        % Blanket depolarization always runs as a wrapping FLUT round, even
        % for one cell, because the blanket and blank masks alternate with
        % the target's.
        blanketMode=adaptive_optopatch.blanket_depolarization_spec(protocol).enabled;
        dmdAdvance=struct([]);
        maskVaries=any(protocol.events.blue_mask_adjustment_pixels(onePhotonRows)~= ...
            trialTargets.parameters.blue_mask_adjustment_pixels);
        if adaptive_optopatch.is_simultaneous_protocol(protocol)
            config=adaptive_optopatch.prepare_luminos_target(app,trialTargets,row, ...
                "SimultaneousProtocol",protocol,"DryRun",false, ...
                "DmdName",profile.dmd.name,"WriteDmdImmediately",true);
        elseif blanketMode || (any(onePhotonRows) && (any(twoPhotonRows) || ...
                numel(pulseTargets)>1 || maskVaries))
            dmdSequencePlan=adaptive_optopatch.build_dmd_sequence_plan( ...
                protocol,trialTargets, ...
                "HoldPatternUntilTrigger",profile.rig_name=="Spinning_Upright", ...
                "SampleRateHz",double(trialGlobalProps.rate), ...
                "CameraFramePeriodS", ...
                    adaptive_optopatch.daq_camera_frame_period_s(hardware.voltage_camera));
            config=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                hardware.dmd,dmdSequencePlan,"DryRun",false);
        elseif any(onePhotonRows)
            config=adaptive_optopatch.prepare_luminos_target(app,trialTargets,row, ...
                "DryRun",false,"DmdName",profile.dmd.name, ...
                "WriteDmdImmediately",true);
        end
        run.trials.orange_configuration{k}= ...
            adaptive_optopatch.prepare_luminos_orange_mask(app,trialTargets, ...
            "DryRun",false,"Profile",profile);
        run.trials.target_configuration{k}=config;
        run.trials.acquisition_status(k)="configured";

        % mod488 commands come from the frozen resolved schedule; a 1P run
        % has no execution-time voltage override.
        twoPhotonWaveforms=struct([]);
        if any(twoPhotonRows)
            targetIndices=unique(protocol.events.target_index(twoPhotonRows));
            target=trialTargets.targets(targetIndices(1));
            twoPhotonWaveforms=adaptive_optopatch.build_2p_trial_waveforms( ...
                protocol,target,targetingTform, ...
                "SampleRateHz",double(trialGlobalProps.rate), ...
                "MaximumVelocityVPerS",options.MaximumVelocityVPerS, ...
                "MaximumAccelerationVPerS2",options.MaximumAccelerationVPerS2);
            if isfinite(twoPhotonCommandOverride)
                twoPhotonWaveforms.pockels_v(:)=twoPhotonCommandOverride;
            end
        end
        [globalProps,wfmData,waveformSummary]= ...
            adaptive_optopatch.build_luminos_mixed_waveform_config( ...
            trialGlobalProps,original.wfm_data,protocol, ...
            "DmdSequencePlan",dmdSequencePlan, ...
            "TwoPhotonWaveforms",twoPhotonWaveforms, ...
            "OnePhotonProfile",profile,"Manifest",stimulationManifest);
        % Measure the candidate configuration BEFORE it is installed, so a
        % configuration that would drive an AO-owned stimulation line
        % nobody commanded never reaches the DAQ at all.
        trialModality=trial_modality(onePhotonRows,twoPhotonRows);
        accounting=adaptive_optopatch.account_stimulation_outputs( ...
            globalProps,wfmData,"Modality",trialModality, ...
            "Policy",options.StimulationAccountingPolicy, ...
            "Manifest",stimulationManifest, ...
            "Context",sprintf("1p trial %d (%s)",k,string(row.output_tag)));
        run.trials.stimulation_accounting{k}=accounting;
        report_accounting(accounting);
        if ~accounting.passed
            error("adaptive_optopatch:StimulationAccountingFailed","%s", ...
                strjoin(accounting.blocking,newline));
        end

        % Safe state is reasserted per trial, not once at the top of the
        % run. A multi-trial run spends minutes between its first trial and
        % its last, and an earlier trial's failure, a stop, or anything the
        % operator did to the rig in between sits between them.
        % The trial's own modality, not the run's: a pure 1P trial inside a
        % run that also contains 2P trials still must not command the 2P
        % hardware it is not about to use.
        adaptive_optopatch.neutralize_all_stimulation(app, ...
            "Context",sprintf("1p trial %d pre-arm",k),"BlankBlueDmd",false, ...
            "Modality",trialModality,"Manifest",stimulationManifest, ...
            "OnePhotonProfile",profile);

        hardware.daq.global_props=globalProps;
        hardware.daq.wfm_data=wfmData;
        hardware.daq.waveforms_built=false;
        % THE CAMERA CADENCE IS AO'S, on a rig whose profile declares it.
        % The voltage camera is put into DAQ-triggered synchronous readout
        % at the declared frame period and exposure, whatever the Camera
        % tab was left on, and restored afterwards. AO used only to READ
        % these - and a camera left free-running fell through to AutoN and
        % recorded an untriggered movie whose frame rate the archive could
        % only estimate.
        %
        % Every other camera keeps the established behaviour: its frame
        % count is sized for the acquisition and nothing else about it is
        % touched. ROI, binning and field of view are the Camera tab's on
        % every camera, including this one.
        cameraPlan=struct([]);
        if hardware.owns_camera_timing
            [hardware.cameras(hardware.voltage_camera_index),cameraPlan]= ...
                adaptive_optopatch.apply_camera_acquisition_state( ...
                hardware.cameras(hardware.voltage_camera_index), ...
                profile,globalProps.total_time);
            hardware.voltage_camera=hardware.cameras(hardware.voltage_camera_index);
        end
        onlyCameraIndex=0;
        if profile.rig_name=="Spinning_Upright"
            onlyCameraIndex=hardware.voltage_camera_index;
        end
        % Run over every camera as before, voltage camera included. For the
        % AO-owned one it now reads back the cadence just applied and
        % arrives at the same frame count, which is what makes the archived
        % camera_frame_plan describe the recording rather than whatever the
        % Camera tab had been set to.
        [hardware.cameras,cameraFramePlan]= ...
            adaptive_optopatch.set_camera_frames_for_duration( ...
            hardware.cameras,globalProps.total_time, ...
            "AllowRateLimitOverride",options.AllowCameraRateOverride, ...
            "OnlyCameraIndex",onlyCameraIndex);
        waveformSummary.camera_frame_plan=cameraFramePlan;
        waveformSummary.camera_acquisition_state=cameraPlan;
        waveformSummary.daq_timing=trialTiming;
        waveformSummary.two_photon_release_level=options.TwoPhotonReleaseLevel;
        run.trials.waveform_summary{k}=waveformSummary;

        % Only now is the beam path opened, and only after everything above
        % has succeeded. mod488 stays dark: the buffered waveform is what
        % decides when light is emitted, and this shutter write must not
        % become a second source of timing.
        hardware.modulator.level=profile.modulator.dark_v;
        if blanketMode
            % Before any light: the playlist must still be where Set_Playlist
            % left it. A stray edge since arming would start every state
            % one mask late.
            check_blanket_dmd_still_armed(hardware.dmd,config);
        end
        % The orange recording shutter, opened for EVERY acquisition
        % whatever it stimulates: 594 nm is how the voltage is read out, so
        % a trial with no blue light at all still needs it. Opened before
        % the blue shutter so the two settle together under one pause.
        if ~isempty(hardware.orange_shutter)
            hardware.orange_shutter.State=profile.orange_shutter.open_state;
        end
        if any(onePhotonRows) || blanketMode
            % A blanket recruitment sweep targets no cell and still emits
            % 488 nm light on every cycle, so the shutter opens for it too.
            hardware.shutter.State=profile.shutter.open_state;
        end
        if ~isempty(hardware.orange_shutter) || any(onePhotonRows) || blanketMode
            pause(options.ShutterSettleTimeS);
        end
        app.acquisition_active=true;
        run.trials.acquisition_status(k)="acquiring";
        save_checkpoint();
        report_progress(k,"acquiring","");
        bins=arrayfun(@(camera)camera.bin,hardware.cameras);
        if strlength(options.OutputRoot)>0
            adaptive_optopatch.execute_waveform_camera_sync(app,bins, ...
                "tag",char(row.output_tag),"fullpath",char(options.OutputRoot));
        else
            adaptive_optopatch.execute_waveform_camera_sync(app,bins, ...
                "tag",char(row.output_tag));
        end
        wait_for_acquisition(globalProps.total_time+options.TimeoutMarginS);
        hardware.shutter.State=profile.shutter.closed_state;
        hardware.modulator.level=profile.modulator.dark_v;
        close_orange_shutter(hardware,profile);
        if blanketMode
            % Read before the DMD is blanked: blanking reloads the device.
            dmdAdvance=adaptive_optopatch.verify_dmd_advance_count( ...
                config.dmd_progress_armed, ...
                adaptive_optopatch.read_dmd_projection_progress(hardware.dmd), ...
                dmdSequencePlan.expected_trigger_count, ...
                dmdSequencePlan.programmed_playlist_length);
        end

        experimentDirectory=string(app.expfolder);
        if ~isfolder(experimentDirectory) || ...
                ~isfile(fullfile(experimentDirectory,"output_data.mat"))
            error("adaptive_optopatch:MissingLuminosOutput", ...
                "Luminos completed but output_data.mat was not found in %s.",experimentDirectory);
        end
        record=build_trial_record(row,waveformSummary,config,experimentDirectory);
        if blanketMode
            record.dmd_advance_verification=dmdAdvance;
            record.blanket_validity=blanket_validity(dmdAdvance);
        end
        adaptive_optopatch_record=record;
        save(fullfile(experimentDirectory,"output_data.mat"), ...
            "adaptive_optopatch_record","-append");
        if blanketMode
            % Archived first, so the evidence is on disk; then the run stops.
            % Later rounds of a shifted playlist are not data.
            report_blanket_advance(dmdAdvance,k);
        end
        run.trials.experiment_directory(k)=experimentDirectory;
        run.trials.acquisition_status(k)="completed";
        run.trials.error_message(k)="";
        run.trials.cleanup_error_message(k)="";
        completedThisCall=completedThisCall+1;
        if options.BlankDmdAfterTrial
            try
                blank_dmd();
            catch cleanupException
                run.trials.acquisition_status(k)="completed_cleanup_failed";
                run.trials.cleanup_error_message(k)=string(cleanupException.message);
                run.cleanup_failed_trial=k;
                cleanupRecord=struct( ...
                    "acquisition_completed",true, ...
                    "cleanup_completed",false, ...
                    "cleanup_error_identifier",string(cleanupException.identifier), ...
                    "cleanup_error_message",string(cleanupException.message), ...
                    "recorded_at",string(datetime("now","TimeZone","local")));
                adaptive_optopatch_cleanup=cleanupRecord;
                save(fullfile(experimentDirectory,"output_data.mat"), ...
                    "adaptive_optopatch_cleanup","-append");
                save_checkpoint();
                failure=MException( ...
                    "adaptive_optopatch:PostAcquisitionCleanupFailed", ...
                    "Acquisition %d completed and output_data.mat was archived, " + ...
                     "but post-acquisition DMD blanking failed: %s. The run " + ...
                     "stopped before the next acquisition.", ...
                    k,cleanupException.message);
                failure=addCause(failure,cleanupException);
                throw(failure)
            end
        end
        save_checkpoint();
        report_progress(k,run.trials.acquisition_status(k),experimentDirectory);
        if ~isempty(options.StopRequestedFcn) && logical(options.StopRequestedFcn())
            break
        end
        if options.StopAfterTrial>0 && completedThisCall>=options.StopAfterTrial
            break
        end
    catch exception
        % Before anything else, and before the unwind below gets its turn:
        % the 2P runner has always darkened its modulator on this path and
        % the 1P runner did not, so a mid-trial failure left 488 nm behind
        % an open shutter until onCleanup ran.
        try
            hardware.modulator.level=profile.modulator.dark_v;
        catch
        end
        try
            hardware.shutter.State=profile.shutter.closed_state;
        catch
        end
        try
            close_orange_shutter(hardware,profile);
        catch
        end
        completedData=ismember(string(run.trials.acquisition_status(k)), ...
            ["completed","completed_cleanup_failed","analyzed"]);
        if ~completedData
            run.trials.acquisition_status(k)="failed";
            run.trials.error_message(k)=string(exception.message);
            run.failed_trial=k;
        end
        run.last_error=struct("identifier",string(exception.identifier), ...
            "message",string(exception.message), ...
            "stack",exception.stack);
        save_checkpoint();
        report_progress(k,run.trials.acquisition_status(k),"");
        rethrow(exception)
    end
end
run.finished_at=string(datetime("now","TimeZone","local"));
save_checkpoint();

    function wait_for_acquisition(timeoutS)
        started=tic;
        while ~logical(app.exp_complete)
            pause(0.05); drawnow;
            if toc(started)>timeoutS
                error("adaptive_optopatch:LuminosAcquisitionTimeout", ...
                    "Luminos did not complete within %.1f s.",timeoutS);
            end
        end
        while isprop(app,"round_complete") && ~logical(app.round_complete)
            pause(0.05); drawnow;
            if toc(started)>timeoutS+10, break; end
        end
    end

    function record=build_trial_record(row,waveformSummary,config,folder)
        record=struct;
        record.schema_version="1.0.0";
        record.simulation=simulation;
        record.backend=string(class(app));
        record.created_at=string(datetime("now","TimeZone","local"));
        record.hardware_profile=profile;
        record.trial=row;
        record.pulse_schedule=run.trials.executed_pulse_schedule{k};
        record.waveform_summary=waveformSummary;
        record.target_configuration=config;
        record.experiment_directory=folder;
        record.run_directory=options.OutputDirectory;
        record.reference_model_path=linked_reference_path(options.OutputDirectory);
        record.obis_power_w=hardware.laser_power_w;
        record.obis_mode=hardware.laser_mode;
        if ~isempty(hardware.laser)
            record.obis_power_w=double(hardware.laser.SetPower);
            record.obis_mode=string(hardware.laser.Mode);
        end
        record.daq_synchronization= ...
            adaptive_optopatch.capture_luminos_daq_sync(hardware.daq);
        record.camera_geometry=cameraGeometry;
        record.dmd_calibration=dmdCalibration;
        record.expected_frame_map=make_frame_map(waveformSummary.pulses);
        record.realized_pulses=join_pulse_provenance( ...
            waveformSummary.pulses,record.expected_frame_map);
        record.advisories=row_advisories(row);
        record.stimulation_accounting=run.trials.stimulation_accounting{k};
    end

    function warn_neutralization(neutralization)
        % Not an error: a rig without 2P hardware cannot neutralise a
        % Pockels cell it does not have, and a 1P run there is still valid.
        % On the VU, which has all of it, this is a real safety signal, so
        % it is said out loud as well as archived.
        if neutralization.all_succeeded, return; end
        warning("adaptive_optopatch:StimulationNeutralizationIncomplete", ...
            "Could not neutralize: %s. Check the run's " + ...
            "initial_neutralization report.", ...
            strjoin(neutralization.failures,", "));
    end

    function report_accounting(accounting)
        % Unaccounted terminals are never silently passed through, whatever
        % the policy says about blocking on them.
        for w=reshape(accounting.warnings,1,[])
            warning("adaptive_optopatch:UnaccountedStimulationOutput","%s",w);
        end
        for v=reshape(accounting.violations,1,[])
            warning("adaptive_optopatch:StimulationOwnershipViolation","%s",v);
        end
    end

    function map=make_frame_map(pulses)
        frameRate=cameraFramePlan(hardware.voltage_camera_index).frame_rate_hz;
        if ~isfinite(frameRate)
            frameRate=double(hardware.voltage_camera.calculate_framerate());
        end
        expected_frame=floor(pulses.onset_s*frameRate)+1;
        if blanketMode
            % Blanket epochs start exactly on frame boundaries by
            % construction, where floor(seconds x rate) can land one frame
            % early on floating-point error; count samples instead.
            stateTable=dmdSequencePlan.state_table;
            expected_frame=round(pulses.onset_s*stateTable.sample_rate_hz)/ ...
                stateTable.camera_frame_samples+1;
        end
        map=table(pulses.pulse_id,pulses.onset_s,expected_frame, ...
            repmat(frameRate,height(pulses),1), ...
            'VariableNames',{'pulse_id','onset_s','expected_frame','expected_frame_rate_hz'});
    end

    function realized=join_pulse_provenance(pulses,frameMap)
        realized=pulses;
        realized.expected_camera_frame=frameMap.expected_frame;
        realized.expected_camera_frame_rate_hz=frameMap.expected_frame_rate_hz;
    end

    function report_progress(index,status,experimentDirectory)
        % One small record per acquisition boundary, for an observer that
        % wants to know where the run has got to.
        %
        % SMALL ON PURPOSE. The checkpoint beside it already holds the whole
        % truth - every trial's settings snapshot, preflight report, target
        % configuration and executed schedule - and reading that file is what
        % the controller used to have to do to answer "4 of 10". This carries
        % the counts and the identity and nothing else, so an observer can be
        % called after every acquisition without the run paying for it.
        %
        % NEVER FAILS THE RUN. An observer is a bystander; a broken one must
        % not abort an acquisition that has already happened, and must not
        % mask the exception the catch block is on its way to rethrowing.
        if isempty(options.ProgressFcn), return; end
        try
            targetCells=strings(0,1);
            try
                targetCells=string(run.trials.target_cell_id(index));
            catch
            end
            record=struct( ...
                "schema_version","1.0.0", ...
                "trial_index",double(index), ...
                "trial_id",double(run.trials.trial_id(index)), ...
                "status",string(status), ...
                ... % The same set runProgress and batch_is_complete count,
                ... % so the in-memory answer and the checkpoint-derived one
                ... % can never differ by one.
                "completed_in_batch",double(sum(ismember( ...
                    string(run.trials.acquisition_status), ...
                    ["completed","analyzed"]))), ...
                "acquisitions_in_batch",double(height(run.trials)), ...
                "target_cell_ids",reshape(targetCells,[],1), ...
                "experiment_directory",string(experimentDirectory));
            options.ProgressFcn(record);
        catch
        end
    end

    function save_checkpoint()
        run.updated_at=string(datetime("now","TimeZone","local"));
        % Rolled up here rather than after the loop so a run that threw
        % still archives what its accounting measured. A failed run is
        % exactly the one somebody will want to read this from.
        run.stimulation_accounting= ...
            adaptive_optopatch.summarize_stimulation_accounting( ...
                run.trials.stimulation_accounting);
        if strlength(checkpoint)>0, save(checkpoint,"run","-v7.3"); end
    end

    function blank_dmd()
        hardware.dmd.Target=adaptive_optopatch.blank_dmd_pattern(hardware.dmd);
        hardware.dmd.Write_Static();
    end

end

function check_blanket_dmd_still_armed(dmd,config)
armed=config.dmd_progress_armed;
if ~armed.available, return; end
current=adaptive_optopatch.read_dmd_projection_progress(dmd);
if ~current.available, return; end
fields=["sequence_counter","frame_counter","frames_per_sub_sequence"];
moved=fields(arrayfun(@(name)current.(name)~=armed.(name),fields));
if ~isempty(moved)
    error("adaptive_optopatch:DmdAdvancedBeforeAcquisition", ...
        "The blanket DMD playlist moved after it was armed and before the " + ...
        "acquisition started (%s changed). No light was emitted. Check the " + ...
        "DMD trigger line for stray edges.",strjoin(moved,", "));
end
end

function validity=blanket_validity(dmdAdvance)
switch dmdAdvance.status
    case "matched"
        validity="valid";
    case "mismatched"
        validity="invalid_dmd_advance_mismatch";
    otherwise
        validity="unverified_dmd_advance_count";
end
end

function report_blanket_advance(dmdAdvance,trialIndex)
if dmdAdvance.status=="mismatched"
    error("adaptive_optopatch:DmdAdvanceMismatch", ...
        "Trial %d is INVALID: %s The DMD playlist may have been shifted " + ...
        "against mod488, which can put Vstim on the blanket union mask. " + ...
        "Its record is archived with blanket_validity " + ...
        "invalid_dmd_advance_mismatch, and the run stopped.", ...
        trialIndex,dmdAdvance.detail);
end
if dmdAdvance.status~="matched"
    warning("adaptive_optopatch:DmdAdvanceUnverified", ...
        "Trial %d: the DMD advance count could not be verified (%s). " + ...
        "It is archived as unverified_dmd_advance_count.", ...
        trialIndex,dmdAdvance.detail);
end
end

function path=linked_reference_path(runDirectory)
path="";
if strlength(runDirectory)>0
    candidate=fullfile(runDirectory,"reference_model.mat");
    if isfile(candidate)
        path=adaptive_optopatch.make_portable_reference_path(string(candidate));
    end
end
end

function value=row_advisories(row)
value=struct([]);
if ismember("advisories",string(row.Properties.VariableNames))
    value=row.advisories{1};
end
end

function original=capture_original_state(hardware)
%CAPTURE_ORIGINAL_STATE Everything this run is about to take over.
%   Read once, before anything is written, and handed to
%   restore_1p_hardware - which runs on success, on error, on abort and on
%   Ctrl-C. What is captured here is exactly what is written during the run;
%   nothing else is captured, so nothing else can be "restored" over an
%   operator's deliberate change.
original=struct("global_props",hardware.daq.global_props, ...
    "wfm_data",hardware.daq.wfm_data, ...
    "camera_frames",arrayfun(@(camera)camera.frames_requested,hardware.cameras), ...
    "laser_power_w",hardware.laser_power_w);
% The voltage camera's cadence, when this rig's profile says AO owns it.
% Only the voltage camera: a second camera on the rig is not part of the
% acquisition AO configures, and its frame count is already covered above.
original.camera_acquisition_state=struct([]);
if isfield(hardware,"owns_camera_timing") && hardware.owns_camera_timing
    original.camera_acquisition_state= ...
        adaptive_optopatch.capture_camera_acquisition_state( ...
            hardware.voltage_camera);
end
% The live-view orange level. AO installs a buffered constant on this
% terminal, and when the task releases the line the channel keeps the last
% sample it played - so without putting this back the live view returns at
% the recording voltage rather than at whatever the operator had been
% looking at.
original.orange_level=NaN;
if ~isempty(hardware.orange_modulator)
    try
        original.orange_level=double(hardware.orange_modulator.level);
    catch
    end
end
end

function trials=ensure_column(trials,name,value)
if ~ismember(name,string(trials.Properties.VariableNames)), trials.(name)=value; end
end

function value=trial_modality(onePhotonRows,twoPhotonRows)
if any(onePhotonRows) && any(twoPhotonRows)
    value="mixed";
elseif any(twoPhotonRows)
    value="2p_spiral";
else
    value="1p_dmd";
end
end

function restore_1p_hardware(app,hardware,original,profile,blankDmd, ...
        restorePower,stopLaser,modality,dmdOwnership,stimulationManifest)
% Stimulation goes safe first, over what this run actually used. Cleanup
% once unwound only the modality that had been selected, so a 1P run ended
% with the Pockels cell and the galvos exactly as the previous 2P run had
% left them; the remedy for that was to command everything, which made a
% pure 1P run write to 2P hardware it never touched. Both are wrong. What
% this run owned is made safe, and what the manifest declares suppressed
% for it is not commanded - not darkened, and not restored to a saved
% value either, which would be a command like any other.
try
    adaptive_optopatch.neutralize_all_stimulation(app, ...
        "Context","1p cleanup","BlankBlueDmd",blankDmd,"Modality",modality, ...
        "Manifest",stimulationManifest,"OnePhotonProfile",profile);
catch
end
try
    hardware.shutter.State=profile.shutter.closed_state;
catch
end
try
    hardware.modulator.level=profile.modulator.dark_v;
catch
end
% THE ORANGE SHUTTER IS CLOSED, NOT RESTORED, and the orange LEVEL is
% restored, not zeroed. They are opposite decisions about one light path
% and both are deliberate.
%
% The shutter is the mechanical block. Cleanup runs when an acquisition
% ended, failed, was aborted or was interrupted, and the state that is
% right in all four cases is closed - the same rule shutter488 has always
% followed. Putting back an open shutter because the operator happened to
% have one open would mean a failed run leaving the preparation
% illuminated, which is the case cleanup exists for.
%
% The level is different: it is not a hazard, it is the operator's live
% view. AO drove a buffered constant onto that terminal and the channel
% holds its last sample once the task releases it, so without this the
% live view comes back at the recording voltage rather than at whatever
% the operator had been looking at before the run. Restoring it is undoing
% AO's own write, not overriding a choice.
try
    close_orange_shutter(hardware,profile);
catch
end
try
    if ~isempty(hardware.orange_modulator) && isfinite(original.orange_level)
        hardware.orange_modulator.level=original.orange_level;
    end
catch
end
try
    if isprop(app,"acquisition_active") && logical(app.acquisition_active)
        for k=1:numel(hardware.cameras)
            hardware.cameras(k).Stop();
        end
        disconnect_clock_bridge(hardware.daq);
        hardware.daq.reset();
        app.acquisition_active=false;
    end
catch
end
try
    if blankDmd
        hardware.dmd.Target=adaptive_optopatch.blank_dmd_pattern(hardware.dmd);
        hardware.dmd.Write_Static();
    end
catch
end
try
    hardware.daq.global_props=original.global_props;
    hardware.daq.wfm_data=original.wfm_data;
    hardware.daq.waveforms_built=false;
catch
end
% The voltage camera's cadence first, then every camera's frame count. The
% cadence restore writes frames_requested too, so the loop below runs after
% it and has the last word - which matters on a rig where AO owns the
% cadence but the capture could not read one of the other properties.
try
    if ~isempty(original.camera_acquisition_state)
        adaptive_optopatch.restore_camera_acquisition_state( ...
            hardware.voltage_camera,original.camera_acquisition_state);
    end
catch
end
for k=1:numel(hardware.cameras)
    try
        hardware.cameras(k).frames_requested=original.camera_frames(k);
    catch
    end
end
try
    if restorePower && ~isempty(hardware.laser)
        hardware.laser.SetPower=original.laser_power_w;
    end
catch
end
try
    if stopLaser && ~isempty(hardware.laser), hardware.laser.Stop(); end
catch
end
% Last, after the DMDs have been blanked: releasing restores each device's
% Write Stack setting, and doing it earlier would let the generic stack
% reload over the blank if anything else armed an acquisition in between.
adaptive_optopatch.release_dmd_pattern_ownership(dmdOwnership);
end

function close_orange_shutter(hardware,profile)
%CLOSE_ORANGE_SHUTTER Block 594 nm, on a rig that declares the shutter.
if isempty(hardware.orange_shutter), return; end
hardware.orange_shutter.State=profile.orange_shutter.closed_state;
end

function disconnect_clock_bridge(daq)
try
    if ismethod(daq,"Disconnect_Clock_Bridge")
        daq.Disconnect_Clock_Bridge();
    end
catch
end
end
