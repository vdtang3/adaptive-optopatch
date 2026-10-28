classdef TestBlanketDepolarization < matlab.unittest.TestCase
    %TESTBLANKETDEPOLARIZATION Blanket-mode round robin, before any rig use.
    %   One sample-exact state table drives the wrapping FLUT playlist, the
    %   DMD trigger line and mod488. These tests compile the real waveform
    %   records to samples (the independent Luminos transcription in
    %   compile_wfm_data_to_samples), walk the DMD through the wrapped
    %   playlist one trigger edge at a time, and check every sample of
    %   mod488 against the mask the DMD is showing.
    properties
        OutputRoot string
    end

    methods (TestMethodSetup)
        function makeOutputRoot(testCase)
            testCase.OutputRoot=string(tempname);
            mkdir(testCase.OutputRoot);
            testCase.addTeardown(@()rmdir(testCase.OutputRoot,"s"));
        end
    end

    methods (Test)
        % ---------------------------------------------------------------
        % Off by default, and off means unchanged
        % ---------------------------------------------------------------

        function protocolsWithoutTheBlockAreUntouched(testCase)
            [~,protocol]=flut_fixture(3,repmat((1:3)',4,1));
            testCase.verifyFalse(isfield(protocol,"blanket_depolarization"));
            testCase.verifyFalse( ...
                adaptive_optopatch.blanket_depolarization_spec(protocol).enabled);
        end

        function disabledBlockGivesIdenticalPlanAndWaveforms(testCase)
            [targets,protocol]=flut_fixture(3,repmat((1:3)',4,1));
            disabled=protocol;
            disabled.blanket_depolarization=struct("enabled",false);
            disabled=adaptive_optopatch.normalize_protocol(disabled);
            testCase.verifyFalse(disabled.blanket_depolarization.enabled);

            planA=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            planB=adaptive_optopatch.build_dmd_sequence_plan(disabled,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            testCase.verifyEqual(planB,planA);
            [propsA,wfmA,summaryA]=waveforms(protocol,planA);
            [propsB,wfmB,summaryB]=waveforms(disabled,planB);
            testCase.verifyEqual(propsB,propsA);
            testCase.verifyEqual(wfmB,wfmA);
            testCase.verifyEqual(summaryB.pulses,summaryA.pulses);
            testCase.verifyFalse(isfield(summaryB,"blanket_depolarization"));
        end

        % ---------------------------------------------------------------
        % State expansion, in samples derived from the clock
        % ---------------------------------------------------------------

        function twentyMsEpochIsTwentyCyclesOfFortyStates(testCase)
            protocol=resolved_blanket(testCase,3,2);
            table=adaptive_optopatch.build_blanket_state_table(protocol,200000,0.001);
            epoch=table.states(table.states.position_in_round==1 & ...
                table.states.segment=="epoch",:);
            testCase.verifyEqual(height(epoch),40);
            testCase.verifyEqual(max(epoch.cycle_in_segment),20);
            testCase.verifyEqual(epoch.state_type, ...
                repmat(["blanket";"target"],20,1));
            testCase.verifyEqual(sum(epoch.duration_samples)/200000,0.020, ...
                "AbsTol",1e-12);
        end

        function tenMsGapIsTenBlanketDarkCycles(testCase)
            protocol=resolved_blanket(testCase,3,2);
            table=adaptive_optopatch.build_blanket_state_table(protocol,200000,0.001);
            gap=table.states(table.states.position_in_round==2 & ...
                table.states.segment=="gap",:);
            testCase.verifyEqual(height(gap),20);
            testCase.verifyEqual(gap.state_type,repmat(["blanket";"dark"],10,1));
            testCase.verifyEqual(gap.mod488_v(gap.state_type=="dark"),zeros(10,1));
            testCase.verifyEqual(gap.mask_key(gap.state_type=="dark"), ...
                repmat("blank",10,1));
        end

        function stateDurationsComeFromTheClock(testCase)
            protocol=resolved_blanket(testCase,2,1);
            at200=adaptive_optopatch.build_blanket_state_table(protocol,200000,0.001);
            testCase.verifyEqual(at200.blanket_samples,40);
            testCase.verifyEqual(at200.target_samples,160);
            testCase.verifyEqual(at200.target_onset_guard_samples,10);
            testCase.verifyEqual(at200.cycle_samples,200);
            at100=adaptive_optopatch.build_blanket_state_table(protocol,100000,0.001);
            testCase.verifyEqual([at100.blanket_samples at100.target_samples ...
                at100.target_onset_guard_samples],[20 80 5]);
        end

        function representativeTenCellRoundIsSixHundredStates(testCase)
            protocol=resolved_blanket(testCase,10,1);
            [targets]=fov_targets(10);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            testCase.verifyEqual(plan.programmed_playlist_length,600);
            testCase.verifyEqual(plan.unique_mask_count,12);
            testCase.verifyTrue(plan.playlist_wraps);
            testCase.verifyEqual(plan.expected_trigger_count,600);
            testCase.verifyEqual(plan.state_table.round_samples,0.300*200000);
        end

        % ---------------------------------------------------------------
        % DMD and mod488 agree on every sample, across the wrap
        % ---------------------------------------------------------------

        function everyStateDeliversItsVoltageThroughItsMask(testCase)
            [protocol,targets]=resolved_blanket(testCase,3,3);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            [props,wfm]=waveforms(protocol,plan);
            [mod488,trigger]=compiled_lines(props,wfm);
            delivered=walk_wrapped_playlist(plan,mod488,trigger,0);

            blanketV=protocol.blanket_depolarization.mod488_v;
            testCase.verifyEqual(numel(delivered.slot),plan.expected_trigger_count);
            for k=1:numel(delivered.slot)
                key=plan.slot_mask_keys(delivered.slot(k));
                level=delivered.levels{k};
                switch key
                    case "blanket"
                        testCase.verifyEqual(unique(level),blanketV);
                    case "blank"
                        testCase.verifyEqual(unique(level),0);
                    otherwise
                        index=double(extractBetween(key,"target:","|"));
                        cellId=targets.targets(index).cell_id;
                        vstim=unique(protocol.events.command_voltage_v( ...
                            protocol.events.target_cell_id==cellId));
                        guard=plan.state_table.target_onset_guard_samples;
                        testCase.verifyEqual(level(1:guard),zeros(1,guard));
                        testCase.verifyEqual(unique(level(guard+1:end)),vstim);
                end
            end
        end

        function wrappedPlaylistReproducesEveryRoundsMasks(testCase)
            [protocol,targets]=resolved_blanket(testCase,3,3);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            [props,wfm]=waveforms(protocol,plan);
            [~,trigger]=compiled_lines(props,wfm);
            edges=rising_edges(trigger);
            L=plan.programmed_playlist_length;
            slots=plan.programmed_playlist_slots(mod((1:numel(edges))'-1,L)+1);
            % Independently of the state table: what should the DMD show at
            % each edge, from the logical epochs alone?
            rate=200000; cycle=200; blanket=40;
            events=sortrows(protocol.events,"onset_s");
            onsets=round(events.onset_s*rate); offsets=round(events.offset_s*rate);
            for k=1:numel(edges)
                sample=edges(k)-1;
                inBlanketPhase=mod(sample,cycle)<blanket;
                epoch=find(onsets<=sample & sample<offsets,1);
                if inBlanketPhase
                    expected="blanket";
                elseif isempty(epoch)
                    expected="blank";
                else
                    expected="target:"+string(events.target_index(epoch))+"|"+ ...
                        string(events.blue_mask_adjustment_pixels(epoch));
                end
                shown=split(plan.slot_mask_keys(slots(k)),",");
                testCase.verifyTrue(any(shown==expected), ...
                    sprintf("edge %d (sample %d)",k,sample));
            end
        end

        function triggerEdgesEqualExpectedAdvances(testCase)
            [protocol,targets]=resolved_blanket(testCase,3,4);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            [props,wfm]=waveforms(protocol,plan);
            [mod488,trigger]=compiled_lines(props,wfm);
            edges=rising_edges(trigger);
            testCase.verifyEqual(numel(edges),plan.expected_trigger_count);
            testCase.verifyEqual(plan.expected_trigger_count, ...
                plan.programmed_playlist_length*plan.round_count);
            % Every mod488 level change happens on a trigger sample or a
            % guard end, never between.
            changes=find(diff(mod488)~=0)+1;
            guardEnds=edges+plan.state_table.target_onset_guard_samples;
            testCase.verifyEmpty(setdiff(changes,[edges guardEnds ...
                plan.state_table.final_sample+1]));
            % Light only inside complete rounds.
            first=plan.state_table.round_start_sample+1;
            last=plan.state_table.final_sample;
            testCase.verifyEqual(mod488([1:first-1 last+1:end]), ...
                zeros(1,numel(mod488)-(last-first+1)));
        end

        % ---------------------------------------------------------------
        % Camera alignment
        % ---------------------------------------------------------------

        function cyclesAndEpochsStartOnCameraFrames(testCase)
            [protocol,targets]=resolved_blanket(testCase,3,2);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            table=plan.state_table; frame=table.camera_frame_samples;
            starts=table.round_start_sample+table.states.start_sample;
            testCase.verifyEqual(mod(starts(table.states.state_type=="blanket"),frame), ...
                zeros(sum(table.states.state_type=="blanket"),1));
            testCase.verifyEqual(mod(round(protocol.events.onset_s*200000),frame), ...
                zeros(height(protocol.events),1));
            testCase.verifyError(@()adaptive_optopatch.build_blanket_state_table( ...
                protocol,200000,0.0005),"adaptive_optopatch:BlanketCycleNotCameraFrame");
            testCase.verifyError(@()adaptive_optopatch.build_blanket_state_table( ...
                protocol,199999,0.001),"adaptive_optopatch:BlanketTimingNotWholeSamples");
            testCase.verifyError(@()adaptive_optopatch.build_blanket_state_table( ...
                protocol,200000,NaN),"adaptive_optopatch:BlanketCameraPeriodRequired");
        end

        % ---------------------------------------------------------------
        % Whole rounds, whole cycles, capacity
        % ---------------------------------------------------------------

        function editedEventsNoLongerFormWholeRounds(testCase)
            protocol=resolved_blanket(testCase,3,2);
            truncated=protocol;
            truncated.events=truncated.events(1:end-1,:);
            testCase.verifyError(@()adaptive_optopatch.build_blanket_state_table( ...
                truncated,200000,0.001),"adaptive_optopatch:BlanketEventsNotWholeRounds");
            shifted=protocol;
            shifted.events.onset_s(4)=shifted.events.onset_s(4)+0.001;
            testCase.verifyError(@()adaptive_optopatch.build_blanket_state_table( ...
                shifted,200000,0.001),"adaptive_optopatch:BlanketEventsNotWholeRounds");
            revoltaged=protocol;
            revoltaged.events.command_voltage_v(4)=4.9;
            testCase.verifyError(@()adaptive_optopatch.build_blanket_state_table( ...
                revoltaged,200000,0.001),"adaptive_optopatch:BlanketEventsNotWholeRounds");
        end

        function timingMustBeWholeCycles(testCase)
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                "BlanketMod488V",1,"InterEpochGapS",0.0105), ...
                "adaptive_optopatch:BlanketTimingNotWholeCycles");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                "BlanketMod488V",1,"EpochDurationS",0.0205), ...
                "adaptive_optopatch:BlanketTimingNotWholeCycles");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                "BlanketMod488V",1,"PreDelayS",0.1003), ...
                "adaptive_optopatch:BlanketTimingNotWholeCycles");
        end

        function acquisitionIsWholeRoundsPlusDelays(testCase)
            protocol=resolved_blanket(testCase,3,5);
            realized=protocol.blanket_depolarization.round;
            testCase.verifyEqual(height(protocol.events),3*5);
            testCase.verifyEqual(protocol.acquisition_duration_s, ...
                realized.start_s+5*realized.period_s+0.1,"AbsTol",1e-12);
            testCase.verifyEqual(realized.cell_ids,["cell_001";"cell_002";"cell_003"]);
        end

        function oneRoundTooLongForTheFlutIsRefused(testCase)
            [reference,fov,targets,gui]=blanket_fov(3);
            definition=adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                "BlanketMod488V",1,"Rounds",1,"EpochDurationS",1.0);
            testCase.verifyError(@()adaptive_optopatch.build_manifest(reference, ...
                targets,definition,"Mode","1p_dmd","FovState",fov,"GuiDefaults",gui), ...
                "adaptive_optopatch:BlanketRoundExceedsFlutCapacity");
            protocol=resolved_blanket(testCase,3,2);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            dmd=simulated_dmd(targets.reference_camera);
            dmd.flut_max_entries=plan.programmed_playlist_length-1;
            testCase.verifyError(@()adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",true),"adaptive_optopatch:FlutPlaylistTooLong");
        end

        function onlyOneRoundIsProgrammedAndMasksAreDeduplicated(testCase)
            [protocol,targets]=resolved_blanket(testCase,3,50);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            dmd=simulated_dmd(targets.reference_camera);
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            testCase.verifyEqual(numel(dmd.playlist),180);
            testCase.verifyEqual(dmd.slot_write_count,5);
            testCase.verifyEqual(sort(plan.slot_mask_keys), ...
                sort(["blank";"blanket";"target:1|0";"target:2|0";"target:3|0"]));
            testCase.verifyEqual(dmd.playlist_mode,"slave");
            testCase.verifyEqual(configuration.execution_mode,"flut_playlist");
            testCase.verifyTrue(configuration.dmd_progress_armed.available);
            % The blanket is the union of the Stim-enabled cells' own
            % masks, not the whole field of view: every cell keeps its
            % depolarization through another cell's pulse, and the tissue
            % between them is never lit.
            blanketSlot=slot_for(plan,"blanket");
            blanketMask=plan.unique_camera_masks(:,:,blanketSlot);
            testCase.verifyEqual(blanketMask,cells_union(targets,1:3));
            testCase.verifyLessThan(nnz(blanketMask),numel(blanketMask));
            testCase.verifyEqual(plan.blanket_depolarization.mask.cell_ids, ...
                string({targets.targets.cell_id})');
            testCase.verifyEqual(plan.blanket_depolarization.mask.source, ...
                "stim_enabled_union");
        end

        % ---------------------------------------------------------------
        % Phase slip: what it does, and that it is caught
        % ---------------------------------------------------------------

        function oneStateSlipPutsVstimOnTheBlanketMask(testCase)
            [protocol,targets]=resolved_blanket(testCase,3,2);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            [props,wfm]=waveforms(protocol,plan);
            [mod488,trigger]=compiled_lines(props,wfm);
            blanketV=protocol.blanket_depolarization.mod488_v;
            for slip=[-1 0 1]
                delivered=walk_wrapped_playlist(plan,mod488,trigger,slip);
                onBlanket=delivered.slot==slot_for(plan,"blanket");
                overdrive=cellfun(@(level)sum(level>blanketV),delivered.levels(onBlanket));
                if slip==0
                    testCase.verifyEqual(sum(overdrive),0);
                else
                    % Every target state of every epoch lands on the
                    % full-FOV mask: Vstim over the whole FOV.
                    testCase.verifyGreaterThan(sum(overdrive), ...
                        0.5*height(protocol.events)*20*150);
                end
            end
        end

        function postRunCountCatchesALostOrDoubledEdge(testCase)
            armed=progress(0,180); final=progress(720,180);
            report=adaptive_optopatch.verify_dmd_advance_count(armed,final,720,180);
            testCase.verifyEqual(report.status,"matched");
            for slip=[-1 1]
                final=progress(720+slip,180);
                report=adaptive_optopatch.verify_dmd_advance_count(armed,final,720,180);
                testCase.verifyEqual(report.status,"mismatched");
                testCase.verifyEqual(report.reported_advance_count,720+slip);
            end
            missing=progress(0,180); missing.available=false; missing.detail="none";
            report=adaptive_optopatch.verify_dmd_advance_count(armed,missing,720,180);
            testCase.verifyEqual(report.status,"unavailable");
            testCase.verifyFalse(report.matched);
        end

        function simulatedRunIsValidWhenEveryEdgeLands(testCase)
            [manifest,targets,app]=blanket_run_fixture(testCase,2,3);
            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "Profile",AoFixtures.onePhotonProfile(),"ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "BlankDmdAfterTrial",false,"OutputDirectory",testCase.OutputRoot);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            record=load(fullfile(run.trials.experiment_directory(1), ...
                "output_data.mat"),"adaptive_optopatch_record").adaptive_optopatch_record;
            testCase.verifyEqual(record.blanket_validity,"valid");
            verification=record.dmd_advance_verification;
            testCase.verifyEqual(verification.expected_advance_count,2*60*3);
            testCase.verifyEqual(verification.reported_advance_count,2*60*3);
            testCase.verifyEqual(record.pulse_schedule.blanket_depolarization.mod488_v,1);
        end

        function simulatedRunWithALostEdgeIsInvalidAndStops(testCase)
            [manifest,targets,app]=blanket_run_fixture(testCase,2,3);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            dmd.SimulatedTriggerCountError=-1;
            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"Profile",AoFixtures.onePhotonProfile(),"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"BlankDmdAfterTrial",false, ...
                "OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:DmdAdvanceMismatch");
            folder=app.AcquisitionHistory(end).experiment_directory;
            record=load(fullfile(folder,"output_data.mat"), ...
                "adaptive_optopatch_record").adaptive_optopatch_record;
            testCase.verifyEqual(record.blanket_validity,"invalid_dmd_advance_mismatch");
            testCase.verifyEqual(record.dmd_advance_verification.reported_advance_count, ...
                record.dmd_advance_verification.expected_advance_count-1);
        end

        function runWithoutProgressReadbackIsArchivedUnverified(testCase)
            [manifest,targets,app]=blanket_run_fixture(testCase,2,2);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            dmd.supports_projection_progress=false;
            testCase.verifyWarning(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"Profile",AoFixtures.onePhotonProfile(),"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"BlankDmdAfterTrial",false, ...
                "OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:DmdAdvanceUnverified");
            folder=app.AcquisitionHistory(end).experiment_directory;
            record=load(fullfile(folder,"output_data.mat"), ...
                "adaptive_optopatch_record").adaptive_optopatch_record;
            testCase.verifyEqual(record.blanket_validity,"unverified_dmd_advance_count");
        end

        % ---------------------------------------------------------------
        % Analysis sees one trial per epoch
        % ---------------------------------------------------------------

        function fortyStatesArchiveAsOneLogicalEpoch(testCase)
            [manifest,targets,app]=blanket_run_fixture(testCase,2,3);
            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "Profile",AoFixtures.onePhotonProfile(),"ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "BlankDmdAfterTrial",false,"OutputDirectory",testCase.OutputRoot);
            record=load(fullfile(run.trials.experiment_directory(1), ...
                "output_data.mat"),"adaptive_optopatch_record").adaptive_optopatch_record;
            realized=record.realized_pulses;
            testCase.verifyEqual(height(realized),2*3);
            testCase.verifyEqual(height(record.expected_frame_map),2*3);
            testCase.verifyEqual(unique(realized.duration_s),0.020);
            testCase.verifyEqual(unique(realized.blue_delivery),"blanket_modulated");
            testCase.verifyEqual(unique(realized.target_illumination_s),0.015, ...
                "AbsTol",1e-12);
            testCase.verifyEqual(realized.expected_camera_frame, ...
                round(realized.onset_s*1000)+1);
            % ...while the physical record inside one epoch is 40 states.
            plan=record.waveform_summary.dmd_sequence;
            first=plan.state_table.states(plan.state_table.states.position_in_round==1 & ...
                plan.state_table.states.segment=="epoch",:);
            testCase.verifyEqual(height(first),40);
            testCase.verifyEqual(unique(first.logical_pulse_id),realized.pulse_id(1));
        end

        % ---------------------------------------------------------------
        % Refusals
        % ---------------------------------------------------------------

        function definitionErrors(testCase)
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_round_robin_protocol(), ...
                "adaptive_optopatch:InvalidBlanketDepolarization");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                "BlanketMod488V",1,"BlanketFraction",1), ...
                "adaptive_optopatch:InvalidBlanketDepolarization");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                "BlanketMod488V",1,"BlanketFraction",0), ...
                "adaptive_optopatch:InvalidBlanketDepolarization");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                "BlanketMod488V",1,"TargetOnsetGuardS",0.0008), ...
                "adaptive_optopatch:InvalidBlanketDepolarization");
            definition=adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                "BlanketMod488V",1);
            typo=definition; typo.blanket_depolarization.blanket_fration=0.3;
            testCase.verifyError(@()adaptive_optopatch.normalize_protocol(typo), ...
                "adaptive_optopatch:InvalidBlanketDepolarization");
            orphan=rmfield(definition,"blanket_depolarization");
            testCase.verifyError(@()adaptive_optopatch.normalize_protocol(orphan), ...
                "adaptive_optopatch:BlanketSchedulerWithoutBlanketMode");
            connectivity=adaptive_optopatch.generate_connectivity_chunked_protocol();
            connectivity.blanket_depolarization=definition.blanket_depolarization;
            testCase.verifyError(@()adaptive_optopatch.normalize_protocol(connectivity), ...
                "adaptive_optopatch:InvalidBlanketDepolarization");
        end

        function executionRefusals(testCase)
            [protocol,targets]=resolved_blanket(testCase,2,1);
            testCase.verifyError(@()adaptive_optopatch.build_dmd_sequence_plan( ...
                protocol,targets,"HoldPatternUntilTrigger",true, ...
                "SampleRateHz",100000,"CameraFramePeriodS",0.001), ...
                "adaptive_optopatch:BlanketModeRequiresSlaveDmd");
            testCase.verifyError(@()adaptive_optopatch.build_dmd_sequence_plan( ...
                protocol,targets),"adaptive_optopatch:BlanketSampleRateRequired");
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            dmd=simulated_dmd(targets.reference_camera);
            dmd.supports_flut=false;
            testCase.verifyError(@()adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",true),"adaptive_optopatch:WrappingPlaylistRequiresFlut");
            testCase.verifyError(@()adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_props(),empty_wfm(),protocol, ...
                AoFixtures.onePhotonProfile(),"DmdSequencePlan",plan), ...
                "adaptive_optopatch:BlanketPlanNeedsMixedBuilder");
            props=live_props(); props.rate=100000;
            testCase.verifyError(@()waveforms(protocol,plan,props), ...
                "adaptive_optopatch:BlanketSampleRateChanged");
        end

        function strayEdgeBeforeAcquisitionStopsBeforeLight(testCase)
            % A stray edge between arming and acquisition is simulated by
            % advancing the DMD once, the first time mod488 is darkened
            % after its playlist was programmed - which is before the
            % runner's pre-trigger check and before the shutter opens.
            [manifest,targets,app]=blanket_run_fixture(testCase,2,1);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            modulator=app.getDevice("NI_DAQ_Modulator","name","mod488");
            shutter=app.getDevice("NI_DAQ_Shutter","name","shutter488");
            nudge=addlistener(modulator,"level","PostSet",@(~,~)nudge_once(dmd));
            opened=addlistener(shutter,"State","PostSet", ...
                @(~,~)testCase.verifyFalse(logical(shutter.State), ...
                "The shutter opened after a stray DMD edge."));
            testCase.addTeardown(@()delete([nudge opened]));
            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"Profile",AoFixtures.onePhotonProfile(),"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"BlankDmdAfterTrial",false, ...
                "OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:DmdAdvancedBeforeAcquisition");
        end
    end
