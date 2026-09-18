classdef TestAdaptiveOptopatchReferenceChooser < matlab.unittest.TestCase
    %TESTADAPTIVEOPTOPATCHREFERENCECHOOSER One chooser for snapshots and saved FOVs.
    %   Loading a saved Adaptive Optopatch FOV, and saving one, were the last
    %   steps of the normal workflow that still needed the MATLAB GUI, because
    %   both needed a file chooser. These tests pin the indirection that
    %   replaced them, which is the one snapshotChoices() established: MATLAB
    %   lists what it is willing to load, a frontend returns one id, and the
    %   file is resolved and read entirely on this side.
    %
    %   What is new, and what most of this file is about, is that the listing
    %   now carries TWO KINDS and that they are not interchangeable. A camera
    %   snapshot starts a fresh FOV; a saved FOV restores soma geometry, stable
    %   cell identities, per-cell decisions and Blue calibration. An Adaptive
    %   Optopatch FOV must never be loaded as though it were a camera snap, and
    %   saving one must never overwrite either the snapshot it came from or a
    %   bundle saved earlier.
    %
    %   Everything goes through adaptive_optopatch.apply_controller_action
    %   where an action exists for it, because the thing under test is the
    %   contract a browser has.

    methods (Test)
        % ---------------------------------------------------------------
        % One listing, two kinds
        % ---------------------------------------------------------------
        function snapshotsAndSavedFovsCoexistInOneChooser(testCase)
            [controller,folder]=testCase.sessionWithSavedFov();

            choices=controller.referenceChoices();

            kinds=[choices.kind];
            testCase.verifyEqual(sum(kinds=="snapshot"),2, ...
                "Both camera snapshots must still be offered.");
            testCase.verifyEqual(sum(kinds=="ao_fov"),1, ...
                "The saved FOV must be offered beside them.");
            testCase.verifyTrue(all([choices.loadable]));
            testCase.verifyTrue(all(startsWith([choices.folder],folder)));
        end

        function eachKindCarriesWhatThatKindKnows(testCase)
            controller=testCase.sessionWithSavedFov();

            choices=controller.referenceChoices();
            snapshot=choices([choices.kind]=="snapshot" & ...
                [choices.choice_id]=="120000full_cam-OrcaFusion");
            bundle=choices([choices.kind]=="ao_fov");

            % A snapshot has no cells to count, and says so with NaN rather
            % than with a zero that would read as "none eligible".
            testCase.verifyEqual(snapshot.camera_name,"Orca Fusion");
            testCase.verifyEqual(snapshot.image_size,[128 160]);
            testCase.verifyTrue(isnan(snapshot.cell_count));
            testCase.verifyTrue(isnan(snapshot.fov_number));

            testCase.verifyEqual(bundle.fov_number,1);
            testCase.verifyEqual(bundle.cell_count,2);
            testCase.verifyEqual(bundle.stimulation_enabled_count,1);
            testCase.verifyEqual(bundle.calibrated_cell_count,1);
            testCase.verifyEqual(bundle.image_size,[128 160]);
        end

        function aSavedFovIsGroupedWithTheSnapshotItWasDrawnOn(testCase)
            controller=testCase.sessionWithSavedFov();

            choices=controller.referenceChoices();
            bundle=choices([choices.kind]=="ao_fov");
            snapshot=choices([choices.choice_id]=="120000full_cam-OrcaFusion");

            testCase.verifyEqual(bundle.reference_id,snapshot.reference_id, ...
                "A bundle and its snapshot describe the same field.");
            testCase.verifyEqual(bundle.group_index,snapshot.group_index);
            testCase.verifyEqual(bundle.source_snapshot,snapshot.path);
        end

        function aSavedFovIsNeverOfferedAsACameraSnapshot(testCase)
            % Without the exclusion, a bundle would be listed by
            % list_snapshot_choices as an unloadable snapshot - the snapshot
            % reader cannot read one - which is both wrong and alarming.
            controller=testCase.sessionWithSavedFov();

            snapshots=controller.snapshotChoices();

            testCase.verifyEqual(numel(snapshots),2);
            testCase.verifyFalse(any(contains([snapshots.choice_id],"_FOV")));
            testCase.verifyTrue(all([snapshots.loadable]));
        end

        function listingIsReadOnly(testCase)
            % Both listings: referenceChoices is the one a frontend reads,
            % and snapshotChoices is still reachable on its own.
            controller=testCase.sessionWithSavedFov();
            before=controller.getState();

            controller.referenceChoices();
            controller.referenceChoices();
            controller.snapshotChoices();

            testCase.verifyTrue(isequaln(controller.getState(),before));
            testCase.verifyEqual(controller.Revision,before.revision);
        end

        function listingSurvivesTheJsonEncodingJsServerUses(testCase)
            controller=testCase.sessionWithSavedFov();

            decoded=jsondecode(jsonencode(controller.referenceChoices()));

            testCase.verifyNumElements(decoded,3);
            for field=["choice_id","kind","label","name","folder","path", ...
                    "loadable","issue","reference_id","fov_number","fov_id", ...
                    "cell_count","camera_name","camera_bin","image_size", ...
                    "roi_origin_xy","roi_size_xy","source_snapshot", ...
                    "timestamp","group_index","is_current"]
                testCase.verifyTrue(isfield(decoded,field), ...
                    sprintf("The encoded listing is missing %s.",field));
            end
        end

        function theListingCarriesNoPixelsOrObjects(testCase)
            % A saved FOV holds the reference image, the ROI mask stack and
            % every cell's calibration history. None of that may reach a
            % listing a browser reads once per button press.
            controller=testCase.sessionWithSavedFov();

            choices=controller.referenceChoices();

            for k=1:numel(choices)
                for field=string(fieldnames(choices(k)))'
                    value=choices(k).(field);
                    testCase.verifyFalse(isobject(value) && ~isstring(value), ...
                        sprintf("%s is an object.",field));
                    testCase.verifyLessThan(numel(value),100, ...
                        sprintf("%s is large enough to be an image.",field));
                end
            end
        end

        % ---------------------------------------------------------------
        % Loading: the two kinds do different things
        % ---------------------------------------------------------------
        function choosingASnapshotLoadsAFreshFov(testCase)
            controller=testCase.sessionWithSavedFov();
            % Start from the restored FOV, so "fresh" means something.
            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV001"));
            testCase.assertNotEmpty(controller.getState().cells);

            response=testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion"));

            testCase.verifyTrue(response.ok,response.message);
            testCase.verifyEqual(response.state.fov.source_kind,"snapshot");
            testCase.verifyEmpty(response.state.cells, ...
                "A camera snapshot carries no saved soma decisions.");
            testCase.verifyEmpty(response.state.soma_polygons);
            testCase.verifyEqual(response.state.fov.next_cell_index,1);
        end

        function choosingASavedFovRestoresTheCanonicalState(testCase)
            controller=testCase.sessionWithSavedFov();
            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion"));
            testCase.assertEmpty(controller.getState().cells);

            response=testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV001"));

            testCase.verifyTrue(response.ok,response.message);
            testCase.verifyEqual(response.state.fov.source_kind,"ao_fov");
            state=response.state;
            testCase.verifyEqual([state.cells.cell_id],["cell_001" "cell_002"], ...
                "Stable identities come back, not a renumbering.");
            testCase.verifyEqual([state.cells.recording_enabled],[true false]);
            testCase.verifyEqual([state.cells.stimulation_enabled],[true false]);
            testCase.verifyEqual(state.cells(1).selected_blue_voltage_v,1.4);
            testCase.verifyTrue(isnan(state.cells(2).selected_blue_voltage_v));
        end

        function somaVerticesSurviveTheRoundTrip(testCase)
            controller=testCase.sessionWithSavedFov();
            expected=controller.FovGeometry.polygons;

            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion"));
            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV001"));

            restored=controller.FovGeometry.polygons;
            testCase.verifyNumElements(restored,numel(expected));
            for k=1:numel(expected)
                testCase.verifyEqual(restored{k},expected{k},"AbsTol",1e-9, ...
                    "Vertices stay in snapshot-intrinsic pixels.");
            end
            testCase.verifyEqual(controller.FovGeometry.next_cell_index,3, ...
                "The next identity is not recycled by a round trip.");
        end

        function referenceMetadataSurvivesTheRoundTrip(testCase)
            controller=testCase.sessionWithSavedFov();
            before=controller.getState().fov;

            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV001"));
            after=controller.getState().fov;

            for field=["rig_name","camera_name","camera_bin", ...
                    "snapshot_path","snapshot_directory","image_size", ...
                    "roi_origin_xy"]
                testCase.verifyEqual(after.(field),before.(field), ...
                    sprintf("%s must survive a save and load.",field));
            end
            testCase.verifyEqual(after.image_coordinate_space, ...
                "snapshot_intrinsic_pixels");
            % The link back to the camera snapshot is what the chooser
            % groups on and what the next save is named from, so it matters
            % more than the display name does.
            testCase.verifyTrue(endsWith(after.snapshot_path, ...
                "120000full_cam-OrcaFusion.mat"));
        end

        function theFovIdBecomesTheArtifactIdentityOnTheFirstSave(testCase)
            % A loaded snapshot reports the file stem as fov_id. Building
            % the reference model turns that into a valid MATLAB name,
            % because fov_id names saved variables and run folders - so a
            % restored FOV reports the valid-name form and not the stem.
            % That is the artifact's identity, and the point worth pinning
            % is that it is STABLE from then on: a second round trip must
            % not keep mangling it.
            controller=testCase.sessionWithSavedFov();

            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV001"));
            first=controller.getState().fov.fov_id;
            testCase.act(controller,"save_fov");
            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV002"));
            second=controller.getState().fov.fov_id;

            testCase.verifyEqual(first,"x120000full_cam_OrcaFusion");
            testCase.verifyEqual(second,first, ...
                "The artifact identity is stable across further saves.");
        end

        function theBundleRoundTripsThroughTheExistingLoader(testCase)
            % There is one persistence format, not a second one for FOVs a
            % browser saved: what save_fov wrote is what load_fov_state reads
            % and what the schema check accepts.
            [controller,folder]=testCase.sessionWithSavedFov(); %#ok<ASGLU>
            path=fullfile(folder,"120000full_cam-OrcaFusion_FOV001.mat");

            fovState=adaptive_optopatch.load_fov_state(path);

            testCase.verifyEqual(string(fovState.schema_version),"2.0.0");
            testCase.verifyNumElements(fovState.cells,2);
            testCase.verifyEqual(double(fovState.next_cell_index),3);
            testCase.verifyEqual(size(fovState.canonical_roi_masks,3),2);
        end

        function theLoadedEntryIsMarkedCurrent(testCase)
            controller=testCase.sessionWithSavedFov();

            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV001"));
            choices=controller.referenceChoices();

            current=choices([choices.is_current]);
            testCase.verifyNumElements(current,1);
            testCase.verifyEqual(current.choice_id, ...
                "120000full_cam-OrcaFusion_FOV001");
            testCase.verifyEqual(current.kind,"ao_fov");

            % A snapshot loaded through its own endpoint is marked the same
            % way, and in the snapshot-only listing too.
            testCase.act(controller,"load_snapshot_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion"));
            snapshots=controller.snapshotChoices();
            currentSnapshot=snapshots([snapshots.is_current]);
            testCase.verifyNumElements(currentSnapshot,1);
            testCase.verifyEqual(currentSnapshot.choice_id, ...
                "120000full_cam-OrcaFusion");
        end

        % ---------------------------------------------------------------
        % Saving allocates; it never replaces
        % ---------------------------------------------------------------
        function savingChoosesTheNextNumberDeterministically(testCase)
            [controller,folder]=testCase.sessionWithSavedFov();

            testCase.verifyTrue(testCase.act(controller,"save_fov").ok);
            testCase.verifyTrue(testCase.act(controller,"save_fov").ok);

            listing=string({dir(fullfile(folder,"*_FOV*.mat")).name});
            testCase.verifyEqual(sort(listing),[ ...
                "120000full_cam-OrcaFusion_FOV001.mat"
                "120000full_cam-OrcaFusion_FOV002.mat"
                "120000full_cam-OrcaFusion_FOV003.mat"]');
        end

        function savingNeverOverwritesAnExistingBundle(testCase)
            [controller,folder]=testCase.sessionWithSavedFov();
            first=fullfile(folder,"120000full_cam-OrcaFusion_FOV001.mat");
            before=dir(first);

            testCase.act(controller,"save_fov");

            after=dir(first);
            testCase.verifyEqual(after.bytes,before.bytes);
            testCase.verifyEqual(after.datenum,before.datenum, ...
                "An existing bundle must not be rewritten.");
        end

        function theCameraSnapshotIsNeverTouched(testCase)
            % The one file in the session that cannot be regenerated.
            [controller,folder]=testCase.sessionWithSavedFov();
            path=fullfile(folder,"120000full_cam-OrcaFusion.mat");
            before=dir(path);

            testCase.act(controller,"save_fov");
            testCase.act(controller,"save_fov");

            after=dir(path);
            testCase.verifyEqual(after.bytes,before.bytes);
            testCase.verifyEqual(after.datenum,before.datenum);
        end

        function aFovSavedFromAFovStaysNamedForItsSnapshot(testCase)
            % snap_FOV001 -> snap_FOV002, never snap_FOV001_FOV001: the chain
            % of bundles stays named for, and grouped with, the one snapshot
            % they are all views of.
            [controller,folder]=testCase.sessionWithSavedFov();
            testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV001"));

            testCase.act(controller,"save_fov");

            testCase.verifyTrue(isfile(fullfile(folder, ...
                "120000full_cam-OrcaFusion_FOV002.mat")));
            testCase.verifyFalse(isfile(fullfile(folder, ...
                "120000full_cam-OrcaFusion_FOV001_FOV001.mat")));
        end

        function numberingContinuesPastADeletedBundle(testCase)
            % One past the highest present, not the first gap, so numbering
            % follows the order FOVs were saved in.
            [controller,folder]=testCase.sessionWithSavedFov();
            testCase.act(controller,"save_fov");
            delete(fullfile(folder,"120000full_cam-OrcaFusion_FOV001.mat"));

            testCase.act(controller,"save_fov");

            testCase.verifyTrue(isfile(fullfile(folder, ...
                "120000full_cam-OrcaFusion_FOV003.mat")));
        end

        function savingCarriesTheCurrentDecisionsIntoTheNewBundle(testCase)
            controller=testCase.sessionWithSavedFov();
            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_002","voltage_v",2.75));

            response=testCase.act(controller,"save_fov");

            testCase.verifyTrue(response.ok,response.message);
            saved=adaptive_optopatch.load_fov_state( ...
                controller.ReferenceSourcePath);
            testCase.verifyEqual( ...
                double(saved.cells(2).selected_blue_voltage_v),2.75);
        end

        function savingWithNoFovIsRefusedRatherThanWritingAFile(testCase)
            controller=testCase.emptyController();

            response=testCase.act(controller,"save_fov");

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:NothingToSave");
            testCase.verifyFalse(response.state.legal_actions.save_fov);
        end

        % ---------------------------------------------------------------
        % The whole point of the indirection
        % ---------------------------------------------------------------
        function aPathSentAsAChoiceIdReachesNothing(testCase)
            % The failure this exists to prevent: a frontend that discovers
            % it can put a filename in choice_id and load whatever it likes.
            [controller,folder]=testCase.sessionWithSavedFov();
            elsewhere=testCase.temporaryFolder();
            testCase.writeSnapshot(elsewhere,"not_offered", ...
                [0 64 0 64],1,"Orca Fusion");

            candidates=[ ...
                string(fullfile(folder,"120000full_cam-OrcaFusion.mat"))
                string(fullfile(folder,"120000full_cam-OrcaFusion_FOV001.mat"))
                string(fullfile(elsewhere,"not_offered.mat"))
                "../not_offered"
                "/etc/passwd"];

            endpoints=[ ...
                "load_reference_choice","adaptive_optopatch:UnknownReferenceChoice"
                "load_snapshot_choice","adaptive_optopatch:UnknownSnapshotChoice"];
            for candidate=candidates'
                for k=1:size(endpoints,1)
                    response=testCase.act(controller,endpoints(k,1), ...
                        struct("choice_id",candidate));
                    testCase.verifyEqual(response.identifier,endpoints(k,2), ...
                        sprintf("'%s' must not resolve to a file through %s.", ...
                        candidate,endpoints(k,1)));
                    testCase.verifyFalse(response.state.fov.source_kind=="", ...
                        "A refused load must leave the reference in use.");
                end
            end
        end

        function aBundleThatHasGoneAwayIsRefusedCleanly(testCase)
            [controller,folder]=testCase.sessionWithSavedFov();
            controller.referenceChoices();
            delete(fullfile(folder,"120000full_cam-OrcaFusion_FOV001.mat"));

            response=testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV001"));

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:UnknownReferenceChoice", ...
                "A file that has gone away sends the operator back to the " + ...
                "list rather than reporting a path they never chose.");
        end

        function anUnreadableBundleIsListedWithItsReasonNotHidden(testCase)
            [controller,folder]=testCase.sessionWithSavedFov();
            fid=fopen(fullfile(folder, ...
                "120000full_cam-OrcaFusion_FOV009.mat"),"w");
            fprintf(fid,"this is not a MAT file");
            fclose(fid);

            choices=controller.referenceChoices();
            bad=choices([choices.choice_id]=="120000full_cam-OrcaFusion_FOV009");

            testCase.verifyNumElements(choices,4, ...
                "One bad bundle must not hide the ones beside it.");
            testCase.verifyFalse(bad.loadable);
            testCase.verifyNotEqual(bad.issue,"");

            response=testCase.act(controller,"load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion_FOV009"));
            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:UnloadableReferenceChoice", ...
                "A file the listing could not read is refused with its " + ...
                "own reason, not as an unexpected fault.");
            testCase.verifyEqual(response.status,"validation_error");
        end

        function aStaleRequestLoadsAndSavesNothing(testCase)
            [controller,folder]=testCase.sessionWithSavedFov();
            stale=controller.Revision;
            controller.setStatus("somebody used the MATLAB GUI");
            before=controller.getState();

            load=adaptive_optopatch.apply_controller_action(controller, ...
                "load_reference_choice", ...
                struct("choice_id","120000full_cam-OrcaFusion"),stale);
            loadSnapshot=adaptive_optopatch.apply_controller_action(controller, ...
                "load_snapshot_choice", ...
                struct("choice_id","130000crop_cam-OrcaFusion"),stale);
            save=adaptive_optopatch.apply_controller_action(controller, ...
                "save_fov",struct(),stale);

            testCase.verifyEqual(load.status,"stale_revision");
            testCase.verifyEqual(loadSnapshot.status,"stale_revision");
            testCase.verifyEqual(save.status,"stale_revision");
            testCase.verifyTrue(isequaln(controller.getState(),before));
            testCase.verifyFalse(isfile(fullfile(folder, ...
                "120000full_cam-OrcaFusion_FOV002.mat")), ...
                "A refused save must not write a bundle.");
        end

        function anEmptySelectionIsRefusedBeforeTheController(testCase)
            controller=testCase.sessionWithSavedFov();

            for action=["load_reference_choice","load_snapshot_choice"]
                for payload={struct(),struct("choice_id",""), ...
                        struct("choice_id",7)}
                    response=testCase.act(controller,action,payload{1});
                    testCase.verifyFalse(response.ok);
                    testCase.verifyEqual(response.status,"validation_error");
                end
            end
        end

        % ---------------------------------------------------------------
        % The naming convention itself
        % ---------------------------------------------------------------
        function bundleNamesAreParsedNotGuessed(testCase)
            parse=@adaptive_optopatch.parse_fov_bundle_name;

            [isBundle,stem,number]=parse("snap_cam-OrcaFusion_FOV007");
            testCase.verifyTrue(isBundle);
            testCase.verifyEqual(stem,"snap_cam-OrcaFusion");
            testCase.verifyEqual(number,7);

            % A snapshot, and names that merely look like one.
            for name=["snap_cam-OrcaFusion","cell_FOVs_backup","_FOV001", ...
                    "snap_FOV","snap_FOVx01"]
                testCase.verifyFalse(parse(name), ...
                    sprintf("'%s' is not a FOV bundle.",name));
            end
        end

        function numberingIsPerSnapshotNotPerFolder(testCase)
            folder=testCase.temporaryFolder();
            fid=fopen(fullfile(folder,"other_FOV004.mat"),"w");
            fclose(fid);

            [path,number]=adaptive_optopatch.next_fov_bundle_path(folder,"snap");

            testCase.verifyEqual(number,1, ...
                "Another reference's bundles are a different sequence.");
            testCase.verifyEqual(path,string(fullfile(folder,"snap_FOV001.mat")));
        end

        % ---------------------------------------------------------------
        % The camera-snapshot endpoint
        %   load_snapshot_choice predates the unified chooser and is still
        %   allowlisted: it is the narrow "start a fresh FOV from a snap"
        %   path, and it reads the camera identity, crop origin and binning
        %   out of the file itself. These came from
        %   TestAdaptiveOptopatchSnapshotChoices, which owned that endpoint
        %   before the chooser existed and had nothing else left in it.
        % ---------------------------------------------------------------
        function theNewestReferenceIsOfferedFirst(testCase)
            % The one an operator wants is almost always the one they just
            % took, and both listings are capped, so ordering is not
            % cosmetic. The folder is built with distinguishable file times
            % because this is the one test that reads the listing by
            % position.
            folder = testCase.orderedSnapshotFolder();
            controller = testCase.snapshotSession(folder);

            snapshots = controller.snapshotChoices();
            references = controller.referenceChoices();

            testCase.verifyEqual(snapshots(1).choice_id, ...
                "130000crop_cam-OrcaFusion");
            testCase.verifyEqual(references(1).choice_id, ...
                "130000crop_cam-OrcaFusion", ...
                "The unified listing groups by reference, newest first.");
        end

        function croppedAndBinnedMetadataIsReportedBeforeLoading(testCase)
            controller = testCase.snapshotSession(testCase.snapshotFolder());

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
            controller = testCase.snapshotSession(folder);

            choices = controller.snapshotChoices();
            other = choices([choices.choice_id] == "140000other");

            testCase.verifyEqual(numel(choices), 3, ...
                "A wrong-camera snap must not hide the usable ones.");
            testCase.verifyFalse(other.loadable);
            testCase.verifySubstring(char(other.issue), "Kinetix");
        end

        function anUnreadableSnapshotIsListedAsUnloadableNotHidden(testCase)
            folder = testCase.snapshotFolder();
            fid = fopen(fullfile(folder, "rubbish.mat"), "w");
            fprintf(fid, "this is not a MAT file");
            fclose(fid);
            controller = testCase.snapshotSession(folder);

            choices = controller.snapshotChoices();
            bad = choices([choices.choice_id] == "rubbish");

            testCase.verifyEqual(numel(choices), 3);
            testCase.verifyFalse(bad.loadable);
            testCase.verifyNotEqual(bad.issue, "");
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

        function onlyTheOfferedFolderIsReachable(testCase)
            % The same claim from the other side: a snapshot outside the
            % configured root is not listed, so there is no id for it.
            folder = testCase.snapshotFolder();
            elsewhere = testCase.temporaryFolder();
            testCase.writeSnapshot(elsewhere, "not_offered", ...
                [0 64 0 64], 1, "Orca Fusion");
            controller = testCase.snapshotSession(folder);

            choices = controller.snapshotChoices();

            testCase.verifyFalse(any([choices.choice_id] == "not_offered"));
            testCase.verifyTrue(all(startsWith([choices.folder], folder)));
        end

        function choosingASnapshotLoadsTheCanonicalFov(testCase)
            controller = testCase.snapshotSession(testCase.snapshotFolder());
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
            controller = testCase.snapshotSession(testCase.snapshotFolder());
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

        function theReferenceImageMatchesTheSnapshotThatWasLoaded(testCase)
            controller = testCase.snapshotSession(testCase.snapshotFolder());

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

        function loadingASnapshotMakesRoiDrawingAvailable(testCase)
            controller = testCase.snapshotSession(testCase.snapshotFolder());
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

        function aSnapshotThatHasGoneAwayIsRefusedCleanly(testCase)
            folder = testCase.snapshotFolder();
            controller = testCase.snapshotSession(folder);
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
            controller = testCase.snapshotSession(folder);

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
            controller = testCase.snapshotSession(folder);
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

        function controller=emptyController(testCase)
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp());
            testCase.addTeardown(@()delete(controller));
        end

        function [controller,folder]=sessionWithSavedFov(testCase)
            %SESSIONWITHSAVEDFOV Two snapshots, and one FOV saved from the first.
            %   The FOV carries decisions that are only worth restoring if
            %   they were made: one cell excluded from both recording and
            %   stimulation, and one with a Blue calibration.
            folder=testCase.snapshotFolder();
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 160 984 128]));
            testCase.addTeardown(@()delete(controller));
            controller.SnapshotRoot=folder;
            controller.loadSnapshotChoice("120000full_cam-OrcaFusion");
            controller.addSomaPolygon([30 30; 46 30; 46 46; 30 46]);
            controller.addSomaPolygon([80 60; 96 60; 96 76; 80 76]);
            controller.setCellBlueVoltage("cell_001",1.4);
            controller.setCellEligibility("cell_002", ...
                "RecordingEnabled",false,"StimulationEnabled",false);
            controller.saveNextFov();
        end

        function controller=snapshotSession(testCase,snapshotRoot)
            %SNAPSHOTSESSION A session with a snapshot folder and no FOV.
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp());
            testCase.addTeardown(@()delete(controller));
            controller.SnapshotRoot=snapshotRoot;
        end

        function folder=snapshotFolder(testCase)
            %SNAPSHOTFOLDER One full-frame snapshot and one cropped, binned one.
            %   Written back to back. Nothing here reads the listing
            %   POSITIONALLY - every test selects by choice_id - so the two
            %   files do not need distinguishable modification times, and
            %   the second of wall clock it used to cost was being paid once
            %   per test in the suite. The one test that is about ordering
            %   builds its own folder with orderedSnapshotFolder.
            folder=testCase.temporaryFolder();
            testCase.writeSnapshot(folder,"120000full_cam-OrcaFusion", ...
                [0 160 0 128],1,"Orca Fusion");
            testCase.writeSnapshot(folder,"130000crop_cam-OrcaFusion", ...
                [512 140 300 96],2,"Orca Fusion");
        end

        function folder=orderedSnapshotFolder(testCase)
            %ORDEREDSNAPSHOTFOLDER The same two snaps, a second apart.
            %   The listing orders by file time, so a test about ordering has
            %   to wait long enough for the two files to be distinguishable
            %   on any filesystem the rig might use.
            folder=testCase.temporaryFolder();
            testCase.writeSnapshot(folder,"120000full_cam-OrcaFusion", ...
                [0 160 0 128],1,"Orca Fusion");
            pause(1.1);
            testCase.writeSnapshot(folder,"130000crop_cam-OrcaFusion", ...
                [512 140 300 96],2,"Orca Fusion");
        end

        function writeSnapshot(~,folder,stem,roi,bin,cameraName)
            snap=struct; %#ok<NASGU>
            snap.img=uint16(reshape(mod(1:roi(4)*roi(2),4096),roi(4),roi(2)));
            snap.name=cameraName;
            snap.bin=bin;
            snap.ref2d=imref2d(size(snap.img), ...
                [roi(1) roi(1)+roi(2)],[roi(3) roi(3)+roi(4)]);
            snap.timestamp=datetime("now");
            snap.tform=struct("name","DMD_Blue","tform",affine2d());
            save(fullfile(folder,stem+".mat"),"snap");
        end

        function root=temporaryFolder(testCase)
            root=string(tempname);
            mkdir(root);
            testCase.addTeardown(@()remove_if_present(root));
        end
    end
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
