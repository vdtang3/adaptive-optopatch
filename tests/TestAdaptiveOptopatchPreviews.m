classdef TestAdaptiveOptopatchPreviews < matlab.unittest.TestCase
    %TESTADAPTIVEOPTOPATCHPREVIEWS Showing the experiment without running it.
    %   Two questions, and this suite holds both because answering one
    %   without the other is how a preview lies.
    %
    %     Is the endpoint safe?      spatialPreview and waveformPreview must
    %                                change nothing, bump no revision, reach
    %                                no hardware, carry the revision they
    %                                describe, and survive JSON encoding.
    %                                They are read by a browser, repeatedly.
    %
    %     Is it the truth?           what is drawn must be what would
    %                                execute: the resolved per-event Blue
    %                                masks rather than the bundle default,
    %                                the resolved Orange expansion, and the
    %                                resolved spiral geometry - each compared
    %                                against the canonical helper execution
    %                                itself goes through.
    %
    %   The second group came from TestPreviewMatchesExecution and is not
    %   redundant with the first: an endpoint can be perfectly inert and
    %   perfectly wrong. It sits one layer below, on build_target_preview,
    %   because that is where preview and execution have to agree.
    %
    %   No hardware is touched anywhere here: the session is the packaged
    %   simulator, and every call under test is one that must be inert even
    %   against a real rig.

    methods (Test)
        % ---------------------------------------------------------------
        % A. The spatial preview endpoint
        % ---------------------------------------------------------------
        function theSpatialPreviewIsReadOnlyAndBumpsNoRevision(testCase)
            controller=testCase.loadedController();
            before=controller.getState();

            controller.spatialPreview("1p_dmd");
            controller.spatialPreview("2p_spiral");
            controller.spatialPreview("1p_dmd");

            testCase.verifyTrue(isequaln(controller.getState(),before), ...
                "Asking what would be illuminated must change nothing.");
            testCase.verifyEqual(controller.Revision,before.revision);
        end

        function eachModalityReportsItsOwnLayers(testCase)
            controller=testCase.loadedController();

            onePhoton=controller.spatialPreview("1p_dmd");
            twoPhoton=controller.spatialPreview("2p_spiral");

            testCase.verifyTrue(onePhoton.available);
            testCase.verifyNumElements(onePhoton.blue,2);
            testCase.verifyNumElements(onePhoton.orange,2);
            testCase.verifyEmpty(onePhoton.spiral);

            testCase.verifyTrue(twoPhoton.available);
            testCase.verifyEmpty(twoPhoton.blue, ...
                "There are no Blue DMD masks in a 2P acquisition.");
            testCase.verifyNumElements(twoPhoton.spiral,2);
        end

        function outlinesAreBoundariesOfTheCanonicalMasks(testCase)
            % The preview must draw the mask apply_blue_mask_adjustment
            % produced, in the coordinates the somata are in - not a
            % polygon a frontend could have derived itself.
            controller=testCase.loadedController();
            controller.setPlanParameter("blue_mask_adjustment_pixels",-2);

            preview=controller.spatialPreview("1p_dmd");
            blue=preview.blue(1);

            testCase.verifyEqual(preview.coordinate_space, ...
                "snapshot_intrinsic_pixels");
            testCase.verifyEqual(blue.adjustment_pixels,-2);
            testCase.verifyNotEmpty(blue.rings);
            ring=blue.rings{1};
            testCase.verifyEqual(size(ring,2),2,"A ring is a list of [x y].");
            % Inside the image, and inside the soma it was eroded from.
            [rows,columns]=size(controller.ReferenceImage,1,2);
            testCase.verifyGreaterThanOrEqual(min(ring(:,1)),1);
            testCase.verifyGreaterThanOrEqual(min(ring(:,2)),1);
            testCase.verifyLessThanOrEqual(max(ring(:,1)),columns);
            testCase.verifyLessThanOrEqual(max(ring(:,2)),rows);
            testCase.verifyLessThan(blue.pixel_count, ...
                preview.orange(1).pixel_count, ...
                "An eroded Blue mask is smaller than an expanded Orange one.");
        end

        function theBlueMaskFollowsTheAdjustment(testCase)
            controller=testCase.loadedController();

            controller.setPlanParameter("blue_mask_adjustment_pixels",-1);
            shrunk=controller.spatialPreview("1p_dmd").blue(1).pixel_count;
            controller.setPlanParameter("blue_mask_adjustment_pixels",2);
            grown=controller.spatialPreview("1p_dmd").blue(1).pixel_count;

            testCase.verifyGreaterThan(grown,shrunk, ...
                "Positive expands and negative shrinks, as the canonical " + ...
                "adjustment does.");
        end

        function spiralGeometryComesFromTheCanonicalGenerator(testCase)
            controller=testCase.loadedController();
            controller.setPlanParameter("spiral_radius_um",8);

            preview=controller.spatialPreview("2p_spiral");
            spiral=preview.spiral(1);

            perPixel=controller.PlanParameters.microns_per_pixel;
            testCase.verifyEqual(spiral.radius_pixels,8/perPixel,"RelTol",1e-9);
            testCase.verifyGreaterThan(size(spiral.path_xy,1),10);
            testCase.verifyEqual(size(spiral.path_xy,2),2);
            testCase.verifyNumElements(spiral.parking_xy,2);
            testCase.verifyTrue(all(isfinite(spiral.parking_xy)));
            % The drawn path stays inside the circle it is drawn in.
            radii=vecnorm(spiral.path_xy-spiral.center_xy,2,2);
            testCase.verifyLessThanOrEqual(max(radii), ...
                spiral.radius_pixels*1.01);
        end

        function theSpatialPreviewDescribesTheFovWhateverProtocolIsLoaded(testCase)
            %   THIS USED TO ASSERT THE OPPOSITE, and the opposite was the
            %   defect. The preview reported "bundle_default" with no
            %   protocol and "resolved_plan" with one, and the difference
            %   between those two was not a label: it was which CELLS had
            %   any geometry at all. The resolved branch drew only the cells
            %   the acquisitions addressed, and resolve_protocol selects
            %   them with `if ~stimulation_enabled, continue` - so loading a
            %   protocol, or unticking Stim, erased a soma's Blue mask from
            %   the picture the operator aims with.
            %
            %   The preview answers "what geometry exists for this field of
            %   view". What would execute is the waveform preview's question
            %   and the plan summary's, and both say so.
            controller=testCase.loadedController();
            before=controller.spatialPreview("1p_dmd");
            testCase.verifyEqual(before.source,"fov_geometry");

            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"ModulatorVoltage",1.2));
            controller.setPlanParameter("mode","1p_dmd");
            after=controller.spatialPreview("1p_dmd");

            testCase.verifyEqual(after.source,"fov_geometry");
            testCase.verifyEqual( ...
                sort(arrayfun(@(o)string(o.cell_id),after.blue)), ...
                sort(arrayfun(@(o)string(o.cell_id),before.blue)), ...
                "Loading a protocol must not change which cells have geometry.");
        end

        function aSessionWithNothingToShowSaysSoRatherThanFailing(testCase)
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp());
            testCase.addTeardown(@()delete(controller));

            preview=controller.spatialPreview("1p_dmd");

            testCase.verifyFalse(preview.available);
            testCase.verifyNotEqual(preview.message,"");
            testCase.verifyEmpty(preview.blue);
            testCase.verifyEmpty(preview.spiral);
        end

        function theSpatialPreviewCarriesTheRevisionItDescribes(testCase)
            % What lets a frontend drop an overlay that no longer describes
            % the current geometry instead of deciding for itself which
            % edits matter.
            controller=testCase.loadedController();

            preview=controller.spatialPreview("2p_spiral");
            testCase.verifyEqual(preview.revision,controller.Revision);

            controller.addSomaPolygon([100 30; 116 30; 116 46; 100 46]);
            testCase.verifyNotEqual(preview.revision,controller.Revision);
        end

        function theSpatialPreviewSurvivesJsonEncoding(testCase)
            controller=testCase.loadedController();

            decoded=jsondecode(jsonencode( ...
                controller.spatialPreview("2p_spiral")));

            testCase.verifyTrue(decoded.available);
            for field=["mode","source","coordinate_space","image_size", ...
                    "revision","blue","orange","spiral"]
                testCase.verifyTrue(isfield(decoded,field), ...
                    sprintf("The encoded preview is missing %s.",field));
            end
        end

        % ---------------------------------------------------------------
        % B. The waveform preview endpoint
        % ---------------------------------------------------------------
        function withNoProtocolTheWaveformPreviewSaysToLoadOne(testCase)
            controller=testCase.loadedController();

            preview=controller.waveformPreview();

            testCase.verifyFalse(preview.available);
            testCase.verifyEqual(strjoin(string(preview.message)," "), ...
                "Load a pulse protocol to preview waveforms.");
            testCase.verifyEmpty(preview.channels);
            testCase.verifyEmpty(preview.time_s);
        end

        function theWaveformPreviewIsReadOnlyAndBumpsNoRevision(testCase)
            controller=testCase.onePhotonController();
            before=controller.getState();

            controller.waveformPreview();
            controller.waveformPreview();

            testCase.verifyTrue(isequaln(controller.getState(),before));
            testCase.verifyEqual(controller.Revision,before.revision);
        end

        function theOnePhotonPreviewIsTheResolvedModulatorCommand(testCase)
            controller=testCase.onePhotonController();

            preview=controller.waveformPreview();

            testCase.verifyTrue(preview.available);
            testCase.verifyEqual(preview.mode,"1p_dmd");
            testCase.verifyNumElements(preview.channels,1);
            testCase.verifyEqual(preview.channels(1).name,"mod488");
            testCase.verifyEqual(preview.channels(1).units,"V");
            testCase.verifyEqual(numel(preview.channels(1).values), ...
                numel(preview.time_s), ...
                "Every channel must be plottable against time_s.");
            % The step trace is the pulse edges: four samples per event.
            testCase.verifyEqual(numel(preview.time_s), ...
                4*numel(preview.events));
            testCase.verifyGreaterThan(max(preview.channels(1).values),0);
            testCase.verifyEqual(min(preview.channels(1).values),0);
        end

        function eventTimingAndTargetsComeFromTheResolvedSchedule(testCase)
            controller=testCase.onePhotonController();

            preview=controller.waveformPreview();

            testCase.verifyNotEmpty(preview.events);
            onsets=[preview.events.onset_s];
            testCase.verifyEqual(onsets,sort(onsets), ...
                "Events arrive in the order they fire.");
            testCase.verifyTrue(all([preview.events.offset_s]>onsets));
            testCase.verifyLessThanOrEqual(max([preview.events.offset_s]), ...
                preview.duration_s+1e-9);
            % The per-target counts are the round-robin balance the MATLAB
            % preview's title reports.
            stimulated=~[preview.events.is_null];
            testCase.verifyEqual(sum([preview.targets.event_count]), ...
                sum(stimulated));
            testCase.verifyTrue(all(ismember([preview.targets.cell_id], ...
                [controller.getState().cells.cell_id])));
        end

        function theCommandedVoltageIsTheProtocolsNotTheStoredCalibration(testCase)
            % The waveform a frontend plots must be the one that would
            % execute, which is the resolver's answer and not the cell
            % table's.
            controller=testCase.onePhotonController();
            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",4.5));

            preview=controller.waveformPreview();

            commanded=[preview.events(~[preview.events.is_null]).command_voltage_v];
            testCase.verifyNotEmpty(commanded);
            testCase.verifyEqual(unique(commanded),1.2);
            testCase.verifyEqual(max(preview.channels(1).values),1.2);
        end

        function aLongScheduleIsWindowedRatherThanThinned(testCase)
            % Cutting at a whole pulse keeps the drawn trace exactly what
            % would be commanded during that window. Thinning the pulses
            % would draw a schedule that was never scheduled.
            controller=testCase.onePhotonController(60);

            preview=controller.waveformPreview("MaximumPoints",40);

            testCase.verifyTrue(preview.truncated);
            testCase.verifyLessThanOrEqual(numel(preview.time_s),40);
            testCase.verifyEqual(mod(numel(preview.time_s),4),0, ...
                "The trace ends on a whole pulse.");
            testCase.verifyLessThan(preview.window_s(2),preview.duration_s);
        end

        function theWaveformPreviewSurvivesJsonEncoding(testCase)
            controller=testCase.onePhotonController();

            decoded=jsondecode(jsonencode(controller.waveformPreview()));

            testCase.verifyTrue(decoded.available);
            for field=["mode","duration_s","window_s","time_s","channels", ...
                    "events","targets","truncated","decimation_step"]
                testCase.verifyTrue(isfield(decoded,field), ...
                    sprintf("The encoded preview is missing %s.",field));
            end
        end

        % ---------------------------------------------------------------
        % C. The preview is the experiment that would run
        %   One layer below the endpoints above: build_target_preview
        %   against the same canonical mask, expansion and spiral helpers
        %   the DMD sequence builder and the waveform builder use. A
        %   preview that agrees with the endpoint contract but disagrees
        %   with execution is the failure these exist to find.
        % ---------------------------------------------------------------
        function bluePreviewShowsResolvedEventMasksNotTheBundleDefault(testCase)
            [fovState,targets]=single_cell_fixture(0);
            adjustments=[-1 0 2];
            definition=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                adjustments,"EventOrder","ordered");
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","1p_dmd");

            bundlePreview=adaptive_optopatch.build_target_preview(targets,"1p_dmd");
            testCase.verifyEqual(bundlePreview.source,"bundle_default");
            testCase.verifyNumElements(bundlePreview.blue,1);

            preview=adaptive_optopatch.build_target_preview(targets,"1p_dmd", ...
                "ResolvedProtocols",resolved);
            testCase.verifyEqual(preview.source,"resolved_plan");
            testCase.verifyEqual(sort([preview.blue.adjustment_pixels]), ...
                sort(double(adjustments)));

            % Each previewed mask is exactly the pattern the DMD sequence
            % builder will project for that event.
            plan=adaptive_optopatch.build_dmd_sequence_plan(resolved{1},targets);
            events=resolved{1}.events;
            for k=1:height(events)
                adjustment=events.blue_mask_adjustment_pixels(k);
                index=find([preview.blue.adjustment_pixels]==adjustment,1);
                testCase.verifyNotEmpty(index);
                slot=plan.event_slot_indices(k);
                testCase.verifyEqual(preview.blue(index).mask, ...
                    plan.unique_camera_masks(:,:,slot));
            end

            % The bundle default is only one of them, so the old preview
            % showed a mask that two of the three pulses never use.
            defaultMask=bundlePreview.blue(1).mask;
            differing=arrayfun(@(entry)~isequal(entry.mask,defaultMask), ...
                preview.blue);
            testCase.verifyGreaterThan(sum(differing),0);
        end

        function orangePreviewShowsTheResolvedExpansion(testCase)
            [fovState,targets]=single_cell_fixture(0);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            definition.parameters.orange_expansion_pixels=5;
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","1p_dmd");
            preview=adaptive_optopatch.build_target_preview(targets,"1p_dmd", ...
                "ResolvedProtocols",resolved);
            executed=adaptive_optopatch.apply_acquisition_parameters( ...
                targets,resolved{1});
            testCase.verifyEqual([preview.orange.expansion_pixels],5);
            testCase.verifyEqual(preview.orange(1).mask, ...
                executed.orange_camera_masks(:,:,1));
            testCase.verifyNotEqual(nnz(preview.orange(1).mask), ...
                nnz(targets.orange_camera_masks(:,:,1)));
        end

        function spiralPreviewUsesResolvedRadiusDensityAndDuration(testCase)
            [fovState,targets]=single_cell_fixture(0);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"PulseDurationMs",8,"ModulatorVoltage",1, ...
                "StimulationSource","2p_spiral");
            definition.parameters.spiral_radius_um=5;
            definition.parameters.spiral_density_points_per_volt=17;
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","2p_spiral");
            preview=adaptive_optopatch.build_target_preview(targets,"2p_spiral", ...
                "ResolvedProtocols",resolved);
            executed=adaptive_optopatch.apply_acquisition_parameters( ...
                targets,resolved{1});

            testCase.verifyNumElements(preview.spiral,1);
            testCase.verifyEqual(preview.spiral.radius_pixels, ...
                executed.targets(1).spiral_preview_radius_pixels);
            testCase.verifyEqual(preview.spiral.density_points_per_volt,17);
            testCase.verifyEqual(preview.spiral.pulse_duration_ms,8,"AbsTol",1e-9);

            bundlePreview=adaptive_optopatch.build_target_preview( ...
                targets,"2p_spiral");
            testCase.verifyNotEqual(bundlePreview.spiral.radius_pixels, ...
                preview.spiral.radius_pixels);
            testCase.verifyNotEqual(bundlePreview.spiral.density_points_per_volt, ...
                preview.spiral.density_points_per_volt);
        end

        function unifiedPreviewDerivesFromTheResolvedPlan(testCase)
            root=tempname; mkdir(root);
            cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>
            [app,~]=open_simulated_test_gui( ...
                "CameraRoi",[974 100 984 80],"Visible","off","RunRoot",root);
            appCleanup=onCleanup(@()delete(app)); %#ok<NASGU>
            app.setReferenceData(ones(80,100),unified_info(root), ...
                {[40 30;60 30;60 50;40 50]});
            app.setPlanParameter("mode","1p_dmd");
            app.setPlanParameter("blue_mask_adjustment_pixels",0);
            % A mask titration deliberately runs at the cell's calibrated
            % voltage, so its parameter_sources exclude the GUI default.
            app.setCellCalibration("cell_001",1);
            app.setPulseProtocol( ...
                adaptive_optopatch.generate_blue_mask_titration_protocol( ...
                [-2 0],"EventOrder","ordered"));

            resolved=app.buildCurrentPlan().resolved_protocols;
            testCase.verifyNumElements(resolved,1);
            testCase.verifyEqual( ...
                sort(unique(resolved{1}.events.blue_mask_adjustment_pixels))', ...
                [-2 0]);

            app.previewCurrentPlan();
            status=string(app.statusText());
            testCase.verifyTrue(any(contains(status,"resolved acquisition values")), ...
                char(strjoin(status,newline)));
            testCase.verifyTrue(any(contains(status,"-2")), ...
                char(strjoin(status,newline)));
        end
    end

    % -------------------------------------------------------------------
    % Fixtures
    % -------------------------------------------------------------------
    methods (Access=private)
        function response=act(~,controller,action,payload)
            arguments
                ~
                controller
                action (1,1) string
                payload = struct()
            end
            response=AoFixtures.act(controller,action,payload);
        end

        function controller=loadedController(testCase)
            controller=AoFixtures.previewController(testCase);
        end

        function controller=onePhotonController(testCase,pulseCount)
            arguments
                testCase
                pulseCount (1,1) double = 3
            end
            controller=testCase.loadedController();
            controller.setProtocol( ...
                adaptive_optopatch.generate_screen_protocol( ...
                    "PulseCount",pulseCount,"ModulatorVoltage",1.2));
            controller.setPlanParameter("mode","1p_dmd");
        end
    end
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end

function [fovState,targets]=single_cell_fixture(defaultAdjustment)
image=zeros(40,40); masks=false(40,40);
masks(14:25,14:25)=true;
polygons={[14 14;25 14;25 25;14 25]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","preview_test","CellIds","cell_001","RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons);
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"SpiralDensityPointsPerVolt",10, ...
    "ParkingClearancePixels",1,"OrangeExpansionPixels",2, ...
    "BlueMaskAdjustmentPixels",defaultAdjustment);
end

function defaults=gui_defaults()
defaults=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function info=unified_info(root)
camera=struct("name","Orca Fusion","ROI",[0 0 100 80],"bin",1, ...
    "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
metadata=struct("rig_name","Virtual_Upright","voltage_camera",camera);
info=struct("snapshot_name","preview_test", ...
    "snapshot_directory",string(root), ...
    "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
    "metadata",metadata);
end