end

% -----------------------------------------------------------------------
% Fixtures
% -----------------------------------------------------------------------

function [reference,fov,targets,gui]=blanket_fov(nCells)
image=zeros(40,8*nCells+8); masks=false([size(image),nCells]);
polygons=cell(1,nCells); ids=compose("cell_%03d",(1:nCells)');
for k=1:nCells
    column=4+(k-1)*8;
    masks(10:14,column:column+4,k)=true;
    polygons{k}=[column 10;column+4 10;column+4 14;column 14];
end
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","blanket_test","CellIds",ids,"RoiPolygons",polygons);
fov=adaptive_optopatch.create_fov_state(reference,polygons,"StimulationMode","1p_dmd");
for k=1:nCells
    fov=adaptive_optopatch.update_cell_calibration(fov,ids(k), ...
        "CommandVoltageV",2+0.25*k);
end
targets=adaptive_optopatch.build_target_bundle(fov.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1,"BlueMaskAdjustmentPixels",0);
gui=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function targets=fov_targets(nCells)
[~,~,targets]=blanket_fov(nCells);
end

function [protocol,targets]=resolved_blanket(~,nCells,rounds)
[reference,fov,targets,gui]=blanket_fov(nCells);
definition=adaptive_optopatch.generate_blanket_round_robin_protocol( ...
    "BlanketMod488V",1,"Rounds",rounds);
manifest=adaptive_optopatch.build_manifest(reference,targets,definition, ...
    "Mode","1p_dmd","FovState",fov,"GuiDefaults",gui);
protocol=manifest.trials.pulse_schedule{1};
end

function [manifest,targets,app]=blanket_run_fixture(testCase,nCells,rounds)
[reference,fov,targets,gui]=blanket_fov(nCells);
definition=adaptive_optopatch.generate_blanket_round_robin_protocol( ...
    "BlanketMod488V",1,"Rounds",rounds);
manifest=adaptive_optopatch.build_manifest(reference,targets,definition, ...
    "Mode","1p_dmd","FovState",fov,"GuiDefaults",gui);
app=adaptive_optopatch.testing.make_simulated_luminos( ...
    "SimulationOutputRoot",testCase.OutputRoot, ...
    "CameraRoi",targets.reference_camera.roi);
end

function [targets,protocol]=flut_fixture(nTargets,targetSequence)
[~,~,targets]=blanket_fov(nTargets);
targetSequence=double(targetSequence(:)); n=numel(targetSequence);
ids=string({targets.targets.cell_id})';
pulse_id=(1:n)'; condition_id=repmat("test",n,1);
stimulation_source=repmat("1p_dmd",n,1);
target_cell_id=ids(targetSequence); target_index=targetSequence;
onset_s=0.1+(0:n-1)'*0.02; duration_s=0.01*ones(n,1);
is_null=false(n,1); command_voltage_v=ones(n,1);
blue_mask_adjustment_pixels=zeros(n,1);
dmd_pattern_index=targetSequence;
command_voltage_source=repmat("event",n,1);
pulse_duration_source=repmat("event",n,1);
blue_mask_adjustment_source=repmat("event",n,1);
events=table(pulse_id,condition_id,stimulation_source,target_cell_id,target_index,onset_s, ...
    duration_s,is_null,command_voltage_v,blue_mask_adjustment_pixels, ...
    dmd_pattern_index,command_voltage_source,pulse_duration_source, ...
    blue_mask_adjustment_source);
parameters=struct("orange_expansion_pixels",2,"spiral_radius_um",2, ...
    "spiral_density_points_per_volt",10);
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","resolved_acquisition","protocol_id","flut_test", ...
    "protocol_type","test","source_protocol_id","flut_test", ...
    "acquisition_id","test","target_policy","multi_target_continuous", ...
    "event_order","ordered","random_seed",1,"events",events, ...
    "parameters",parameters,"parameter_sources",struct, ...
    "acquisition_duration_s",max(onset_s+duration_s)+0.1);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function dmd=simulated_dmd(camera)
