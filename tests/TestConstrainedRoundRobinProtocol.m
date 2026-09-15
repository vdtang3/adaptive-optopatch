classdef TestConstrainedRoundRobinProtocol < matlab.unittest.TestCase
    properties
        ProtocolPath string
    end

    methods (TestClassSetup)
        function addProtocolFolder(testCase)
            root=fileparts(fileparts(mfilename("fullpath")));
            testCase.ProtocolPath=fullfile(root,"pulse-protocols");
            addpath(testCase.ProtocolPath);
        end
    end

    methods (TestClassTeardown)
        function removeProtocolFolder(testCase)
            rmpath(testCase.ProtocolPath);
        end
    end

    methods (Test)
        function longScheduleIsExactlyBalancedRefractoryAndContinuous(testCase)
            ids=compose("cell_%03d",(1:10)');
            started=tic;
            [events,metadata]=generate_constrained_round_robin_schedule( ...
                ids,1000,0.020,0.020,0.100,1,"RandomSeed",11);
            elapsed=toc(started);
            testCase.verifyEqual(height(events),10000);
            for id=ids'
                rows=events.target_cell_id==id;
                testCase.verifyEqual(sum(rows),1000);
                testCase.verifyGreaterThanOrEqual(min(diff(events.onset_s(rows))), ...
                    0.120-1e-12);
            end
            testCase.verifyEqual(diff(events.onset_s),0.020*ones(9999,1), ...
                "AbsTol",1e-12);
            testCase.verifyEqual(metadata.idle_gap_count,0);
            testCase.verifyEqual(metadata.total_event_count,10000);
            testCase.verifyLessThan(elapsed,10);
        end

        function sixTargetsSustainPreferredSpacing(testCase)
            events=schedule(6,20,0.020,0.020,0.100,12);
            testCase.verifyEqual(diff(events.onset_s),0.020*ones(119,1), ...
                "AbsTol",1e-12);
            verify_refractory(testCase,events,0.120);
        end

        function fiveTargetsInsertIdleWithoutLosingBalance(testCase)
            [events,metadata]=schedule(5,20,0.020,0.020,0.100,13);
            testCase.verifyEqual(height(events),100);
            testCase.verifyGreaterThan(metadata.idle_gap_count,0);
            verify_balance(testCase,events,20);
            verify_refractory(testCase,events,0.120);
        end

        function oneTargetRecursEveryOneHundredTwentyMilliseconds(testCase)
            events=schedule(1,8,0.020,0.020,0.100,14);
            testCase.verifyEqual(diff(events.onset_s),0.120*ones(7,1), ...
                "AbsTol",1e-12);
        end

        function alternateTenMillisecondDesignUsesProtocolValues(testCase)
            events=schedule(10,20,0.010,0.010,0.100,15);
            testCase.verifyEqual(events.duration_s,0.010*ones(200,1));
            verify_refractory(testCase,events,0.110);
        end

        function freshSchedulesDifferAndFrozenEventsDoNot(testCase)
            ids=compose("cell_%03d",(1:10)');
            first=generate_constrained_round_robin_schedule( ...
                ids,20,0.020,0.020,0.100,1);
            second=generate_constrained_round_robin_schedule( ...
                ids,20,0.020,0.020,0.100,1);
            testCase.verifyNotEqual(first.target_cell_id,second.target_cell_id);
            frozen=first;
            testCase.verifyEqual(frozen,first);
        end

        function explicitScheduleResolvesWithoutChangingOrderOrTimes(testCase)
            ids=["cell_001";"cell_002"];
            [events,metadata]=generate_constrained_round_robin_schedule( ...
                ids,4,0.020,0.020,0.100,[0.7;0.9],"RandomSeed",19);
            definition=definition_from(events,metadata);
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

function [events,metadata]=schedule(n,pulses,duration,spacing,recovery,seed)
ids=compose("cell_%03d",(1:n)');
[events,metadata]=generate_constrained_round_robin_schedule( ...
    ids,pulses,duration,spacing,recovery,1,"RandomSeed",seed);
end

function verify_balance(testCase,events,pulses)
ids=unique(events.target_cell_id);
for id=ids'
    testCase.verifyEqual(sum(events.target_cell_id==id),pulses);
end
end

function verify_refractory(testCase,events,minimumInterval)
ids=unique(events.target_cell_id);
for id=ids'
    testCase.verifyGreaterThanOrEqual( ...
        min(diff(events.onset_s(events.target_cell_id==id))),minimumInterval-1e-12);
end
end

function definition=definition_from(events,metadata)
acquisition=struct("acquisition_id","round_robin","events",events, ...
    "parameters",struct,"event_order_realized",true,"target_repetitions",1, ...
    "post_delay_s",0.1,"scheduler_metadata",metadata);
definition=struct("schema_version","3.0.0", ...
    "artifact_type","experiment_definition","protocol_id","explicit_rr", ...
    "protocol_type","round_robin","target_policy","multi_target_continuous", ...
    "event_order","randomized","random_seed",19, ...
    "parameter_sources",struct("command_voltage_v","event"), ...
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
gui=struct("command_voltage_v",1,"pulse_duration_s",0.020, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
