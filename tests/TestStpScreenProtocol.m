classdef TestStpScreenProtocol < matlab.unittest.TestCase
    %TESTSTPSCREENPROTOCOL Canonical 1P short-term plasticity screen.
    %
    %   Covers the pure scheduler
    %   adaptive_optopatch.generate_constrained_stp_round_robin_schedule and
    %   the user-facing pulse-protocols/create_stp_screen_protocol.m.
    %
    %   The load-bearing behaviour is whole-train interleaving: different
    %   targets share the timeline at TRAIN granularity only, never at pulse
    %   granularity, so the screen does not build a repeated millisecond-scale
    %   spike pairing between stimulated neurons.

    properties
        ProtocolPath string
        ScriptProtocol struct
    end

    methods (TestClassSetup)
        function addProtocolFolder(testCase)
            root=fileparts(fileparts(mfilename("fullpath")));
            testCase.ProtocolPath=fullfile(root,"pulse-protocols");
            addpath(testCase.ProtocolPath);
        end

        function generateScriptProtocolOnce(testCase)
            import matlab.unittest.fixtures.TemporaryFolderFixture
            fixture=testCase.applyFixture(TemporaryFolderFixture);
            testCase.ScriptProtocol=run_stp_script( ...
                string(fixture.Folder),testCase.ProtocolPath);
        end
    end

    methods (TestClassTeardown)
        function removeProtocolFolder(testCase)
            rmpath(testCase.ProtocolPath);
        end
    end

    methods (Test)
        % --- 14-22: the shipped experimental design -------------------------

        function shippedScriptUsesFivePulseTwentyHertzTenMillisecondTrains(testCase)
            metadata=testCase.ScriptProtocol.acquisitions.scheduler_metadata;
            events=testCase.ScriptProtocol.acquisitions.events;
            testCase.verifyEqual(metadata.pulses_per_train,5);
            testCase.verifyEqual(metadata.frequency_hz,20);
            testCase.verifyEqual(metadata.pulse_duration_s,0.010,"AbsTol",1e-12);
            testCase.verifyEqual(events.duration_s,0.010*ones(height(events),1), ...
                "AbsTol",1e-12);
            testCase.verifyTrue(all(events.frequency_hz==20));
        end

        function shippedScriptPlacesPulsesAtZeroFiftyHundredOneFiftyTwoHundred(testCase)
            events=testCase.ScriptProtocol.acquisitions.events;
            metadata=testCase.ScriptProtocol.acquisitions.scheduler_metadata;
            expected=[0;0.050;0.100;0.150;0.200];
            trains=unique(events.train_id);
            for trainId=reshape(trains(1:min(50,numel(trains))),1,[])
                rows=events.train_id==trainId;
                testCase.verifyEqual(events.pulse_in_train(rows),(1:5)');
                onsets=events.onset_s(rows);
                testCase.verifyEqual(onsets-onsets(1),expected,"AbsTol",1e-12);
                % The train ends 210 ms after P1 onset.
                testCase.verifyEqual(max(events.offset_s(rows))-onsets(1), ...
                    0.210,"AbsTol",1e-12);
            end
            testCase.verifyEqual(metadata.train_duration_s,0.210,"AbsTol",1e-12);
        end

        function shippedScriptDefaultsToThreeHundredTrainsPerCell(testCase)
            metadata=testCase.ScriptProtocol.acquisitions.scheduler_metadata;
            events=testCase.ScriptProtocol.acquisitions.events;
            testCase.verifyEqual(metadata.trains_per_cell,300);
            testCase.verifyEqual(metadata.target_count,10);
            testCase.verifyEqual(metadata.total_train_count,3000);
            testCase.verifyEqual(metadata.total_event_count,15000);
            testCase.verifyEqual(height(events),15000);
        end

        function shippedScriptGivesEveryTargetThreeHundredTrainsAndFifteenHundredPulses(testCase)
            events=testCase.ScriptProtocol.acquisitions.events;
            ids=unique(events.target_cell_id);
            testCase.verifyNumElements(ids,10);
            for id=reshape(ids,1,[])
                rows=events.target_cell_id==id;
                testCase.verifyNumElements(unique(events.train_id(rows)),300);
                testCase.verifyEqual(sum(rows),1500);
                % n = 300 at each of P1..P5 for this cell.
                for position=1:5
                    testCase.verifyEqual( ...
                        sum(rows & events.pulse_in_train==position),300);
                end
                testCase.verifyEqual(sort(unique(events.repeat_index(rows))),(1:300)');
            end
        end

        % --- 23: whole-train interleaving only ------------------------------

        function noOtherTargetEventFallsInsideATrain(testCase)
            verify_train_blocks_are_contiguous(testCase, ...
                testCase.ScriptProtocol.acquisitions.events);
        end

        function noPulseLevelRoiInterleavingAppearsForAnyTargetCount(testCase)
            for targetCount=[2 3 6 10]
                events=stp_schedule(targetCount,4,5,20,0.010,0.020,1.000,targetCount);
                verify_train_blocks_are_contiguous(testCase,events);
            end
        end

        % --- 24, 25: inter-train gap and same-cell recovery -----------------

        function adifferentTargetMayStartAfterThePreferredTwentyMillisecondGap(testCase)
            [events,metadata]=stp_schedule(10,5,5,20,0.010,0.020,1.000,31);
            testCase.verifyEqual(metadata.preferred_inter_train_gap_s,0.020);
            [starts,ends,targets]=train_blocks(events);
            gaps=starts(2:end)-ends(1:end-1);
            testCase.verifyEqual(min(gaps),0.020,"AbsTol",1e-9);
            % A 20 ms gap only ever hands the timeline to a different target.
            tight=find(abs(gaps-0.020)<1e-9);
            testCase.verifyNotEmpty(tight);
            testCase.verifyTrue(all(targets(tight+1)~=targets(tight)));
        end

        function sameTargetWaitsAFullSecondAfterItsOwnTrainEnds(testCase)
            [events,metadata]=stp_schedule(10,5,5,20,0.010,0.020,1.000,31);
            testCase.verifyEqual(metadata.minimum_same_cell_post_train_gap_s,1.000);
            testCase.verifyEqual(metadata.same_cell_minimum_train_onset_interval_s, ...
                1.210,"AbsTol",1e-12);
            verify_post_train_recovery(testCase,events,1.000);
        end

        function shippedScriptEnforcesTheSameCellRecoveryWindow(testCase)
            verify_post_train_recovery(testCase, ...
                testCase.ScriptProtocol.acquisitions.events,1.000);
        end

        % --- 26, 27: idle only when necessary -------------------------------

        function tooFewTargetsForceIdleTime(testCase)
            % Three targets cover 3*0.230 s = 0.690 s of the 1.210 s same-cell
            % train-onset interval, so the scheduler must wait.
            [events,metadata]=stp_schedule(3,5,5,20,0.010,0.020,1.000,41);
            testCase.verifyGreaterThan(metadata.idle_gap_count,0);
            testCase.verifyGreaterThan(metadata.total_idle_time_s,0);
            verify_post_train_recovery(testCase,events,1.000);
            verify_train_balance(testCase,events,5);
        end

        function enoughTargetsRemoveIdleTimeEntirely(testCase)
            % Six targets cover 6*0.230 s = 1.380 s >= 1.210 s, so the timeline
            % stays continuously occupied at the preferred inter-train gap.
            for targetCount=[6 8 10]
                [events,metadata]=stp_schedule(targetCount,5,5,20,0.010,0.020,1.000,51);
                testCase.verifyEqual(metadata.idle_gap_count,0);
                testCase.verifyEqual(metadata.total_idle_time_s,0);
                [starts,~,~]=train_blocks(events);
                testCase.verifyEqual(diff(starts), ...
                    0.230*ones(numel(starts)-1,1),"AbsTol",1e-9);
            end
            testCase.verifyEqual( ...
                testCase.ScriptProtocol.acquisitions.scheduler_metadata.idle_gap_count,0);
        end

        % --- 28, 29: balanced, randomized, reproducible ---------------------

        function trainOrderIsBalancedAndRandomized(testCase)
            [first,~,firstTargets]=ordered_train_targets(10,30,61);
            [second,~,secondTargets]=ordered_train_targets(10,30,62);
            verify_train_balance(testCase,first,30);
            verify_train_balance(testCase,second,30);
            testCase.verifyNotEqual(secondTargets,firstTargets);
            % Balanced quotas mean each block of 10 consecutive trains visits
            % all 10 targets exactly once, in a randomized order.
            block=reshape(firstTargets,10,[]);
            for k=1:size(block,2)
                testCase.verifyNumElements(unique(block(:,k)),10);
            end
            testCase.verifyFalse(isequal(block(:,1),block(:,2)));
        end

        function sameSeedReproducesTheScheduleExactly(testCase)
            ids=compose("cell_%03d",(1:6)');
            first=adaptive_optopatch.generate_constrained_stp_round_robin_schedule( ...
                ids,8,5,20,0.010,0.020,1.000,NaN,"RandomSeed",7777);
            second=adaptive_optopatch.generate_constrained_stp_round_robin_schedule( ...
                ids,8,5,20,0.010,0.020,1.000,NaN,"RandomSeed",7777);
            testCase.verifyEqual(second,first);
        end

        % --- 30, 31, 33: schema-4 ownership ---------------------------------

        function shippedScriptMarksEverySourceAsOnePhotonDmd(testCase)
            events=testCase.ScriptProtocol.acquisitions.events;
            testCase.verifyTrue(all(events.stimulation_source=="1p_dmd"));
            testCase.verifyFalse(any(events.is_null));
            testCase.verifyTrue(all(events.condition_id=="stp_20hz_5pulse"));
            testCase.verifyNumElements(unique(events.condition_id),1);
        end

        function shippedScriptLeavesVoltageUnresolvedForFovCalibration(testCase)
            protocol=testCase.ScriptProtocol;
            events=protocol.acquisitions.events;
            testCase.verifyTrue(all(isnan(events.command_voltage_v)));
            testCase.verifyTrue(ismember("fov_cell", ...
                string(protocol.parameter_sources.command_voltage_v)));
            testCase.verifyFalse(isfield(protocol.parameters,"command_voltage_v"));
            testCase.verifyFalse(isfield(protocol.acquisitions.parameters, ...
                "command_voltage_v"));
        end

        function shippedScriptNormalizesUnderSchemaFour(testCase)
            protocol=testCase.ScriptProtocol;
            testCase.verifyEqual(string(protocol.schema_version),"4.0.0");
            testCase.verifyEqual(string(protocol.artifact_type),"experiment_definition");
            testCase.verifyEqual(string(protocol.protocol_type),"stp_screen");
            testCase.verifyTrue(startsWith(protocol.protocol_id,"stp_screen_"));
            testCase.verifyTrue(protocol.acquisitions.event_order_realized);
            report=adaptive_optopatch.validate_protocol(protocol);
            testCase.verifyTrue(report.passed,strjoin(report.issues,newline));
        end

        function explicitVoltagesOutsideTheAllowedRangeAreRejected(testCase)
            ids=["cell_001";"cell_002"];
            testCase.verifyError(@()adaptive_optopatch.generate_constrained_stp_round_robin_schedule( ...
                ids,2,5,20,0.010,0.020,1.000,[0;1]), ...
                "adaptive_optopatch:InvalidStpVoltage");
            testCase.verifyError(@()adaptive_optopatch.generate_constrained_stp_round_robin_schedule( ...
                ids,2,5,20,0.010,0.020,1.000,[1;9]), ...
                "adaptive_optopatch:InvalidStpVoltage");
        end

        % --- 31, 32: one multi-target acquisition, resolved at fov_cell -----

        function oneMultiTargetAcquisitionResolvesThroughFovCell(testCase)
            ids=["cell_001";"cell_002"];
            [events,metadata]=adaptive_optopatch.generate_constrained_stp_round_robin_schedule( ...
                ids,3,5,20,0.010,0.020,1.000,NaN,"RandomSeed",77);
            definition=definition_from(events,metadata);
            testCase.verifyEqual(string(definition.target_policy), ...
                "multi_target_continuous");
            [fov,targets,gui]=fixture();
            fov=adaptive_optopatch.update_cell_calibration(fov,"cell_001", ...
                "CommandVoltageV",0.85,"PulseDurationMs",10);
            fov=adaptive_optopatch.update_cell_calibration(fov,"cell_002", ...
                "CommandVoltageV",1.35,"PulseDurationMs",10);
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            % One acquisition for two targets, not one acquisition per target.
            testCase.verifyNumElements(resolved,1);
            resolvedEvents=resolved{1}.events;
            testCase.verifyEqual(height(resolvedEvents),height(events));
            testCase.verifyNumElements(unique(resolvedEvents.target_cell_id),2);
            testCase.verifyTrue(all(resolvedEvents.command_voltage_source=="fov_cell"));
            expected=0.85*(resolvedEvents.target_cell_id=="cell_001")+ ...
                1.35*(resolvedEvents.target_cell_id=="cell_002");
            testCase.verifyEqual(resolvedEvents.command_voltage_v,expected);
            testCase.verifyEqual(resolvedEvents.target_cell_id,events.target_cell_id);
            testCase.verifyEqual(resolvedEvents.onset_s,events.onset_s);
            testCase.verifyEqual(resolvedEvents.duration_s,events.duration_s);
            testCase.verifyEqual(resolved{1}.scheduler_metadata,metadata);
            verify_train_blocks_are_contiguous(testCase,resolvedEvents);
        end

        function resolvedScheduleCompilesToTheSameOnePhotonTimeline(testCase)
            ids=["cell_001";"cell_002"];
            events=adaptive_optopatch.generate_constrained_stp_round_robin_schedule( ...
                ids,2,5,20,0.010,0.020,1.000,[0.7;0.9],"RandomSeed",88);
            definition=definition_from(events,struct("note","explicit"));
            definition.parameter_sources.command_voltage_v="event";
            [fov,targets,gui]=fixture();
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            plan=adaptive_optopatch.build_dmd_sequence_plan(resolved{1},targets);
            globalProps=struct("rate",200000,"total_time",1, ...
                "clock_source","Internal Dev1","trigger_source","Dev1/PFI9", ...
                "daq_master",true);
            wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
                "ao_camera_triggered",[],"do_camera_triggered",[]);
            [~,~,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,resolved{1}, ...
                adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);
            testCase.verifyEqual(summary.pulses.onset_s,events.onset_s);
            testCase.verifyEqual(numel(summary.dmd_sequence.dmd_trigger_s), ...
                height(events));
        end
    end
end

function protocol=run_stp_script(outputDirectory,protocolPath) %#ok<STOUT>
% Run the user-facing script in its own workspace so the shipped defaults,
% not a copy of them, are what the tests assert.
protocol_output_directory=outputDirectory; %#ok<NASGU>
run(fullfile(protocolPath,"create_stp_screen_protocol.m"));
end

function [events,metadata]=stp_schedule(targetCount,trainsPerCell,pulsesPerTrain, ...
        frequencyHz,pulseDurationS,gapS,recoveryS,seed)
ids=compose("cell_%03d",(1:targetCount)');
[events,metadata]=adaptive_optopatch.generate_constrained_stp_round_robin_schedule( ...
    ids,trainsPerCell,pulsesPerTrain,frequencyHz,pulseDurationS,gapS,recoveryS, ...
    NaN,"RandomSeed",seed);
end

function [events,metadata,orderedTargets]=ordered_train_targets(targetCount,trainsPerCell,seed)
[events,metadata]=stp_schedule(targetCount,trainsPerCell,5,20,0.010,0.020,1.000,seed);
[~,~,orderedTargets]=train_blocks(events);
end

function [starts,ends,targets]=train_blocks(events)
% Summarize the schedule as whole trains in timeline order.
[~,order]=sort(events.onset_s);
sorted=events(order,:);
trainIds=unique(sorted.train_id,"stable");
starts=zeros(numel(trainIds),1); ends=zeros(numel(trainIds),1);
targets=strings(numel(trainIds),1);
for k=1:numel(trainIds)
    rows=sorted.train_id==trainIds(k);
    starts(k)=min(sorted.onset_s(rows));
    ends(k)=max(sorted.offset_s(rows));
    targets(k)=sorted.target_cell_id(find(rows,1));
end
end

function verify_train_blocks_are_contiguous(testCase,events)
% A train is one uninterrupted block on the timeline: one target, and no
% event belonging to any other train between its first onset and its last
% offset. This is the assertion that forbids ROI1-P1, ROI2-P1, ROI1-P2, ...
[~,order]=sort(events.onset_s);
sorted=events(order,:);
trainIds=unique(sorted.train_id,"stable");
cursor=0;
for k=1:numel(trainIds)
    rows=find(sorted.train_id==trainIds(k));
    testCase.verifyEqual(rows,(cursor+1:cursor+numel(rows))', ...
        "Train "+string(trainIds(k))+" is interrupted by another train.");
    testCase.verifyNumElements(unique(sorted.target_cell_id(rows)),1);
    cursor=cursor+numel(rows);
end
testCase.verifyEqual(cursor,height(sorted));
end

function verify_train_balance(testCase,events,trainsPerCell)
ids=unique(events.target_cell_id);
for id=reshape(ids,1,[])
    testCase.verifyNumElements( ...
        unique(events.train_id(events.target_cell_id==id)),trainsPerCell);
end
end

function verify_post_train_recovery(testCase,events,minimumPostTrainGap)
% A cell's next P1 never starts until minimumPostTrainGap has elapsed after
% its own previous P5 ENDED.
[starts,ends,targets]=train_blocks(events);
for id=reshape(unique(targets),1,[])
    rows=find(targets==id);
    if numel(rows)<2, continue; end
    testCase.verifyGreaterThanOrEqual( ...
        min(starts(rows(2:end))-ends(rows(1:end-1))),minimumPostTrainGap-1e-9);
end
end

function definition=definition_from(events,metadata)
acquisition=struct("acquisition_id","stp_screen","events",events, ...
    "parameters",struct,"event_order_realized",true,"target_repetitions",1, ...
    "post_delay_s",0.1,"scheduler_metadata",metadata);
definition=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition","protocol_id","explicit_stp", ...
    "protocol_type","stp_screen","target_policy","multi_target_continuous", ...
    "event_order","randomized","random_seed",77, ...
    "parameter_sources",struct("command_voltage_v", ...
    ["event","acquisition","protocol","fov_cell"]), ...
    "parameters",struct,"acquisitions",acquisition);
definition=adaptive_optopatch.normalize_protocol(definition);
end

function [fov,targets,gui]=fixture()
image=zeros(20,30); masks=false(20,30,2);
masks(3:7,3:7,1)=true; masks(12:16,20:24,2)=true;
polygons={[3 3;7 3;7 7;3 7],[20 12;24 12;24 16;20 16]};
metadata=struct("rig_name","test", ...
    "voltage_camera",struct("name","Camera 1","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","stp_test","CellIds",["cell_001";"cell_002"], ...
    "RoiPolygons",polygons);
fov=adaptive_optopatch.create_fov_state(reference,polygons);
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1,"BlueMaskAdjustmentPixels",0);
gui=struct("command_voltage_v",1,"pulse_duration_s",0.010, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
