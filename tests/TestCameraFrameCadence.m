classdef TestCameraFrameCadence < matlab.unittest.TestCase
    %TESTCAMERAFRAMECADENCE The DAQ trigger period owns the camera's cadence.
    %   A camera triggered by the DAQ acquires one frame per trigger, so the
    %   frame rate is the trigger period's and not the camera's own estimate
    %   of what it could manage. Getting this wrong silently changes the time
    %   axis of every trace extracted from the recording afterwards, which is
    %   why an unusable period is an error rather than a fallback.
    %
    %   Both input shapes the rig produces are covered: a plain struct, and a
    %   live Luminos camera device.

    methods (Test)
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

        function daqTriggerPeriodOwnsExplicitCameraCadence(testCase)
            camera=struct("name","Camera 1", ...
                "frametrigger_source","DAQ","daqtrig_period_ms",1, ...
                "frames_requested",2,"maximum_frame_rate_hz",848.128);
            [updated,plan]=adaptive_optopatch.set_camera_frames_for_duration( ...
                camera,1);
            testCase.verifyEqual(updated.frames_requested,1000);
            testCase.verifyEqual(plan.frame_rate_hz,1000);
            testCase.verifyEqual(plan.calculated_camera_limit_hz,848.128);
            testCase.verifyTrue(isnan(plan.conservative_camera_limit_hz));
            testCase.verifyFalse(plan.rate_override_used);
        end

        function daqPeriodControlsFrameRateDespiteLowerEstimate(testCase)
            camera=adaptive_optopatch.testing.SimulatedLuminosDevice( ...
                "Camera","Orca Fusion");
            camera.frametrigger_source="Trigger each Frame (DAQ)";
            camera.daqtrig_period_ms=1;
            camera.maximum_frame_rate_hz=848.128;
            durationS=1.001;

            [camera,plan]=adaptive_optopatch.set_camera_frames_for_duration( ...
                camera,durationS);
            testCase.verifyEqual(plan.frame_rate_hz,1000);
            testCase.verifyEqual(camera.frames_requested,ceil(durationS*1000));
            testCase.verifyEqual(plan.calculated_camera_limit_hz,848.128);
            testCase.verifyTrue(plan.rate_validation_passed);
        end

        function invalidDaqPeriodsStillFail(testCase)
            for period={[],0,-1,NaN,Inf,[1 2]}
                camera=struct("frametrigger_source","DAQ", ...
                    "daqtrig_period_ms",period{1},"frames_requested",1);
                testCase.verifyError( ...
                    @()adaptive_optopatch.set_camera_frames_for_duration(camera,1), ...
                    "adaptive_optopatch:InvalidCameraTriggerPeriod");
            end
            missing=rmfield(camera,"daqtrig_period_ms");
            testCase.verifyError( ...
                @()adaptive_optopatch.set_camera_frames_for_duration(missing,1), ...
                "adaptive_optopatch:InvalidCameraTriggerPeriod");
        end
    end
end
