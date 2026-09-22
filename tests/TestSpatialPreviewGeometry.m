classdef TestSpatialPreviewGeometry < matlab.unittest.TestCase
    %TESTSPATIALPREVIEWGEOMETRY The targeting preview answers "what is here".
    %   NOT "what will run". Those are different questions and the preview
    %   used to answer the second while being asked the first: it called
    %   resolvedProtocolsForPreview, which is buildPlan, and then drew only
    %   the cells the resolved acquisitions addressed. resolve_protocol
    %   selects targets with `if ~stimulation_enabled, continue`, so
    %   unticking Stim made a soma's Blue mask VANISH from the picture the
    %   operator aims with - and loading a protocol removed geometry that
    %   had been visible a moment before, because with no protocol the
    %   preview had always drawn every cell.
    %
    %   Read only throughout. No mask is programmed and no device is
    %   touched; that is asserted here too.

    methods (Test)
        % ---------------------------------------------------------------
        % A. Geometry does not depend on execution selection
        % ---------------------------------------------------------------
        function blueGeometryIsDrawnForEveryCellWhateverStimSays(testCase)
            controller=testCase.configuredController();
            controller.setCellEligibility("cell_002","StimulationEnabled",false);

            preview=controller.spatialPreview("1p_dmd");

            testCase.verifyTrue(preview.available);
            testCase.verifyEqual(sort(testCase.cellIds(preview.blue)), ...
                ["cell_001";"cell_002"], ...
                "A deselected cell still has Blue mask geometry.");
        end

        function loadingAProtocolDoesNotRemoveGeometry(testCase)
            % The clearest statement of the defect: the same FOV, the same
            % somata, and the set of drawn cells must not change because a
            % protocol was loaded.
            controller=testCase.controllerWithoutProtocol();
            before=testCase.cellIds(controller.spatialPreview("1p_dmd").blue);
            testCase.assertNotEmpty(before);

            controller.setProtocol(testCase.protocol());
            after=testCase.cellIds(controller.spatialPreview("1p_dmd").blue);

            testCase.verifyEqual(sort(after),sort(before));
        end

        function zeroStimEnabledCellsStillPreviews(testCase)
            % resolve_protocol raises NoAcceptedTargets here, which used to
            % propagate out of a read-only preview and reach the browser as
            % "Nothing to preview." with the reason only in the console.
            controller=testCase.configuredController();
            for cellId=["cell_001","cell_002"]
                controller.setCellEligibility(cellId,"StimulationEnabled",false);
            end

            preview=controller.spatialPreview("1p_dmd");

            testCase.verifyTrue(preview.available, ...
                "A FOV with no selected cell still has geometry.");
            testCase.verifyNumElements(preview.blue,2);
        end

        function twoPhotonSpiralsAreDrawnForEveryCellToo(testCase)
            controller=testCase.configuredController();
            controller.setPlanParameter("mode","2p_spiral");
            controller.setCellEligibility("cell_002","StimulationEnabled",false);

            preview=controller.spatialPreview("2p_spiral");

            testCase.verifyTrue(preview.available);
            testCase.verifyEqual(sort(testCase.cellIds(preview.spiral)), ...
                ["cell_001";"cell_002"]);
        end

        % ---------------------------------------------------------------
        % B. Orange follows Record, and says so
        % ---------------------------------------------------------------
        function orangeGeometryDoesNotFollowStim(testCase)
            controller=testCase.configuredController();
            controller.setCellEligibility("cell_002","StimulationEnabled",false);

            preview=controller.spatialPreview("1p_dmd");

            testCase.verifyEqual(sort(testCase.cellIds(preview.orange)), ...
                ["cell_001";"cell_002"], ...
                "Orange is the recording channel and never reads Stim.");
        end

        function eachOutlineCarriesItsOwnDecisions(testCase)
            % Selection is reported WITH the geometry, so a view can show
            % which cells are selected without geometry being the thing
            % that disappears.
            controller=testCase.configuredController();
            controller.setCellEligibility("cell_002","StimulationEnabled",false);
            controller.setCellEligibility("cell_001","RecordingEnabled",false);

            preview=controller.spatialPreview("1p_dmd");

            testCase.verifyFalse(testCase.flagFor(preview.blue,"cell_002", ...
                "stimulation_enabled"));
            testCase.verifyTrue(testCase.flagFor(preview.blue,"cell_001", ...
                "stimulation_enabled"));
            testCase.verifyFalse(testCase.flagFor(preview.orange,"cell_001", ...
                "recording_enabled"));
            testCase.verifyTrue(testCase.flagFor(preview.orange,"cell_002", ...
                "recording_enabled"));
        end

        function theRecordEnabledSetMatchesTheOrangeExecutionMask(testCase)
            % What the preview says is recorded must be what the Orange DMD
            % would actually illuminate. build_target_bundle gates
            % orange_combined_mask on recording_enabled; the preview's flags
            % must agree with it.
            controller=testCase.configuredController();
            controller.setCellEligibility("cell_001","RecordingEnabled",false);

            preview=controller.spatialPreview("1p_dmd");
            [~,targets]=controller.buildSpatialArtifacts();

            previewRecorded=sort(arrayfun(@(o)string(o.cell_id), ...
                preview.orange(logical([preview.orange.recording_enabled]))));
            executionRecorded=sort(string({targets.targets( ...
                logical([targets.targets.recording_enabled])).cell_id}))';
            testCase.verifyEqual(previewRecorded,executionRecorded);
        end

        % ---------------------------------------------------------------
        % C. It does not build an execution plan, and changes nothing
        % ---------------------------------------------------------------
        function previewingDoesNotPrepareAPlan(testCase)
            controller=testCase.configuredController();

            controller.spatialPreview("1p_dmd");

            testCase.verifyEmpty(controller.ActiveRunPlan, ...
                "A preview must not leave a prepared plan behind.");
            testCase.verifyEqual(controller.planStatus(),"update_required");
        end

        function previewingChangesNothingObservable(testCase)
            controller=testCase.configuredController();
            before=controller.getState();

            controller.spatialPreview("1p_dmd");
            controller.spatialPreview("2p_spiral");

            after=controller.getState();
            testCase.verifyEqual(after.revision,before.revision);
            testCase.verifyEqual(after.scanner_warning,before.scanner_warning, ...
                "ScannerWarning is restored: a preview is not a measurement.");
        end

        function theReplyNamesTheReferenceItDescribes(testCase)
            controller=testCase.configuredController();
            preview=controller.spatialPreview("1p_dmd");
            testCase.verifyEqual(preview.reference_revision, ...
                controller.getState().fov.reference_revision);
            testCase.verifyEqual(preview.source,"fov_geometry");
        end

        % ---------------------------------------------------------------
        % D. Uncommitted spatial values may be previewed without committing
        % ---------------------------------------------------------------
        function anOverrideChangesTheGeometryAndCommitsNothing(testCase)
            controller=testCase.configuredController();
            committed=controller.PlanParameters.blue_mask_adjustment_pixels;
            plain=controller.spatialPreview("1p_dmd");

            widened=controller.spatialPreview("1p_dmd", ...
                "SpatialOverrides",struct("blue_mask_adjustment_pixels",3));

            testCase.verifyNotEqual( ...
                sum([widened.blue.pixel_count]),sum([plain.blue.pixel_count]), ...
                "A different mask adjustment must produce different masks.");
            testCase.verifyEqual( ...
                controller.PlanParameters.blue_mask_adjustment_pixels,committed, ...
                "Previewing a draft value must not commit it.");
        end

        function anOverrideOfSomethingUnspatialIsIgnored(testCase)
            % A read-only preview is not a second way to set a parameter.
            controller=testCase.configuredController();
            before=controller.PlanParameters.repeat_batch_count;

            controller.spatialPreview("1p_dmd", ...
                "SpatialOverrides",struct("repeat_batch_count",99));

            testCase.verifyEqual(controller.PlanParameters.repeat_batch_count, ...
                before);
        end
    end

    % -------------------------------------------------------------------
    methods (Access=private)
        function ids=cellIds(~,outlines)
            if isempty(outlines), ids=strings(0,1); return; end
            ids=reshape(arrayfun(@(o)string(o.cell_id),outlines),[],1);
        end

        function value=flagFor(testCase,outlines,cellId,name)
            ids=testCase.cellIds(outlines);
            index=find(ids==cellId,1);
            testCase.assertNotEmpty(index, ...
                sprintf("No outline for %s.",cellId));
            value=logical(outlines(index).(name));
        end

        function controller=controllerWithoutProtocol(testCase)
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
                "RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
            controller.setReferenceData(testCase.referenceImage(), ...
                testCase.referenceInfo(),testCase.somaPolygons());
            controller.setPlanParameter("mode","1p_dmd");
        end

        function controller=configuredController(testCase)
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
                "RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
            controller.setReferenceData(testCase.referenceImage(), ...
                testCase.referenceInfo(),testCase.somaPolygons());
            controller.setPlanParameter("mode","1p_dmd");
            controller.setProtocol(testCase.protocol());
        end

        function image=referenceImage(~)
            image=uint16(reshape(mod(1:80*100,4096),80,100));
        end

        function polygons=somaPolygons(~)
            polygons={[25 25; 40 25; 40 40; 25 40], ...
                [60 40; 75 40; 75 55; 60 55]};
        end

        function info=referenceInfo(testCase)
            camera=struct("name","Orca Fusion","ROI",[0 0 100 80],"bin",1, ...
                "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
            root=testCase.temporaryFolder();
            info=struct("snapshot_name","spatial_preview_test", ...
                "snapshot_directory",string(root), ...
                "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
                "metadata",struct("rig_name","Virtual_Upright", ...
                    "voltage_camera",camera));
        end

        function value=protocol(~)
            value=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
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
