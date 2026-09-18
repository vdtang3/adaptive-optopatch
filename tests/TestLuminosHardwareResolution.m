classdef TestLuminosHardwareResolution < matlab.unittest.TestCase
    %TESTLUMINOSHARDWARERESOLUTION Finding the rig's devices in a live session.
    %   The rig profiles name the terminals, devices and clocks Adaptive
    %   Optopatch expects; resolve_luminos_1p_hardware and
    %   resolve_luminos_2p_hardware find them in a session and refuse to guess.
    %
    %   Two properties are worth stating because their failures are quiet:
    %   resolving hardware must not MUTATE it (the operator's OBIS mode
    %   survives a preflight), and a terminal that differs only in whitespace
    %   is the same terminal while one that differs in substance is not.

    methods (Test)
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

        function acceptsAndPreservesLuminosObisModes(testCase)
            for mode=["CWP","ANALOG","MIXED"]
                luminosApp=simulatedLuminosApp("LaserMode",mode);
                laser=luminosApp.getDevice("Laser_Device","name","488");

                hardware=adaptive_optopatch.resolve_luminos_1p_hardware(luminosApp);

                testCase.verifyEqual(hardware.laser_mode,mode);
                testCase.verifyEqual(laser.Mode,mode, ...
                    "1P hardware preflight must not mutate the Luminos OBIS mode.");
            end
        end

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
    end
end
