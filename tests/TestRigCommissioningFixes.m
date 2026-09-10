classdef TestRigCommissioningFixes < matlab.unittest.TestCase
    methods (Test)
        function trimsDaqTerminalWhitespaceWithoutWeakeningMatch(testCase)
            luminosApp=simulatedLuminosApp();
            daq=luminosApp.getDevice("DAQ");
            daq.clock_bridge=["Dev1/PFI12","Dev2/PFI0 "];

            hardware=adaptive_optopatch.resolve_luminos_1p_hardware(luminosApp);
            testCase.verifyEqual(hardware.daq_sync.clock_bridge, ...
                ["Dev1/PFI12","Dev2/PFI0"]);

            daq.clock_bridge=["Dev1/PFI12","Dev2/PFI1"];
            testCase.verifyError( ...
                @()adaptive_optopatch.resolve_luminos_1p_hardware(luminosApp), ...
                "adaptive_optopatch:UnexpectedClockBridge");
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

        function fovDialogFilterUsesCharacterVectors(testCase)
            filter=adaptive_optopatch.fov_file_dialog_filter();
            testCase.verifyTrue(iscell(filter));
            testCase.verifySize(filter,[1 2]);
            testCase.verifyTrue(all(cellfun(@ischar,filter)));
            testCase.verifyEqual(filter,{'*.mat','FOV state MAT (*.mat)'});
        end
    end
end
