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
                "MaximumAccelerationVPerS2",1e6);
            testCase.verifyTrue(w.preflight.passed);
            testCase.verifyEqual(max(w.pockels_v),1);
            testCase.verifyEqual(w.parking_v,[0.8 0.5],"AbsTol",1e-12);
            testCase.verifyEqual(numel(w.x_v), ...
                ceil(protocol.acquisition_duration_s*w.sample_rate_hz));
            testCase.verifyGreaterThan(w.per_pulse(1).cycle_fraction_during_light,0);
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
        end

        function constructsTwoPhotonTestRunnerGui(testCase)
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            protocol=adaptive_optopatch.generate_screen_protocol("PulseCount",3);
            targets=struct("targets",struct("spiral_center_xy",[20 20])); %#ok<NASGU>
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

        function randomizesMixedStfConditions(testCase)
            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",4,"PulsesPerTrain",3);
            p=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[100 120],"RandomSeed",2);
            testCase.verifyEqual(height(p.events),12);
            testCase.verifyEqual(sum(p.events.frequency_hz==100),4);
            testCase.verifyLessThanOrEqual(max(p.events.frequency_hz,[],"omitnan"),100);
            testCase.verifyTrue(all(p.events.event_onset_s(2:end)>= ...
                p.events.event_offset_s(1:end-1)));
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
                "DmdErosionPixels",1);
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

        function negativeDmdErosionDilatesMask(testCase)
            img=zeros(30); masks=false(30,30,1); masks(14:16,14:16,1)=true;
            metadata=struct("rig_name","Virtual_Upright", ...
                "voltage_camera",struct("serial","001125"));
            ref=adaptive_optopatch.create_reference_model(img,masks,metadata);
            contracted=adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",1,"ParkingClearancePixels",1, ...
                "DmdErosionPixels",1);
            expanded=adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",1,"ParkingClearancePixels",1, ...
                "DmdErosionPixels",-2);
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
                "ModulatorVoltage",2);
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
    end
end
