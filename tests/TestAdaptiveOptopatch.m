classdef TestAdaptiveOptopatch < matlab.unittest.TestCase
    methods (Test)
        function warnsWhenLiveScannerIsUnavailable(testCase)
            [calibration,message]= ...
                adaptive_optopatch.get_live_scanner_calibration([]);
            testCase.verifyEmpty(calibration);
            testCase.verifyTrue(contains(message,"Live Luminos app was not supplied"));
        end

        function findsOutputDataAndLatestPlanningSession(testCase)
            root=tempname; mkdir(root); cleanup=onCleanup(@()rmdir(root,"s")); %#ok<NASGU>
            experimentFolder=fullfile(root,"experiment"); mkdir(experimentFolder);
            Device_Data={struct("rigName","Virtual_Upright")}; %#ok<NASGU>
            save(fullfile(experimentFolder,"output_data.mat"),"Device_Data");
            located=adaptive_optopatch.find_luminos_experiment(root);
            testCase.verifyEqual(located.experiment_directory,string(experimentFolder));

            planFolder=fullfile(root,"adaptive_optopatch_test_20260716_120000");
            mkdir(planFolder);
            reference=struct("source_experiment",string(experimentFolder)); %#ok<NASGU>
            planning_session=struct("image_size",[10 12], ... %#ok<NASGU>
                "roi_positions",{{[1 1;2 1;2 2]}}, ...
                "parameters",struct("pulse_count",200));
            save(fullfile(planFolder,"reference_model.mat"),"reference");
            save(fullfile(planFolder,"planning_session.mat"),"planning_session");
            bundle=adaptive_optopatch.find_latest_planning_bundle(root, ...
                "ExperimentDirectory",experimentFolder);
            testCase.verifyEqual(bundle.folder,string(planFolder));
            testCase.verifyTrue(isfile(bundle.session_path));
        end

        function selectsCellFreeLocalParkingPoints(testCase)
            masks=false(80,100,2);
            masks(35:45,25:35,1)=true;
            masks(35:45,65:75,2)=true;
            image=100*ones(80,100);
            image(15:19,28:32)=1;
            image(60:64,68:72)=2;
            parking=adaptive_optopatch.select_local_parking_points( ...
                image,masks,[30 40;70 40],6,"ClearancePixels",2, ...
                "MaximumDistanceSpiralDiameters",2, ...
                "IntensityAveragingRadiusPixels",1);
            testCase.verifyTrue(all([parking.parking_qc_pass]));
            testCase.verifyGreaterThanOrEqual( ...
                min([parking.parking_clearance_pixels]),8);
            for k=1:2
                p=parking(k).parking_point_xy;
                testCase.verifyFalse(any(masks(p(2),p(1),:),"all"));
            end
            testCase.verifyLessThan(parking(1).parking_mean_reference_intensity,10);
            testCase.verifyLessThan(parking(2).parking_mean_reference_intensity,10);
        end

        function calculatesCalibratedSpiralsPerPulse(testCase)
            % Luminos archives scanner transforms as galvo volts -> pixels.
            tform=affinetform2d([100 0 0;0 100 0;0 0 1]);
            metrics=adaptive_optopatch.calculate_spiral_cycles( ...
                tform,[50 40],10,10,5);
            testCase.verifyTrue(metrics.calibrated);
            testCase.verifyEqual(metrics.scanner_radius_volts,0.1,"AbsTol",1e-12);
            testCase.verifyGreaterThan(metrics.complete_cycles_during_pulse,0);
            testCase.verifyEqual(metrics.cycles_started_during_pulse, ...
                ceil(metrics.fractional_cycles_during_pulse));
        end

        function buildsCameraCalibratedTwoPhotonWaveforms(testCase)
            tform=affinetform2d([100 0 50;0 100 40;0 0 1]);
            target=struct("spiral_center_xy",[100 90], ...
                "spiral_radius_pixels",10, ...
                "spiral_density_points_per_volt",20, ...
                "parking_point_xy",[130 90]);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"PulseDurationMs",5, ...
                "DarkIntervalMs",[200 200],"PreDelayMs",100, ...
                "PostDelayMs",100,"ModulatorVoltage",1);
            w=adaptive_optopatch.build_2p_trial_waveforms( ...
                protocol,target,tform,"MaximumVelocityVPerS",500, ...
                "MaximumAccelerationVPerS2",1e6, ...
                "MinimumIlluminatedRadiusFraction",0.5);
            testCase.verifyTrue(w.preflight.passed);
            testCase.verifyEqual(max(w.pockels_v),1);
            testCase.verifyEqual(w.parking_v,[0.8 0.5],"AbsTol",1e-12);
            testCase.verifyEqual(numel(w.x_v), ...
                ceil(protocol.acquisition_duration_s*w.sample_rate_hz));
            testCase.verifyGreaterThan(w.per_pulse(1).cycle_fraction_during_light,0);
        end

        function extendsFinalTailForSafeSpiralReturn(testCase)
            tform=affinetform2d([100 0 50;0 100 40;0 0 1]);
            target=struct("spiral_center_xy",[100 90], ...
                "spiral_radius_pixels",10, ...
                "spiral_density_points_per_volt",20, ...
                "parking_point_xy",[130 90]);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"PulseDurationMs",5, ...
                "DarkIntervalMs",[50 50],"PreDelayMs",100, ...
                "PostDelayMs",1,"ModulatorVoltage",0);
            requested=ceil(protocol.acquisition_duration_s*200000);
            w=adaptive_optopatch.build_2p_trial_waveforms( ...
                protocol,target,tform,"MaximumVelocityVPerS",30, ...
                "MaximumAccelerationVPerS2",1800, ...
                "MinimumIlluminatedRadiusFraction",eps);
            testCase.verifyGreaterThan(numel(w.x_v),requested);
            testCase.verifyGreaterThan(w.automatic_extension_s,0);
            testCase.verifyEqual([w.x_v(end) w.y_v(end)],w.parking_v, ...
                "AbsTol",1e-12);
            testCase.verifyEqual(w.per_pulse(end).parking_arrival_sample, ...
                numel(w.x_v));
        end

        function derivesFrameCountsFromEachDaqTriggerPeriod(testCase)
            cameras(1)=struct("name","Camera 1", ...
                "frametrigger_source","DAQ", ...
                "daqtrig_period_ms",1,"frames_requested",2, ...
                "maximum_frame_rate_hz",1200);
            cameras(2)=struct("name","Camera 2", ...
                "frametrigger_source","DAQ", ...
                "daqtrig_period_ms",2.5,"frames_requested",2, ...
                "maximum_frame_rate_hz",500);
            [cameras,plan]=adaptive_optopatch.set_camera_frames_for_duration( ...
                cameras,1.001);
            testCase.verifyEqual([cameras.frames_requested],[1001 401]);
            testCase.verifyEqual([plan.frame_rate_hz],[1000 400], ...
                "AbsTol",1e-12);
            testCase.verifyEqual(string({plan.calculation_method}), ...
                ["daq_trigger_period" "daq_trigger_period"]);
        end

        function rejectsDaqTriggerFasterThanCameraRoi(testCase)
            camera=struct("name","Camera 1", ...
                "frametrigger_source","DAQ","daqtrig_period_ms",1, ...
                "frames_requested",2,"maximum_frame_rate_hz",380);
            testCase.verifyError(@() ...
                adaptive_optopatch.set_camera_frames_for_duration(camera,1), ...
                "adaptive_optopatch:CameraTriggerTooFastForRoi");
            [updated,plan]=adaptive_optopatch.set_camera_frames_for_duration( ...
                camera,1,"AllowRateLimitOverride",true);
            testCase.verifyEqual(updated.frames_requested,1000);
            testCase.verifyTrue(plan.rate_override_allowed);
            testCase.verifyTrue(plan.rate_override_used);
        end

        function rejectsTargetOutsideCalibrationGrid(testCase)
            artifact=struct("calibration",struct("camera_pixels", ...
                [0 0;100 0;100 100;0 100]));
            target=struct("spiral_center_xy",[95 50], ...
                "spiral_radius_pixels",10,"parking_point_xy",[80 50]);
            report=adaptive_optopatch.validate_2p_calibration_coverage( ...
                target,artifact);
            testCase.verifyFalse(report.passed);
            target.spiral_center_xy=[50 50];
            target.parking_point_xy=[70 50];
            report=adaptive_optopatch.validate_2p_calibration_coverage( ...
                target,artifact);
            testCase.verifyTrue(report.passed);
        end

        function capturesAndIdentifiesGalvoFeedbackAxes(testCase)
            n=1000; t=linspace(0,1,n)';
            waveforms=struct("sample_rate_hz",200000, ...
                "x_v",sin(2*pi*t),"y_v",cos(4*pi*t));
            channels(1)=struct("phys_channel","Dev2/ai1", ...
                "data",0.6*waveforms.x_v');
            channels(2)=struct("phys_channel","Dev2/ai2", ...
                "data",-0.5*waveforms.y_v');
            task=struct("task_type","aif","rate",200000, ...
                "channels",channels);
            daq=struct("buffered_tasks",task);
            feedback=adaptive_optopatch.capture_galvo_feedback(daq,waveforms);
            testCase.verifyTrue(feedback.passed);
            testCase.verifyEqual(string({feedback.summary.best_axis}),["x" "y"]);
            testCase.verifyGreaterThan( ...
                [feedback.summary.best_absolute_correlation],[0.99 0.99]);
            testCase.verifyEmpty(feedback.summary(1).data);
            testCase.verifyEqual(numel(feedback.channels(1).data),n);
        end

        function generatesAndScoresGalvoDynamicsBurst(testCase)
            waveform=adaptive_optopatch.generate_galvo_dynamics_waveform( ...
                "x",0.1,100,"Cycles",20,"RampCycles",2);
            lag=55;
            measured=[zeros(lag,1);0.625*waveform.x_v(1:end-lag)];
            channel=struct("port","Dev2/ai2","sample_rate_hz",200000, ...
                "data",measured,"sample_count",numel(measured), ...
                "minimum_v",min(measured),"maximum_v",max(measured), ...
                "range_v",range(measured),"correlation_with_x",NaN, ...
                "correlation_with_y",NaN,"best_axis","x", ...
                "best_absolute_correlation",NaN);
            feedback=struct("channels",channel);
            result=adaptive_optopatch.analyze_galvo_dynamics_feedback( ...
                waveform,feedback);
            testCase.verifyTrue(result.passed);
            testCase.verifyEqual(result.best_channel.lag_samples,lag,"AbsTol",1);
            testCase.verifyEqual(result.best_channel.gain,0.625,"AbsTol",1e-3);
            testCase.verifyGreaterThan(waveform.maximum_velocity_v_per_s,60);
        end

        function injectsTwoPhotonVectorsIntoLuminosSettings(testCase)
            fs=200000; n=100;
            waveforms=struct("sample_rate_hz",fs, ...
                "x_v",linspace(0,0.1,n)',"y_v",zeros(n,1), ...
                "pockels_v",zeros(n,1),"preflight",struct("passed",true), ...
                "per_pulse",struct([]));
            globalProps=struct("rate",fs,"total_time",1, ...
                "clock_source","Internal Dev1", ...
                "trigger_source","Dev1/PFI9 Trigger Bridge","daq_master",true);
            old=struct("name","2P mod","port","2P mod", ...
                "wavefile","awfm_constant","params",{{0}}, ...
                "operation","Multiplication","concatTime",[]);
            wfm=struct("ao",old,"do",[],"ai",[],"di",[],"ctri",[], ...
                "ao_camera_triggered",[],"do_camera_triggered",[]);
            [g,w,summary]=adaptive_optopatch.build_luminos_2p_waveform_config( ...
                globalProps,wfm,waveforms);
            testCase.verifyEqual(numel(w.ao),3);
            testCase.verifyEqual(g.total_time,n/fs,"AbsTol",1e-12);
            testCase.verifyEqual(sort(string({w.ao.port})), ...
                sort(["Dev2/ao0","Dev2/ao1","2P mod"]));
            testCase.verifyEqual(summary.pockels_port,"Dev1/ao3");
        end

        function keepsGalvosScanningWithinTenPulseTrain(testCase)
            conditions=table("train_100hz",100,10,5,1,0.1,false, ...
                'VariableNames',{'condition_id','frequency_hz', ...
                'pulses_per_train','pulse_duration_ms','repeats', ...
                'command_voltage_v','is_null'});
            protocol=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[450 550]);
            target=struct("spiral_center_xy",[0 0], ...
                "spiral_radius_pixels",1,"spiral_density_points_per_volt",10, ...
                "parking_point_xy",[2 0]);
            tform=affinetform2d([100 0 0;0 100 0;0 0 1]);
            waveform=adaptive_optopatch.build_2p_trial_waveforms( ...
                protocol,target,tform,"MinimumIlluminatedRadiusFraction",eps);
            testCase.verifyEqual([waveform.per_pulse(1:9).parking_arrival_sample], ...
                zeros(1,9));
            testCase.verifyGreaterThan( ...
                waveform.per_pulse(10).parking_arrival_sample,0);
            light=waveform.pockels_v>0;
            testCase.verifyEqual(nnz(diff([false;light])==1),10);
        end

        function rejectsOutOfDomainScannerCalibration(testCase)
            bad=affinetform2d([0.04 0 -190;0 0.04 48;0 0 1]);
            testCase.verifyError(@()adaptive_optopatch.generate_2p_spiral_cycle( ...
                bad,[1000 1100],17,10), ...
                "adaptive_optopatch:ScannerCalibrationOutsideBounds");
        end

        function fitsGalvoToCameraCalibration(testCase)
            [x,y]=meshgrid([-1 0 1],[-1 0 1]);
            volts=[x(:) y(:)];
            pixels=[100*volts(:,1)+20*volts(:,2)+500, ...
                -10*volts(:,1)+80*volts(:,2)+400];
            c=adaptive_optopatch.fit_galvo_camera_calibration(volts,pixels);
            testCase.verifyTrue(c.passed);
            testCase.verifyLessThan(c.rmse_pixels,1e-10);
            recovered=adaptive_optopatch.camera_to_galvo_volts( ...
                c.tform,pixels);
            testCase.verifyEqual(recovered,volts,"AbsTol",1e-10);
        end

        function validatesFittedTransformWithLocalizationResiduals(testCase)
            [x,y]=meshgrid([-0.3 0 0.3],[-0.3 0 0.3]);
            volts=[x(:) y(:)];
            pixels=[1.4*volts(:,1)+77*volts(:,2)+1018, ...
                80*volts(:,1)-1.6*volts(:,2)+1158];
            pixels=pixels+[0.25 -0.15;-0.2 0.1;0.1 0.2; ...
                -0.15 -0.2;0.2 0.15;-0.1 0.1; ...
                0.15 -0.1;-0.2 -0.15;0.1 0.05];
            calibration=adaptive_optopatch.fit_galvo_camera_calibration( ...
                volts,pixels);
            artifact=struct("calibration_id","test", ...
                "rig_name","Virtual_Upright","camera_serial","001125", ...
                "scanner_name","Chameleon (To friends: Ben)", ...
                "scanner_x_port","Dev2/ao0","scanner_y_port","Dev2/ao1", ...
                "calibration",calibration);
            report=adaptive_optopatch.validate_galvo_calibration_artifact( ...
                artifact);
            testCase.verifyTrue(report.passed,join(report.issues,newline));
        end

        function generatesBoundedGalvoCalibrationGrid(testCase)
            plan=adaptive_optopatch.generate_galvo_calibration_waveforms( ...
                "GridSize",3,"HalfRangeV",0.05, ...
                "CameraFrameRateHz",20,"FramesPerPoint",2, ...
                "PockelsVoltage",0);
            testCase.verifyTrue(plan.preflight.passed);
            testCase.verifyEqual(size(plan.grid_volts),[9 2]);
            testCase.verifyEqual(max(abs(plan.grid_volts),[],"all"),0.05, ...
                "AbsTol",1e-12);
            testCase.verifyEqual(max(plan.pockels_v),0);
            testCase.verifyTrue(all(arrayfun( ...
                @(p)~isempty(p.expected_frame_indices),plan.points)));
        end

        function constructsGalvoCalibrationGui(testCase)
            gui=adaptive_optopatch.GalvoCalibrationApp([],"Visible","off");
            cleanup=onCleanup(@()delete(gui)); %#ok<NASGU>
            testCase.verifyClass(gui,"adaptive_optopatch.GalvoCalibrationApp");
            testCase.verifyTrue(isvalid(gui.Figure));
        end

        function readsAndValidatesPersistedGalvoCalibration(testCase)
            root=tempname; mkdir(root); cleanup=onCleanup(@()rmdir(root,"s")); %#ok<NASGU>
            [x,y]=meshgrid([-1 0 1],[-1 0 1]);
            volts=[x(:) y(:)];
            pixels=[100*volts(:,1)+500,80*volts(:,2)+400];
            calibration=adaptive_optopatch.fit_galvo_camera_calibration( ...
                volts,pixels);
            profile=adaptive_optopatch.virtual_upright_2p_profile();
            galvo_calibration_artifact=struct("schema_version","0.1.0", ... %#ok<NASGU>
                "calibration_id","test_calibration","rig_name","Virtual_Upright", ...
                "camera_serial","001125","scanner_name",profile.scanner.name, ...
                "scanner_x_port",profile.scanner.x_port, ...
                "scanner_y_port",profile.scanner.y_port, ...
                "calibration",calibration);
            save(fullfile(root,"galvo_calibration_test.mat"), ...
                "galvo_calibration_artifact");
            active_galvo_calibration=struct( ... %#ok<NASGU>
                "artifact_filename","galvo_calibration_test.mat");
            save(fullfile(root,"active_galvo_calibration.mat"), ...
                "active_galvo_calibration");
            [loaded,status]=adaptive_optopatch.get_active_galvo_calibration( ...
                "StoreRoot",root);
            report=adaptive_optopatch.validate_galvo_calibration_artifact( ...
                loaded,[]);
            testCase.verifyTrue(status.found);
            testCase.verifyTrue(report.passed);
            testCase.verifyEqual(loaded.calibration_id,"test_calibration");
        end

        function enforcesStagedTwoPhotonReleaseLevels(testCase)
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",3);
            trials=table(1,"2p_spiral","cell_001",false,1,{protocol}, ...
                protocol.acquisition_duration_s,"test","planned","", ...
                'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
                'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
                'output_tag','acquisition_status','experiment_directory'});
            manifest=struct("trials",trials);
            blocked=adaptive_optopatch.validate_2p_release_level( ...
                manifest,"blocked_test","ConfirmTrajectoryTest",true);
            testCase.verifyTrue(blocked.passed);
            attenuated=adaptive_optopatch.validate_2p_release_level( ...
                manifest,"attenuated_test","ConfirmTrajectoryTest",true, ...
                "ConfirmLiveOutput",true,"ModulatorVoltageOverride",0.1);
            testCase.verifyTrue(attenuated.passed);
            rejected=adaptive_optopatch.validate_2p_release_level( ...
                manifest,"attenuated_test","ConfirmTrajectoryTest",true, ...
                "ModulatorVoltageOverride",0.1);
            testCase.verifyFalse(rejected.passed);

            pilotProtocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",200);
            pilotManifest=manifest;
            pilotManifest.trials.pulse_schedule={pilotProtocol};
            pilot=adaptive_optopatch.validate_2p_release_level( ...
                pilotManifest,"pilot_single","ConfirmTrajectoryTest",true, ...
                "ConfirmLiveOutput",true,"ModulatorVoltageOverride",0.1);
            testCase.verifyTrue(pilot.passed);

            unlimitedProtocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",500);
            pilotManifest.trials.pulse_schedule={unlimitedProtocol};
            unlimited=adaptive_optopatch.validate_2p_release_level( ...
                pilotManifest,"pilot_single","ConfirmTrajectoryTest",true, ...
                "ConfirmLiveOutput",true,"ModulatorVoltageOverride",0.1);
            testCase.verifyTrue(unlimited.passed);
            attenuatedManifest=pilotManifest;
            unlimitedTest=adaptive_optopatch.validate_2p_release_level( ...
                attenuatedManifest,"attenuated_test", ...
                "ConfirmTrajectoryTest",true,"ConfirmLiveOutput",true, ...
                "ModulatorVoltageOverride",0.1);
            testCase.verifyTrue(unlimitedTest.passed);
        end

        function constructsTwoPhotonTestRunnerGui(testCase)
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",3);
            target=struct("spiral_center_xy",[20 20], ...
                "spiral_radius_pixels",5,"parking_point_xy",[30 20], ...
                "spiral_preview_center_xy",[20 20], ...
                "parking_preview_point_xy",[30 20]);
            targets=struct("schema_version","0.2.0", ...
                "coordinate_space","voltage_camera_full_sensor_pixels", ...
                "targets",target); %#ok<NASGU>
            trials=table(1,"2p_spiral","cell_001",false,1,{protocol}, ...
                protocol.acquisition_duration_s,"test","planned","", ...
                'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
                'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
                'output_tag','acquisition_status','experiment_directory'});
            manifest=struct("trials",trials); %#ok<NASGU>
            save(fullfile(folder,"pattern_bundle.mat"),"targets");
            save(fullfile(folder,"trial_manifest.mat"),"manifest");
            gui=adaptive_optopatch.TwoPhotonTestRunnerApp([],folder,"Visible","off");
            guiCleanup=onCleanup(@()delete(gui)); %#ok<NASGU>
            testCase.verifyTrue(isvalid(gui.Figure));
        end

        function evaluatesConservativeGalvoLimits(testCase)
            t=linspace(0,2*pi,4001)';
            x=0.05*cos(t); y=0.05*sin(t);
            report=adaptive_optopatch.evaluate_galvo_waveform(x,y,200000);
            testCase.verifyTrue(report.passed);
            testCase.verifyTrue(report.small_angle_class);
            testCase.verifyLessThan(report.repetition_rate_hz,1000);
            testCase.verifyLessThan(report.wrap_step_volts,1e-10);
        end

        function generatesNonoverlappingScreenSchedule(testCase)
            p=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",200,"PulseDurationMs",5, ...
                "DarkIntervalMs",[45 55],"RandomSeed",9);
            gaps=1000*(p.events.onset_s(2:end)-p.events.offset_s(1:end-1));
            testCase.verifyGreaterThanOrEqual(min(gaps),45);
            testCase.verifyLessThanOrEqual(max(gaps),55);
            testCase.verifyEqual(p.events.onset_s(1),0.1,"AbsTol",1e-12);
            testCase.verifyEqual(p.acquisition_duration_s, ...
                p.events.offset_s(end)+0.1,"AbsTol",1e-12);
        end

        function allowsLongSinglePulseDurations(testCase)
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"PulseDurationMs",250, ...
                "DarkIntervalMs",[50 50]);
            testCase.verifyEqual(protocol.events.duration_s,0.25*ones(2,1));
            testCase.verifyEqual(protocol.pulse_duration_ms,250);
        end

        function randomizesMixedStfConditions(testCase)
            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",4,"PulsesPerTrain",3);
            p=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[100 120],"RandomSeed",2);
            testCase.verifyEqual(height(p.events),28);
            testCase.verifyEqual(sum(p.events.frequency_hz==100),12);
            testCase.verifyLessThanOrEqual(max(p.events.frequency_hz,[],"omitnan"),100);
            testCase.verifyTrue(all(p.events.onset_s(2:end)>= ...
                p.events.offset_s(1:end-1)));
        end

        function buildsPilotSingleAndTenPulseProtocol(testCase)
            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",50,"PulsesPerTrain",10, ...
                "PulseDurationMs",5,"CommandVoltageV",0.1);
            protocol=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[450 550],"RandomSeed",1001);
            pulses=adaptive_optopatch.flatten_pulse_schedule(protocol);
            testCase.verifyEqual(height(protocol.events),1050);
            testCase.verifyEqual(height(pulses),1050);
            testCase.verifyEqual(sum(protocol.events.pulse_in_train==1),150);
            testCase.verifyEqual(sum(protocol.events.frequency_hz==100),500);
            testCase.verifyEqual(sort(unique(protocol.events.frequency_hz(~isnan( ...
                protocol.events.frequency_hz)))),[50;100]);
            trials=table(1,"2p_spiral","cell_001",false,1,{protocol}, ...
                protocol.acquisition_duration_s,"mixed","planned","", ...
                'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
                'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
                'output_tag','acquisition_status','experiment_directory'});
            report=adaptive_optopatch.validate_2p_release_level( ...
                struct("trials",trials),"pilot_mixed_trains", ...
                "ConfirmTrajectoryTest",true,"ConfirmLiveOutput",true, ...
                "ModulatorVoltageOverride",0.1);
            testCase.verifyTrue(report.passed);
        end

        function createsContinuousAngularSpiralReturn(testCase)
            t=(0:199)'; r=sqrt(t/199); theta=4*pi*r;
            x=r.*cos(theta); y=r.*sin(theta);
            [xd,yd]=adaptive_optopatch.append_continuous_spiral_return(x,y,[0 0]);
            nonzero=hypot(xd,yd)>1e-10;
            angle=unwrap(atan2(yd(nonzero),xd(nonzero)));
            testCase.verifyGreaterThanOrEqual(min(diff(angle)),-1e-9);
            testCase.verifyEqual([xd(end) yd(end)],[0 0],"AbsTol",1e-12);
            testCase.verifyEqual(numel(xd),2*numel(x)-1);
        end

        function savesBundleInGeneratedSubfolder(testCase)
            parent=tempname; mkdir(parent); cleanup=onCleanup(@()rmdir(parent,"s")); %#ok<NASGU>
            reference=struct("fov_id","pilot fov");
            targets=struct("schema_version","test");
            manifest=struct("schema_version","test");
            session=struct("roi_positions",{{[1 1;2 1;2 2]}});
            paths=adaptive_optopatch.save_bundle(parent,reference,targets,manifest, ...
                "CreateSubfolder",true,"SessionState",session);
            testCase.verifyTrue(isfolder(paths.output_directory));
            testCase.verifyTrue(startsWith(string(paths.output_directory), ...
                fullfile(string(parent),"adaptive_optopatch_pilotFov_")));
            testCase.verifyTrue(isfile(paths.reference));
            testCase.verifyTrue(isfile(paths.targets));
            testCase.verifyTrue(isfile(paths.manifest));
            testCase.verifyTrue(isfile(paths.session));
        end

        function generatesNormalizedLuminosSpiral(testCase)
            xy=adaptive_optopatch.generate_spiral_preview([20 30],10,10);
            radii=hypot(xy(:,1)-20,xy(:,2)-30);
            testCase.verifyEqual(xy(1,:),[20 30],"AbsTol",1e-12);
            testCase.verifyLessThanOrEqual(max(radii),10);
            testCase.verifyGreaterThan(max(radii),9.9);
            testCase.verifyGreaterThan(size(xy,1),600);
            testCase.verifyEqual(xy(end,:),[20 30],"AbsTol",1e-12);
            nonzero=hypot(xy(:,1)-20,xy(:,2)-30)>1e-10;
            angle=unwrap(atan2(xy(nonzero,2)-30,xy(nonzero,1)-20));
            testCase.verifyGreaterThanOrEqual(min(diff(angle)),-1e-9);
        end

        function acceptsClockwiseContinuousAngularReturn(testCase)
            t=(0:199)'; r=sqrt(t/199); theta=-4*pi*r;
            x=r.*cos(theta); y=r.*sin(theta);
            [xd,yd]=adaptive_optopatch.append_continuous_spiral_return( ...
                x,y,[0 0]);
            nonzero=hypot(xd,yd)>1e-10;
            angle=unwrap(atan2(yd(nonzero),xd(nonzero)));
            testCase.verifyLessThanOrEqual(max(diff(angle)),1e-9);
            testCase.verifyEqual([xd(end) yd(end)],[0 0],"AbsTol",1e-12);
        end

        function handlesHandednessReversingScannerCalibration(testCase)
            tform=affinetform2d([0 100 500;100 0 400;0 0 1]);
            cycle=adaptive_optopatch.generate_2p_spiral_cycle( ...
                tform,[550 450],10,50);
            testCase.verifyEqual(cycle.galvo_angle_direction,"decreasing");
            center=cycle.center_v;
            outbound=[cycle.x_v(1:cycle.outbound_samples)-center(1), ...
                cycle.y_v(1:cycle.outbound_samples)-center(2)];
            nonzero=hypot(outbound(:,1),outbound(:,2))>1e-10;
            angle=unwrap(atan2(outbound(nonzero,2),outbound(nonzero,1)));
            testCase.verifyLessThanOrEqual(max(diff(angle)),1e-9);
        end

        function readsLuminosCameraSnapshot(testCase)
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            expected=uint16([1 2 3;4 5 6]);
            snap=struct; %#ok<NASGU>
            snap.img=expected;
            snap.name="Orca Fusion";
            snap.bin=1;
            snap.ref2d=imref2d(size(expected),[10 13],[20 22]);
            snap.timestamp=datetime("now");
            snap.tform=struct("name","DMD_Blue","tform",affine2d());
            snapshotPath=fullfile(folder,"120000pilot.mat");
            save(snapshotPath,"snap");
            [image,info]=adaptive_optopatch.read_reference_snapshot(snapshotPath);
            testCase.verifyEqual(image,single(expected));
            testCase.verifyEqual(info.image_size,[2 3]);
            testCase.verifyEqual(info.metadata.voltage_camera.ROI,[10 3 20 2]);
            testCase.verifyEqual(info.metadata.stimulation_dmd.name,"DMD_Blue");
            testCase.verifyEqual(info.snapshot_directory,string(folder));
        end

        function readsLegacyLuminosCameraSnapshot(testCase)
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            expected=uint16([1 2 3;4 5 6]);
            snap=struct; %#ok<NASGU>
            snap.img=expected;
            snap.name="orca fusion";
            snap.ref2d=imref2d(size(expected),[10 16],[20 24]);
            snap.tform=affine2d([1 0 0;0 1 0;2 3 1]);
            snapshotPath=fullfile(folder,"legacy_snapshot.mat");
            save(snapshotPath,"snap");

            [image,info]=adaptive_optopatch.read_reference_snapshot(snapshotPath);

            testCase.verifyEqual(image,single(expected));
            testCase.verifyEqual(info.camera_bin,2,"AbsTol",1e-12);
            testCase.verifyClass(info.timestamp,"datetime");
            testCase.verifyEqual(info.metadata.stimulation_dmd.name,"DMD_Blue");
            testCase.verifyEqual( ...
                info.metadata.stimulation_dmd.tform.T,snap.tform.T);
        end


        function mapsSnapshotRoisIntoFullCameraCoordinates(testCase)
            image=zeros(20,30,"single");
            masks=false(20,30,1); masks(7:9,9:11,1)=true;
            camera=struct("x_world_limits",[600 630], ...
                "y_world_limits",[756 776]);
            scanner=struct("tform",affinetform2d( ...
                [100 0 600;0 100 756;0 0 1]),"sample_rate",200000);
            metadata=struct("rig_name","Virtual_Upright", ...
                "voltage_camera",camera,"scanner",scanner);
            reference=adaptive_optopatch.create_reference_model( ...
                image,masks,metadata,"MicronsPerPixel",1);
            testCase.verifyEqual(reference.cells.image_centroid_xy,[10 8], ...
                "AbsTol",1e-12);
            testCase.verifyEqual(reference.cells.camera_centroid_xy, ...
                [609.5 763.5],"AbsTol",1e-12);
            targets=adaptive_optopatch.build_target_bundle(reference, ...
                "SpiralRadiusUm",2,"PulseDurationMs",5);
            testCase.verifyEqual(targets.targets.spiral_preview_center_xy, ...
                [10 8],"AbsTol",1e-12);
            testCase.verifyEqual(targets.targets.spiral_center_xy, ...
                [609.5 763.5],"AbsTol",1e-12);
            testCase.verifyTrue(targets.targets.spiral_cycle_metrics.calibrated);
            validation=adaptive_optopatch.validate_2p_planning_bundle(targets);
            testCase.verifyTrue(validation.passed);
        end

        function rejectsPreCoordinateFixTwoPhotonBundle(testCase)
            oldTargets=struct("schema_version","0.1.0", ...
                "coordinate_space","voltage_camera_acquired_roi", ...
                "targets",struct("spiral_center_xy",[20 30], ...
                "spiral_radius_pixels",10,"parking_point_xy",[40 30]));
            validation=adaptive_optopatch.validate_2p_planning_bundle(oldTargets);
            testCase.verifyFalse(validation.passed);
            testCase.verifyTrue(any(contains(validation.issues,"schema 0.2.0")));
        end

        function extractsBackgroundCorrectedRoiTrace(testCase)
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            camera=struct("deviceType","Camera","name","Voltage", ...
                "cam_id","S/N: 001125","ROI",[0 8 0 8],"bin",1, ...
                "bit_depth",16,"frames_requested",4,"exposuretime",1);
            dmd=struct("deviceType","DMD_Device","name","DMD_Blue");
            Device_Data={struct("rigName","Virtual_Upright"),camera,dmd}; %#ok<NASGU>
            save(fullfile(folder,"output_data.mat"),"Device_Data");
            fid=fopen(fullfile(folder,"frames1.bin"),"w","ieee-le");
            masks=false(8,8,1); masks(3:5,3:5,1)=true;
            expected=zeros(4,1);
            for k=1:4
                frame=uint16(10*ones(8)); frame(masks)=uint16(10+2*k);
                expected(k)=2*k;
                fwrite(fid,permute(frame,[2 1]),"uint16");
            end
            fclose(fid);
            metadata=adaptive_optopatch.load_luminos_metadata( ...
                fullfile(folder,"output_data.mat"));
            ref=adaptive_optopatch.create_reference_model(zeros(8),masks,metadata);
            out=adaptive_optopatch.extract_roi_traces(folder,ref, ...
                "BackgroundMode","local_annulus","AnnulusInnerPixels",0, ...
                "AnnulusOuterPixels",2,"FrameRateHz",1000);
            testCase.verifyEqual(out.corrected_traces,expected,"AbsTol",1e-12);
            testCase.verifyEqual(out.frame_rate_hz,1000);
        end

        function buildsReferenceTargetsAndManifest(testCase)
            img = zeros(30,40);
            img(8:12,8:12) = 10;
            img(18:23,25:30) = 20;
            masks = false(30,40,2);
            masks(8:12,8:12,1) = true;
            masks(18:23,25:30,2) = true;
            metadata = struct("rig_name","Virtual_Upright", ...
                "voltage_camera",struct("serial","001125"));

            ref = adaptive_optopatch.create_reference_model(img,masks,metadata, ...
                "FovId","test","MicronsPerPixel",0.5);
            targets = adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",5,"SpiralDensityPointsPerVolt",12, ...
                "BlueMaskAdjustmentPixels",-1);
            manifest = adaptive_optopatch.build_screen_manifest(ref,targets, ...
                "Repeats",3,"NullFraction",0.25,"RandomSeed",4);

            testCase.verifyEqual(numel(ref.cells),2);
            testCase.verifySize(targets.dmd_camera_masks,[30 40 2]);
            testCase.verifyEqual(targets.targets(1).spiral_density_points_per_volt,12);
            testCase.verifyEqual( ...
                manifest.trials.spiral_density_points_per_volt(~manifest.trials.is_null), ...
                repmat(12,sum(~manifest.trials.is_null),1));
            testCase.verifyEqual(sum(~manifest.trials.is_null),6);
            testCase.verifyTrue(manifest.one_acquisition_per_row);
            testCase.verifyEqual( ...
                manifest.trials.pulse_schedule{1}.pulse_count,200);
            testCase.verifyGreaterThan(manifest.trials.acquisition_duration_s(1),10);
        end

        function signedBlueAdjustmentDilatesMask(testCase)
            img=zeros(30); masks=false(30,30,1); masks(14:16,14:16,1)=true;
            metadata=struct("rig_name","Virtual_Upright", ...
                "voltage_camera",struct("serial","001125"));
            ref=adaptive_optopatch.create_reference_model(img,masks,metadata);
            contracted=adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",1,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",-1);
            expanded=adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",1,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",2);
            testCase.verifyGreaterThan(nnz(expanded.dmd_camera_masks), ...
                nnz(contracted.dmd_camera_masks));
            testCase.verifyTrue(all(expanded.dmd_camera_masks(masks)));
        end

        function dryRunsAndResumesManifest(testCase)
            img=zeros(20); masks=false(20,20,1); masks(8:12,8:12,1)=true;
            metadata=struct("rig_name","Virtual_Upright", ...
                "voltage_camera",struct("serial","001125"));
            ref=adaptive_optopatch.create_reference_model(img,masks,metadata);
            targets=adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",1,"ParkingClearancePixels",1);
            manifest=adaptive_optopatch.build_screen_manifest(ref,targets, ...
                "Repeats",1,"NullFraction",0);
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            run=adaptive_optopatch.run_manifest(manifest,targets, ...
                "OutputDirectory",folder);
            testCase.verifyEqual(run.trials.acquisition_status,"dry_run_complete");
            run2=adaptive_optopatch.run_manifest(manifest,targets, ...
                "OutputDirectory",folder,"Resume",true);
            testCase.verifyEqual(run2.trials.acquisition_status,"dry_run_complete");
        end

        function ranksAndBuildsStfManifest(testCase)
            reference=struct;
            reference.cells=struct("cell_id",{"cell_001","cell_002","cell_003"});
            connectivity=struct("zscore",[NaN 5 1;2 NaN 4;1 1 NaN], ...
                "effect",[NaN 2 0;1 NaN 2;0 0 NaN], ...
                "consistency",[NaN .9 .2;.3 NaN .8;.2 .2 NaN], ...
                "target_activation_z",[6;5;4], ...
                "candidate_edge",logical([0 1 0;0 0 1;0 0 0]));
            ranking=adaptive_optopatch.rank_connectivity_candidates(connectivity,reference);
            ranking.accepted(1:2)=true;
            targets.targets=repmat(struct("dmd_mask_index",1, ...
                "spiral_radius_um",6,"spiral_density_points_per_volt",10),3,1);
            manifest=adaptive_optopatch.build_stf_manifest(ranking,targets, ...
                adaptive_optopatch.default_stf_conditions("RepeatsPerCondition",2));
            testCase.verifyGreaterThanOrEqual(height(manifest.trials),1);
            testCase.verifyEqual(manifest.manifest_type,"stf");
        end

        function infersDirectedEdge(testCase)
            t = (0:0.01:12)';
            traces = 0.05*randn(numel(t),2);
            stimTimes = (1:2:11)';
            targetIndex = [1;1;1;0;0;0];
            isNull = targetIndex==0;
            for i = 1:3
                win = t >= stimTimes(i)+0.05 & t <= stimTimes(i)+0.2;
                traces(win,1) = traces(win,1)+1.5;
                traces(win,2) = traces(win,2)+0.8;
            end
            epochs = table(targetIndex,isNull,stimTimes, ...
                'VariableNames',{'target_index','is_null','stim_time'});
            out = adaptive_optopatch.infer_connectivity(traces,t,epochs, ...
                "ResponseWindow",[0.05 0.2],"BaselineWindow",[-0.4 -0.05], ...
                "EdgeThresholdZ",1,"MinimumTargetResponseZ",1);
            testCase.verifyTrue(out.candidate_edge(1,2));
            testCase.verifyFalse(out.candidate_edge(1,1));
        end

        function definesVirtualUprightBlueDmdProfile(testCase)
            profile=adaptive_optopatch.virtual_upright_1p_profile();
            testCase.verifyEqual(profile.dmd.name,"DMD_Blue");
            testCase.verifyEqual(profile.laser.name,"488");
            testCase.verifyEqual(profile.laser.max_power_w,0.055,"AbsTol",1e-12);
            testCase.verifyEqual(profile.modulator.port,"Dev1/ao2");
            testCase.verifyEqual(profile.shutter.port,"Dev1/port0/line0");
            testCase.verifyEqual(profile.dmd.trigger_port,"Dev1/port0/line4");
            testCase.verifyEqual(profile.camera.clock,"Dev1/PFI0");
            testCase.verifyEqual(profile.daq.default_clock,"Internal Dev1");
            testCase.verifyEqual(profile.daq.default_trigger, ...
                ["Dev1/PFI9","Dev2/PFI1"]);
            testCase.verifyEqual(profile.daq.clock_bridge, ...
                ["Dev1/PFI12","Dev2/PFI0"]);
        end

        function flattensScreenAndStfPulseSchedules(testCase)
            screen=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",4,"ModulatorVoltage",1.25,"RandomSeed",3);
            pulses=adaptive_optopatch.flatten_pulse_schedule(screen);
            testCase.verifyEqual(height(pulses),4);
            testCase.verifyEqual(pulses.modulator_voltage,1.25*ones(4,1));
            testCase.verifyFalse(any(pulses.is_null));

            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",1,"PulsesPerTrain",3, ...
                "CommandVoltageV",2);
            stf=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[100 100],"RandomSeed",4);
            stfPulses=adaptive_optopatch.flatten_pulse_schedule(stf);
            expected=sum(conditions.pulses_per_train);
            testCase.verifyEqual(height(stfPulses),expected);
            testCase.verifyTrue(all(diff(stfPulses.onset_s)>=0));
        end

        function injectsOnePhotonWaveformIntoActiveLuminosSettings(testCase)
            globalProps=struct("rate",200000,"total_time",1, ...
                "clock_source","Internal Dev1","trigger_source","Dev1/PFI9", ...
                "completion_trigger","None","daq_master",true);
            existing=struct("name","mod594","port","mod594", ...
                "wavefile","awfm_constant","params",{{0.1}}, ...
                "operation","Multiplication","concatTime",[]);
            replaced=struct("name","mod488","port","mod488", ...
                "wavefile","awfm_constant","params",{{0.2}}, ...
                "operation","Multiplication","concatTime",[]);
            wfm=struct("ao",[existing replaced],"do",[],"ai",[],"di",[], ...
                "ctri",[],"ao_camera_triggered",[],"do_camera_triggered",[]);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",3,"ModulatorVoltage",0,"RandomSeed",2);
            [updatedGlobal,updatedWfm,summary]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,protocol, ...
                adaptive_optopatch.virtual_upright_1p_profile(), ...
                "ModulatorVoltageOverride",1.5);
            testCase.verifyEqual(updatedGlobal.total_time,protocol.acquisition_duration_s);
            testCase.verifyEqual(numel(updatedWfm.ao),2);
            testCase.verifyTrue(any(string({updatedWfm.ao.name})=="mod594"));
            idx=find(string({updatedWfm.ao.name})=="mod488",1);
            testCase.verifyEqual(string(updatedWfm.ao(idx).wavefile), ...
                "adaptive_optopatch.luminos_event_waveform");
            params=updatedWfm.ao(idx).params;
            testCase.verifyEqual(numel(params),4);
            testCase.verifyEqual(summary.pulses.modulator_voltage,1.5*ones(3,1));
            t=(0:1/globalProps.rate:updatedGlobal.total_time-1/globalProps.rate);
            y=feval(updatedWfm.ao(idx).wavefile,t,params{:});
            testCase.verifyEqual(max(y),1.5);
            testCase.verifyEqual(y(end),0);
        end

        function requiresExplicitConfirmationBeforeLiveOnePhotonRun(testCase)
            manifest=struct("trials",table("1p_dmd", ...
                'VariableNames',{'stimulation_mode'}));
            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,struct,[]),"adaptive_optopatch:LiveOutputNotConfirmed");
        end

        function capturesMultiDaqSynchronizationState(testCase)
            daq=struct;
            daq.global_props=struct("rate",200000, ...
                "clock_source","Internal Dev1", ...
                "trigger_source","Dev1/PFI9","daq_master",true);
            daq.default_trigger=["Dev1/PFI9","Dev2/PFI1"];
            daq.clock_bridge=["Dev1/PFI12","Dev2/PFI0"];
            daq.clock_master_device="Dev1";
            daq.master_clock_task_index=1;
            daq.wfm_data=struct;
            daq.wfm_data.ao=struct("port",{"Dev1/ao2","Dev2/ao0"});
            daq.wfm_data.do=[]; daq.wfm_data.ai=[];
            daq.wfm_data.di=[]; daq.wfm_data.ctri=[];
            daq.buffered_tasks=[];
            sync=adaptive_optopatch.capture_luminos_daq_sync(daq);
            testCase.verifyTrue(sync.passed);
            testCase.verifyEqual(sync.selected_master_device,"Dev1");
            testCase.verifyEqual(sync.active_waveform_devices,["Dev1","Dev2"]);
            testCase.verifyEqual(sync.clock_bridge,["Dev1/PFI12","Dev2/PFI0"]);
        end

        function constructsOnePhotonRunnerGui(testCase)
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            targets=struct("schema_version","test"); %#ok<NASGU>
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",2);
            trials=table(1,"1p_dmd","cell_001",false,1,{protocol}, ...
                protocol.acquisition_duration_s,"test_trial","planned","", ...
                'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
                'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
                'output_tag','acquisition_status','experiment_directory'});
            manifest=struct("trials",trials); %#ok<NASGU>
            save(fullfile(folder,"pattern_bundle.mat"),"targets");
            save(fullfile(folder,"trial_manifest.mat"),"manifest");
            gui=adaptive_optopatch.OnePhotonRunnerApp([],folder,"Visible","off");
            guiCleanup=onCleanup(@()delete(gui)); %#ok<NASGU>
            testCase.verifyClass(gui,"adaptive_optopatch.OnePhotonRunnerApp");
            testCase.verifyTrue(isvalid(gui.Figure));
        end

        function constructsAndResolvesSimulatedLuminos(testCase)
            outputRoot=tempname;
            sim=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",outputRoot,"CameraFrameRateHz",1000, ...
                "LaserPowerMw",20);
            testCase.verifyClass(sim, ...
                "adaptive_optopatch.testing.SimulatedLuminosApp");
            testCase.verifyTrue(sim.IsSimulation);
            onePhoton=adaptive_optopatch.resolve_luminos_1p_hardware(sim);
            testCase.verifyEqual(onePhoton.voltage_camera.cam_id,"S/N: 001125");
            testCase.verifyEqual(onePhoton.dmd.name,"DMD_Blue");
            testCase.verifyEqual(onePhoton.laser.name,"488");
            testCase.verifyEqual(onePhoton.modulator.name,"mod488");
            testCase.verifyEqual(onePhoton.shutter.name,"shutter488");
            testCase.verifyTrue(onePhoton.daq_sync.passed);
            twoPhoton=adaptive_optopatch.resolve_luminos_2p_hardware(sim);
            testCase.verifyEqual(twoPhoton.calibration.calibration_id, ...
                "SIMULATED_VU_CALIBRATION");
            testCase.verifyTrue(twoPhoton.calibration.simulation);
        end

        function constructsSimulatorThroughLuminosStyleEntryPoint(testCase)
            sim=simulatedLuminosApp("CameraFrameRateHz",900,"LaserPowerMw",15);
            testCase.verifyClass(sim, ...
                "adaptive_optopatch.testing.SimulatedLuminosApp");
            hardware=adaptive_optopatch.resolve_luminos_1p_hardware(sim);
            testCase.verifyEqual(hardware.laser_power_w,0.015,"AbsTol",1e-12);
            testCase.verifyEqual(hardware.voltage_camera.daqtrig_period_ms, ...
                1000/900,"AbsTol",1e-12);
        end

        function launchesRealRunnerGuisInSimulationMode(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1);

            onePhotonFolder=fullfile(root,"one_photon"); mkdir(onePhotonFolder);
            targets=struct("schema_version","test"); %#ok<NASGU>
            trials=table(1,"1p_dmd","cell_001",false,1,{protocol}, ...
                protocol.acquisition_duration_s,"gui_1p","planned","", ...
                'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
                'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
                'output_tag','acquisition_status','experiment_directory'});
            manifest=struct("trials",trials); %#ok<NASGU>
            save(fullfile(onePhotonFolder,"pattern_bundle.mat"),"targets");
            save(fullfile(onePhotonFolder,"trial_manifest.mat"),"manifest");
            [gui1,sim1]=launch_simulated_runner_gui(onePhotonFolder,"Visible","off");
            cleanup1=onCleanup(@()delete(gui1)); %#ok<NASGU>
            testCase.verifyClass(gui1,"adaptive_optopatch.OnePhotonRunnerApp");
            testCase.verifyTrue(sim1.IsSimulation);
            testCase.verifyTrue(contains(gui1.Figure.Name,"[SIMULATION]"));
            testCase.verifyNotEmpty(findall(gui1.Figure, ...
                "Text","SIMULATION — NO HARDWARE OUTPUT"));

            twoPhotonFolder=fullfile(root,"two_photon"); mkdir(twoPhotonFolder);
            target=struct("spiral_center_xy",[1024 1024], ...
                "spiral_radius_pixels",10,"parking_point_xy",[1080 1024], ...
                "spiral_preview_center_xy",[1024 1024], ...
                "parking_preview_point_xy",[1080 1024]);
            targets=struct("schema_version","0.2.0", ... %#ok<NASGU>
                "coordinate_space","voltage_camera_full_sensor_pixels", ...
                "targets",target);
            trials.stimulation_mode(:)="2p_spiral";
            manifest=struct("trials",trials); %#ok<NASGU>
            save(fullfile(twoPhotonFolder,"pattern_bundle.mat"),"targets");
            save(fullfile(twoPhotonFolder,"trial_manifest.mat"),"manifest");
            [gui2,sim2]=launch_simulated_2p_test_runner_gui( ...
                twoPhotonFolder,"Visible","off");
            cleanup2=onCleanup(@()delete(gui2)); %#ok<NASGU>
            testCase.verifyClass(gui2,"adaptive_optopatch.TwoPhotonTestRunnerApp");
            testCase.verifyTrue(sim2.IsSimulation);
            testCase.verifyTrue(contains(gui2.Figure.Name,"[SIMULATION]"));
            testCase.verifyNotEmpty(findall(gui2.Figure, ...
                "Text","SIMULATION — NO HARDWARE OUTPUT"));
        end

        function runsSimulatedOnePhotonManifest(testCase)
            outputRoot=tempname;
            cleanup=onCleanup(@()remove_if_present(outputRoot)); %#ok<NASGU>
            sim=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",outputRoot);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"PreDelayMs",10,"PostDelayMs",10);
            protocol.events.target_cell_id(:)="cell_001";
            protocol.events.dmd_pattern_index(:)=1;
            target=struct("cell_id","cell_001","qc_pass",true, ...
                "stimulation_enabled",true);
            targets=struct("targets",target,"dmd_camera_masks",true(8,9,1), ...
                "blank_dmd_mask",false(8,9));
            trials=table(1,"1p_dmd","cell_001",false,1,{protocol}, ...
                protocol.acquisition_duration_s,"sim_1p","planned","", ...
                'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
                'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
                'output_tag','acquisition_status','experiment_directory'});
            run=adaptive_optopatch.run_1p_manifest( ...
                struct("trials",trials),targets,sim, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0);
            testCase.verifyTrue(run.simulation);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            folder=run.trials.experiment_directory;
            testCase.verifyTrue(startsWith(string(folder),string(outputRoot)));
            saved=load(fullfile(folder,"output_data.mat"));
            testCase.verifyTrue(saved.simulation);
            testCase.verifyTrue(saved.adaptive_optopatch_record.simulation);
            testCase.verifyEqual(numel(sim.AcquisitionHistory),1);
        end

        function runsSimulatedBlockedTwoPhotonManifest(testCase)
            outputRoot=tempname;
            cleanup=onCleanup(@()remove_if_present(outputRoot)); %#ok<NASGU>
            sim=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",outputRoot);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"PulseDurationMs",5, ...
                "PreDelayMs",100,"PostDelayMs",100);
            protocol.events.target_cell_id(:)="cell_001";
            target=struct("cell_id","cell_001","qc_pass",true,"spiral_center_xy",[1024 1024], ...
                "spiral_radius_pixels",10,"spiral_density_points_per_volt",20, ...
                "parking_point_xy",[1080 1024], ...
                "spiral_preview_center_xy",[1024 1024], ...
                "parking_preview_point_xy",[1080 1024]);
            targets=struct("schema_version","1.0.0", ...
                "coordinate_space","voltage_camera_full_sensor_pixels", ...
                "targets",target);
            trials=table(1,"2p_spiral","cell_001",false,1,{protocol}, ...
                protocol.acquisition_duration_s,"sim_2p","planned","", ...
                'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
                'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
                'output_tag','acquisition_status','experiment_directory'});
            run=adaptive_optopatch.run_2p_manifest( ...
                struct("trials",trials),targets,sim, ...
                "ReleaseLevel","blocked_test","ConfirmTrajectoryTest",true);
            testCase.verifyTrue(run.simulation);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            folder=run.trials.experiment_directory;
            saved=load(fullfile(folder,"output_data.mat"));
            feedback=load(fullfile(folder,"adaptive_optopatch_2p_waveforms.mat"), ...
                "galvo_feedback");
            testCase.verifyTrue(saved.simulation);
            testCase.verifyTrue(saved.adaptive_optopatch_record.simulation);
            testCase.verifyTrue(feedback.galvo_feedback.simulated);
            testCase.verifyTrue(feedback.galvo_feedback.passed);
        end

        function buildsSwitchesAndInvalidatesUnifiedPlan(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>
            [app,sim]=launch_simulated_adaptive_optopatch_gui( ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            app.setReferenceData(ones(80,100),unified_test_info(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            app.setPulseProtocol(protocol);
            twoPhoton=app.buildCurrentPlan();
            testCase.verifyEqual(unique( ...
                string(twoPhoton.manifest.trials.stimulation_mode)),"2p_spiral");
            app.setPlanParameter("mode","1p_dmd");
            app.setPlanParameter("arm_output",true);
            onePhoton=app.buildCurrentPlan();
            testCase.verifyEqual(unique( ...
                string(onePhoton.manifest.trials.stimulation_mode)),"1p_dmd");
            testCase.verifyEqual(app.PlanState,"DIRTY");
            report=app.validateCurrentPlan();
            testCase.verifyTrue(report.passed);
            testCase.verifyEqual(app.PlanState,"VALIDATED");
            changed=adaptive_optopatch.generate_screen_protocol("PulseCount",2);
            changedPath=fullfile(root,"changed_protocol.mat");
            adaptive_optopatch.save_protocol(changedPath,changed);
            app.loadPulseProtocol(changedPath);
            testCase.verifyEqual(app.PlanState,"DIRTY");
            testCase.verifyEqual(app.PulseProtocolPath,string(changedPath));
        end

        function generatesCanonicalConnectivityAndStfProtocols(testCase)
            required=["pulse_id","condition_id","onset_s","duration_s", ...
                "target_cell_id","is_null","command_voltage_v","amplitude_fraction"];
            screen=adaptive_optopatch.generate_screen_protocol("PulseCount",3);
            testCase.verifyEqual(screen.schema_version,"2.0.0");
            testCase.verifyTrue(all(ismember(required, ...
                string(screen.events.Properties.VariableNames))));
            testCase.verifyEqual(screen.events.amplitude_fraction,ones(3,1));
            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",1,"PulsesPerTrain",3);
            stf=adaptive_optopatch.generate_stf_protocol(conditions);
            testCase.verifyTrue(all(ismember(required, ...
                string(stf.events.Properties.VariableNames))));
            testCase.verifyTrue(adaptive_optopatch.validate_protocol(stf).passed);
        end

        function savesAndLoadsCanonicalProtocolExactly(testCase)
            folder=tempname; mkdir(folder);
            cleanup=onCleanup(@()remove_if_present(folder)); %#ok<NASGU>
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",4,"RandomSeed",42);
            protocol.protocol_id="round_trip_test";
            path=fullfile(folder,"pulse_protocol.mat");
            adaptive_optopatch.save_protocol(path,protocol);
            loaded=adaptive_optopatch.load_protocol(path);
            testCase.verifyEqual(loaded, ...
                adaptive_optopatch.normalize_protocol(protocol));
        end

        function rejectsInvalidAndObsoleteTrainProtocols(testCase)
            invalid=adaptive_optopatch.generate_screen_protocol("PulseCount",2);
            invalid.events.onset_s(2)=invalid.events.onset_s(1);
            report=adaptive_optopatch.validate_protocol(invalid);
            testCase.verifyFalse(report.passed);
            obsolete=invalid;
            obsolete.events.pulse_times_s={0.1;0.2};
            testCase.verifyError(@()adaptive_optopatch.normalize_protocol(obsolete), ...
                "adaptive_optopatch:ObsoleteTrainRepresentation");
        end

        function mapsRelativeAmplitudeToPhysicalHardwareVoltage(testCase)
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",2);
            protocol.events.amplitude_fraction=[0.25;1];
            canonicalOnly=protocol;
            canonicalOnly.events.command_voltage_v(:)=NaN;
            canonicalOnly=rmfield(canonicalOnly,["modulator_voltage","hardware_command_voltage"]);
            testCase.verifyTrue(adaptive_optopatch.validate_protocol(canonicalOnly).passed);
            originalTiming=protocol.events(:,["onset_s","duration_s"]);
            globalProps=struct("rate",200000,"total_time",1, ...
                "clock_source","Internal Dev1","trigger_source","Dev1/PFI9", ...
                "completion_trigger","None","daq_master",true);
            wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
                "ao_camera_triggered",[],"do_camera_triggered",[]);
            [~,~,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,protocol, ...
                adaptive_optopatch.virtual_upright_1p_profile(), ...
                "ModulatorVoltageOverride",4);
            testCase.verifyEqual(summary.pulses.modulator_voltage,[1;4]);
            testCase.verifyEqual(protocol.events(:,["onset_s","duration_s"]), ...
                originalTiming);
            p1=adaptive_optopatch.flatten_pulse_schedule( ...
                protocol,"ConfiguredVoltage",2);
            testCase.verifyEqual(p1.modulator_voltage,[0.5;2]);
            target=struct("spiral_center_xy",[100 90], ...
                "spiral_radius_pixels",10, ...
                "spiral_density_points_per_volt",20, ...
                "parking_point_xy",[130 90]);
            tform=affinetform2d([100 0 50;0 100 40;0 0 1]);
            waveforms=adaptive_optopatch.build_2p_trial_waveforms( ...
                protocol,target,tform,"ModulatorVoltage",2, ...
                "MaximumVelocityVPerS",500, ...
                "MaximumAccelerationVPerS2",1e6, ...
                "MinimumIlluminatedRadiusFraction",0.5);
            testCase.verifyTrue(any(abs(waveforms.pockels_v-0.5)<1e-12));
            testCase.verifyEqual(max(waveforms.pockels_v),2);
            testCase.verifyTrue(adaptive_optopatch.validate_protocol_for_mode( ...
                protocol,"1p_dmd").passed);
            testCase.verifyTrue(adaptive_optopatch.validate_protocol_for_mode( ...
                protocol,"2p_spiral").passed);
        end

        function unifiedOnePhotonRunFreezesAllArtifacts(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>
            [app,sim]=launch_simulated_adaptive_optopatch_gui( ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            app.setReferenceData(ones(80,100),unified_test_info(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            app.setPulseProtocol(protocol);
            app.setPlanParameter("mode","1p_dmd");
            app.setPlanParameter("modulator_voltage",1.3);
            app.setPlanParameter("arm_output",true);
            run=app.runNext();
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyTrue(run.simulation);
            for filename=["reference_model.mat","pattern_bundle.mat", ...
                    "pulse_protocol.mat","trial_manifest.mat", ...
                    "planning_session.mat","fov_state.mat","run_checkpoint.mat"]
                testCase.verifyTrue(isfile(fullfile(app.ActiveRunFolder,filename)), ...
                    "Missing frozen run artifact "+filename);
            end
            frozenProtocol=adaptive_optopatch.load_protocol( ...
                fullfile(app.ActiveRunFolder,"pulse_protocol.mat"));
            frozenFov=adaptive_optopatch.load_fov_state( ...
                fullfile(app.ActiveRunFolder,"fov_state.mat"));
            savedManifest=load(fullfile(app.ActiveRunFolder,"trial_manifest.mat"),"manifest");
            savedTargets=load(fullfile(app.ActiveRunFolder,"pattern_bundle.mat"),"targets");
            testCase.verifyEqual(frozenProtocol.events.target_cell_id, ...
                savedManifest.manifest.trials.pulse_schedule{1}.events.target_cell_id);
            testCase.verifyEqual(frozenProtocol.events.command_voltage_v,1.3);
            testCase.verifyEqual(string({frozenFov.cells.cell_id}),"cell_001");
            testCase.verifyTrue(isfield(savedManifest.manifest,"advisories"));
            testCase.verifyTrue(isfield(savedManifest.manifest,"software"));
            testCase.verifyEqual(savedTargets.targets.parameters.orange_expansion_pixels, ...
                frozenFov.orange_expansion_pixels);
            testCase.verifyEqual(savedTargets.targets.parameters.blue_mask_adjustment_pixels, ...
                frozenFov.blue_mask_adjustment_pixels);
            testCase.verifyEqual(savedTargets.targets.orange_combined_mask, ...
                any(savedTargets.targets.orange_camera_masks,3));
            testCase.verifyFalse(app.ControlsLocked);
        end

        function unifiedTwoPhotonPreviewAndRunComplete(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>
            [app,sim]=launch_simulated_adaptive_optopatch_gui( ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            image=ones(80,100); image(10:15,10:15)=0;
            app.setReferenceData(image,unified_test_info(root), ...
                {[40 30;60 30;60 50;40 50]});
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            app.setPulseProtocol(protocol);
            app.setPlanParameter("trajectory_confirmed",true);
            plan=app.previewCurrentPlan();
            testCase.verifyEqual(unique( ...
                string(plan.manifest.trials.stimulation_mode)),"2p_spiral");
            run=app.runNext();
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyTrue(isfile(fullfile( ...
                run.trials.experiment_directory, ...
                "adaptive_optopatch_2p_waveforms.mat")));
        end

        function unifiedResumeUsesFrozenManifest(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>
            [app,sim]=launch_simulated_adaptive_optopatch_gui( ...
                "Visible","off","RunRoot",root); %#ok<ASGLU>
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            rois={[25 25;40 25;40 40;25 40], ...
                [60 40;75 40;75 55;60 55]};
            app.setReferenceData(ones(80,100),unified_test_info(root),rois);
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",1);
            app.setPulseProtocol(protocol);
            app.setPlanParameter("mode","1p_dmd");
            app.setPlanParameter("arm_output",true);
            first=app.runNext();
            frozenFolder=app.ActiveRunFolder;
            testCase.verifyEqual(sum(first.trials.acquisition_status=="completed"),1);
            changedProtocol=adaptive_optopatch.generate_screen_protocol("PulseCount",7);
            app.setPulseProtocol(changedProtocol);
            app.setPlanParameter("mode","2p_spiral");
            app.resumeRun(frozenFolder);
            frozen=app.ActiveRunPlan;
            testCase.verifyTrue(all(frozen.manifest.trials.stimulation_mode=="1p_dmd"));
            testCase.verifyEqual( ...
                frozen.manifest.trials.pulse_schedule{1}.pulse_count,1);
            app.setPlanParameter("mode","1p_dmd");
            app.setPlanParameter("arm_output",true);
            app.resumeRun(frozenFolder);
            resumed=app.runAll();
            testCase.verifyEqual(sum(resumed.trials.acquisition_status=="completed"),2);
        end

        function persistsCanonicalFovAndIndependentDerivedMasks(testCase)
            [fovState,polygons]=test_fov_state();
            folder=tempname; mkdir(folder);
            cleanup=onCleanup(@()remove_if_present(folder)); %#ok<NASGU>
            path=fullfile(folder,"fov_state.mat");
            adaptive_optopatch.save_fov_state(path,fovState);
            loaded=adaptive_optopatch.load_fov_state(path);
            testCase.verifyEqual(string({loaded.cells.cell_id}), ...
                ["cell_001","cell_002","cell_003"]);
            testCase.verifyEqual(loaded.canonical_roi_polygons,polygons(:));
            before=loaded.canonical_roi_masks;
            first=adaptive_optopatch.build_target_bundle(loaded.reference, ...
                "OrangeExpansionPixels",1,"BlueMaskAdjustmentPixels",-1, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1);
            second=adaptive_optopatch.build_target_bundle(loaded.reference, ...
                "OrangeExpansionPixels",4,"BlueMaskAdjustmentPixels",2, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1);
            testCase.verifyEqual(loaded.canonical_roi_masks,before);
            testCase.verifyGreaterThan(nnz(second.orange_combined_mask), ...
                nnz(first.orange_combined_mask));
            testCase.verifyGreaterThan(nnz(second.blue_camera_masks), ...
                nnz(first.blue_camera_masks));
        end

        function guiReloadsFovWithStableIdsAndCalibration(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>
            [first,~]=launch_simulated_adaptive_optopatch_gui( ...
                "Visible","off","RunRoot",root);
            cleanupFirst=onCleanup(@()delete(first)); %#ok<NASGU>
            polygons={[15 15;25 15;25 25;15 25], ...
                [45 30;55 30;55 40;45 40]};
            first.setReferenceData(ones(70,90),unified_test_info(root),polygons);
            first.setCellCalibration("cell_002",1.25,"good",true);
            path=fullfile(root,"persistent_fov.mat");
            first.saveCurrentFov(path);
            [second,~]=launch_simulated_adaptive_optopatch_gui( ...
                "Visible","off","RunRoot",root);
            cleanupSecond=onCleanup(@()delete(second)); %#ok<NASGU>
            second.loadFov(path);
            second.setPulseProtocol(adaptive_optopatch.generate_single_cell_ramp_protocol( ...
                "cell_002",[0.75 1.25],"RepeatsPerVoltage",1));
            second.setPlanParameter("mode","1p_dmd");
            plan=second.buildCurrentPlan();
            testCase.verifyEqual(string({plan.fov_state.cells.cell_id}), ...
                ["cell_001","cell_002"]);
            testCase.verifyEqual(plan.fov_state.cells(2).selected_blue_voltage_v,1.25);
            testCase.verifyEqual(plan.fov_state.canonical_roi_polygons,polygons(:));
        end

        function generatesAscendingArbitraryVoltageRamp(testCase)
            levels=[0.5 0.75 1.15 1.6];
            protocol=adaptive_optopatch.generate_single_cell_ramp_protocol( ...
                "cell_004",levels,"RepeatsPerVoltage",3, ...
                "PulseDurationMs",10,"DarkIntervalMs",90);
            testCase.verifyEqual(height(protocol.events),12);
            testCase.verifyEqual(protocol.events.command_voltage_v, ...
                repelem(levels(:),3));
            testCase.verifyEqual(unique(protocol.events.target_cell_id),"cell_004");
            testCase.verifyEqual(protocol.events.onset_s(2:end)- ...
                protocol.events.onset_s(1:end-1),0.1*ones(11,1),"AbsTol",1e-12);
            review=adaptive_optopatch.summarize_ramp_response(protocol, ...
                [zeros(3,1);ones(3,1);2*ones(3,1);ones(3,1)], ...
                [zeros(9,1);ones(3,1)],nan(12,1));
            testCase.verifyEqual(review.exactly_one_spike_fraction,[0;1;0;1]);
            testCase.verifyEqual(review.neighbor_spike_fraction,[0;0;0;1]);
        end

        function roundRobinUsesOnlyCalibratedEnabledCells(testCase)
            [fovState,~]=test_fov_state();
            fovState=adaptive_optopatch.update_cell_calibration( ...
                fovState,"cell_001","CommandVoltageV",0.8);
            fovState=adaptive_optopatch.update_cell_calibration( ...
                fovState,"cell_002","CommandVoltageV",1.2);
            fovState=adaptive_optopatch.update_cell_calibration( ...
                fovState,"cell_003","Status","excluded", ...
                "StimulationEnabled",false,"RecordingEnabled",true);
            first=adaptive_optopatch.generate_round_robin_protocol(fovState, ...
                "PulsesPerCell",5,"RandomSeed",99);
            second=adaptive_optopatch.generate_round_robin_protocol(fovState, ...
                "PulsesPerCell",5,"RandomSeed",99);
            testCase.verifyEqual(first.events,second.events);
            testCase.verifyFalse(any(first.events.target_cell_id=="cell_003"));
            testCase.verifyTrue(fovState.cells(3).recording_enabled);
            testCase.verifyFalse(fovState.cells(3).stimulation_enabled);
            expected=0.8*double(first.events.target_cell_id=="cell_001") + ...
                1.2*double(first.events.target_cell_id=="cell_002");
            testCase.verifyEqual(first.events.command_voltage_v,expected);
        end

        function buildsHardwareTimedDmdSequenceAtPulseOffsets(testCase)
            [fovState,~]=test_fov_state();
            for k=1:3
                fovState=adaptive_optopatch.update_cell_calibration(fovState, ...
                    compose("cell_%03d",k),"CommandVoltageV",0.5+0.2*k);
            end
            protocol=adaptive_optopatch.generate_round_robin_protocol(fovState, ...
                "PulsesPerCell",2,"RandomSeed",7);
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
            manifest=adaptive_optopatch.build_manifest(fovState.reference,targets, ...
                protocol,"Mode","1p_dmd");
            resolved=manifest.trials.pulse_schedule{1};
            plan=adaptive_optopatch.build_dmd_sequence_plan(resolved,targets);
            testCase.verifyEqual(plan.pattern_activation_s, ...
                [0;resolved.events.offset_s(1:end-1)]);
            testCase.verifyEqual(plan.advance_onset_s, ...
                resolved.events.offset_s(1:end-1));
            testCase.verifyTrue(plan.no_artificial_settle_interval);
            for k=1:height(resolved.events)
                index=resolved.events.dmd_pattern_index(k);
                testCase.verifyEqual(plan.camera_pattern_stack(:,:,k), ...
                    targets.blue_camera_masks(:,:,index));
            end
            sim=adaptive_optopatch.testing.make_simulated_luminos();
            dmd=sim.getDevice("DMD","name","DMD_Blue");
            config=adaptive_optopatch.prepare_luminos_dmd_sequence(dmd,plan, ...
                "DryRun",false);
            testCase.verifyTrue(config.loaded);
            testCase.verifyEqual(dmd.StackMode,"slave");
            testCase.verifyEqual(dmd.StackWriteCount,1);
            globalProps=struct("rate",200000,"total_time",1, ...
                "clock_source","Internal Dev1","trigger_source","Dev1/PFI9", ...
                "daq_master",true);
            wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
                "ao_camera_triggered",[],"do_camera_triggered",[]);
            [~,configured,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,resolved,adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);
            trigger=find(string({configured.do.name})=="AdaptiveOptopatch DMD trigger",1);
            testCase.verifyNotEmpty(trigger);
            testCase.verifyEqual(configured.do(trigger).params{1}, ...
                [0;resolved.events.offset_s(1:end-1)]);
            testCase.verifyEqual(summary.dmd_sequence.dmd_trigger_s, ...
                [0;resolved.events.offset_s(1:end-1)]);
            testCase.verifyEqual(summary.dmd_sequence.trigger_associated_pulse_id, ...
                resolved.events.pulse_id);
            testCase.verifyEqual(summary.dmd_sequence.stack_pattern_number, ...
                (1:height(resolved.events))');
            testCase.verifyLessThan(plan.initialization_trigger_s, ...
                resolved.events.onset_s(1));
            triggerWaveform=adaptive_optopatch.luminos_event_waveform( ...
                [0 1/globalProps.rate],configured.do(trigger).params{:});
            testCase.verifyEqual(triggerWaveform(1),1);
            noPreDelay=resolved;
            shift=noPreDelay.events.onset_s(1);
            noPreDelay.events.onset_s=noPreDelay.events.onset_s-shift;
            noPreDelay.acquisition_duration_s=noPreDelay.acquisition_duration_s-shift;
            noPrePlan=adaptive_optopatch.build_dmd_sequence_plan(noPreDelay,targets);
            testCase.verifyError(@()adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,noPreDelay,adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",noPrePlan), ...
                "adaptive_optopatch:DmdInitializationNotDark");
        end

        function validatesPulseIdentityTargetsAndPhysicalVoltage(testCase)
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",2);
            protocol.events.command_voltage_v=[1.1;NaN];
            protocol.events.amplitude_fraction=[0.1;0.5];
            resolved=adaptive_optopatch.resolve_protocol_commands(protocol,4);
            testCase.verifyEqual(resolved.events.command_voltage_v,[1.1;2]);
            duplicate=protocol; duplicate.events.pulse_id(2)=duplicate.events.pulse_id(1);
            testCase.verifyFalse(adaptive_optopatch.validate_protocol(duplicate).passed);
            invalidVoltage=resolved; invalidVoltage.events.command_voltage_v(1)=5.1;
            globalProps=struct("rate",200000,"clock_source","Internal Dev1", ...
                "trigger_source","Dev1/PFI9","daq_master",true);
            wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
                "ao_camera_triggered",[],"do_camera_triggered",[]);
            testCase.verifyError(@()adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,invalidVoltage,adaptive_optopatch.virtual_upright_1p_profile()), ...
                "adaptive_optopatch:ModulatorVoltageOutOfRange");
            [fovState,~]=test_fov_state();
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1);
            unknown=resolved; unknown.events.target_cell_id(:)="cell_999";
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                fovState.reference,targets,unknown,"Mode","1p_dmd"), ...
                "adaptive_optopatch:UnknownTargetCell");
        end

        function runsContinuousSimulatedRoundRobinAcquisition(testCase)
            outputRoot=tempname;
            cleanup=onCleanup(@()remove_if_present(outputRoot)); %#ok<NASGU>
            [fovState,~]=test_fov_state();
            for k=1:3
                fovState=adaptive_optopatch.update_cell_calibration(fovState, ...
                    compose("cell_%03d",k),"CommandVoltageV",0.6+0.2*k);
            end
            protocol=adaptive_optopatch.generate_round_robin_protocol(fovState, ...
                "PulsesPerCell",2,"RandomSeed",17,"DarkIntervalMs",[20 20]);
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
            manifest=adaptive_optopatch.build_manifest(fovState.reference,targets, ...
                protocol,"Mode","1p_dmd");
            sim=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",outputRoot);
            run=adaptive_optopatch.run_1p_manifest(manifest,targets,sim, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0);
            testCase.verifyEqual(height(run.trials),1);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyEqual(numel(sim.AcquisitionHistory),1);
            dmd=sim.getDevice("DMD","name","DMD_Blue");
            testCase.verifyEqual(dmd.StackWriteCount,1);
            saved=load(fullfile(run.trials.experiment_directory,"output_data.mat"), ...
                "adaptive_optopatch_record");
            realized=saved.adaptive_optopatch_record.realized_pulses;
            testCase.verifyEqual(realized.target_cell_id,protocol.events.target_cell_id);
            testCase.verifyEqual(realized.command_voltage_v,protocol.events.command_voltage_v);
            testCase.verifyEqual(realized.dmd_pattern_index, ...
                manifest.trials.pulse_schedule{1}.events.dmd_pattern_index);
            sequence=saved.adaptive_optopatch_record.waveform_summary.dmd_sequence;
            testCase.verifyEqual(sequence.dmd_trigger_s, ...
                [0;protocol.events.offset_s(1:end-1)]);
            testCase.verifyEqual(numel(sequence.dmd_trigger_s),height(protocol.events));
        end

        function calibrationDriftIsAdvisoryButUnsafeStatesStillError(testCase)
            [fovState,~]=test_fov_state();
            fovState=adaptive_optopatch.update_cell_calibration(fovState,"cell_001", ...
                "CommandVoltageV",0.8,"PulseDurationMs",10,"ObisPowerW",0.01);
            frozen=adaptive_optopatch.generate_round_robin_protocol(fovState, ...
                "PulsesPerCell",1,"PulseDurationMs",8);
            fovState.cells(1).selected_blue_voltage_v=0.9;
            fovState.cells(1).canonical_roi_polygon= ...
                fovState.cells(1).canonical_roi_polygon+[0.25 0];
            fovState.reference.cells=fovState.cells;
            fovState.blue_mask_adjustment_pixels=0;
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "PulseDurationMs",8,"OrangeExpansionPixels",7, ...
                "BlueMaskAdjustmentPixels",0);
            manifest=adaptive_optopatch.build_manifest(fovState.reference,targets, ...
                frozen,"Mode","1p_dmd","CurrentObisPowerW",0.02);
            codes=string({manifest.advisories.code});
            testCase.verifyTrue(all(ismember(["blue_mask_adjustment_changed", ...
                "pulse_duration_changed","roi_geometry_changed", ...
                "obis_setpoint_changed","selected_voltage_changed", ...
                "frozen_protocol_voltage_differs"],codes)));
            testCase.verifyFalse(any(contains(codes,"orange")));
            testCase.verifyEqual(manifest.trials.pulse_schedule{1}.events.command_voltage_v,0.8);

            disabledReference=fovState.reference;
            disabledReference.cells(1).stimulation_enabled=false;
            disabledTargets=adaptive_optopatch.build_target_bundle(disabledReference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1);
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                disabledReference,disabledTargets,frozen,"Mode","1p_dmd"), ...
                "adaptive_optopatch:StimulationDisabledCell");
            invalid=frozen; invalid.events.command_voltage_v(:)=0;
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                fovState.reference,targets,invalid,"Mode","1p_dmd"), ...
                "adaptive_optopatch:InvalidTargetVoltage");
            unsafe=frozen; unsafe.events.command_voltage_v(:)=5.1;
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                fovState.reference,targets,unsafe,"Mode","1p_dmd"), ...
                "adaptive_optopatch:ModulatorVoltageOutOfRange");
        end

        function programsCurrentCombinedOrangeMask(testCase)
            [fovState,~]=test_fov_state();
            fovState.cells(2).recording_enabled=false;
            fovState.reference.cells=fovState.cells;
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "OrangeExpansionPixels",4);
            sim=adaptive_optopatch.testing.make_simulated_luminos();
            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                sim,targets,"DryRun",false);
            dmd=sim.getDevice("DMD","name","DMD_Orange");
            testCase.verifyTrue(configuration.loaded);
            testCase.verifyEqual(configuration.recording_cell_ids,["cell_001","cell_003"]);
            testCase.verifyEqual(configuration.orange_expansion_pixels,4);
            testCase.verifyEqual(dmd.Target,targets.orange_combined_mask);
            testCase.verifyEqual(dmd.StaticWriteCount,1);
        end

        function preservesStableIdsAcrossEditDeleteAddAndReload(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>
            [app,~]=launch_simulated_adaptive_optopatch_gui("Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            [~,polygons]=test_fov_state();
            app.setReferenceData(ones(70,90),unified_test_info(root),polygons);
            app.setCellCalibration("cell_003",1.1,"good",true);
            firstPath=fullfile(root,"first_fov.mat"); app.saveCurrentFov(firstPath);
            app.loadFov(firstPath);
            moved=polygons{3}+[1 0]; app.setCanonicalRoi("cell_003",moved);
            app.deleteCell("cell_002");
            newId=app.addCanonicalRoi([40 30;49 30;49 39;40 39]);
            testCase.verifyEqual(newId,"cell_004");
            secondPath=fullfile(root,"second_fov.mat"); app.saveCurrentFov(secondPath);
            loaded=adaptive_optopatch.load_fov_state(secondPath);
            testCase.verifyEqual(string({loaded.cells.cell_id}), ...
                ["cell_001","cell_003","cell_004"]);
            testCase.verifyEqual(loaded.cells(2).selected_blue_voltage_v,1.1);
            testCase.verifyEqual(loaded.canonical_roi_polygons{2},moved);
            testCase.verifyEqual(loaded.next_cell_index,5);
        end

        function rampReviewStoresManualDecisionWithoutSpikeDetector(testCase)
            [fovState,~]=test_fov_state();
            protocol=adaptive_optopatch.generate_single_cell_ramp_protocol( ...
                "cell_001",[0.6 0.9],"RepeatsPerVoltage",2);
            t=(0:0.001:protocol.acquisition_duration_s)';
            traces=struct("tvec",t,"frame_rate_hz",1000, ...
                "corrected_traces",sin(2*pi*5*t)*(1:3));
            review=adaptive_optopatch.RampReviewApp("simulated_ramp",protocol, ...
                fovState,"Visible","off","TraceResult",traces);
            cleanup=onCleanup(@()delete(review)); %#ok<NASGU>
            updated=review.applyDecision(0.9,"good","manual review");
            calibration=updated.cells(1).blue_calibration;
            testCase.verifyEqual(updated.cells(1).selected_blue_voltage_v,0.9);
            testCase.verifyEqual(calibration.pulse_duration_ms,10);
            testCase.verifyEqual(calibration.calibration_acquisition,"simulated_ramp");
        end
    end
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end

function info=unified_test_info(root)
camera=struct("ROI",[0 0 100 80],"bin",1, ...
    "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
metadata=struct("rig_name","Virtual_Upright","voltage_camera",camera);
info=struct("snapshot_name","unified_test", ...
    "snapshot_directory",string(root), ...
    "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
    "metadata",metadata);
end

function [fovState,polygons]=test_fov_state()
image=zeros(70,90); masks=false(70,90,3);
masks(15:24,15:24,1)=true;
masks(15:24,40:49,2)=true;
masks(40:49,65:74,3)=true;
polygons={ [15 15;24 15;24 24;15 24], ...
    [40 15;49 15;49 24;40 24], ...
    [65 40;74 40;74 49;65 49] };
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","test_fov","CellIds",["cell_001";"cell_002";"cell_003"], ...
    "RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons);
end
