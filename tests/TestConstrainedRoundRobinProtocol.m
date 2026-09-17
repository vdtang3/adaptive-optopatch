classdef TestConstrainedRoundRobinProtocol < matlab.unittest.TestCase
    %TESTCONSTRAINEDROUNDROBINPROTOCOL Canonical 1P connectivity screen.
    %
    %   Covers the pure scheduler
    %   adaptive_optopatch.generate_constrained_round_robin_schedule and the
    %   user-facing pulse-protocols/create_connectivity_round_robin_protocol.m.

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
            testCase.ScriptProtocol=run_connectivity_script( ...
                string(fixture.Folder),testCase.ProtocolPath);
        end
    end

    methods (TestClassTeardown)
        function removeProtocolFolder(testCase)
            rmpath(testCase.ProtocolPath);
        end
    end

    methods (Test)
        % --- 1, 2, 4, 5, 10, 11, 13: the shipped experimental design --------

        function shippedScriptUsesTenMillisecondPulses(testCase)
            protocol=testCase.ScriptProtocol;
            events=protocol.acquisitions.events;
            testCase.verifyEqual(events.duration_s,0.010*ones(height(events),1), ...
                "AbsTol",1e-12);
            testCase.verifyEqual(protocol.acquisitions.scheduler_metadata.pulse_duration_s, ...
                0.010,"AbsTol",1e-12);
        end

        function shippedScriptDefaultsToOneThousandPulsesPerCell(testCase)
            metadata=testCase.ScriptProtocol.acquisitions.scheduler_metadata;
            testCase.verifyEqual(metadata.pulses_per_cell,1000);
            testCase.verifyEqual(metadata.target_count,10);
            testCase.verifyEqual(metadata.total_event_count,10000);
            verify_balance(testCase,testCase.ScriptProtocol.acquisitions.events,1000);
        end

        function shippedScriptHoldsTwentyMillisecondCadence(testCase)
            events=testCase.ScriptProtocol.acquisitions.events;
            metadata=testCase.ScriptProtocol.acquisitions.scheduler_metadata;
            testCase.verifyEqual(metadata.requested_preferred_global_spacing_s,0.020);
            testCase.verifyEqual(diff(events.onset_s), ...
                0.020*ones(height(events)-1,1),"AbsTol",1e-9);
            testCase.verifyEqual(metadata.idle_gap_count,0);
        end

        function shippedScriptEnforcesHundredMillisecondPostPulseRecovery(testCase)
            events=testCase.ScriptProtocol.acquisitions.events;
            metadata=testCase.ScriptProtocol.acquisitions.scheduler_metadata;
            testCase.verifyEqual(metadata.minimum_same_cell_post_pulse_gap_s,0.100);
            testCase.verifyEqual(metadata.same_cell_minimum_onset_interval_s,0.110, ...
                "AbsTol",1e-12);
            verify_post_pulse_recovery(testCase,events,0.100);
        end

        function shippedScriptMarksEverySourceAsOnePhotonDmd(testCase)
            events=testCase.ScriptProtocol.acquisitions.events;
            testCase.verifyTrue(all(events.stimulation_source=="1p_dmd"));
            testCase.verifyFalse(any(events.is_null));
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
            testCase.verifyEqual(string(protocol.target_policy),"multi_target_continuous");
            testCase.verifyTrue(protocol.acquisitions.event_order_realized);
            testCase.verifyEqual(protocol.acquisitions.target_repetitions,1);
            report=adaptive_optopatch.validate_protocol(protocol);
            testCase.verifyTrue(report.passed,strjoin(report.issues,newline));
        end

        % --- 3: the documented higher-SNR variant ---------------------------

        function fifteenHundredPulsesPerCellIsATrivialEdit(testCase)
            [events,metadata]=schedule(4,1500,0.010,0.020,0.100,21);
            testCase.verifyEqual(metadata.pulses_per_cell,1500);
            testCase.verifyEqual(height(events),6000);
            verify_balance(testCase,events,1500);
            verify_post_pulse_recovery(testCase,events,0.100);
        end

        % --- 6, 7: idle instead of a shortened recovery ---------------------

        function fiveTargetsInsertIdleRatherThanShortenRecovery(testCase)
            % Five targets at the preferred 20 ms cadence would revisit a cell
            % every 100 ms, which is shorter than the 110 ms minimum onset
            % interval. The scheduler must idle rather than weaken the rule.
            [events,metadata]=schedule(5,20,0.010,0.020,0.100,13);
            testCase.verifyEqual(height(events),100);
            testCase.verifyGreaterThan(metadata.idle_gap_count,0);
            testCase.verifyGreaterThan(metadata.total_idle_time_s,0);
            verify_balance(testCase,events,20);
            verify_post_pulse_recovery(testCase,events,0.100);
        end

        function sixTargetsSustainPreferredSpacingWithoutIdle(testCase)
            [events,metadata]=schedule(6,20,0.010,0.020,0.100,12);
            testCase.verifyEqual(diff(events.onset_s),0.020*ones(119,1), ...
                "AbsTol",1e-12);
            testCase.verifyEqual(metadata.idle_gap_count,0);
            verify_post_pulse_recovery(testCase,events,0.100);
        end

        function everyTargetReceivesExactlyItsQuota(testCase)
            for targetCount=[1 2 3 7 11]
                [events,metadata]=schedule(targetCount,13,0.010,0.020,0.100,targetCount);
                testCase.verifyEqual(height(events),targetCount*13);
                testCase.verifyEqual(metadata.total_event_count,targetCount*13);
                verify_balance(testCase,events,13);
                verify_post_pulse_recovery(testCase,events,0.100);
            end
        end

        function loneTargetRecursEveryHundredTenMilliseconds(testCase)
            events=schedule(1,8,0.010,0.020,0.100,14);
            testCase.verifyEqual(diff(events.onset_s),0.110*ones(7,1), ...
                "AbsTol",1e-12);
        end

        % --- 8, 9: reproducibility ------------------------------------------

        function sameSeedReproducesTheScheduleExactly(testCase)
            ids=compose("cell_%03d",(1:8)');
            first=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,25,0.010,0.020,0.100,NaN,"RandomSeed",4242);
            second=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,25,0.010,0.020,0.100,NaN,"RandomSeed",4242);
            testCase.verifyEqual(second,first);
        end

        function differentSeedGivesADifferentButValidOrdering(testCase)
            ids=compose("cell_%03d",(1:8)');
            first=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,25,0.010,0.020,0.100,NaN,"RandomSeed",4242);
            second=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,25,0.010,0.020,0.100,NaN,"RandomSeed",99);
            testCase.verifyNotEqual(second.target_cell_id,first.target_cell_id);
            testCase.verifyEqual(second.onset_s,first.onset_s,"AbsTol",1e-12);
            verify_balance(testCase,second,25);
            verify_post_pulse_recovery(testCase,second,0.100);
        end

        function longScheduleStaysBalancedRefractoryAndContinuous(testCase)
            ids=compose("cell_%03d",(1:10)');
            started=tic;
            [events,metadata]=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,1000,0.010,0.020,0.100,NaN,"RandomSeed",11);
            elapsed=toc(started);
            testCase.verifyEqual(height(events),10000);
            verify_balance(testCase,events,1000);
            verify_post_pulse_recovery(testCase,events,0.100);
            testCase.verifyEqual(diff(events.onset_s),0.020*ones(9999,1), ...
                "AbsTol",1e-9);
            testCase.verifyEqual(metadata.idle_gap_count,0);
            testCase.verifyEqual(metadata.total_event_count,10000);
            testCase.verifyLessThan(elapsed,10);
        end

        % --- voltage ownership ----------------------------------------------

        function nanVoltageIsLegalAndIsNeverConvertedToANumber(testCase)
            perTarget=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ["cell_001";"cell_002";"cell_003"],4,0.010,0.020,0.100, ...
                [NaN;1.2;NaN],"RandomSeed",5);
            testCase.verifyTrue(all(isnan( ...
                perTarget.command_voltage_v(perTarget.target_cell_id=="cell_001"))));
            testCase.verifyTrue(all(isnan( ...
                perTarget.command_voltage_v(perTarget.target_cell_id=="cell_003"))));
            testCase.verifyEqual( ...
                perTarget.command_voltage_v(perTarget.target_cell_id=="cell_002"), ...
                1.2*ones(4,1));
        end

        function explicitVoltagesOutsideTheAllowedRangeAreRejected(testCase)
            ids=["cell_001";"cell_002"];
            testCase.verifyError(@()adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,2,0.010,0.020,0.100,[0;1]), ...
                "adaptive_optopatch:InvalidRoundRobinVoltage");
            testCase.verifyError(@()adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,2,0.010,0.020,0.100,[1;7]), ...
                "adaptive_optopatch:InvalidRoundRobinVoltage");
            testCase.verifyError(@()adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,2,0.010,0.020,0.100,[1;Inf]), ...
                "adaptive_optopatch:InvalidRoundRobinVoltage");
        end

        % --- 12: resolution reaches the per-cell Blue calibration -----------

        function unresolvedVoltageResolvesThroughFovCell(testCase)
            ids=["cell_001";"cell_002"];
            [events,metadata]=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,4,0.010,0.020,0.100,NaN,"RandomSeed",23);
            definition=definition_from(events,metadata);
            [fov,targets,gui]=fixture();
            fov=adaptive_optopatch.update_cell_calibration(fov,"cell_001", ...
                "CommandVoltageV",0.8,"PulseDurationMs",10);
            fov=adaptive_optopatch.update_cell_calibration(fov,"cell_002", ...
                "CommandVoltageV",1.4,"PulseDurationMs",10);
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyNumElements(resolved,1);
            resolvedEvents=resolved{1}.events;
            testCase.verifyTrue(all(resolvedEvents.command_voltage_source=="fov_cell"));
            expected=0.8*(resolvedEvents.target_cell_id=="cell_001")+ ...
                1.4*(resolvedEvents.target_cell_id=="cell_002");
            testCase.verifyEqual(resolvedEvents.command_voltage_v,expected);
            testCase.verifyEqual(resolvedEvents.target_cell_id,events.target_cell_id);
            testCase.verifyEqual(resolvedEvents.onset_s,events.onset_s);
        end

        function explicitScheduleResolvesWithoutChangingOrderOrTimes(testCase)
            ids=["cell_001";"cell_002"];
            [events,metadata]=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
                ids,4,0.010,0.020,0.100,[0.7;0.9],"RandomSeed",19);
            definition=definition_from(events,metadata);
            definition.parameter_sources.command_voltage_v="event";
            [fov,targets,gui]=fixture();
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyNumElements(resolved,1);
            testCase.verifyEqual(resolved{1}.events.target_cell_id,events.target_cell_id);
            testCase.verifyEqual(resolved{1}.events.onset_s,events.onset_s);
            testCase.verifyEqual(resolved{1}.events.duration_s,events.duration_s);
            testCase.verifyEqual(resolved{1}.scheduler_metadata,metadata);

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

