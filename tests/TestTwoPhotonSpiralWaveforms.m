classdef TestTwoPhotonSpiralWaveforms < matlab.unittest.TestCase
    %TESTTWOPHOTONSPIRALWAVEFORMS What the scanner is actually commanded to do.
    %   Spiral geometry, the parking point it returns to, the trial waveforms
    %   built from a protocol and a calibration, and the motion limits and
    %   staged release levels that decide whether those waveforms may be
    %   played at all.
    %
    %   Deliberately separate from TestTwoPhotonScannerCalibration: a correct
    %   transform and an unplayable trajectory are different failures and are
    %   found by different assertions.

    methods (Test)
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

        function buildsCameraCalibratedTwoPhotonWaveforms(testCase)
            tform=affinetform2d([100 0 50;0 100 40;0 0 1]);
            target=struct("spiral_center_xy",[100 90], ...
                "spiral_radius_pixels",10, ...
                "spiral_density_points_per_volt",20, ...
                "parking_point_xy",[130 90]);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"PulseDurationMs",5, ...
                "DarkIntervalMs",[200 200],"PreDelayMs",100, ...
                "PostDelayMs",100,"ModulatorVoltage",1);
            protocol=AoFixtures.resolvedProtocol(definition,"2p_spiral");
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
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"PulseDurationMs",5, ...
                "DarkIntervalMs",[50 50],"PreDelayMs",100, ...
                "PostDelayMs",1,"ModulatorVoltage",1);
            protocol=AoFixtures.resolvedProtocol(definition,"2p_spiral");
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

        function keepsGalvosScanningWithinTenPulseTrain(testCase)
            conditions=table("train_100hz",100,10,5,1,0.1,false, ...
                'VariableNames',{'condition_id','frequency_hz', ...
                'pulses_per_train','pulse_duration_ms','repeats', ...
                'command_voltage_v','is_null'});
            definition=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[450 550]);
            protocol=AoFixtures.resolvedProtocol(definition,"2p_spiral");
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

        function evaluatesConservativeGalvoLimits(testCase)
            t=linspace(0,2*pi,4001)';
            x=0.05*cos(t); y=0.05*sin(t);
            report=adaptive_optopatch.evaluate_galvo_waveform(x,y,200000);
            testCase.verifyTrue(report.passed);
            testCase.verifyTrue(report.small_angle_class);
            testCase.verifyLessThan(report.repetition_rate_hz,1000);
            testCase.verifyLessThan(report.wrap_step_volts,1e-10);
        end

        function enforcesStagedTwoPhotonReleaseLevels(testCase)
            protocol=AoFixtures.resolvedProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",3,"ModulatorVoltage",1),"2p_spiral");
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

            pilotProtocol=AoFixtures.resolvedProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",200,"ModulatorVoltage",1),"2p_spiral");
            pilotManifest=manifest;
            pilotManifest.trials.pulse_schedule={pilotProtocol};
            pilot=adaptive_optopatch.validate_2p_release_level( ...
                pilotManifest,"pilot_single","ConfirmTrajectoryTest",true, ...
                "ConfirmLiveOutput",true,"ModulatorVoltageOverride",0.1);
            testCase.verifyTrue(pilot.passed);

            unlimitedProtocol=AoFixtures.resolvedProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",500,"ModulatorVoltage",1),"2p_spiral");
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
            standard=adaptive_optopatch.validate_2p_release_level( ...
                pilotManifest,"standard");
            testCase.verifyTrue(standard.passed);
            testCase.verifyEqual(standard.maximum_trials_this_call,Inf);

            % A Pockels command that execution would silently discard is
            % rejected rather than accepted and ignored.
            discarded=adaptive_optopatch.validate_2p_release_level( ...
                pilotManifest,"standard","ModulatorVoltageOverride",0.1);
            testCase.verifyFalse(discarded.passed);
            blockedWithVoltage=adaptive_optopatch.validate_2p_release_level( ...
                manifest,"blocked_test","ConfirmTrajectoryTest",true, ...
                "ModulatorVoltageOverride",0.1);
            testCase.verifyFalse(blockedWithVoltage.passed);
            aboveLimit=adaptive_optopatch.validate_2p_release_level( ...
                manifest,"attenuated_test","ConfirmTrajectoryTest",true, ...
                "ConfirmLiveOutput",true,"ModulatorVoltageOverride",6);
            testCase.verifyFalse(aboveLimit.passed);
        end
    end
end
