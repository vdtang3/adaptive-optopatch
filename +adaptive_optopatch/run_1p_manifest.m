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
    options.LaserPowerW (1,1) double = NaN
    options.ConfirmLiveOutput (1,1) logical = false
    options.ManageLaserEmission (1,1) logical = true
    options.BlankDmdAfterTrial (1,1) logical = true
    options.ShutterSettleTimeS (1,1) double {mustBeNonnegative} = 0.05
    options.TimeoutMarginS (1,1) double {mustBePositive} = 30
    options.StopRequestedFcn = []
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
        "Live 488-nm output was not confirmed. Review the DMD mask, OBIS " + ...
        "power, and mod488 voltage, then pass ConfirmLiveOutput=true.");
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
dmdCalibration=adaptive_optopatch.capture_1p_dmd_calibration(hardware,targets);
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

% Neutral state first, source power second. The OBIS setpoint used to be
% raised before mod488 was known to be dark, so for the length of those two
% statements the laser was at experiment power behind a modulator holding
% whatever the previous run had left on it. Nothing downstream needs the
% power set that early.
try
    run.initial_neutralization=adaptive_optopatch.neutralize_all_stimulation( ...
        app,"Context","1p run start","Modality",runModality);
    warn_neutralization(run.initial_neutralization);
    if isfinite(options.LaserPowerW)
        hardware.laser.SetPower=options.LaserPowerW;
    end
    if options.ManageLaserEmission && ~hardware.laser_was_on
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
        runnerStartedLaser,runModality);
    rethrow(exception)
end
cleanup=onCleanup(@()restore_1p_hardware(app,hardware,original,profile, ...
    options.BlankDmdAfterTrial,isfinite(options.LaserPowerW), ...
    runnerStartedLaser,runModality));

