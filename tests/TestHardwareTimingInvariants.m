classdef TestHardwareTimingInvariants < matlab.unittest.TestCase
%TESTHARDWARETIMINGINVARIANTS Physical timing limits that a frozen 1P
%schedule must satisfy on the live hardware before output is armed.
    methods (Test)
        function unavailableDmdCapabilityIsRecordedNotInvented(testCase)
            [plan,~]=screen_sequence_plan();
            dmd=simulated_blue_dmd();
            testCase.verifyTrue(isnan(dmd.minimum_picture_time_us));
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            testCase.verifyTrue(configuration.loaded);
            testCase.verifyFalse(configuration.pattern_advance.validated);
            testCase.verifyTrue(isnan( ...
                configuration.pattern_advance.minimum_picture_time_s));
        end

        function dmdRejectsAdvanceFasterThanItsMinimumPictureTime(testCase)
            [plan,~]=screen_sequence_plan();
            shortest=min(diff(plan.dmd_trigger_s));
            dmd=simulated_blue_dmd();
            dmd.minimum_picture_time_us=1e6*shortest*1.5;
            testCase.verifyError( ...
                @()adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false), ...
                "adaptive_optopatch:DmdPatternAdvanceTooFast");
        end

        function dmdAcceptsAdvanceAtItsMinimumPictureTime(testCase)
            [plan,~]=screen_sequence_plan();
            shortest=min(diff(plan.dmd_trigger_s));
            dmd=simulated_blue_dmd();
            dmd.minimum_picture_time_us=1e6*shortest;
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            testCase.verifyTrue(configuration.pattern_advance.validated);
            testCase.verifyEqual( ...
                configuration.pattern_advance.requested_minimum_interval_s, ...
                shortest,"AbsTol",1e-12);
        end
    end
end

function dmd=simulated_blue_dmd()
sim=adaptive_optopatch.testing.make_simulated_luminos();
dmd=sim.getDevice("DMD","name","DMD_Blue");
end

function [plan,protocol]=screen_sequence_plan()
[fovState,targets]=single_cell_fixture();
definition=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",3,"PulseDurationMs",5,"DarkIntervalMs",[50 50], ...
    "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1);
resolved=adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
    gui_defaults(),"Mode","1p_dmd");
protocol=resolved{1};
plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
end

function [fovState,targets]=single_cell_fixture()
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","hardware_timing_test","CellIds","cell_001", ...
    "RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
end

function defaults=gui_defaults()
defaults=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