function protocol=run_connectivity_script(outputDirectory,protocolPath) %#ok<STOUT>
% Run the user-facing script in its own workspace so the shipped defaults,
% not a copy of them, are what the tests assert.
protocol_output_directory=outputDirectory; %#ok<NASGU>
run(fullfile(protocolPath,"create_connectivity_round_robin_protocol.m"));
end

function [events,metadata]=schedule(n,pulses,duration,spacing,recovery,seed)
ids=compose("cell_%03d",(1:n)');
[events,metadata]=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
    ids,pulses,duration,spacing,recovery,NaN,"RandomSeed",seed);
end

function verify_balance(testCase,events,pulses)
ids=unique(events.target_cell_id);
for id=reshape(ids,1,[])
    testCase.verifyEqual(sum(events.target_cell_id==id),pulses);
end
end

function verify_post_pulse_recovery(testCase,events,minimumPostPulseGap)
% The constraint is expressed exactly as the experiment states it: a cell is
% never revisited until minimumPostPulseGap has elapsed after its previous
% pulse ENDED.
ids=unique(events.target_cell_id);
for id=reshape(ids,1,[])
    rows=events.target_cell_id==id;
    onsets=events.onset_s(rows); offsets=events.offset_s(rows);
    if numel(onsets)<2, continue; end
    testCase.verifyGreaterThanOrEqual(min(onsets(2:end)-offsets(1:end-1)), ...
        minimumPostPulseGap-1e-9);
end
end

function definition=definition_from(events,metadata)
acquisition=struct("acquisition_id","connectivity_round_robin","events",events, ...
    "parameters",struct,"event_order_realized",true,"target_repetitions",1, ...
    "post_delay_s",0.1,"scheduler_metadata",metadata);
definition=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition","protocol_id","explicit_rr", ...
    "protocol_type","connectivity_round_robin", ...
    "target_policy","multi_target_continuous", ...
    "event_order","randomized","random_seed",19, ...
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
    "FovId","rr_test","CellIds",["cell_001";"cell_002"], ...
    "RoiPolygons",polygons);
fov=adaptive_optopatch.create_fov_state(reference,polygons);
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1,"BlueMaskAdjustmentPixels",0);
gui=struct("command_voltage_v",1,"pulse_duration_s",0.010, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