completedThisCall=0;
for k=1:n
    status=string(run.trials.acquisition_status(k));
    if options.Resume && ismember(status, ...
            ["completed","completed_cleanup_failed","analyzed"]), continue; end
    try
        row=run.trials(k,:);
        protocol=adaptive_optopatch.normalize_protocol(row.pulse_schedule{1});
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

        onePhotonRows=protocol.events.stimulation_source=="1p_dmd";
        twoPhotonRows=protocol.events.stimulation_source=="2p_spiral";
        pulseTargets=unique(protocol.events.target_cell_id(onePhotonRows),"stable");
        dmdSequencePlan=struct([]);
        config=struct("mode","no_1p_events");
        maskVaries=any(protocol.events.blue_mask_adjustment_pixels(onePhotonRows)~= ...
            trialTargets.parameters.blue_mask_adjustment_pixels);
        if any(onePhotonRows) && (any(twoPhotonRows) || numel(pulseTargets)>1 || maskVaries)
            dmdSequencePlan=adaptive_optopatch.build_dmd_sequence_plan(protocol,trialTargets);
            config=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                hardware.dmd,dmdSequencePlan,"DryRun",false);
        elseif any(onePhotonRows)
            config=adaptive_optopatch.prepare_luminos_target(app,trialTargets,row, ...
                "DryRun",false,"DmdName",profile.dmd.name, ...
                "WriteDmdImmediately",true);
        end
        run.trials.orange_configuration{k}= ...
            adaptive_optopatch.prepare_luminos_orange_mask(app,trialTargets, ...
            "DryRun",false);
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
                "SampleRateHz",double(original.global_props.rate), ...
                "MaximumVelocityVPerS",options.MaximumVelocityVPerS, ...
                "MaximumAccelerationVPerS2",options.MaximumAccelerationVPerS2);
            if isfinite(twoPhotonCommandOverride)
                twoPhotonWaveforms.pockels_v(:)=twoPhotonCommandOverride;
            end
        end
        [globalProps,wfmData,waveformSummary]= ...
            adaptive_optopatch.build_luminos_mixed_waveform_config( ...
            original.global_props,original.wfm_data,protocol, ...
            "DmdSequencePlan",dmdSequencePlan, ...
            "TwoPhotonWaveforms",twoPhotonWaveforms);
        % Measure the candidate configuration BEFORE it is installed, so a
        % configuration that would drive an AO-owned stimulation line
        % nobody commanded never reaches the DAQ at all.
        trialModality=trial_modality(onePhotonRows,twoPhotonRows);
        accounting=adaptive_optopatch.account_stimulation_outputs( ...
            globalProps,wfmData,"Modality",trialModality, ...
            "Policy",options.StimulationAccountingPolicy, ...
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
            "Modality",trialModality);

        hardware.daq.global_props=globalProps;
        hardware.daq.wfm_data=wfmData;
        hardware.daq.waveforms_built=false;
        [hardware.cameras,cameraFramePlan]= ...
            adaptive_optopatch.set_camera_frames_for_duration( ...
            hardware.cameras,globalProps.total_time, ...
            "AllowRateLimitOverride",options.AllowCameraRateOverride);
        waveformSummary.camera_frame_plan=cameraFramePlan;
        waveformSummary.two_photon_release_level=options.TwoPhotonReleaseLevel;
        run.trials.waveform_summary{k}=waveformSummary;

        % Only now is the beam path opened, and only after everything above
        % has succeeded. mod488 stays dark: the buffered waveform is what
        % decides when light is emitted, and this shutter write must not
        % become a second source of timing.
        hardware.modulator.level=profile.modulator.dark_v;
        if any(onePhotonRows)
            hardware.shutter.State=profile.shutter.open_state;
            pause(options.ShutterSettleTimeS);
        end
        app.acquisition_active=true;
        run.trials.acquisition_status(k)="acquiring";
        save_checkpoint();
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

        experimentDirectory=string(app.expfolder);
        if ~isfolder(experimentDirectory) || ...
                ~isfile(fullfile(experimentDirectory,"output_data.mat"))
            error("adaptive_optopatch:MissingLuminosOutput", ...
                "Luminos completed but output_data.mat was not found in %s.",experimentDirectory);
        end
        record=build_trial_record(row,waveformSummary,config,experimentDirectory);
        adaptive_optopatch_record=record;
        save(fullfile(experimentDirectory,"output_data.mat"), ...
            "adaptive_optopatch_record","-append");
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
        record.pulse_schedule=row.pulse_schedule{1};
        record.waveform_summary=waveformSummary;
        record.target_configuration=config;
        record.experiment_directory=folder;
        record.run_directory=options.OutputDirectory;
        record.reference_model_path=linked_reference_path(options.OutputDirectory);
        record.obis_power_w=double(hardware.laser.SetPower);
        record.obis_mode=string(hardware.laser.Mode);
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
        map=table(pulses.pulse_id,pulses.onset_s,expected_frame, ...
            repmat(frameRate,height(pulses),1), ...
            'VariableNames',{'pulse_id','onset_s','expected_frame','expected_frame_rate_hz'});
    end

    function realized=join_pulse_provenance(pulses,frameMap)
        realized=pulses;
        realized.expected_camera_frame=frameMap.expected_frame;
        realized.expected_camera_frame_rate_hz=frameMap.expected_frame_rate_hz;
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
original=struct("global_props",hardware.daq.global_props, ...
    "wfm_data",hardware.daq.wfm_data, ...
    "camera_frames",arrayfun(@(camera)camera.frames_requested,hardware.cameras), ...
    "laser_power_w",hardware.laser_power_w);
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
        restorePower,stopLaser,modality)
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
        "Context","1p cleanup","BlankBlueDmd",blankDmd,"Modality",modality);
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
for k=1:numel(hardware.cameras)
    try
        hardware.cameras(k).frames_requested=original.camera_frames(k);
    catch
    end
end
try
    if restorePower
        hardware.laser.SetPower=original.laser_power_w;
    end
catch
end
try
    if stopLaser, hardware.laser.Stop(); end
catch
end
end

function disconnect_clock_bridge(daq)
try
    if ismethod(daq,"Disconnect_Clock_Bridge")
        daq.Disconnect_Clock_Bridge();
    end
catch
end
end
