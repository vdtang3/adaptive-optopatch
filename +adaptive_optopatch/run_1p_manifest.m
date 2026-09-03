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
    options.ModulatorVoltageOverride (1,1) double = NaN
    options.LaserPowerW (1,1) double = NaN
    options.ConfirmLiveOutput (1,1) logical = false
    options.ManageLaserEmission (1,1) logical = true
    options.BlankDmdAfterTrial (1,1) logical = true
    options.ShutterSettleTimeS (1,1) double {mustBeNonnegative} = 0.05
    options.TimeoutMarginS (1,1) double {mustBePositive} = 30
    options.StopRequestedFcn = []
end
if ~options.ConfirmLiveOutput
    error("adaptive_optopatch:LiveOutputNotConfirmed", ...
        "Live 488-nm output was not confirmed. Review the DMD mask, OBIS " + ...
        "power, and mod488 voltage, then pass ConfirmLiveOutput=true.");
end
if ~isfield(manifest,"trials") || isempty(manifest.trials)
    error("adaptive_optopatch:EmptyManifest","The manifest has no trials.");
end
if any(string(manifest.trials.stimulation_mode)~="1p_dmd")
    error("adaptive_optopatch:WrongRunnerMode", ...
        "run_1p_manifest accepts only 1p_dmd trials.");
end
profile=options.Profile;
if isfinite(options.LaserPowerW) && ...
        (options.LaserPowerW<0 || options.LaserPowerW>profile.laser.max_power_w)
    error("adaptive_optopatch:LaserPowerOutOfRange", ...
        "Requested OBIS power must be between 0 and %.3g W.",profile.laser.max_power_w);
end
if isfinite(options.ModulatorVoltageOverride) && ...
        (options.ModulatorVoltageOverride<profile.modulator.minimum_v || ...
         options.ModulatorVoltageOverride>profile.modulator.maximum_v)
    error("adaptive_optopatch:ModulatorVoltageOutOfRange", ...
        "Requested mod488 command must be between %.3g and %.3g V.", ...
        profile.modulator.minimum_v,profile.modulator.maximum_v);
end

hardware=adaptive_optopatch.resolve_luminos_1p_hardware(app,profile);
original=capture_original_state(hardware);
runnerStartedLaser=false;

trials=manifest.trials;
n=height(trials);
trials=ensure_column(trials,"preflight_report",cell(n,1));
trials=ensure_column(trials,"target_configuration",cell(n,1));
trials=ensure_column(trials,"settings_snapshot",cell(n,1));
trials=ensure_column(trials,"waveform_summary",cell(n,1));
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

simulation=isa(app,"adaptive_optopatch.testing.SimulatedLuminosApp");
run=struct("schema_version","0.4.0","mode","live_1p_dmd", ...
    "simulation",simulation,"backend",string(class(app)), ...
    "hardware_profile",profile, ...
    "started_at",string(datetime("now","TimeZone","local")), ...
    "initial_settings_snapshot",adaptive_optopatch.snapshot_luminos_settings(app), ...
    "trials",trials);

try
    if isfinite(options.LaserPowerW)
        hardware.laser.SetPower=options.LaserPowerW;
    end
    hardware.modulator.level=profile.modulator.dark_v;
    hardware.shutter.State=profile.shutter.closed_state;
    if options.ManageLaserEmission && ~hardware.laser_was_on
        hardware.laser.Start();
        runnerStartedLaser=true;
    end
catch exception
    restore_1p_hardware(app,hardware,original,profile, ...
        options.BlankDmdAfterTrial,isfinite(options.LaserPowerW),runnerStartedLaser);
    rethrow(exception)
end
cleanup=onCleanup(@()restore_1p_hardware(app,hardware,original,profile, ...
    options.BlankDmdAfterTrial,isfinite(options.LaserPowerW),runnerStartedLaser));

