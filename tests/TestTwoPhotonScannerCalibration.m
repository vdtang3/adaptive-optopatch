classdef TestTwoPhotonScannerCalibration < matlab.unittest.TestCase
    %TESTTWOPHOTONSCANNERCALIBRATION The galvo-to-camera transform, end to end.
    %   Owns everything between "point the scanner somewhere" and "know where
    %   it pointed": fitting the transform from a calibration grid, validating
    %   a fitted artifact, persisting and reloading it, reading the feedback
    %   channels back, and refusing a calibration that cannot describe the
    %   target being asked for.
    %
    %   The spiral and trial waveforms BUILT on a transform belong to
    %   TestTwoPhotonSpiralWaveforms; whether a run keeps using the transform
    %   it was frozen with belongs to TestFrozenRunLifecycle. This suite is
    %   only about the transform itself.

    methods (Test)
        function warnsWhenLiveScannerIsUnavailable(testCase)
            [calibration,message]= ...
                adaptive_optopatch.get_live_scanner_calibration([]);
            testCase.verifyEmpty(calibration);
            testCase.verifyTrue(contains(message,"Live Luminos app was not supplied"));
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

        function rejectsOutOfDomainScannerCalibration(testCase)
            bad=affinetform2d([0.04 0 -190;0 0.04 48;0 0 1]);
            testCase.verifyError(@()adaptive_optopatch.generate_2p_spiral_cycle( ...
                bad,[1000 1100],17,10), ...
                "adaptive_optopatch:ScannerCalibrationOutsideBounds");
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
    end
end
