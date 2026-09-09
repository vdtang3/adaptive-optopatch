classdef TestProtocolSchema3 < matlab.unittest.TestCase
    methods (Test)
        function targetPoliciesResolveFromCurrentFov(testCase)
            [fov,targets,gui]=fixture();
            ramp=adaptive_optopatch.generate_single_cell_ramp_protocol( ...
                [0.4 0.8],"RepeatsPerVoltage",1);
            testCase.verifyFalse(ismember("target_cell_id", ...
                string(ramp.acquisitions.events.Properties.VariableNames)));
            resolved=adaptive_optopatch.resolve_protocol(ramp,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyNumElements(resolved,2);
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,[0.4;0.8]);
            testCase.verifyEqual(resolved{2}.events.command_voltage_v,[0.4;0.8]);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source, ...
                ["event";"event"]);
            testCase.verifyFalse(any(resolved{1}.events.target_cell_id=="cell_002"));

            roundRobin=adaptive_optopatch.generate_round_robin_protocol( ...
                "PulsesPerCell",2,"RandomSeed",41);
            testCase.verifyFalse(ismember("target_cell_id", ...
                string(roundRobin.acquisitions.events.Properties.VariableNames)));
            continuous=adaptive_optopatch.resolve_protocol( ...
                roundRobin,fov,targets,gui,"Mode","1p_dmd");
            testCase.verifyNumElements(continuous,1);
            testCase.verifyEqual(height(continuous{1}.events),4);
            testCase.verifyEqual(sort(unique(continuous{1}.events.target_cell_id)), ...
                ["cell_001";"cell_003"]);
        end

        function explicitAcquisitionsAreNeverInferred(testCase)
            [fov,targets,gui]=fixture();
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            definition.acquisitions(2)=definition.acquisitions(1);
            definition.acquisitions(2).acquisition_id="second";
            definition.acquisitions(2).parameters.orange_expansion_pixels=4;
            resolved=adaptive_optopatch.resolve_protocol( ...
                definition,fov,targets,gui,"Mode","1p_dmd");
            testCase.verifyNumElements(resolved,4);
            testCase.verifyEqual([resolved{1}.parameters.orange_expansion_pixels, ...
                resolved{2}.parameters.orange_expansion_pixels, ...
                resolved{3}.parameters.orange_expansion_pixels, ...
                resolved{4}.parameters.orange_expansion_pixels],[2 2 4 4]);

            invalid=definition;
            invalid.acquisitions=invalid.acquisitions(1);
            invalid.acquisitions.parameters.orange_expansion_pixels=[0 1 2];
            report=adaptive_optopatch.validate_protocol(invalid);
            testCase.verifyFalse(report.passed);
            testCase.verifyTrue(any(contains(lower(report.issues), ...
                "separate acquisition entries")));
        end

        function voltagePrecedenceIsGeneric(testCase)
            [fov,targets,gui]=fixture();
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1.5);
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,1.5);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source,"event");

            definition.acquisitions.events.command_voltage_v=NaN;
            definition.acquisitions.parameters.command_voltage_v=1.4;
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,1.4);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source,"acquisition");

            definition.acquisitions.parameters=struct;
            definition.parameters.command_voltage_v=1.3;
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.events.command_voltage_source,"protocol");

            definition.parameters=struct;
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,0.8);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source,"fov_cell");

            fov.cells(1).selected_blue_voltage_v=NaN;
            fov.reference.cells=fov.cells;
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,1.1);
            testCase.verifyEqual(resolved{1}.events.command_voltage_source,"gui");
        end

        function unresolvedVoltageFailsOnlyWhenNeeded(testCase)
            [fov,targets,gui]=fixture();
            fov.cells(1).selected_blue_voltage_v=NaN;
            fov.cells(3).selected_blue_voltage_v=NaN;
            fov.reference.cells=fov.cells;
            gui.command_voltage_v=NaN;
            roundRobin=adaptive_optopatch.generate_round_robin_protocol( ...
                "PulsesPerCell",1);
            testCase.verifyError(@()adaptive_optopatch.resolve_protocol( ...
                roundRobin,fov,targets,gui,"Mode","1p_dmd"), ...
                "adaptive_optopatch:UnresolvedProtocolParameter");

            ramp=adaptive_optopatch.generate_single_cell_ramp_protocol(0.7, ...
                "RepeatsPerVoltage",1);
            resolved=adaptive_optopatch.resolve_protocol(ramp,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyNumElements(resolved,2);
            testCase.verifyEqual(resolved{1}.events.command_voltage_v,0.7);
        end

        function blueMaskTitrationIsRealizedAndReproducible(testCase)
            [fov,targets,gui]=fixture();
            first=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                [-4 -3 -2 -1 0],"RandomSeed",2001);
            second=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                [-4 -3 -2 -1 0],"RandomSeed",2001);
            third=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                [-4 -3 -2 -1 0],"RandomSeed",2002);
            testCase.verifyEqual(first.acquisitions.events,second.acquisitions.events);
            testCase.verifyNotEqual(first.acquisitions.events.blue_mask_adjustment_pixels, ...
                third.acquisitions.events.blue_mask_adjustment_pixels);
            resolved=adaptive_optopatch.resolve_protocol(first,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyEqual(sort(resolved{1}.events.blue_mask_adjustment_pixels), ...
                (-4:0)');
            testCase.verifyEqual(resolved{1}.events.blue_mask_adjustment_source, ...
                repmat("event",5,1));
        end

        function orangeScopeAndFallbackAreEnforced(testCase)
            [fov,targets,gui]=fixture();
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"ModulatorVoltage",1);
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.parameters.orange_expansion_pixels,2);
            testCase.verifyEqual(resolved{1}.parameter_sources.orange_expansion_pixels,"gui");

            definition.acquisitions.parameters.orange_expansion_pixels=5;
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyEqual(resolved{1}.parameters.orange_expansion_pixels,5);
            testCase.verifyEqual(resolved{1}.parameter_sources.orange_expansion_pixels, ...
                "acquisition");
            materialized=adaptive_optopatch.apply_acquisition_parameters( ...
                targets,resolved{1});
            testCase.verifyEqual(materialized.parameters.orange_expansion_pixels,5);
            testCase.verifyGreaterThan(nnz(materialized.orange_combined_mask), ...
                nnz(targets.orange_combined_mask));

            invalid=definition;
            invalid.acquisitions.events.orange_expansion_pixels=[1;2];
            report=adaptive_optopatch.validate_protocol(invalid);
            testCase.verifyFalse(report.passed);
            testCase.verifyTrue(any(contains(report.issues, ...
                "Orange DMD mask expansion cannot vary within one acquisition")));
        end

        function orderingAndJitterSemanticsAreIndependent(testCase)
            ordered=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                [-4 -3 -2 -1 0],"EventOrder","ordered","RandomSeed",99);
            testCase.verifyEqual(ordered.acquisitions.events.blue_mask_adjustment_pixels, ...
                (-4:0)');
            first=adaptive_optopatch.generate_round_robin_protocol( ...
                "PulsesPerCell",4,"EventOrder","randomized","RandomSeed",9);
            second=adaptive_optopatch.generate_round_robin_protocol( ...
                "PulsesPerCell",4,"EventOrder","randomized","RandomSeed",9);
            [fov,targets,gui]=fixture();
            a=adaptive_optopatch.resolve_protocol(first,fov,targets,gui,"Mode","1p_dmd");
            b=adaptive_optopatch.resolve_protocol(second,fov,targets,gui,"Mode","1p_dmd");
            testCase.verifyEqual(a{1}.events,b{1}.events);
            testCase.verifyTrue(a{1}.event_order_realized);
            testCase.verifyTrue(all(isfinite(a{1}.events.onset_s)));
            testCase.verifyTrue(ismember("realized_dark_interval_s", ...
                string(a{1}.events.Properties.VariableNames)));
        end

        function fovSchemaHasIndependentEligibilityAndNoStatus(testCase)
            [fov,~,~]=fixture();
            fov.cells(1).selected_blue_voltage_v=NaN;
            fov.cells(1).stimulation_enabled=true;
            fov.cells(1).recording_enabled=false;
            testCase.verifyTrue(fov.cells(1).stimulation_enabled);
            testCase.verifyFalse(fov.cells(1).recording_enabled);
            testCase.verifyFalse(isfield(fov.cells,"calibration_status"));
            updated=adaptive_optopatch.update_cell_calibration(fov,"cell_001", ...
                "CommandVoltageV",0.9,"PulseDurationMs",10,"Notes","manual");
            updated=adaptive_optopatch.update_cell_calibration(updated,"cell_001", ...
                "CommandVoltageV",1.0,"PulseDurationMs",10,"Notes","second");
            testCase.verifyEqual(updated.cells(1).selected_blue_voltage_v,1.0);
            testCase.verifyNotEmpty(updated.cells(1).blue_calibration_history);
            testCase.verifyFalse(isfield(updated.cells,"calibration_status"));
        end

        function obsoleteSchemasFailClearly(testCase)
            old=struct("schema_version","2.0.0");
            testCase.verifyError(@()adaptive_optopatch.normalize_protocol(old), ...
                "adaptive_optopatch:ObsoleteProtocolSchema");
        end
    end
end

function [fov,targets,gui]=fixture()
image=zeros(60,90); masks=false(60,90,3);
masks(15:24,10:19,1)=true;
masks(15:24,40:49,2)=true;
masks(35:44,70:79,3)=true;
ids=["cell_001";"cell_002";"cell_003"];
polygons={[10 15;19 15;19 24;10 24], ...
    [40 15;49 15;49 24;40 24], ...
    [70 35;79 35;79 44;70 44]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","schema3_fixture","CellIds",ids,"RoiPolygons",polygons);
fov=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd","SpiralRadiusUm",2, ...
    "BlueMaskAdjustmentPixels",0);
fov.cells(1).selected_blue_voltage_v=0.8;
fov.cells(2).selected_blue_voltage_v=0.9;
fov.cells(2).stimulation_enabled=false;
fov.cells(3).selected_blue_voltage_v=1.2;
fov.reference.cells=fov.cells;
targets=adaptive_optopatch.build_target_bundle(fov.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
gui=struct("command_voltage_v",1.1,"pulse_duration_s",0.01, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
