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
            [fovState,~]=AoFixtures.fovState();
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
                targets,AoFixtures.guiDefaults(),"Mode","1p_dmd");
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
                slot=plan.event_slot_indices(k);
                testCase.verifyEqual(plan.unique_camera_masks(:,:,slot),expected);
            end
            % Resolved event order must be preserved in the playlist.
            testCase.verifyEqual(plan.pulse_id,resolved.events.pulse_id);

            areaByAdjustment=arrayfun(@(k)nnz(plan.unique_camera_masks( ...
                :, :, plan.event_slot_indices(k))), ...
                (1:height(resolved.events))');
            [~,order]=sort(resolved.events.blue_mask_adjustment_pixels);
            testCase.verifyTrue(issorted(areaByAdjustment(order)));
        end

        function requestedErosionThatEmptiesMaskFailsResolutionInsteadOfSubstitutingCanonicalMask(testCase)
            [fovState,~]=AoFixtures.fovState();
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
                targets,AoFixtures.guiDefaults(),"Mode","1p_dmd"), ...
                "adaptive_optopatch:EmptyBlueMaskAdjustment");
        end

        % ---------------------------------------------------------------
        % The adjustment a target bundle carries
        % ---------------------------------------------------------------
        function signedBlueAdjustmentDilatesMask(testCase)
            img=zeros(30); masks=false(30,30,1); masks(14:16,14:16,1)=true;
            metadata=struct("rig_name","Virtual_Upright", ...
                "voltage_camera",struct("serial","001125"));
            ref=adaptive_optopatch.create_reference_model(img,masks,metadata);
            contracted=adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",1,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",-1);
            expanded=adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",1,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",2);
            testCase.verifyGreaterThan(nnz(expanded.dmd_camera_masks), ...
                nnz(contracted.dmd_camera_masks));
            testCase.verifyTrue(all(expanded.dmd_camera_masks(masks)));
        end
    end
end

function mask=canonical_roi_mask()
mask=false(30,30);
mask(11:20,11:20)=true;
end


