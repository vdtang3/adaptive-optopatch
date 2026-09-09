classdef TestBlueMaskEventExecutability < matlab.unittest.TestCase
%TESTBLUEMASKEVENTEXECUTABILITY 1P Blue executability follows the resolved
%per-event mask adjustment, not the bundle/GUI default, and ROI overlap is
%no longer a spatial QC/advisory concept.
    methods (Test)
        function defaultInvalidEventValidRemainsExecutable(testCase)
            % Case 1: bundle/GUI default erosion empties the canonical
            % ROI, but the resolved event explicitly requests adjustment
            % 0. Resolution must succeed, the target must not be silently
            % excluded, and the produced physical mask must be the
            % canonical mask.
            [fovState,~]=single_cell_fov_state();
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",-5);

            definition=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                0,"EventOrder","ordered","RandomSeed",7);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","1p_dmd");
            testCase.verifyNumElements(resolved,1);
            protocol=resolved{1};
            testCase.verifyEqual(protocol.events.target_cell_id(1),"cell_001");
            testCase.verifyEqual(protocol.events.blue_mask_adjustment_pixels(1),0);

            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            canonicalMask=targets.canonical_roi_masks(:,:,1);
            testCase.verifyEqual(plan.camera_pattern_stack(:,:,1),canonicalMask);
        end

        function defaultValidEventInvalidFailsExplicitly(testCase)
            % Case 2: bundle/GUI default is valid (0), but the resolved
            % event requests an erosion large enough to empty the mask.
            % Planning must fail explicitly, naming the requested mask
            % failure, rather than silently dropping the target/event or
            % reducing acquisition count.
            [fovState,~]=single_cell_fov_state();
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);

            definition=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                -5,"EventOrder","ordered","RandomSeed",7);
            testCase.verifyError( ...
                @()adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","1p_dmd"), ...
                "adaptive_optopatch:EmptyBlueMaskAdjustment");
            try
                adaptive_optopatch.resolve_protocol(definition,fovState, ...
                    targets,gui_defaults(),"Mode","1p_dmd");
                testCase.verifyFail("Expected resolution to raise an explicit error.");
            catch exception
                testCase.verifyEqual(string(exception.identifier), ...
                    "adaptive_optopatch:EmptyBlueMaskAdjustment");
                testCase.verifyTrue(contains(exception.message,"cell_001"));
                testCase.verifyTrue(contains(exception.message,"-5"));
            end

            % The same failure surfaces through the manifest-building path
            % used by the real acquisition pipeline, not just direct
            % resolver calls.
            testCase.verifyError( ...
                @()adaptive_optopatch.build_manifest(fovState.reference,targets, ...
                definition,"Mode","1p_dmd","FovState",fovState, ...
                "GuiDefaults",gui_defaults()), ...
                "adaptive_optopatch:EmptyBlueMaskAdjustment");
        end

        function multipleEventLevelMaskSizesAreAllExecutable(testCase)
            % Case 3: several valid event-level adjustments on one target
            % are all executable and correspond to the exact masks
            % build_dmd_sequence_plan will project.
            [fovState,~]=single_cell_fov_state();
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);

            adjustments=[-2 -1 0 1];
            definition=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                adjustments,"EventOrder","ordered","RandomSeed",7);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","1p_dmd");
            protocol=resolved{1};
            testCase.verifyEqual(sort(protocol.events.blue_mask_adjustment_pixels), ...
                adjustments');

            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            canonicalMask=targets.canonical_roi_masks(:,:,1);
            for k=1:height(protocol.events)
                expected=adaptive_optopatch.apply_blue_mask_adjustment( ...
                    canonicalMask,protocol.events.blue_mask_adjustment_pixels(k));
                testCase.verifyEqual(plan.camera_pattern_stack(:,:,k),expected);
            end

            manifest=adaptive_optopatch.build_manifest(fovState.reference,targets, ...
                definition,"Mode","1p_dmd","FovState",fovState, ...
                "GuiDefaults",gui_defaults());
            preflight=adaptive_optopatch.preflight_trial(targets,manifest.trials(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
        end

        function overlapDoesNotAffectExecutabilityOrAdvisories(testCase)
            % Case 4: overlapping ROI geometries that previously produced
            % a Blue overlap QC/advisory must not change executability,
            % target selection, acquisition count, or advisories.
            [reference,targets,fovState]=overlapping_two_cell_fov_state();
            overlapDefaults=gui_defaults();
            overlapDefaults.blue_mask_adjustment_pixels=4;

            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            manifest=adaptive_optopatch.build_manifest(reference,targets,definition, ...
                "Mode","1p_dmd","FovState",fovState,"GuiDefaults",overlapDefaults);

            % Confirm the resolved (executed) masks genuinely overlap, so
            % the assertions below test real overlapping stimulation, not
            % an incidental non-overlapping geometry.
            canonicalMask1=targets.canonical_roi_masks(:,:,1);
            canonicalMask2=targets.canonical_roi_masks(:,:,2);
            resolvedMask1=adaptive_optopatch.apply_blue_mask_adjustment(canonicalMask1,4);
            resolvedMask2=adaptive_optopatch.apply_blue_mask_adjustment(canonicalMask2,4);
            testCase.verifyGreaterThan(nnz(resolvedMask1 & resolvedMask2),0);

            testCase.verifyEqual(height(manifest.trials),2);
            testCase.verifyTrue(all(ismember(["cell_001","cell_002"], ...
                string(manifest.trials.target_cell_id))));
            codes=strings(0,1);
            if ~isempty(manifest.advisories)
                codes=string({manifest.advisories.code});
            end
            testCase.verifyFalse(any(codes=="blue_mask_overlap"));
            testCase.verifyFalse(isfield(targets.targets,"dmd_overlap_pixels"));
            testCase.verifyFalse(isfield(targets.targets,"blue_qc_pass"));
            testCase.verifyTrue(targets.targets(1).qc_pass);
            testCase.verifyTrue(targets.targets(2).qc_pass);

            for k=1:height(manifest.trials)
                preflight=adaptive_optopatch.preflight_trial(targets, ...
                    manifest.trials(k,:),"RequireConfirmedLiveProtocol",false);
                testCase.verifyTrue(preflight.passed);
            end
        end
    end
end

function [fovState,polygons]=single_cell_fov_state()
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","blue_event_executability_test","CellIds","cell_001", ...
    "RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1);
end

function [reference,targets,fovState]=overlapping_two_cell_fov_state()
image=zeros(40,50); masks=false(40,50,2);
rows=12:17;
masks(rows,10:15,1)=true;
masks(rows,19:24,2)=true; % overlaps the first mask's default Blue adjustment
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","blue_overlap_irrelevant_test");
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",4);
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
