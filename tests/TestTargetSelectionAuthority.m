classdef TestTargetSelectionAuthority < matlab.unittest.TestCase
%TESTTARGETSELECTIONAUTHORITY Stim selection is authoritative for target
%participation in both 1P and 2P resolution. Advisory QC (spiral_qc_pass,
%edge_flag, parking QC) must never silently reduce acquisition count; a
%requested target either participates or fails explicitly.
    methods (Test)
        function allStimEnabledTargetsSurvive2pResolutionDespiteAdvisoryQc(testCase)
            % Case 1: several Stim-enabled targets, one of which fails
            % advisory spiral_qc_pass (edge proximity). Every
            % Stim-enabled target must still be represented in the
            % resolved experiment and acquisition count must not shrink.
            [~,targets,fov]=three_cell_fixture();
            testCase.verifyFalse(targets.targets(1).spiral_qc_pass);
            testCase.verifyTrue(targets.targets(2).spiral_qc_pass);
            testCase.verifyTrue(targets.targets(3).spiral_qc_pass);

            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets, ...
                gui_defaults(),"Mode","2p_spiral");
            testCase.verifyNumElements(resolved,3);
            cellIds=cellfun(@(r)r.events.target_cell_id(1),resolved);
            testCase.verifyEqual(sort(cellIds),["cell_001";"cell_002";"cell_003"]);
        end

        function advisoryQcDoesNotBlock2pResolutionOrPreflight(testCase)
            % Case 2: edge/parking advisory state alone must not cause a
            % target to disappear or produce an unjustified hard
            % failure at either resolution or preflight.
            [reference,targets,fov]=three_cell_fixture();
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            manifest=adaptive_optopatch.build_manifest(reference,targets, ...
                definition,"Mode","2p_spiral","FovState",fov, ...
                "GuiDefaults",gui_defaults());
            testCase.verifyEqual(height(manifest.trials),3);
            testCase.verifyTrue(any(manifest.trials.target_cell_id=="cell_001"));

            failingTrial=manifest.trials(manifest.trials.target_cell_id=="cell_001",:);
            preflight=adaptive_optopatch.preflight_trial(targets,failingTrial(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
        end

        function missingTargetMappingFailsExplicitly(testCase)
            % Case 3: a Stim-enabled FOV cell whose matching target entry
            % is absent must raise a clear explicit error naming that
            % cell rather than being silently skipped.
            [~,targets,fov]=three_cell_fixture();
            targets.targets(2)=[];

            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            testCase.verifyError(@()adaptive_optopatch.resolve_protocol( ...
                definition,fov,targets,gui_defaults(),"Mode","2p_spiral"), ...
                "adaptive_optopatch:MissingTargetGeometry");
            try
                adaptive_optopatch.resolve_protocol(definition,fov,targets, ...
                    gui_defaults(),"Mode","2p_spiral");
                testCase.verifyFail("Expected resolution to raise an explicit error.");
            catch exception
                testCase.verifyEqual(string(exception.identifier), ...
                    "adaptive_optopatch:MissingTargetGeometry");
                testCase.verifyTrue(contains(exception.message,"cell_002"));
            end
        end

        function onePhotonBehaviorRemainsCorrect(testCase)
            % Case 4: Stim-enabled 1P targets are retained regardless of
            % advisory geometry state, and an impossible resolved Blue
            % mask still fails through the existing explicit
            % resolved-mask validation rather than silent exclusion.
            [reference,targets,fov]=three_cell_fixture();
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets, ...
                gui_defaults(),"Mode","1p_dmd");
            testCase.verifyNumElements(resolved,3);
            cellIds=cellfun(@(r)r.events.target_cell_id(1),resolved);
            testCase.verifyEqual(sort(cellIds),["cell_001";"cell_002";"cell_003"]);

            emptyingDefaults=gui_defaults();
            emptyingDefaults.blue_mask_adjustment_pixels=-5;
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,targets,definition,"Mode","1p_dmd", ...
                "FovState",fov,"GuiDefaults",emptyingDefaults), ...
                "adaptive_optopatch:EmptyBlueMaskAdjustment");
        end
    end
end

function [reference,targets,fovState]=three_cell_fixture()
% cell_001 sits near the image edge, producing edge_flag=true and
% spiral_qc_pass=false purely due to advisory edge-proximity QC.
% cell_002 and cell_003 are interior cells with passing advisory QC.
image=zeros(40,60); masks=false(40,60,3);
masks(1:6,5:10,1)=true;      % near top edge
masks(15:20,25:30,2)=true;   % interior
masks(15:20,45:50,3)=true;   % interior
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","target_selection_authority_test");
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
polygons=cell(numel(reference.cells),1);
for k=1:numel(reference.cells)
    boundaries=bwboundaries(reference.roi_masks(:,:,k));
    p=boundaries{1}; polygons{k}=[p(:,2) p(:,1)];
end
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
end

function defaults=gui_defaults()
defaults=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
