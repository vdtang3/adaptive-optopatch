classdef TestReferenceSnapshotIngest < matlab.unittest.TestCase
    %TESTREFERENCESNAPSHOTINGEST From a camera snapshot to a target bundle.
    %   Reading a Luminos snapshot (current and legacy layouts), turning it
    %   into a reference model with cell identities and camera-space
    %   centroids, building the target bundle a plan is resolved against, and
    %   refusing a bundle written before the coordinate fix.
    %
    %   TestAdaptiveOptopatchReferenceChooser owns which snapshot a session is
    %   ALLOWED to load and how it is chosen; this suite owns what is read out
    %   of the file once that choice has been made.

    methods (Test)
        function readsLuminosCameraSnapshot(testCase)
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            expected=uint16([1 2 3;4 5 6]);
            snap=struct; %#ok<NASGU>
            snap.img=expected;
            snap.name="Orca Fusion";
            snap.bin=1;
            snap.ref2d=imref2d(size(expected),[10 13],[20 22]);
            snap.timestamp=datetime("now");
            snap.tform=struct("name","DMD_Blue","tform",affine2d());
            snapshotPath=fullfile(folder,"120000pilot.mat");
            save(snapshotPath,"snap");
            [image,info]=adaptive_optopatch.read_reference_snapshot(snapshotPath);
            testCase.verifyEqual(image,single(expected));
            testCase.verifyEqual(info.image_size,[2 3]);
            testCase.verifyEqual(info.metadata.voltage_camera.ROI,[10 3 20 2]);
            testCase.verifyEqual(info.metadata.stimulation_dmd.name,"DMD_Blue");
            testCase.verifyEqual(info.snapshot_directory,string(folder));
        end

        function readsLegacyLuminosCameraSnapshot(testCase)
            folder=tempname; mkdir(folder); cleanup=onCleanup(@()rmdir(folder,"s")); %#ok<NASGU>
            expected=uint16([1 2 3;4 5 6]);
            snap=struct; %#ok<NASGU>
            snap.img=expected;
            snap.name="orca fusion";
            snap.ref2d=imref2d(size(expected),[10 16],[20 24]);
            snap.tform=affine2d([1 0 0;0 1 0;2 3 1]);
            snapshotPath=fullfile(folder,"legacy_snapshot.mat");
            save(snapshotPath,"snap");

            [image,info]=adaptive_optopatch.read_reference_snapshot(snapshotPath);

            testCase.verifyEqual(image,single(expected));
            testCase.verifyEqual(info.camera_bin,2,"AbsTol",1e-12);
            testCase.verifyClass(info.timestamp,"datetime");
            testCase.verifyEqual(info.metadata.stimulation_dmd.name,"DMD_Blue");
            testCase.verifyEqual( ...
                info.metadata.stimulation_dmd.tform.T,snap.tform.T);
        end

        function mapsSnapshotRoisIntoFullCameraCoordinates(testCase)
            image=zeros(20,30,"single");
            masks=false(20,30,1); masks(7:9,9:11,1)=true;
            camera=struct("name","Orca Fusion","x_world_limits",[600 630], ...
                "y_world_limits",[756 776]);
            scanner=struct("tform",affinetform2d( ...
                [100 0 600;0 100 756;0 0 1]),"sample_rate",200000);
            metadata=struct("rig_name","Virtual_Upright", ...
                "voltage_camera",camera,"scanner",scanner);
            reference=adaptive_optopatch.create_reference_model( ...
                image,masks,metadata,"MicronsPerPixel",1);
            testCase.verifyEqual(reference.cells.image_centroid_xy,[10 8], ...
                "AbsTol",1e-12);
            testCase.verifyEqual(reference.cells.camera_centroid_xy, ...
                [609.5 763.5],"AbsTol",1e-12);
            targets=adaptive_optopatch.build_target_bundle(reference, ...
                "SpiralRadiusUm",2,"PulseDurationMs",5);
            testCase.verifyEqual(targets.targets.spiral_preview_center_xy, ...
                [10 8],"AbsTol",1e-12);
            testCase.verifyEqual(targets.targets.spiral_center_xy, ...
                [609.5 763.5],"AbsTol",1e-12);
            testCase.verifyTrue(targets.targets.spiral_cycle_metrics.calibrated);
            validation=adaptive_optopatch.validate_2p_planning_bundle(targets);
            testCase.verifyTrue(validation.passed);
        end

        function rejectsPreCoordinateFixTwoPhotonBundle(testCase)
            oldTargets=struct("schema_version","0.1.0", ...
                "coordinate_space","voltage_camera_acquired_roi", ...
                "targets",struct("spiral_center_xy",[20 30], ...
                "spiral_radius_pixels",10,"parking_point_xy",[40 30]));
            validation=adaptive_optopatch.validate_2p_planning_bundle(oldTargets);
            testCase.verifyFalse(validation.passed);
            testCase.verifyTrue(any(contains(validation.issues,"schema 2.0.0")));
        end

        function buildsReferenceTargetsAndManifest(testCase)
            img = zeros(30,40);
            img(8:12,8:12) = 10;
            img(18:23,25:30) = 20;
            masks = false(30,40,2);
            masks(8:12,8:12,1) = true;
            masks(18:23,25:30,2) = true;
            metadata = struct("rig_name","Virtual_Upright", ...
                "voltage_camera",struct("serial","001125"));

            ref = adaptive_optopatch.create_reference_model(img,masks,metadata, ...
                "FovId","test","MicronsPerPixel",0.5);
            targets = adaptive_optopatch.build_target_bundle(ref, ...
                "SpiralRadiusUm",5,"SpiralDensityPointsPerVolt",12, ...
                "BlueMaskAdjustmentPixels",-1);
            fov=adaptive_optopatch.create_fov_state(ref,{}, ...
                "SpiralDensityPointsPerVolt",12);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",200,"ModulatorVoltage",1,"RandomSeed",4, ...
                "StimulationSource","2p_spiral");
            base=definition.acquisitions;
            definition.acquisitions=repmat(base,1,3);
            for k=1:3
                definition.acquisitions(k).acquisition_id="repeat_"+k;
            end
            manifest=adaptive_optopatch.build_manifest(ref,targets,definition, ...
                "Mode","2p_spiral","FovState",fov, ...
                "GuiDefaults",AoFixtures.guiDefaults());

            testCase.verifyEqual(numel(ref.cells),2);
            testCase.verifySize(targets.dmd_camera_masks,[30 40 2]);
            testCase.verifyEqual(targets.targets(1).spiral_density_points_per_volt,12);
            testCase.verifyEqual(cellfun(@(p)p.spiral_density_points_per_volt, ...
                manifest.trials.acquisition_parameters),10*ones(6,1));
            testCase.verifyEqual(height(manifest.trials),6);
            testCase.verifyTrue(manifest.one_acquisition_per_row);
            testCase.verifyEqual( ...
                height(manifest.trials.pulse_schedule{1}.events),200);
            testCase.verifyGreaterThan(manifest.trials.acquisition_duration_s(1),10);
        end

        function findsOutputDataAndLatestPlanningSession(testCase)
            root=tempname; mkdir(root); cleanup=onCleanup(@()rmdir(root,"s")); %#ok<NASGU>
            experimentFolder=fullfile(root,"experiment"); mkdir(experimentFolder);
            Device_Data={struct("rigName","Virtual_Upright")}; %#ok<NASGU>
            save(fullfile(experimentFolder,"output_data.mat"),"Device_Data");
            located=adaptive_optopatch.find_luminos_experiment(root);
            testCase.verifyEqual(located.experiment_directory,string(experimentFolder));

            planFolder=fullfile(root,"adaptive_optopatch_test_20260716_120000");
            mkdir(planFolder);
            reference=struct("source_experiment",string(experimentFolder)); %#ok<NASGU>
            planning_session=struct("image_size",[10 12], ... %#ok<NASGU>
                "roi_positions",{{[1 1;2 1;2 2]}}, ...
                "parameters",struct("pulse_count",200));
            save(fullfile(planFolder,"reference_model.mat"),"reference");
            save(fullfile(planFolder,"planning_session.mat"),"planning_session");
            bundle=adaptive_optopatch.find_latest_planning_bundle(root, ...
                "ExperimentDirectory",experimentFolder);
            testCase.verifyEqual(bundle.folder,string(planFolder));
            testCase.verifyTrue(isfile(bundle.session_path));
        end

        function savesBundleInGeneratedSubfolder(testCase)
            parent=tempname; mkdir(parent); cleanup=onCleanup(@()rmdir(parent,"s")); %#ok<NASGU>
            reference=struct("fov_id","pilot fov");
            targets=struct("schema_version","test");
            manifest=struct("schema_version","test");
            session=struct("roi_positions",{{[1 1;2 1;2 2]}});
            paths=adaptive_optopatch.save_bundle(parent,reference,targets,manifest, ...
                "CreateSubfolder",true,"SessionState",session);
            testCase.verifyTrue(isfolder(paths.output_directory));
            testCase.verifyTrue(startsWith(string(paths.output_directory), ...
                fullfile(string(parent),"adaptive_optopatch_pilotFov_")));
            testCase.verifyTrue(isfile(paths.reference));
            testCase.verifyTrue(isfile(paths.targets));
            testCase.verifyTrue(isfile(paths.manifest));
            testCase.verifyTrue(isfile(paths.session));
        end
    end
end
