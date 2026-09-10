classdef TestSimulationWorkflow < matlab.unittest.TestCase
    methods (Test)
        function convenienceFactoryReturnsCanonicalBackend(testCase)
            luminosApp=simulatedLuminosApp();
            testCase.verifyClass(luminosApp, ...
                "adaptive_optopatch.testing.SimulatedLuminosApp");
            testCase.verifyTrue(luminosApp.IsSimulation);
        end

        function multipleGeometryIssuesKeepDomainError(testCase)
            camera=adaptive_optopatch.testing.SimulatedLuminosDevice( ...
                "Camera","Orca Fusion");
            camera.ROI=[0 2048 0 2048];
            camera.bin=1;
            targets=struct("reference_camera",struct( ...
                "image_size",[180 500],"origin_xy",[800 1012],"bin",1));

            exception=capture_exception( ...
                @()adaptive_optopatch.validate_camera_geometry(camera,targets));
            testCase.verifyEqual(string(exception.identifier), ...
                "adaptive_optopatch:CameraGeometryChangedSinceFreeze");
            testCase.verifySubstring(exception.message, ...
                "Live frames are 2048x2048");
            testCase.verifySubstring(exception.message, ...
                "live sensor ROI starts at [0 0]");
        end

        function loadingSnapshotMatchesSimulatedCamera(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_folder(root)); %#ok<NASGU>
            snapshotPath=write_snapshot(root,[31 48 180 500],2);
            luminosApp=simulatedLuminosApp();
            app=launch_adaptive_optopatch_gui(luminosApp,"Visible","off", ...
                "RunRoot",root);
            closeApp=onCleanup(@()delete(app)); %#ok<NASGU>

            app.loadSnapshot(snapshotPath);
            camera=luminosApp.getDevice("Camera");
            testCase.verifyEqual(camera.ROI,[31 48 180 500]);
            testCase.verifyEqual(camera.bin,2);
        end

        function loadingFovMatchesAndLaterMismatchStillFails(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_folder(root)); %#ok<NASGU>
            [fovState,targets]=reference_fixture([21 66 37 56],2);
            fovPath=fullfile(root,"saved_fov.mat");
            adaptive_optopatch.save_fov_state(fovPath,fovState);
            luminosApp=simulatedLuminosApp();
            app=launch_adaptive_optopatch_gui(luminosApp,"Visible","off", ...
                "RunRoot",root);
            closeApp=onCleanup(@()delete(app)); %#ok<NASGU>

            app.loadFov(fovPath);
            camera=luminosApp.getDevice("Camera");
            testCase.verifyEqual(camera.ROI,[21 66 37 56]);
            testCase.verifyEqual(camera.bin,2);
            testCase.verifyTrue( ...
                adaptive_optopatch.validate_camera_geometry(camera,targets).passed);

            camera.ROI=[22 66 37 56];
            testCase.verifyError( ...
                @()adaptive_optopatch.validate_camera_geometry(camera,targets), ...
                "adaptive_optopatch:CameraGeometryChangedSinceFreeze");
        end
    end
end

function path=write_snapshot(root,roi,bin)
snap=struct; %#ok<NASGU>
snap.img=zeros(roi(4),roi(2),"uint16");
snap.name="Orca Fusion";
snap.bin=bin;
snap.ref2d=imref2d(size(snap.img), ...
    [roi(1) roi(1)+roi(2)],[roi(3) roi(3)+roi(4)]);
snap.timestamp=datetime("now");
snap.tform=struct("name","DMD_Blue","tform",affine2d());
path=fullfile(root,"reference_snap.mat");
save(path,"snap");
end

function [fovState,targets]=reference_fixture(roi,bin)
image=zeros(roi(4),roi(2));
mask=false(size(image)); mask(10:15,10:15)=true;
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","ROI",roi,"bin",bin, ...
    "x_world_limits",[roi(1) roi(1)+roi(2)], ...
    "y_world_limits",[roi(3) roi(3)+roi(4)]), ...
    "stimulation_dmd",struct("name","DMD_Blue","tform",affine2d()));
reference=adaptive_optopatch.create_reference_model(image,mask,metadata, ...
    "CellIds","cell_001","RoiPolygons",{[10 10;15 10;15 15;10 15]});
fovState=adaptive_optopatch.create_fov_state(reference, ...
    {[10 10;15 10;15 15;10 15]});
targets=adaptive_optopatch.build_target_bundle(reference);
end

function remove_folder(path)
if isfolder(path), rmdir(path,"s"); end
end

function exception=capture_exception(operation)
exception=[];
try
    operation();
catch exception
end
if isempty(exception)
    error("adaptive_optopatch:ExpectedTestException", ...
        "The operation did not throw the expected exception.");
end
end
