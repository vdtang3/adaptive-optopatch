classdef TestConnectivitySchedulerResolution < matlab.unittest.TestCase
    %TESTCONNECTIVITYSCHEDULERRESOLUTION A design, realized against a FOV.
    %   A connectivity definition names no cell. It says HOW its schedule is
    %   built; resolve_protocol builds it, once, against whichever cells are
    %   Stim-enabled when Update plan is pressed; and the literal event table
    %   that comes out is what is frozen, archived and executed.
    %
    %   Three things used to be one thing:
    %
    %     WHICH CELLS   the Stim checkboxes, read at Update plan
    %     THE DESIGN    the saved experiment definition
    %     WHAT RAN      the frozen resolved acquisitions
    %
    %   These tests are about the seams between them.

    methods (Test)
        % ---------------------------------------------------------------
        % A. The definition is independent of any field of view
        % ---------------------------------------------------------------
        function aDefinitionCarriesNoCellIdAnywhere(testCase)
            protocol=testCase.definition();
            text=formattedDisplayText(protocol);
            testCase.verifyEmpty(regexp(text,'cell_\d{3}',"once"), ...
                "A connectivity definition must name no FOV cell.");
            for k=1:numel(protocol.acquisitions)
                columns=string( ...
                    protocol.acquisitions(k).events.Properties.VariableNames);
                testCase.verifyFalse(ismember("target_cell_id",columns));
            end
        end

        function aDefinitionSavesAndLoadsWithoutAnyFov(testCase)
            % No controller, no Luminos, no reference image.
            path=fullfile(testCase.temporaryFolder(),"connectivity.mat");
            adaptive_optopatch.save_protocol(path,testCase.definition());
            reloaded=adaptive_optopatch.load_protocol(path);
            report=adaptive_optopatch.validate_protocol(reloaded);
            testCase.verifyTrue(report.passed,strjoin(report.issues,newline));
            testCase.verifyEqual( ...
                adaptive_optopatch.acquisition_scheduler_spec( ...
                    reloaded.acquisitions(1)).pulses_per_cell,4);
        end

        % ---------------------------------------------------------------
        % B. The Stim checkboxes choose the targets, at Update plan
        % ---------------------------------------------------------------
        function everyChunkSchedulesExactlyTheSelectedCells(testCase)
            resolved=testCase.resolve(["cell_001","cell_002","cell_003"]);

            testCase.verifyNumElements(resolved,2);
            for k=1:numel(resolved)
                events=resolved{k}.events;
                testCase.verifyEqual( ...
                    sort(unique(events.target_cell_id)), ...
                    ["cell_001";"cell_002";"cell_003"]);
            end
        end

        function changingTheStimSelectionChangesTheTargetsWithNoRegeneration(testCase)
            % ONE saved definition, two different selections.
            definition=testCase.definition();
            three=testCase.resolveDefinition(definition, ...
                ["cell_001","cell_002","cell_003"]);
            two=testCase.resolveDefinition(definition,["cell_002","cell_003"]);

            testCase.verifyEqual(sort(unique(three{1}.events.target_cell_id)), ...
                ["cell_001";"cell_002";"cell_003"]);
            testCase.verifyEqual(sort(unique(two{1}.events.target_cell_id)), ...
                ["cell_002";"cell_003"]);
            % The definition was never rewritten between the two.
            testCase.verifyEqual(definition,testCase.definition(), ...
                "Resolution must not mutate the definition.");
        end

        function eachSelectedCellGetsExactlyItsQuota(testCase)
            resolved=testCase.resolve(["cell_001","cell_002","cell_003"]);
            for k=1:numel(resolved)
                events=resolved{k}.events;
                testCase.verifyEqual(height(events),3*4, ...
                    "target_count * pulses_per_cell_per_chunk");
                for cellId=["cell_001","cell_002","cell_003"]
                    testCase.verifyEqual(sum(events.target_cell_id==cellId),4, ...
                        sprintf("%s did not receive its quota.",cellId));
                end
            end
        end

        % ---------------------------------------------------------------
        % C. Determinism
        % ---------------------------------------------------------------
        function theSameDefinitionAndSelectionGiveTheSameSchedule(testCase)
            first=testCase.resolve(["cell_001","cell_002","cell_003"]);
            second=testCase.resolve(["cell_001","cell_002","cell_003"]);
            for k=1:numel(first)
                testCase.verifyEqual(first{k}.events.target_cell_id, ...
                    second{k}.events.target_cell_id);
                testCase.verifyEqual(first{k}.events.onset_s, ...
                    second{k}.events.onset_s,"AbsTol",1e-12);
            end
        end

        function differentChunkSeedsGiveDifferentOrders(testCase)
            resolved=testCase.resolve(["cell_001","cell_002","cell_003"]);
            testCase.verifyNotEqual(resolved{1}.events.target_cell_id, ...
                resolved{2}.events.target_cell_id, ...
                "Chunk 2 uses BaseRandomSeed+1 and should order differently.");
        end

        function theStoredSeedIsWhatIsUsed(testCase)
            resolved=testCase.resolve(["cell_001","cell_002","cell_003"]);
            for k=1:numel(resolved)
                testCase.verifyEqual( ...
                    resolved{k}.scheduler_metadata.random_seed,4242+k-1);
                testCase.verifyEqual( ...
                    resolved{k}.scheduler_metadata.chunk_index,k);
            end
        end

        % ---------------------------------------------------------------
        % D. The realized schedule keeps every scheduler invariant
        % ---------------------------------------------------------------
        function theRealizedScheduleKeepsItsTimingContract(testCase)
            resolved=testCase.resolve(["cell_001","cell_002","cell_003"]);
            for k=1:numel(resolved)
                events=resolved{k}.events;
                % 3: every pulse is the configured duration.
                testCase.verifyEqual(events.duration_s, ...
                    0.010*ones(height(events),1),"AbsTol",1e-12);
                % 7: the pre-delay is respected.
                testCase.verifyEqual(min(events.onset_s),0.100,"AbsTol",1e-12);
                % 4/6: cadence is the preferred one, and idle time appears
                % only where nothing was eligible - never shorter.
                spacing=diff(sort(events.onset_s));
                testCase.verifyGreaterThanOrEqual(spacing,0.020-1e-9);
                % 5: a cell is never revisited before its pulse has ended
                % plus the recovery gap. 10 ms + 100 ms = 110 ms.
                for cellId=unique(events.target_cell_id)'
                    onsets=sort(events.onset_s(events.target_cell_id==cellId));
                    if numel(onsets)<2, continue; end
                    testCase.verifyGreaterThanOrEqual(diff(onsets),0.110-1e-9, ...
                        sprintf("%s was revisited too soon.",cellId));
                end
            end
        end

        function thePostDelayIsIncludedInTheAcquisitionDuration(testCase)
            resolved=testCase.resolve(["cell_001","cell_002","cell_003"]);
            events=resolved{1}.events;
            testCase.verifyEqual(resolved{1}.acquisition_duration_s, ...
                max(events.offset_s)+0.100,"AbsTol",1e-9);
        end

        % ---------------------------------------------------------------
        % E. FLUT capacity, against the count that actually matters
        % ---------------------------------------------------------------
        function anOversizedSelectionFailsAtUpdatePlanNotAtRun(testCase)
            % The definition itself is fine; this field of view is too big
            % for the requested chunk. It has to fail while there is still
            % something to do about it.
            definition=adaptive_optopatch.generate_connectivity_chunked_protocol( ...
                "TotalPulsesPerCell",8000,"PulsesPerCellPerChunk",4000, ...
                "BaseRandomSeed",4242);
            failure=testCase.captureError(@() ...
                testCase.resolveDefinition(definition, ...
                    ["cell_001","cell_002","cell_003"]));
            testCase.verifyEqual(string(failure.identifier), ...
                "adaptive_optopatch:ConnectivityChunkExceedsFlutCapacity");
            testCase.verifySubstring(failure.message,"3 selected cells");
            testCase.verifySubstring(failure.message,"pulses_per_cell_per_chunk");
        end

        function acapacityCheckThatPassesRecordsWhatItChecked(testCase)
            resolved=testCase.resolve(["cell_001","cell_002"]);
            flut=resolved{1}.scheduler_metadata.flut;
            testCase.verifyEqual(flut.event_count,2*4);
            testCase.verifyEqual(flut.unique_mask_upper_bound,2);
            testCase.verifyTrue(flut.playlist_capacity>=flut.event_count);
        end

        % ---------------------------------------------------------------
        % F. Per-cell Blue voltage
        % ---------------------------------------------------------------
        function everyEventTakesItsOwnTargetsBlueVoltage(testCase)
            voltages=struct("cell_001",1.2,"cell_002",1.5,"cell_003",1.8);
            resolved=testCase.resolve(["cell_001","cell_002","cell_003"], ...
                "Voltages",voltages);
            for k=1:numel(resolved)
                events=resolved{k}.events;
                for cellId=["cell_001","cell_002","cell_003"]
                    selected=events.target_cell_id==cellId;
                    testCase.verifyEqual( ...
                        unique(events.command_voltage_v(selected)), ...
                        voltages.(cellId),"AbsTol",1e-12, ...
                        sprintf("%s received the wrong voltage.",cellId));
                end
                testCase.verifyTrue(all(events.command_voltage_source=="fov_cell"));
            end
        end

        function anUncalibratedCellIsNamedInTheFailure(testCase)
            voltages=struct("cell_001",1.2,"cell_003",1.8); % cell_002 missing
            failure=testCase.captureError(@() ...
                testCase.resolve(["cell_001","cell_002","cell_003"], ...
                    "Voltages",voltages));
            testCase.verifyEqual(string(failure.identifier), ...
                "adaptive_optopatch:UnresolvedProtocolParameter");
            testCase.verifySubstring(failure.message,"cell_002", ...
                "The failure must name the cell that is missing a Blue V.");
            testCase.verifySubstring(failure.message,"Blue");
        end

        function anExplicitProtocolVoltageStillOverridesTheCalibration(testCase)
            definition=testCase.definition("CommandVoltageV",2.5);
            voltages=struct("cell_001",1.2,"cell_002",1.5,"cell_003",1.8);
            resolved=testCase.resolveDefinition(definition, ...
                ["cell_001","cell_002","cell_003"],"Voltages",voltages);
            events=resolved{1}.events;
            testCase.verifyEqual(unique(events.command_voltage_v),2.5, ...
                "AbsTol",1e-12);
            testCase.verifyTrue(all(events.command_voltage_source=="event"));
        end

        % ---------------------------------------------------------------
        % G. The realized schedule is frozen, and the runner never reschedules
        % ---------------------------------------------------------------
        function updatePlanFreezesTheRealizedScheduleAndKeepsTheDesign(testCase)
            controller=testCase.controllerWithConnectivity();
            controller.updatePlan();
            plan=controller.ActiveRunPlan;

            % The definition that travels with the plan still names no cell.
            definitionText=formattedDisplayText(plan.protocol_definition);
            testCase.verifyEmpty(regexp(definitionText,'cell_\d{3}',"once"), ...
                "The archived definition must stay FOV-independent.");

            % The resolved acquisitions are literal.
            for k=1:numel(plan.resolved_protocols)
                events=plan.resolved_protocols{k}.events;
                testCase.verifyTrue(all(strlength(events.target_cell_id)>0));
                testCase.verifyTrue(all(isfinite(events.onset_s)));
            end
            % And so is what the manifest will execute.
            schedule=plan.manifest.trials.pulse_schedule{1};
            testCase.verifyEqual(schedule.events.target_cell_id, ...
                plan.resolved_protocols{1}.events.target_cell_id);
        end

        function rerunningThePreparedPlanReusesTheIdenticalSchedule(testCase)
            controller=testCase.controllerWithConnectivity();
            controller.updatePlan();
            before=controller.ActiveRunPlan.manifest.trials.pulse_schedule{1}.events;

            controller.runPreparedPlan();
            controller.runPreparedPlan(); % a second batch of the same plan

            after=controller.ActiveRunPlan.manifest.trials.pulse_schedule{1}.events;
            testCase.verifyEqual(after.target_cell_id,before.target_cell_id, ...
                "Running must not reschedule anything.");
            testCase.verifyEqual(after.onset_s,before.onset_s,"AbsTol",1e-12);
        end

        % ---------------------------------------------------------------
        % H. Old explicit schedules are untouched
        % ---------------------------------------------------------------
        function anExplicitScheduleStillResolvesLiterally(testCase)
            % The pre-change artifact shape: realized events with literal
            % targets and finite onsets. It must keep executing exactly as
            % it did, and must NOT be reinterpreted as a scheduler spec.
            definition=testCase.legacyExplicitDefinition();
            resolved=testCase.resolveDefinition(definition, ...
                ["cell_001","cell_002"]);

            events=resolved{1}.events;
            testCase.verifyEqual(events.target_cell_id, ...
                ["cell_001";"cell_002";"cell_001"]);
            testCase.verifyEqual(events.onset_s,[0.1;0.2;0.3],"AbsTol",1e-12);
            testCase.verifyFalse(isfield(resolved{1},"scheduler_metadata"), ...
                "An explicit schedule has no scheduler provenance.");
        end

        function anExplicitScheduleIsNotMistakenForASchedulerSpec(testCase)
            definition=testCase.legacyExplicitDefinition();
            testCase.verifyEmpty( ...
                adaptive_optopatch.acquisition_scheduler_spec( ...
                    definition.acquisitions(1)));
        end

        % ---------------------------------------------------------------
        % I. The summary describes the design honestly
        % ---------------------------------------------------------------
        function theSummaryDoesNotReportTheTemplateAsTheExperiment(testCase)
            summary=adaptive_optopatch.summarize_protocol(testCase.definition());
            testCase.verifyEqual(summary.scheduled_acquisition_count,2);
            testCase.verifyTrue(summary.targets_resolved_at_update_plan);
            testCase.verifyEqual(summary.pulses_per_selected_cell,8);
            testCase.verifyEqual(summary.event_count,0, ...
                "A template event is not an executed pulse.");
            testCase.verifyEqual(summary.definition_acquisition_count,2);
        end

        function anOrdinaryProtocolSummaryIsUnchanged(testCase)
            summary=adaptive_optopatch.summarize_protocol( ...
                testCase.legacyExplicitDefinition());
            testCase.verifyEqual(summary.scheduled_acquisition_count,0);
            testCase.verifyFalse(summary.targets_resolved_at_update_plan);
            testCase.verifyEqual(summary.event_count,3);
        end
    end

    % -------------------------------------------------------------------
    methods (Access=private)
        function failure=captureError(testCase,fcn)
            %CAPTUREERROR The exception a call threw, for asserting its text.
            %   verifyError checks the identifier but does not hand back the
            %   exception, and what these tests are about is whether the
            %   message tells the experimenter which cell to fix.
            failure=MException.empty;
            try
                fcn();
            catch caught
                failure=caught;
            end
            testCase.assertNotEmpty(failure,"Expected this call to fail.");
        end

        function protocol=definition(~,varargin)
            %DEFINITION A small connectivity design: 2 chunks, 4 pulses/cell.
            protocol=adaptive_optopatch.generate_connectivity_chunked_protocol( ...
                "TotalPulsesPerCell",8,"PulsesPerCellPerChunk",4, ...
                "BaseRandomSeed",4242,varargin{:});
        end

        function protocol=legacyExplicitDefinition(~)
            %LEGACYEXPLICITDEFINITION A pre-change explicit multi-target chunk.
            pulse_id=(1:3)';
            condition_id=repmat("legacy_chunk",3,1);
            stimulation_source=repmat("1p_dmd",3,1);
            target_cell_id=["cell_001";"cell_002";"cell_001"];
            onset_s=[0.1;0.2;0.3];
            duration_s=repmat(0.010,3,1);
            is_null=false(3,1);
            command_voltage_v=repmat(1.4,3,1);
            blue_mask_adjustment_pixels=NaN(3,1);
            events=table(pulse_id,condition_id,stimulation_source, ...
                target_cell_id,onset_s,duration_s,is_null,command_voltage_v, ...
                blue_mask_adjustment_pixels);
            acquisition=struct("acquisition_id","legacy_chunk","events",events, ...
                "parameters",struct,"event_order_realized",true, ...
                "target_repetitions",1,"post_delay_s",0.1);
            protocol=struct("schema_version","4.0.0", ...
                "artifact_type","experiment_definition", ...
                "protocol_id","legacy_explicit_connectivity", ...
                "protocol_type","connectivity_round_robin", ...
                "target_policy","multi_target_continuous", ...
                "event_order","randomized","random_seed",11, ...
                "parameter_sources",struct("command_voltage_v", ...
                    ["event","acquisition","protocol","fov_cell"]), ...
                "parameters",struct,"acquisitions",acquisition);
            protocol=adaptive_optopatch.normalize_protocol(protocol);
        end

        function resolved=resolve(testCase,selected,varargin)
            resolved=testCase.resolveDefinition(testCase.definition(), ...
                selected,varargin{:});
        end

        function resolved=resolveDefinition(testCase,definition,selected,options)
            arguments
                testCase
                definition
                selected string
                options.Voltages struct = struct()
            end
            [fovState,targets]=testCase.fovWith(selected,options.Voltages);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,AoFixtures.guiDefaults());
        end

        function [fovState,targets]=fovWith(~,selected,voltages)
            %FOVWITH The shared three-cell FOV, with a given Stim selection.
            if nargin<3, voltages=struct(); end
            [fovState,~]=AoFixtures.fovState();
            for k=1:numel(fovState.cells)
                cellId=string(fovState.cells(k).cell_id);
                fovState.cells(k).stimulation_enabled=any(selected==cellId);
                if isfield(voltages,cellId)
                    fovState.cells(k).selected_blue_voltage_v=voltages.(cellId);
                else
                    fovState.cells(k).selected_blue_voltage_v=1.4;
                end
            end
            % A cell with no entry at all, for the missing-calibration test.
            missing=setdiff(selected,string(fieldnames(voltages))');
            if ~isempty(fieldnames(voltages))
                for cellId=reshape(missing,1,[])
                    index=find(string({fovState.cells.cell_id})==cellId,1);
                    fovState.cells(index).selected_blue_voltage_v=NaN;
                end
            end
            fovState.reference.cells=fovState.cells;
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
        end

        function controller=controllerWithConnectivity(testCase)
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
                "RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
            image=uint16(reshape(mod(1:80*100,4096),80,100));
            camera=struct("name","Orca Fusion","ROI",[0 0 100 80],"bin",1, ...
                "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
            root=testCase.temporaryFolder();
            info=struct("snapshot_name","connectivity_test", ...
                "snapshot_directory",string(root), ...
                "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
                "metadata",struct("rig_name","Virtual_Upright", ...
                    "voltage_camera",camera));
            controller.setReferenceData(image,info, ...
                {[25 25; 40 25; 40 40; 25 40],[60 40; 75 40; 75 55; 60 55]});
            controller.setPlanParameter("mode","1p_dmd");
            for cellId=["cell_001","cell_002"]
                controller.setCellBlueVoltage(cellId,1.4);
            end
            controller.setProtocol(testCase.definition());
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
