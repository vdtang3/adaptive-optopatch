classdef TestBlueMaskAdjustment < matlab.unittest.TestCase
    methods (Test)
        function producesExactAdjustedMasksAndIsMonotonic(testCase)
            mask=canonical_roi_mask();
            areas=containers.Map('KeyType','double','ValueType','double');
            for adjustment=[-2 -1 0 1]
                adjusted=adaptive_optopatch.apply_blue_mask_adjustment(mask,adjustment);
                areas(adjustment)=nnz(adjusted);
                if adjustment==0
                    testCase.verifyEqual(adjusted,mask);
                elseif adjustment<0
                    expected=imerode(mask,strel("disk",abs(adjustment),0));
                    testCase.verifyEqual(adjusted,expected);
                else
                    expected=imdilate(mask,strel("disk",adjustment,0));
                    testCase.verifyEqual(adjusted,expected);
                end
            end
            testCase.verifyLessThan(areas(-2),areas(-1));
            testCase.verifyLessThan(areas(-1),areas(0));
            testCase.verifyLessThan(areas(0),areas(1));
        end

        function erosionThatEmptiesMaskRaisesExplicitErrorInsteadOfFallback(testCase)
            mask=canonical_roi_mask();
            testCase.verifyError( ...
                @()adaptive_optopatch.apply_blue_mask_adjustment(mask,-5), ...
                "adaptive_optopatch:EmptyBlueMaskAdjustment");
            % Confirm no fallback candidate is silently produced: the
            % erosion truly is empty, so the canonical mask cannot have
            % been returned instead.
            testCase.verifyFalse(any(imerode(mask,strel("disk",5,0)),"all"));
        end

        function sameTargetAcrossEventsProducesPhysicallyDistinctMasksInDmdPlan(testCase)
            [fovState,~]=test_fov_state();
            fovState=adaptive_optopatch.update_cell_calibration( ...
                fovState,"cell_001","CommandVoltageV",1);
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
            for k=2:numel(fovState.cells)
                fovState.cells(k).stimulation_enabled=false;
            end
            fovState.reference.cells=fovState.cells;
            definition=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                [-2 -1 0 1],"EventOrder","ordered","RandomSeed",5);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,test_gui_defaults(),"Mode","1p_dmd");
            resolved=resolved{1};

            testCase.verifyEqual(resolved.events.blue_mask_adjustment_pixels, ...
                [-2;-1;0;1]);
            testCase.verifyTrue(all(resolved.events.target_cell_id=="cell_001"));

            plan=adaptive_optopatch.build_dmd_sequence_plan(resolved,targets);
            canonicalMask=targets.canonical_roi_masks(:,:,1);
            for k=1:height(resolved.events)
                adjustment=resolved.events.blue_mask_adjustment_pixels(k);
                expected=adaptive_optopatch.apply_blue_mask_adjustment( ...
                    canonicalMask,adjustment);
                testCase.verifyEqual(plan.camera_pattern_stack(:,:,k),expected);
            end
            % Resolved event order must be preserved in the pattern stack.
            testCase.verifyEqual(plan.pulse_id,resolved.events.pulse_id);

            areaByAdjustment=arrayfun(@(k)nnz(plan.camera_pattern_stack(:,:,k)), ...
                (1:height(resolved.events))');
            [~,order]=sort(resolved.events.blue_mask_adjustment_pixels);
            testCase.verifyTrue(issorted(areaByAdjustment(order)));
        end

        function requestedErosionThatEmptiesMaskFailsResolutionInsteadOfSubstitutingCanonicalMask(testCase)
            [fovState,~]=test_fov_state();
            fovState=adaptive_optopatch.update_cell_calibration( ...
                fovState,"cell_001","CommandVoltageV",1);
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
            for k=2:numel(fovState.cells)
                fovState.cells(k).stimulation_enabled=false;
            end
            fovState.reference.cells=fovState.cells;
            definition=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                -5,"EventOrder","ordered","RandomSeed",5);
            % The resolved event's adjustment (-5), not the bundle/GUI
            % default (0), determines executability: resolution must fail
            % explicitly rather than silently excluding cell_001 or
            % deferring the failure to DMD-sequence construction.
            testCase.verifyError( ...
                @()adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,test_gui_defaults(),"Mode","1p_dmd"), ...
                "adaptive_optopatch:EmptyBlueMaskAdjustment");
        end
    end
end

function mask=canonical_roi_mask()
mask=false(30,30);
mask(11:20,11:20)=true;
end

function [fovState,polygons]=test_fov_state()
image=zeros(70,90); masks=false(70,90,3);
masks(15:24,15:24,1)=true;
masks(15:24,40:49,2)=true;
masks(40:49,65:74,3)=true;
polygons={ [15 15;24 15;24 24;15 24], ...
    [40 15;49 15;49 24;40 24], ...
    [65 40;74 40;74 49;65 49] };
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","test_fov","CellIds",["cell_001";"cell_002";"cell_003"], ...
    "RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons);
end

function defaults=test_gui_defaults()
defaults=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
