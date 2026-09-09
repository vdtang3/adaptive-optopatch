classdef TestBlueDmdAdvisoryPolicy < matlab.unittest.TestCase
    methods (Test)
        function overlapIsAdvisoryAndRunProvenance(testCase)
            [reference,targets,fovState]=blue_case(true,false);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            manifest=adaptive_optopatch.build_manifest(reference,targets,protocol, ...
                "Mode","1p_dmd","FovState",fovState,"GuiDefaults",gui_defaults());
            testCase.verifyFalse(targets.targets(1).blue_qc_pass);
            testCase.verifyGreaterThan(targets.targets(1).dmd_overlap_pixels,0);
            testCase.verifyTrue(has_code(manifest.advisories,"blue_mask_overlap"));
            preflight=adaptive_optopatch.preflight_trial(targets,manifest.trials(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
            testCase.verifyTrue(any(contains(preflight.warnings,"overlaps another canonical ROI")));

            outputRoot=tempname;
            cleanup=onCleanup(@()remove_if_present(outputRoot)); %#ok<NASGU>
            simulator=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",outputRoot);
            run=adaptive_optopatch.run_1p_manifest(manifest,targets,simulator, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0);
            testCase.verifyEqual(run.trials.acquisition_status,repmat("completed",2,1));
            saved=load(fullfile(run.trials.experiment_directory(1),"output_data.mat"), ...
                "adaptive_optopatch_record");
            testCase.verifyTrue(has_code( ...
                saved.adaptive_optopatch_record.advisories,"blue_mask_overlap"));
        end

        function edgeProximityIsAdvisory(testCase)
            [reference,targets,fovState]=blue_case(false,true);
            manifest=adaptive_optopatch.build_manifest(reference,targets, ...
                adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1),"Mode","1p_dmd", ...
                "FovState",fovState,"GuiDefaults",gui_defaults());
            testCase.verifyTrue(targets.targets(1).edge_flag);
            testCase.verifyFalse(targets.targets(1).blue_qc_pass);
            testCase.verifyTrue(has_code(manifest.advisories,"blue_mask_near_edge"));
            preflight=adaptive_optopatch.preflight_trial(targets,manifest.trials(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
            testCase.verifyTrue(any(contains(preflight.warnings,"near the camera ROI edge")));
        end

        function overlapAndEdgeRemainRunnable(testCase)
            [reference,targets,fovState]=blue_case(true,true);
            manifest=adaptive_optopatch.build_manifest(reference,targets, ...
                adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1),"Mode","1p_dmd", ...
                "FovState",fovState,"GuiDefaults",gui_defaults());
            codes=string({manifest.advisories.code});
            testCase.verifyTrue(all(ismember( ...
                ["blue_mask_overlap","blue_mask_near_edge"],codes)));
            preflight=adaptive_optopatch.preflight_trial(targets,manifest.trials(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
        end

        function unresolvedProtocolIncludesWarningTargets(testCase)
            [reference,targets,fovState]=blue_case(true,false);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            manifest=adaptive_optopatch.build_manifest(reference,targets,protocol, ...
                "Mode","1p_dmd","FovState",fovState,"GuiDefaults",gui_defaults());
            assigned=string(cellfun(@(p)p.events.target_cell_id(1), ...
                manifest.trials.pulse_schedule));
            testCase.verifyTrue(any(assigned=="cell_001"));
            testCase.verifyTrue(has_code(manifest.advisories,"blue_mask_overlap"));
        end

        function trueOnePhotonFailuresRemainHard(testCase)
            [reference,targets,fovState]=blue_case(true,false);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);

            disabledReference=reference;
            disabledReference.cells(1).stimulation_enabled=false;
            disabledTargets=adaptive_optopatch.build_target_bundle(disabledReference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",4);
            disabledFov=fovState; disabledFov.cells(1).stimulation_enabled=false;
            [manifest,~]=adaptive_optopatch.build_manifest( ...
                disabledReference,disabledTargets,protocol,"Mode","1p_dmd", ...
                "FovState",disabledFov,"GuiDefaults",gui_defaults());
            testCase.verifyFalse(any(manifest.trials.target_cell_id=="cell_001"));

            unusable=targets; unusable.dmd_camera_masks(:,:,1)=false;
            unusableFov=fovState; unusableFov.cells(2).stimulation_enabled=false;
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,unusable,protocol,"Mode","1p_dmd", ...
                "FovState",unusableFov,"GuiDefaults",gui_defaults()), ...
                "adaptive_optopatch:NoAcceptedTargets");

            testCase.verifyError(@()adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",5.1), ...
                "adaptive_optopatch:InvalidCommandVoltage");
        end

        function twoPhotonExecutionQcRemainsStrict(testCase)
            [reference,targets,fovState]=blue_case(false,true);
            fovState.cells(2).stimulation_enabled=false;
            testCase.verifyFalse(targets.targets(1).spiral_qc_pass);
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,targets,adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1),"Mode","2p_spiral", ...
                "FovState",fovState,"GuiDefaults",gui_defaults()), ...
                "adaptive_optopatch:NoAcceptedTargets");
        end
    end
end

function [reference,targets,fovState]=blue_case(overlap,nearEdge)
image=zeros(40,50); masks=false(40,50,2);
if nearEdge, rows=1:6; else, rows=12:17; end
masks(rows,10:15,1)=true;
if overlap, columns=19:24; adjustment=4; else, columns=35:40; adjustment=0; end
masks(rows,columns,2)=true;
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","blue_advisory_test");
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",adjustment);
polygons=cell(numel(reference.cells),1);
for k=1:numel(reference.cells)
    boundaries=bwboundaries(reference.roi_masks(:,:,k));
    p=boundaries{1}; polygons{k}=[p(:,2) p(:,1)];
end
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
end

function value=gui_defaults()
value=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function tf=has_code(advisories,code)
tf=~isempty(advisories) && any(string({advisories.code})==string(code));
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