dmd=adaptive_optopatch.testing.SimulatedLuminosDevice("DMD","DMD_Blue");
dmd.Dimensions=camera.image_size([2 1]);
dmd.refimage=struct("img",zeros(camera.image_size,"uint16"),"bin",1, ...
    "ref2d",struct("ImageSize",camera.image_size, ...
    "XWorldLimits",[0 camera.image_size(2)], ...
    "YWorldLimits",[0 camera.image_size(1)]));
adaptive_optopatch.testing.calibrate_simulated_dmd(dmd,camera);
end

function props=live_props()
props=struct("rate",200000,"total_time",1, ...
    "clock_source","Internal Dev1","trigger_source",["Dev1/PFI9" "Dev2/PFI1"], ...
    "completion_trigger","None","daq_master",true);
end

function wfm=empty_wfm()
wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
end

function [props,wfm,summary]=waveforms(protocol,plan,props)
if nargin<3, props=live_props(); end
[props,wfm,summary]=adaptive_optopatch.build_luminos_mixed_waveform_config( ...
    props,empty_wfm(),protocol,"DmdSequencePlan",plan, ...
    "OnePhotonProfile",AoFixtures.onePhotonProfile(), ...
    "Manifest",adaptive_optopatch.virtual_upright_stimulation_manifest());
