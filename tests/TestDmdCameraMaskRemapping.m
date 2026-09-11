classdef TestDmdCameraMaskRemapping < matlab.unittest.TestCase
    methods (Test)
        function fullFieldReferenceAcceptsRecordedCrop(testCase)
            camera=geometry([800 1100],[180 400],1);
            dmd=reference_dmd([0 0],[2304 2304],1,"DMD_Blue");
            mask=false(180,400); mask(24,138)=true;

            mapped=adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
                mask,camera,dmd,"DMD_Blue");

            testCase.verifySize(mapped,[2304 2304]);
            testCase.verifyTrue(mapped(1124,938));
            testCase.verifyEqual(nnz(mapped),1);
        end

        function separatedTargetsRemainSeparated(testCase)
            camera=geometry([800 1100],[180 400],1);
            dmd=reference_dmd([0 0],[2304 2304],1,"DMD_Blue");
            first=false(180,400); first(24,138)=true;
            second=false(180,400); second(104,297)=true;
            a=adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
                first,camera,dmd,"DMD_Blue");
            b=adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
                second,camera,dmd,"DMD_Blue");
            testCase.verifyTrue(a(1124,938));
            testCase.verifyTrue(b(1204,1097));
            testCase.verifyFalse(any(a&b,"all"));
        end

        function sameSizeShiftedCropUsesSensorOrigin(testCase)
            dmd=reference_dmd([100 200],[40 50],1,"DMD_Blue");
            camera=geometry([105 207],[20 30],1);
            mask=false(20,30); mask(2,3)=true;
            mapped=adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
                mask,camera,dmd,"DMD_Blue");
            testCase.verifyTrue(mapped(9,8));
        end

        function exactMatchIsUnchanged(testCase)
            camera=geometry([100 200],[20 30],1);
            dmd=reference_dmd([100 200],[20 30],1,"DMD_Blue");
            mask=false(20,30); mask(4:6,8:10)=true;
            mapped=adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
                mask,camera,dmd,"DMD_Blue");
            testCase.verifyEqual(mapped,mask);
        end

        function cropOutsideReferenceIsRejectedWithoutClipping(testCase)
            camera=geometry([25 10],[10 10],1);
            dmd=reference_dmd([0 0],[30 30],1,"DMD_Blue");
            mask=false(10,10); mask(1,1)=true;
            testCase.verifyError(@() ...
                adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
                mask,camera,dmd,"DMD_Blue"), ...
                "adaptive_optopatch:DmdReferenceDoesNotCoverCameraRoi");
        end

        function incompatibleBinningIsRejected(testCase)
            camera=geometry([0 0],[10 10],2);
            dmd=reference_dmd([0 0],[30 30],1,"DMD_Blue");
            testCase.verifyError(@() ...
                adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
                true(10),camera,dmd,"DMD_Blue"), ...
                "adaptive_optopatch:DmdReferenceBinningMismatch");
        end

        function roundRobinStackIsMappedWithoutReordering(testCase)
            camera=geometry([8 11],[10 10],1);
            dmd=reference_dmd([0 0],[30 40],1,"DMD_Blue");
            stack=false(10,10,2); stack(2,3,1)=true; stack(7,8,2)=true;
            plan=sequence_plan(stack,camera);
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            testCase.verifyEqual(configuration.dmd_pattern_index,[1;2]);
            testCase.verifyEqual(configuration.target_cell_id,["cell_a";"cell_b"]);
            testCase.verifyTrue(dmd.pattern_stack(13,11,1));
            testCase.verifyTrue(dmd.pattern_stack(18,16,2));
            testCase.verifyFalse(any(dmd.pattern_stack(:,:,1) & ...
                dmd.pattern_stack(:,:,2),"all"));
        end

        function orangeCombinedMaskUsesSameMapping(testCase)
            camera=geometry([8 11],[10 10],1);
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "CameraRoi",[8 10 11 10]);
            orange=app.getDevice("DMD","name","DMD_Orange");
            orange.refimage=reference_struct([0 0],[30 40],1);
            local=false(10); local(3,4)=true;
            targets=struct("orange_combined_mask",local, ...
                "orange_camera_masks",reshape(local,10,10,1), ...
                "reference_camera",camera, ...
                "targets",struct("cell_id","cell_001", ...
                "recording_enabled",true), ...
                "parameters",struct("orange_expansion_pixels",2));
            configuration=adaptive_optopatch.prepare_luminos_orange_mask( ...
                app,targets,"DryRun",false);
            testCase.verifyTrue(configuration.dmd_reference_mask(14,12));
            testCase.verifyEqual(nnz(configuration.dmd_reference_mask),1);
        end
    end
end

function value=geometry(origin,imageSize,bin)
value=struct("image_size",imageSize,"origin_xy",origin,"bin",bin, ...
    "roi",[origin(1) imageSize(2)*bin origin(2) imageSize(1)*bin]);
end

function dmd=reference_dmd(origin,imageSize,bin,name)
dmd=adaptive_optopatch.testing.SimulatedLuminosDevice("DMD",name);
dmd.refimage=reference_struct(origin,imageSize,bin);
end

function value=reference_struct(origin,imageSize,bin)
value=struct("img",zeros(imageSize,"uint16"),"bin",bin, ...
    "ref2d",struct("ImageSize",imageSize, ...
    "XWorldLimits",origin(1)+[0 imageSize(2)*bin], ...
    "YWorldLimits",origin(2)+[0 imageSize(1)*bin]));
end

function plan=sequence_plan(stack,camera)
plan=struct("schema_version","1.0.0","camera_pattern_stack",stack, ...
    "reference_camera",camera,"pattern_count",2,"pulse_id",[1;2], ...
    "stack_pattern_number",[1;2],"target_cell_id",["cell_a";"cell_b"], ...
    "dmd_pattern_index",[1;2],"pattern_activation_s",[0;0.1], ...
    "dmd_trigger_s",[0;0.1],"trigger_associated_pulse_id",[1;2], ...
    "trigger_target_cell_id",["cell_a";"cell_b"], ...
    "initialization_trigger_s",0,"advance_onset_s",0.1, ...
    "no_artificial_settle_interval",true);
end
