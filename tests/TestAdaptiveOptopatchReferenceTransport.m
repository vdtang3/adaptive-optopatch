classdef TestAdaptiveOptopatchReferenceTransport < matlab.unittest.TestCase
    %TESTADAPTIVEOPTOPATCHREFERENCETRANSPORT Getting the FOV to a frontend.
    %   The reference image is the one large thing an Adaptive Optopatch
    %   frontend needs and the one thing that must never travel on the state
    %   poll. These tests pin the properties the transport depends on: that
    %   fetching it is a read, that what arrives is the size the state
    %   snapshot said it would be, and that a pixel of it is the same pixel of
    %   the canonical reference image - because soma vertices are indices into
    %   exactly that grid.
    %
    %   The wire itself (JS_Server's binary framing, the relay's decoder) is
    %   Luminos's and is tested there. What is tested here is the shape of
    %   what is handed to it, and - since a bare pixel list says nothing
    %   about itself - WHICH REFERENCE a caller is told it belongs to.

    methods (Test)
        % ---------------------------------------------------------------
        % L, M. Reading a picture is a read
        % ---------------------------------------------------------------
        function fetchingTheImageChangesNothing(testCase)
            controller = testCase.controllerWithReference();
            before = controller.getState();

            controller.referenceDisplayImage();

            testCase.verifyEqual(controller.getState(), before);
            testCase.verifyEqual(controller.Revision, before.revision);
        end

        function repeatedFetchesAreIdenticalAndStillChangeNothing(testCase)
            controller = testCase.controllerWithReference();
            before = controller.getState();

            first = controller.referenceDisplayImage();
            for k = 1:5
                testCase.verifyEqual(controller.referenceDisplayImage(), first);
            end

            testCase.verifyEqual(controller.getState(), before, ...
                "A view that refetches its image must not disturb the session.");
        end

        function thereIsNoImageBeforeAReferenceIsLoaded(testCase)
            controller = adaptive_optopatch.AdaptiveOptopatchController();
            testCase.addTeardown(@() delete(controller));

            testCase.verifyEmpty(controller.referenceDisplayImage());
            testCase.verifyFalse(controller.getState().fov.loaded);
        end

        function theStatePollStillCarriesNoImage(testCase)
            % The whole reason this transport is separate. A field holding
            % 8000 pixels would be on the wire once a second per open tab.
            controller = testCase.controllerWithReference();

            state = controller.getState();

            for field = string(fieldnames(state))'
                testCase.verifyLessThan(numel(state.(field)), 1000, ...
                    sprintf("state.%s is large enough to be an image.", field));
            end
        end

        % ---------------------------------------------------------------
        % What the browser has to be able to reconstruct
        % ---------------------------------------------------------------
        function theImageIsExactlyTheSizeTheStateAnnounced(testCase)
            controller = testCase.controllerWithReference();

            state = controller.getState();
            image = controller.referenceDisplayImage();

            testCase.verifyEqual(size(image), state.fov.image_size, ...
                "A frontend reshapes by fov.image_size and nothing else.");
            testCase.verifyClass(image, "uint8");
        end

        function theFlattenedImageReconstructsColumnMajor(testCase)
            % Exactly what the endpoint puts on the wire, and exactly what a
            % frontend does with it: one flat list, rebuilt with the rows
            % count from the state snapshot.
            controller = testCase.controllerWithReference();
            image = controller.referenceDisplayImage();
            rows = controller.getState().fov.image_size(1);

            onTheWire = reshape(image, 1, []);
            rebuilt = reshape(onTheWire, rows, []);

            testCase.verifyEqual(rebuilt, image);
            testCase.verifyEqual(numel(onTheWire), numel(image));
            % Element (r,c) is at (c-1)*rows + r. Named here because the
            % browser has to index it by hand.
            testCase.verifyEqual(onTheWire((7 - 1) * rows + 3), image(3, 7));
        end

        % ---------------------------------------------------------------
        % Pixels are attributed by the CONTROLLER, not by the caller
        %
        % A frontend reads the state, sees reference A and asks for pixels.
        % The reference is replaced in between - by another browser, or in
        % the planning window - and B's pixels arrive. Nothing in a list of
        % uint8 says which reference it is of, so a caller that labelled
        % them with what it expected would draw somata against the wrong
        % cells, and two fields of view of the same size make that
        % undetectable downstream. So the caller NAMES the reference and
        % the controller decides.
        % ---------------------------------------------------------------
        function namingTheLoadedReferenceReturnsItsPicture(testCase)
            controller = testCase.controllerWithReference();
            loaded = controller.getState().fov.reference_revision;

            testCase.verifyEqual( ...
                controller.referenceDisplayImageFor(loaded), ...
                controller.referenceDisplayImage());
        end

        function namingAReferenceTheSessionHasMovedPastReturnsNothing(testCase)
            controller = testCase.controllerWithReference();
            first = controller.getState().fov.reference_revision;

            testCase.installSecondReference(controller);

            testCase.verifyEmpty(controller.referenceDisplayImageFor(first), ...
                "A request about the previous reference must not be " + ...
                "answered with the current picture.");
            testCase.verifyClass( ...
                controller.referenceDisplayImageFor(first), "uint8");
        end

        function twoReferencesOfTheSameSizeAreStillToldApart(testCase)
            % The race the contract exists for. Same rows, same columns, so
            % a caller that checked only that the payload reshaped cleanly
            % would accept either of these as the other.
            dim = zeros(40, 60, "single");
            dim(10:20, 10:20) = 100;
            bright = zeros(40, 60, "single");
            bright(10:20, 30:40) = 4000;
            controller = testCase.controllerWithReference(dim);
            first = controller.getState().fov.reference_revision;

            testCase.installSecondReference(controller, bright);
            second = controller.getState().fov.reference_revision;

            testCase.verifyNotEqual(second, first);
            testCase.verifyEmpty(controller.referenceDisplayImageFor(first));
            testCase.verifyEqual( ...
                size(controller.referenceDisplayImageFor(second)), [40 60]);
            % And it really is the second picture, not the first one under
            % a new number.
            testCase.verifyNotEqual( ...
                controller.referenceDisplayImageFor(second), ...
                uint8(adaptive_optopatch.reference_display_image(dim)));
        end

        function namingAReferenceIsStillARead(testCase)
            controller = testCase.controllerWithReference();
            before = controller.getState();

            controller.referenceDisplayImageFor(before.fov.reference_revision);
            controller.referenceDisplayImageFor(before.fov.reference_revision + 7);

            testCase.verifyEqual(controller.getState(), before, ...
                "Asking - or being refused - must not disturb the session.");
        end

        function editingTheFovDoesNotChangeTheReferenceIdentity(testCase)
            % The whole basis of the same-FOV/new-FOV distinction a frontend
            % draws: an edit advances `revision`, and only a replacement
            % advances `reference_revision`. If an ordinary edit bumped the
            % reference identity, every soma drawn would invalidate the
            % picture it was drawn on.
            controller = testCase.controllerWithReference();
            before = controller.getState();

            controller.addSomaPolygon([10 10; 30 10; 30 30; 10 30]);
            after = controller.getState();

            testCase.verifyGreaterThan(after.revision, before.revision);
            testCase.verifyEqual(after.fov.reference_revision, ...
                before.fov.reference_revision);
            % So the picture a frontend already holds is still this FOV's.
            testCase.verifyEqual( ...
                controller.referenceDisplayImageFor( ...
                    before.fov.reference_revision), ...
                controller.referenceDisplayImage());
        end

        function replacingTheReferenceAdvancesTheIdentity(testCase)
            controller = testCase.controllerWithReference();
            before = controller.getState().fov.reference_revision;

            testCase.installSecondReference(controller);

            testCase.verifyGreaterThan( ...
                controller.getState().fov.reference_revision, before);
        end

        % ---------------------------------------------------------------
        % The coordinate contract
        % ---------------------------------------------------------------
        function aDisplayPixelIsTheSameReferencePixel(testCase)
            % Canonical soma vertices are indices into the reference image.
            % If the display image were cropped, padded, transposed or
            % rescaled, every overlay drawn on it would be wrong - so it is
            % none of those things.
            % A bright block that is nowhere near the centre, in a
            % non-square image: a transpose, a flip or a crop each move it
            % somewhere this cannot confuse with where it belongs.
            reference = zeros(40, 60, "single");
            reference(5:9, 40:44) = 1000;
            controller = testCase.controllerWithReference(reference);

            image = controller.referenceDisplayImage();

            testCase.verifyEqual(size(image), [40 60]);
            [rows, columns] = find(image > 200);
            testCase.verifyEqual([min(rows) max(rows)], [5 9], ...
                "The bright region moved in y.");
            testCase.verifyEqual([min(columns) max(columns)], [40 44], ...
                "The bright region moved in x.");
        end

        function theFovReportsTheCoordinateSpaceItsVerticesAreIn(testCase)
            controller = testCase.controllerWithReference();

            fov = controller.getState().fov;

            testCase.verifyEqual(fov.image_coordinate_space, ...
                "snapshot_intrinsic_pixels");
            testCase.verifyEqual(fov.image_size, ...
                size(controller.ReferenceImage));
        end

        % ---------------------------------------------------------------
        % One display rule, shared with the planning axes
        % ---------------------------------------------------------------
        function theStretchUsesTheSameLimitsTheGuiAxesDo(testCase)
            values = single(reshape(1:4000, 40, 100));

            limits = adaptive_optopatch.reference_contrast_limits(values);
            image = adaptive_optopatch.reference_display_image(values);

            testCase.verifyNumElements(limits, 2);
            testCase.verifyEqual(image(values <= limits(1)), ...
                zeros(nnz(values <= limits(1)), 1, "uint8"));
            testCase.verifyEqual(image(values >= limits(2)), ...
                repmat(uint8(255), nnz(values >= limits(2)), 1));
        end

        function aFlatImageIsShownAsFlatRatherThanAsAFailedTransfer(testCase)
            image = adaptive_optopatch.reference_display_image(ones(20, 30));

            testCase.verifyEqual(size(image), [20 30]);
            testCase.verifyEqual(unique(image), uint8(128));
        end

        function nonFiniteValuesDoNotPoisonTheStretch(testCase)
            values = single(reshape(1:600, 20, 30));
            values(5, 5) = NaN;
            values(6, 6) = Inf;

            image = adaptive_optopatch.reference_display_image(values);

            testCase.verifyClass(image, "uint8");
            testCase.verifyEqual(size(image), [20 30]);
            testCase.verifyTrue(all(isfinite(double(image)), "all"));
        end

        function canonicalIntensitiesAreNeverReplacedByTheDisplayView(testCase)
            controller = testCase.controllerWithReference();
            before = controller.ReferenceImage;

            controller.referenceDisplayImage();

            testCase.verifyEqual(controller.ReferenceImage, before);
            testCase.verifyClass(controller.ReferenceImage, "single");
        end

        % ---------------------------------------------------------------
        % Protocol discovery is a read too
        % ---------------------------------------------------------------
        function listingProtocolsChangesNothing(testCase)
            controller = testCase.controllerWithReference();
            controller.ProtocolRoot = testCase.protocolFolder();
            before = controller.getState();

            controller.protocolChoices();
            controller.protocolChoices();

            testCase.verifyEqual(controller.getState(), before);
        end

        function aMissingProtocolFolderIsAnEmptyListNotAFailure(testCase)
            controller = testCase.controllerWithReference();
            controller.ProtocolRoot = string(tempname);

            testCase.verifyEmpty(controller.protocolChoices());
        end

        function theProtocolListingSurvivesTheJsonEncodingJsServerUses(testCase)
            controller = testCase.controllerWithReference();
            controller.ProtocolRoot = testCase.protocolFolder();

            choices = controller.protocolChoices();
            decoded = jsondecode(jsonencode(choices));

            testCase.verifyNumElements(decoded, 2);
            for field = ["choice_id", "name", "path", "loadable", ...
                    "protocol_id", "protocol_type", "is_current"]
                testCase.verifyTrue(isfield(decoded, field), ...
                    sprintf("The encoded listing is missing %s.", field));
            end
        end
    end

    methods (Access=private)
        function controller = controllerWithReference(testCase, image)
            arguments
                testCase
                image = single(reshape(1:8000, 80, 100))
            end
            root = testCase.temporaryFolder();
            controller = adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp", simulatedLuminosApp("CameraRoi", ...
                    [974 size(image, 2) 984 size(image, 1)]), ...
                "RunRoot", root);
            testCase.addTeardown(@() delete(controller));
            controller.setReferenceData(image, reference_info(root, image), {});
        end

        function installSecondReference(testCase, controller, image)
            %INSTALLSECONDREFERENCE A different field of view, same session.
            arguments
                testCase
                controller
                image = single(reshape(8000:-1:1, 80, 100))
            end
            root = testCase.temporaryFolder();
            controller.setReferenceData(image, reference_info(root, image), {});
        end

        function folder = protocolFolder(testCase)
            folder = testCase.temporaryFolder();
            for name = ["screen_a", "screen_b"]
                protocol = adaptive_optopatch.generate_screen_protocol( ...
                    "PulseCount", 1, "ModulatorVoltage", 1);
                protocol.protocol_id = name + "_protocol";
                adaptive_optopatch.save_protocol( ...
                    fullfile(folder, name + ".mat"), protocol);
            end
        end

        function root = temporaryFolder(testCase)
            root = string(tempname);
            mkdir(root);
            testCase.addTeardown(@() remove_if_present(root));
        end
    end
end

function info = reference_info(root, image)
camera = struct("name", "Orca Fusion", "ROI", [0 0 size(image, 2) size(image, 1)], "bin", 1, ...
    "x_world_limits", [974 974 + size(image, 2)], ...
    "y_world_limits", [984 984 + size(image, 1)]);
info = struct("snapshot_name", "reference_transport_test", ...
    "snapshot_directory", string(root), ...
    "snapshot_path", string(fullfile(root, "snapshot.mat")), ...
    "metadata", struct("rig_name", "Virtual_Upright", "voltage_camera", camera));
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder, "s"); end
end
