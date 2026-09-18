classdef AoFixtures
    %AOFIXTURES Fixtures shared by more than one Adaptive Optopatch test suite.
    %   These were local functions inside TestAdaptiveOptopatch.m, the
    %   historical catch-all. When that file was split into focused owner
    %   suites the fixtures outlived it, because several of the new suites
    %   need the same three-cell FOV, the same GUI defaults and the same
    %   resolution step to say anything at all.
    %
    %   Only fixtures used by MORE THAN ONE suite belong here. A fixture one
    %   suite needs stays a local function in that suite, where it can be
    %   read beside the assertions it serves.

    methods (Static)
        function [fovState,polygons]=fovState()
            %FOVSTATE Three well-separated somata on a 70x90 reference.
            %   Cells are numbered cell_001..cell_003 and all three start
            %   recording- and stimulation-enabled with no calibration, so a
            %   suite can disable, calibrate or move exactly what it means to.
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

        function defaults=guiDefaults()
            %GUIDEFAULTS The planning-window values a protocol resolves against.
            defaults=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
                "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
                "spiral_radius_um",2,"spiral_density_points_per_volt",10);
        end

        function protocol=resolvedProtocol(definition,mode)
            %RESOLVEDPROTOCOL Resolve a definition against a single-target FOV.
            %   Every non-null event is forced to the requested source and only
            %   cell_001 stimulates, so the result is one acquisition whose
            %   target is unambiguous. Tests that care about target policy
            %   resolve against their own FOV instead.
            for acquisitionIndex=1:numel(definition.acquisitions)
                events=definition.acquisitions(acquisitionIndex).events;
                events.stimulation_source(~events.is_null)=mode;
                events.stimulation_source(events.is_null)="none";
                definition.acquisitions(acquisitionIndex).events=events;
            end
            [fovState,~]=AoFixtures.fovState();
            for k=2:numel(fovState.cells)
                fovState.cells(k).stimulation_enabled=false;
            end
            fovState.reference.cells=fovState.cells;
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
                AoFixtures.guiDefaults(),"Mode",mode);
            protocol=resolved{1};
        end

        function roi=unifiedCameraRoi()
            %UNIFIEDCAMERAROI Sensor ROI matching unifiedInfo's 80x100 grid.
            %   [left width top height], so the simulated Camera 1 acquires on
            %   the grid the frozen targets are expressed in.
            roi=[974 100 984 80];
        end

        function info=unifiedInfo(root)
            %UNIFIEDINFO Reference metadata for an 80x100 planning grid.
            camera=struct("name","Orca Fusion","ROI",[0 0 100 80],"bin",1, ...
                "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
            metadata=struct("rig_name","Virtual_Upright","voltage_camera",camera);
            info=struct("snapshot_name","unified_test", ...
                "snapshot_directory",string(root), ...
                "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
                "metadata",metadata);
        end

        function geometry=frameCameraGeometry(imageSize)
            %FRAMECAMERAGEOMETRY Frozen camera geometry at the sensor origin.
            imageSize=double(imageSize(1:2));
            geometry=struct("schema_version","1.0.0","name","Orca Fusion", ...
                "image_size",imageSize,"origin_xy",[0 0],"bin",1, ...
                "roi",[0 imageSize(2) 0 imageSize(1)], ...
                "x_world_limits",[0 imageSize(2)],"y_world_limits",[0 imageSize(1)]);
        end

        function artifact=galvoCalibration(profile,calibrationId,tform)
            %GALVOCALIBRATION A complete simulated galvo calibration artifact.
            [x,y]=meshgrid([-5 0 5],[-5 0 5]);
            volts=[x(:) y(:)];
            [pixelX,pixelY]=transformPointsForward(tform,volts(:,1),volts(:,2));
            calibration=struct("schema_version","SIMULATED", ...
                "passed",true,"transform_direction","galvo_volts_to_camera_pixels", ...
                "tform",tform,"galvo_volts",volts, ...
                "camera_pixels",[pixelX pixelY],"rmse_pixels",0, ...
                "held_out_rmse_pixels",0,"simulation",true);
            artifact=struct("schema_version","SIMULATED", ...
                "calibration_id",calibrationId, ...
                "created_at",string(datetime("now","TimeZone","local")), ...
                "rig_name","Virtual_Upright","camera_serial","001125", ...
                "camera_name","Orca Fusion","scanner_name",profile.scanner.name, ...
                "scanner_x_port",profile.scanner.x_port, ...
                "scanner_y_port",profile.scanner.y_port, ...
                "pockels_port",profile.modulator.port, ...
                "source_experiment_directory","SIMULATION", ...
                "simulation",true,"calibration",calibration);
        end

        function [trials,targets,sim]=twoPhotonTrials(trialCount,outputRoot)
            %TWOPHOTONTRIALS A simulated session and N identical 2P trials.
            sim=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",outputRoot);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"PulseDurationMs",5, ...
                "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1);
            protocol=AoFixtures.resolvedProtocol(definition,"2p_spiral");
            target=struct("cell_id","cell_001","qc_pass",true, ...
                "spiral_center_xy",[1024 1024], ...
                "spiral_radius_pixels",10,"spiral_density_points_per_volt",20, ...
                "parking_point_xy",[1080 1024], ...
                "spiral_preview_center_xy",[1024 1024], ...
                "parking_preview_point_xy",[1080 1024]);
            targets=struct("schema_version","2.0.0", ...
                "coordinate_space","voltage_camera_full_sensor_pixels", ...
                "reference_camera",AoFixtures.frameCameraGeometry([2048 2048]), ...
                "targets",target);
            trialId=(1:trialCount)';
            stimulationMode=repmat("2p_spiral",trialCount,1);
            targetCellId=repmat("cell_001",trialCount,1);
            isNull=false(trialCount,1);
            targetIndex=ones(trialCount,1);
            pulseSchedule=repmat({protocol},trialCount,1);
            acquisitionDuration=repmat(protocol.acquisition_duration_s,trialCount,1);
            outputTag="sim_2p_"+string(1:trialCount)';
            acquisitionStatus=repmat("planned",trialCount,1);
            experimentDirectory=repmat("",trialCount,1);
            trials=table(trialId,stimulationMode,targetCellId,isNull,targetIndex, ...
                pulseSchedule,acquisitionDuration,outputTag,acquisitionStatus, ...
                experimentDirectory,'VariableNames',{'trial_id','stimulation_mode', ...
                'target_cell_id','is_null','target_index','pulse_schedule', ...
                'acquisition_duration_s','output_tag','acquisition_status', ...
                'experiment_directory'});
        end

        function wfm=emptyWaveformConfig()
            %EMPTYWAVEFORMCONFIG An ambient Luminos configuration with no records.
            wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
                "ao_camera_triggered",[],"do_camera_triggered",[]);
        end

        function record=constantOutput(name,port,value)
            %CONSTANTOUTPUT One ambient constant record, as Waveforms writes it.
            record=struct("name",char(name),"port",char(port), ...
                "wavefile","awfm_constant","params",{{value}}, ...
                "operation","Multiplication","concatTime",[]);
        end

        function controller=previewController(testCase)
            %PREVIEWCONTROLLER A loaded session with two bright somata on it.
            %   A real snapshot on disk, loaded through loadSnapshotChoice, so
            %   the reference carries a camera identity, a crop origin and a
            %   DMD transform the way a planning session's does. Two somata,
            %   because a single one cannot show that a per-cell value went to
            %   the right cell.
            %
            %   Shared by TestBlueVoltageCalibration and
            %   TestAdaptiveOptopatchPreviews: the per-cell calibration and
            %   the previews are different behaviours asked of the same
            %   session, and building it twice would let them drift.
            rows=128; columns=160;
            [x,y]=meshgrid(1:columns,1:rows);
            image=120+8*randn(RandStream("mt19937ar","Seed",20260916), ...
                rows,columns);
            centres=[38 40; 104 56]; radii=[9 8];
            polygons=cell(2,1);
            for k=1:2
                centre=centres(k,:); radius=radii(k);
                image=image+900*exp(-((x-centre(1)).^2+(y-centre(2)).^2) ...
                    /(2*(radius/2)^2));
                angles=(0:7)'*pi/4;
                polygons{k}=[centre(1)+(radius+2)*cos(angles), ...
                    centre(2)+(radius+2)*sin(angles)];
            end

            folder=string(tempname); mkdir(folder);
            testCase.addTeardown(@()AoFixtures.removeFolder(folder));
            snap=struct; %#ok<NASGU>
            snap.img=uint16(image);
            snap.name="Orca Fusion";
            snap.bin=1;
            snap.ref2d=imref2d([rows columns],[0 columns],[0 rows]);
            snap.timestamp=datetime("now");
            snap.tform=struct("name","DMD_Blue","tform",affine2d());
            save(fullfile(folder,"120000preview_cam-OrcaFusion.mat"),"snap");

            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp( ...
                    "CameraRoi",[974 columns 984 rows]));
            testCase.addTeardown(@()delete(controller));
            controller.SnapshotRoot=folder;
            controller.loadSnapshotChoice("120000preview_cam-OrcaFusion");
            controller.setSomaPolygons(polygons);
        end

        function response=act(controller,action,payload)
            %ACT One frontend request, at the controller's current revision.
            arguments
                controller
                action (1,1) string
                payload = struct()
            end
            response=adaptive_optopatch.apply_controller_action( ...
                controller,action,payload,controller.Revision);
        end

        function removeFolder(folder)
            %REMOVEFOLDER Delete a temporary folder if it is still there.
            if isfolder(folder), rmdir(folder,"s"); end
        end
    end
end