completedThisCall=0;
for k=1:n
    status=string(run.trials.acquisition_status(k));
    if options.Resume && ismember(status,["completed","analyzed"]), continue; end
    try
        row=run.trials(k,:);
        preflight=adaptive_optopatch.preflight_trial(targets,row, ...
            "RequireConfirmedLiveProtocol",false,"LiveProtocolConfirmed",true);
        run.trials.preflight_report{k}=preflight;
        if ~preflight.passed
            error("adaptive_optopatch:PreflightFailed","%s", ...
                strjoin(preflight.issues,newline));
        end
        run.trials.acquisition_status(k)="preflight_passed";
        run.trials.settings_snapshot{k}= ...
            adaptive_optopatch.snapshot_luminos_settings(app);

        config=adaptive_optopatch.prepare_luminos_target(app,targets,row, ...
            "DryRun",false,"DmdName",profile.dmd.name, ...
            "WriteDmdImmediately",true);
        run.trials.target_configuration{k}=config;
        run.trials.acquisition_status(k)="configured";

        voltageOverride=options.ModulatorVoltageOverride;
        if row.is_null, voltageOverride=0; end
        [globalProps,wfmData,waveformSummary]= ...
            adaptive_optopatch.build_luminos_1p_waveform_config( ...
            original.global_props,original.wfm_data,row.pulse_schedule{1},profile, ...
            "ModulatorVoltageOverride",voltageOverride);
        hardware.daq.global_props=globalProps;
        hardware.daq.wfm_data=wfmData;
        hardware.daq.waveforms_built=false;
        [hardware.cameras,cameraFramePlan]= ...
            adaptive_optopatch.set_camera_frames_for_duration( ...
            hardware.cameras,globalProps.total_time);
        waveformSummary.camera_frame_plan=cameraFramePlan;
        run.trials.waveform_summary{k}=waveformSummary;

        hardware.modulator.level=profile.modulator.dark_v;
        hardware.shutter.State=profile.shutter.open_state;
        pause(options.ShutterSettleTimeS);
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
        completedThisCall=completedThisCall+1;
        if options.BlankDmdAfterTrial, blank_dmd(); end
        save_checkpoint();
        if ~isempty(options.StopRequestedFcn) && logical(options.StopRequestedFcn())
            break
        end
        if options.StopAfterTrial>0 && completedThisCall>=options.StopAfterTrial
            break
        end
    catch exception
        run.trials.acquisition_status(k)="failed";
        run.trials.error_message(k)=string(exception.message);
        run.failed_trial=k;
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
        record.schema_version="0.1.0";
        record.simulation=simulation;
        record.backend=string(class(app));
        record.created_at=string(datetime("now","TimeZone","local"));
        record.hardware_profile=profile;
        record.trial=row;
        record.pulse_schedule=row.pulse_schedule{1};
        record.waveform_summary=waveformSummary;
        record.target_configuration=config;
        record.experiment_directory=folder;
        record.obis_power_w=double(hardware.laser.SetPower);
        record.obis_mode=string(hardware.laser.Mode);
        record.daq_synchronization= ...
            adaptive_optopatch.capture_luminos_daq_sync(hardware.daq);
        record.expected_frame_map=make_frame_map(waveformSummary.pulses);
    end

    function map=make_frame_map(pulses)
        frameRate=cameraFramePlan(hardware.voltage_camera_index).frame_rate_hz;
        if ~isfinite(frameRate)
            frameRate=double(hardware.voltage_camera.calculate_framerate());
        end
        expected_frame=floor(pulses.onset_s*frameRate)+1;
        map=table(pulses.pulse_index,pulses.onset_s,expected_frame, ...
            repmat(frameRate,height(pulses),1), ...
            'VariableNames',{'pulse_index','onset_s','expected_frame','expected_frame_rate_hz'});
    end

    function save_checkpoint()
        run.updated_at=string(datetime("now","TimeZone","local"));
        if strlength(checkpoint)>0, save(checkpoint,"run","-v7.3"); end
    end

    function blank_dmd()
        hardware.dmd.Target=false(hardware.dmd.Dimensions);
        hardware.dmd.Write_Static();
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

function restore_1p_hardware(app,hardware,original,profile,blankDmd,restorePower,stopLaser)
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
        hardware.dmd.Target=false(hardware.dmd.Dimensions);
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
