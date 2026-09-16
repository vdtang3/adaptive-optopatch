classdef TestAdaptiveOptopatchFrontendPreviews < matlab.unittest.TestCase
    %TESTADAPTIVEOPTOPATCHFRONTENDPREVIEWS Blue V editing, and the read-only previews.
    %   Three things a second frontend needs that the MATLAB GUI already had,
    %   and the properties that keep adding them safe:
    %
    %     set_cell_blue_voltage   the per-cell 488 nm CALIBRATION, editable
    %                             from a table. The property that matters is
    %                             that it is not a command source: a protocol
    %                             naming command_voltage_v must be unaffected
    %                             by anything stored here, and a 2P Pockels
    %                             command must be unreachable from it.
    %
    %     spatialPreview          the targeting geometry the planning window
    %                             draws, as coordinates. Must be produced by
    %                             the canonical mask and spiral code, must
    %                             change nothing, and must reach no hardware.
    %
    %     waveformPreview         the commands the planning window plots, as
    %                             samples. Same three requirements.
    %
    %   No hardware is touched anywhere here: the session is the packaged
    %   simulator, and every call under test is one that must be inert even
    %   against a real rig.

    methods (Test)
        % ---------------------------------------------------------------
        % A. Blue V is a calibration, not a command source
        % ---------------------------------------------------------------
        function blueVoltageIsEditableThroughTheAllowlistedAction(testCase)
            controller=testCase.loadedController();

            response=testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_002","voltage_v",2.25));

            testCase.verifyTrue(response.ok,response.message);
            testCase.verifyEqual(response.status,"applied");
            testCase.verifyEqual( ...
                response.state.cells(2).selected_blue_voltage_v,2.25);
        end

        function theActionWritesTheFieldTheMatlabTableWrites(testCase)
            % The MATLAB cell table's edit callback calls
            % setCellBlueVoltage, which updates selected_blue_voltage_v in
            % the canonical FOV cell record. The action must land in the
            % same place, not in a parallel one.
            controller=testCase.loadedController();

            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",1.75));

            fovState=controller.currentFovState();
            testCase.verifyEqual( ...
                double(fovState.cells(1).selected_blue_voltage_v),1.75);
        end

        function anOutOfRangeVoltageIsRefusedAndChangesNothing(testCase)
            controller=testCase.loadedController();
            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",1.5));
            before=controller.getState();

            for voltage={0,-1,5.5,Inf,NaN,"high"}
                response=testCase.act(controller,"set_cell_blue_voltage", ...
                    struct("cell_id","cell_001","voltage_v",voltage{1}));
                testCase.verifyEqual(response.status,"validation_error");
                testCase.verifyEqual(response.identifier, ...
                    "adaptive_optopatch:InvalidCellCalibration");
                testCase.verifyTrue(isequaln(controller.getState(),before), ...
                    "A refused edit leaves the stored calibration alone.");
            end
        end

        function anUnknownCellIsRefused(testCase)
            controller=testCase.loadedController();

            response=testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_999","voltage_v",1.5));

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:UnknownCellId");
        end

        function theControllerMethodNameIsStillNotAnAction(testCase)
            % The action is set_cell_blue_voltage. The METHOD name must
            % remain unreachable, because a dispatcher that accepted it
            % would be reaching controller.(action) rather than reading an
            % allowlist.
            controller=testCase.loadedController();

            response=testCase.act(controller,"setCellBlueVoltage", ...
                struct("cell_id","cell_001","voltage_v",1.5));

            testCase.verifyEqual(response.status,"unknown_action");
        end

        % ---------------------------------------------------------------
        % B. Editing Blue V does not override a protocol
        % ---------------------------------------------------------------
        function aStoredBlueVoltageNeverOverridesAnExplicitProtocolVoltage(testCase)
            % The claim the editable cell table makes. A protocol whose
            % events carry command_voltage_v must execute that voltage no
            % matter what is stored per cell, because the resolver's order
            % is event > acquisition > protocol > fov_cell.
            controller=testCase.loadedController();
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"ModulatorVoltage",1.2));
            controller.setPlanParameter("mode","1p_dmd");

            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",4.5));

            resolved=controller.buildPlan().resolved_protocols{1};
            events=resolved.events(~resolved.events.is_null,:);
            testCase.verifyNotEmpty(events);
            testCase.verifyEqual(unique(events.command_voltage_v),1.2, ...
                "The protocol's explicit voltage is what executes.");
            testCase.verifyTrue(all(events.command_voltage_source=="event"), ...
                "and it is resolved from the event tier, not from fov_cell.");
        end

        function theStoredCalibrationIsUsedOnlyWhenNothingElseDefinesOne(testCase)
            % The other half of the same claim: the fov_cell tier is real,
            % and it is reached only when the event, the acquisition and the
            % protocol all leave the voltage unset. Without this the first
            % test would pass for a stored value that never resolves at all.
            controller=testCase.loadedController();
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2));
            controller.setPlanParameter("mode","1p_dmd");

            % Every stimulated cell needs one: an uncalibrated cell in a
            % protocol that names no voltage is an unresolved event, which
            % the resolver refuses rather than guesses at.
            for cellId=["cell_001","cell_002"]
                testCase.act(controller,"set_cell_blue_voltage", ...
                    struct("cell_id",cellId,"voltage_v",3.25));
            end

            resolved=controller.buildPlan().resolved_protocols{1};
            events=resolved.events(~resolved.events.is_null,:);
            testCase.verifyEqual(unique(events.command_voltage_v),3.25);
            testCase.verifyTrue(all(events.command_voltage_source=="fov_cell"));
        end

        function aStoredBlueVoltageCannotBecomeAPockelsCommand(testCase)
            % selected_blue_voltage_v is a 488 nm calibration. For
            % 2p_spiral the allowed tiers are narrowed to event,
            % acquisition and protocol, so a 2P protocol with no explicit
            % voltage must FAIL rather than quietly command a Chameleon
            % with a Blue number.
            controller=testCase.loadedController();
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2));
            controller.setPlanParameter("mode","2p_spiral");
            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",3.25));

            identifier="<no error was raised>";
            try
                controller.buildPlan();
            catch exception
                identifier=string(exception.identifier);
            end
            testCase.verifyTrue(ismember(identifier, [ ...
                "adaptive_optopatch:MissingTwoPhotonPockelsVoltage"
                "adaptive_optopatch:ProtocolModeIncompatible"]), ...
                "A 2P plan with no explicit Pockels voltage must be " + ...
                "refused, not resolved from a Blue calibration. Got: " + ...
                identifier);
        end

        % ---------------------------------------------------------------
        % C. The spatial preview
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

        function theSpatialPreviewFollowsTheResolvedProtocolWhenThereIsOne(testCase)
            controller=testCase.loadedController();
            testCase.verifyEqual( ...
                controller.spatialPreview("1p_dmd").source,"bundle_default");

            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"ModulatorVoltage",1.2));
            controller.setPlanParameter("mode","1p_dmd");

            testCase.verifyEqual( ...
                controller.spatialPreview("1p_dmd").source,"resolved_plan", ...
                "With a protocol loaded the preview shows what would execute.");
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
        % D. The waveform preview
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
    end

    % -------------------------------------------------------------------
    % Fixtures
    % -------------------------------------------------------------------
    methods (Access=private)
        function response=act(testCase,controller,action,payload)
            arguments
                testCase %#ok<INUSA>
                controller
                action (1,1) string
                payload = struct()
            end
            response=adaptive_optopatch.apply_controller_action( ...
                controller,action,payload,controller.Revision);
        end

        function controller=loadedController(testCase)
            %LOADEDCONTROLLER A reference FOV with two somata on it.
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
            testCase.addTeardown(@()remove_if_present(folder));
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