end

function [mod488,trigger]=compiled_lines(props,wfm)
profile=AoFixtures.onePhotonProfile();
aliases=adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list;
ao=compile_wfm_data_to_samples(props,wfm.ao,"AliasList",aliases);
do=compile_wfm_data_to_samples(props,wfm.do,"AliasList",aliases);
mod488=ao([ao.canonical_terminal]==adaptive_optopatch.canonical_terminal( ...
    profile.modulator.port,aliases)).samples;
trigger=do([do.canonical_terminal]==adaptive_optopatch.canonical_terminal( ...
    profile.dmd.trigger_port,aliases)).samples;
mod488=reshape(double(mod488),1,[]); trigger=reshape(double(trigger),1,[]);
end

function edges=rising_edges(line)
edges=find(diff([0 line>0.5])==1);
end

function delivered=walk_wrapped_playlist(plan,mod488,trigger,slip)
% The DMD as the VU wrap diagnostics showed it: edge k (plus any slip)
% shows playlist entry mod(k-1,L)+1 until the next edge.
edges=rising_edges(trigger);
L=plan.programmed_playlist_length;
stops=[edges(2:end)-1 plan.state_table.final_sample];
k=(1:numel(edges))'+slip;
delivered.slot=plan.programmed_playlist_slots(mod(k-1,L)+1);
delivered.levels=arrayfun(@(a,b)mod488(a:b),edges(:),stops(:),"UniformOutput",false);
end

function value=progress(advanced,L)
completed=floor(advanced/L); within=mod(advanced,L);
value=struct("available",true,"detail","", ...
    "sequence_counter",mod(2^32-1-completed,2^32), ...
    "frame_counter",L-within,"frames_per_sub_sequence",L);
end

function nudge_once(dmd)
if ~isempty(dmd.playlist) && dmd.frames_advanced==0
    dmd.frames_advanced=1;
end
end

function slot=slot_for(plan,key)
%SLOT_FOR The playlist slot showing KEY. Masks that are identical pixels
%   share one slot, so a slot's label can name more than one key - the
%   blanket union and a population-target union are the same pixels.
slot=find(cellfun(@(labels)any(labels==key), ...
    arrayfun(@(entry)split(entry,","),plan.slot_mask_keys, ...
    "UniformOutput",false)));
end

function mask=cells_union(targets,indices)
mask=false(size(targets.blank_dmd_mask));
for k=reshape(double(indices),1,[])
    mask=mask | targets.canonical_roi_masks(:,:,k);
end
end
