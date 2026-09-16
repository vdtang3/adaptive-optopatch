classdef TestAdaptiveOptopatchSnapshotChoices < matlab.unittest.TestCase
    %TESTADAPTIVEOPTOPATCHSNAPSHOTCHOICES Starting a session from the interface.
    %   Loading the first camera snapshot was the last step of the normal
    %   workflow that still needed the MATLAB GUI, because it needed a file
    %   chooser. These tests pin the indirection that replaced it: MATLAB lists
    %   the snapshots it is willing to load, a frontend returns one id, and the
    %   file is resolved and read entirely on this side.
    %
    %   The property that matters most is the last one: a choice_id is not a
    %   path, and a caller that sends a path gets nothing.

    methods (Test)
        % ---------------------------------------------------------------
        % Discovery
        % ---------------------------------------------------------------
        function snapshotsAreOfferedByIdentityNotByPath(testCase)
            folder = testCase.snapshotFolder();
            controller = testCase.controller(folder);

            choices = controller.snapshotChoices();

            testCase.verifyEqual(numel(choices), 2);
            testCase.verifyEqual(sort([choices.choice_id]), ...
                ["120000full_cam-OrcaFusion", "130000crop_cam-OrcaFusion"]);
            testCase.verifyTrue(all([choices.loadable]));
            testCase.verifyFalse(any([choices.is_current]));
        end

        function theNewestSnapshotIsOfferedFirst(testCase)
            % The one an operator wants is almost always the one they just
            % took, and the listing is capped, so ordering is not cosmetic.
            folder = testCase.snapshotFolder();
            controller = testCase.controller(folder);

            choices = controller.snapshotChoices();

            testCase.verifyEqual(choices(1).choice_id, ...
                "130000crop_cam-OrcaFusion");
        end

        function croppedAndBinnedMetadataIsReportedBeforeLoading(testCase)
            controller = testCase.controller(testCase.snapshotFolder());

            choices = controller.snapshotChoices();
            cropped = choices([choices.choice_id] == "130000crop_cam-OrcaFusion");

            testCase.verifyEqual(cropped.camera_name, "Orca Fusion");
            testCase.verifyEqual(cropped.camera_bin, 2);
            testCase.verifyEqual(cropped.image_size, [96 140]);
            testCase.verifyEqual(cropped.roi_origin_xy, [512 300]);
            testCase.verifyEqual(cropped.roi_size_xy, [140 96]);
        end

        function aSnapshotFromAnotherCameraIsListedAsUnloadable(testCase)
            % Listed with the reason rather than hidden: an operator who
            % cannot see the snap they just took has no way to find out why.
            folder = testCase.snapshotFolder();
            testCase.writeSnapshot(folder, "140000other", ...
                [0 100 0 100], 1, "Kinetix");
            controller = testCase.controller(folder);

            choices = controller.snapshotChoices();
            other = choices([choices.choice_id] == "140000other");

            testCase.verifyEqual(numel(choices), 3, ...
                "A wrong-camera snap must not hide the usable ones.");
            testCase.verifyFalse(other.loadable);
            testCase.verifySubstring(char(other.issue), "Kinetix");
        end

        function anUnreadableFileIsListedAsUnloadableNotHidden(testCase)
            folder = testCase.snapshotFolder();
            fid = fopen(fullfile(folder, "rubbish.mat"), "w");
            fprintf(fid, "this is not a MAT file");
            fclose(fid);
            controller = testCase.controller(folder);

            choices = controller.snapshotChoices();
            bad = choices([choices.choice_id] == "rubbish");

            testCase.verifyEqual(numel(choices), 3);
            testCase.verifyFalse(bad.loadable);
            testCase.verifyNotEqual(bad.issue, "");
        end

        function listingIsReadOnly(testCase)
            controller = testCase.controller(testCase.snapshotFolder());
            before = controller.getState();

            controller.snapshotChoices();
            controller.snapshotChoices();

            testCase.verifyEqual(controller.getState(), before);
            testCase.verifyEqual(controller.Revision, before.revision);
        end

        function listingSurvivesTheJsonEncodingJsServerUses(testCase)
            controller = testCase.controller(testCase.snapshotFolder());

            decoded = jsondecode(jsonencode(controller.snapshotChoices()));

            testCase.verifyNumElements(decoded, 2);
            for field = ["choice_id", "name", "path", "loadable", "issue", ...
                    "camera_name", "camera_bin", "image_size", ...
                    "roi_origin_xy", "roi_size_xy", "timestamp", "is_current"]
                testCase.verifyTrue(isfield(decoded, field), ...
                    sprintf("The encoded listing is missing %s.", field));
            end
        end

        function theListingCarriesNoPixelsOrObjects(testCase)
            % read_reference_snapshot keeps the whole CL_RefImage in
            % metadata.voltage_camera.raw_archive. None of that may reach a
            % listing a browser reads once per button press.
            controller = testCase.controller(testCase.snapshotFolder());

            choices = controller.snapshotChoices();

            for k = 1:numel(choices)
                for field = string(fieldnames(choices(k)))'
                    value = choices(k).(field);
                    testCase.verifyFalse(isobject(value) && ~isstring(value), ...
                        sprintf("%s is an object.", field));
                    testCase.verifyLessThan(numel(value), 100, ...
                        sprintf("%s is large enough to be an image.", field));
                end
            end
        end

        function aSessionWithNoSnapshotFolderOffersNothing(testCase)
            % The simulated backend has no datafolder at all, which is also
            % what a session that has not written a snap yet looks like.
            controller = adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp", simulatedLuminosApp());
            testCase.addTeardown(@() delete(controller));

            testCase.verifyEmpty(controller.snapshotChoices());
            testCase.verifyEqual( ...
                adaptive_optopatch.luminos_snapshot_root(simulatedLuminosApp()), "");
            testCase.verifyEqual(adaptive_optopatch.luminos_snapshot_root(), "");
        end

        % ---------------------------------------------------------------
        % Loading through the action contract
        % ---------------------------------------------------------------
        function choosingASnapshotLoadsTheCanonicalFov(testCase)
            controller = testCase.controller(testCase.snapshotFolder());
            testCase.verifyFalse(controller.getState().fov.loaded);

            response = testCase.act(controller, "load_snapshot_choice", ...
                struct("choice_id", "130000crop_cam-OrcaFusion"));

            testCase.verifyTrue(response.ok, response.message);
            testCase.verifyEqual(response.status, "applied");
            fov = response.state.fov;
            testCase.verifyTrue(fov.loaded);
            testCase.verifyEqual(fov.fov_id, "130000crop_cam-OrcaFusion");
            testCase.verifyEqual(fov.camera_name, "Orca Fusion");
            testCase.verifyEqual(fov.camera_bin, 2);
            testCase.verifyEqual(fov.image_size, [96 140]);
            testCase.verifyEqual(fov.roi_origin_xy, [512 300]);
            testCase.verifyEqual(fov.image_coordinate_space, ...
                "snapshot_intrinsic_pixels");
        end

        function loadingAdvancesBothRevisions(testCase)
            controller = testCase.controller(testCase.snapshotFolder());
            before = controller.Revision;
            beforeReference = controller.getState().fov.reference_revision;

            response = testCase.act(controller, "load_snapshot_choice", ...
                struct("choice_id", "120000full_cam-OrcaFusion"));

            testCase.verifyGreaterThan(response.revision, before);
            testCase.verifyEqual(response.revision, controller.Revision);
            testCase.verifyGreaterThan( ...
                response.state.fov.reference_revision, beforeReference, ...
                "The reference revision is what makes a view refetch the image.");
        end

        function theLoadedSnapshotIsMarkedCurrentInTheNextListing(testCase)
            controller = testCase.controller(testCase.snapshotFolder());
            testCase.act(controller, "load_snapshot_choice", ...
                struct("choice_id", "120000full_cam-OrcaFusion"));

            choices = controller.snapshotChoices();

            current = choices([choices.is_current]);
            testCase.verifyNumElements(current, 1);
            testCase.verifyEqual(current.choice_id, "120000full_cam-OrcaFusion");
        end

        function theReferenceImageMatchesTheNewlyLoadedFov(testCase)
            controller = testCase.controller(testCase.snapshotFolder());

            for choiceId = ["120000full_cam-OrcaFusion", "130000crop_cam-OrcaFusion"]
                response = testCase.act(controller, "load_snapshot_choice", ...
                    struct("choice_id", choiceId));
                image = controller.referenceDisplayImage();

                testCase.verifyEqual(double(size(image)), ...
                    response.state.fov.image_size, ...
                    "A view reshapes by fov.image_size and nothing else.");
                testCase.verifyClass(image, "uint8");
                testCase.verifyEqual(numel(reshape(image, 1, [])), ...
                    prod(response.state.fov.image_size));
            end
        end

        function loadingAFovMakesRoiDrawingAvailable(testCase)
            controller = testCase.controller(testCase.snapshotFolder());
            testCase.verifyFalse(controller.getState().legal_actions.edit_cells);

            state = testCase.act(controller, "load_snapshot_choice", ...
                struct("choice_id", "120000full_cam-OrcaFusion")).state;

            testCase.verifyTrue(state.legal_actions.edit_cells);
            testCase.verifyEmpty(state.cells);
            testCase.verifyEqual(state.fov.next_cell_index, 1);

            drawn = testCase.act(controller, "add_soma", ...
                struct("vertices_xy", [20 20; 34 20; 34 34; 20 34]));
            testCase.verifyTrue(drawn.ok, drawn.message);
            testCase.verifyEqual(drawn.state.cells(1).cell_id, "cell_001");
        end

        % ---------------------------------------------------------------
        % Refusals
        % ---------------------------------------------------------------
        function aStaleRequestIsRefusedWithoutLoadingAnything(testCase)
            controller = testCase.controller(testCase.snapshotFolder());
            stale = controller.Revision;
            controller.setStatus("somebody used the MATLAB GUI");
            before = controller.getState();

            response = adaptive_optopatch.apply_controller_action( ...
                controller, "load_snapshot_choice", ...
                struct("choice_id", "120000full_cam-OrcaFusion"), stale);

            testCase.verifyEqual(response.status, "stale_revision");
            testCase.verifyFalse(response.state.fov.loaded);
            testCase.verifyEqual(controller.getState(), before, ...
                "A refused load must leave the session exactly as it was.");
        end

        function aSnapshotThatHasGoneAwayIsRefusedCleanly(testCase)
            folder = testCase.snapshotFolder();
            controller = testCase.controller(folder);
            controller.snapshotChoices();
            delete(fullfile(folder, "120000full_cam-OrcaFusion.mat"));

            response = testCase.act(controller, "load_snapshot_choice", ...
                struct("choice_id", "120000full_cam-OrcaFusion"));

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:UnknownSnapshotChoice", ...
                "A file that has gone away must send the operator back to " + ...
                "the list, not report a path they never chose.");
            testCase.verifyFalse(response.state.fov.loaded);
        end

        function aSnapshotFromAnotherCameraIsRefusedOnLoadToo(testCase)
            folder = testCase.snapshotFolder();
            testCase.writeSnapshot(folder, "140000other", ...
                [0 100 0 100], 1, "Kinetix");
            controller = testCase.controller(folder);

            response = testCase.act(controller, "load_snapshot_choice", ...
                struct("choice_id", "140000other"));

            testCase.verifyEqual(response.status, "validation_error");
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:WrongReferenceCamera");
            testCase.verifyFalse(response.state.fov.loaded, ...
                "A rejected snapshot must not half-load.");
        end

        function aMalformedSnapshotIsRefusedWithoutDisturbingTheCurrentFov(testCase)
            folder = testCase.snapshotFolder();
            fid = fopen(fullfile(folder, "rubbish.mat"), "w");
            fprintf(fid, "this is not a MAT file");
            fclose(fid);
            controller = testCase.controller(folder);
            testCase.act(controller, "load_snapshot_choice", ...
                struct("choice_id", "120000full_cam-OrcaFusion"));
            loaded = controller.getState().fov;

            response = testCase.act(controller, "load_snapshot_choice", ...
                struct("choice_id", "rubbish"));

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.state.fov.fov_id, loaded.fov_id, ...
                "The reference in use must survive a failed load.");
            testCase.verifyEqual(response.state.fov.reference_revision, ...
                loaded.reference_revision);
        end

        function anEmptySelectionIsRefusedBeforeTheController(testCase)
            controller = testCase.controller(testCase.snapshotFolder());

            for payload = {struct(), struct("choice_id", ""), ...
                    struct("choice_id", 7)}
                response = testCase.act(controller, "load_snapshot_choice", ...
                    payload{1});
                testCase.verifyFalse(response.ok);
                testCase.verifyEqual(response.status, "validation_error");
                testCase.verifyFalse(response.state.fov.loaded);
            end
        end

        % ---------------------------------------------------------------
        % The whole point of the indirection
        % ---------------------------------------------------------------
        function aPathSentAsAChoiceIdReachesNothing(testCase)
            % The failure this exists to prevent: a frontend that discovers it
            % can put a filename in choice_id and load whatever it likes.
            folder = testCase.snapshotFolder();
            elsewhere = testCase.temporaryFolder();
            testCase.writeSnapshot(elsewhere, "not_offered", ...
                [0 64 0 64], 1, "Orca Fusion");
            controller = testCase.controller(folder);

            candidates = [ ...
                string(fullfile(folder, "120000full_cam-OrcaFusion.mat"))
                string(fullfile(elsewhere, "not_offered.mat"))
                string(fullfile(elsewhere, "not_offered"))
                "../not_offered"
                "/etc/passwd"];

            for candidate = candidates'
                response = testCase.act(controller, "load_snapshot_choice", ...
                    struct("choice_id", candidate));
                testCase.verifyEqual(response.identifier, ...
                    "adaptive_optopatch:UnknownSnapshotChoice", ...
                    sprintf("'%s' must not resolve to a file.", candidate));
                testCase.verifyFalse(response.state.fov.loaded);
            end
        end

        function onlyTheOfferedFolderIsReachable(testCase)
            % The same claim from the other side: a snapshot outside the
            % configured root is not listed, so there is no id for it.
            folder = testCase.snapshotFolder();
            elsewhere = testCase.temporaryFolder();
            testCase.writeSnapshot(elsewhere, "not_offered", ...
                [0 64 0 64], 1, "Orca Fusion");
            controller = testCase.controller(folder);

            choices = controller.snapshotChoices();

            testCase.verifyFalse(any([choices.choice_id] == "not_offered"));
            testCase.verifyTrue(all(startsWith([choices.folder], folder)));
        end
    end

    % -------------------------------------------------------------------
    % Fixtures
    % -------------------------------------------------------------------
    methods (Access=private)
        function response = act(testCase, controller, action, payload)
            arguments
                testCase %#ok<INUSA>
                controller
                action (1,1) string
                payload = struct()
            end
            response = adaptive_optopatch.apply_controller_action( ...
                controller, action, payload, controller.Revision);
        end

        function controller = controller(testCase, snapshotRoot)
            controller = adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp", simulatedLuminosApp());
            testCase.addTeardown(@() delete(controller));
            controller.SnapshotRoot = snapshotRoot;
        end

        function folder = snapshotFolder(testCase)
            % One full-frame snapshot and one cropped, binned one, written a
            % second apart so their file times order them the way a Snaps
            % folder's really do.
            folder = testCase.temporaryFolder();
            testCase.writeSnapshot(folder, "120000full_cam-OrcaFusion", ...
                [0 160 0 128], 1, "Orca Fusion");
            pause(1.1);
            testCase.writeSnapshot(folder, "130000crop_cam-OrcaFusion", ...
                [512 140 300 96], 2, "Orca Fusion");
        end

        function writeSnapshot(~, folder, stem, roi, bin, cameraName)
            % The shape Camera_Snap writes, as a plain struct.
            % read_reference_snapshot accepts either that or a CL_RefImage,
            % and CL_RefImage is Luminos's class, not this repository's.
            snap = struct; %#ok<NASGU>
            snap.img = uint16(reshape(mod(1:roi(4) * roi(2), 4096), roi(4), roi(2)));
            snap.name = cameraName;
            snap.bin = bin;
            snap.ref2d = imref2d(size(snap.img), ...
                [roi(1) roi(1) + roi(2)], [roi(3) roi(3) + roi(4)]);
            snap.timestamp = datetime("now");
            snap.tform = struct("name", "DMD_Blue", "tform", affine2d());
            save(fullfile(folder, stem + ".mat"), "snap");
        end

        function root = temporaryFolder(testCase)
            root = string(tempname);
            mkdir(root);
            testCase.addTeardown(@() remove_if_present(root));
        end
    end
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder, "s"); end
end
