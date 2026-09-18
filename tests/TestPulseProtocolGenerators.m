classdef TestPulseProtocolGenerators < matlab.unittest.TestCase
    %TESTPULSEPROTOCOLGENERATORS The shipped protocol generators, as definitions.
    %   Screen, STF, single-cell ramp and round-robin generators produce
    %   protocol DEFINITIONS: schedules, schema fields and the refusals that
    %   keep a physically impossible train from being written down.
    %
    %   What happens to a definition afterwards has other owners:
    %   TestProtocolResolution resolves one against a FOV,
    %   TestConstrainedRoundRobinProtocol and TestStpScreenProtocol own the two
    %   constrained schedulers, and TestLuminosWaveformConfiguration turns a
    %   resolved protocol into samples.

    methods (Test)
        function generatesCanonicalConnectivityAndStfProtocols(testCase)
            required=["pulse_id","condition_id","onset_s","duration_s", ...
                "is_null","command_voltage_v","blue_mask_adjustment_pixels"];
            screen=adaptive_optopatch.generate_screen_protocol("PulseCount",3);
            testCase.verifyEqual(screen.schema_version,"4.0.0");
            testCase.verifyEqual(screen.artifact_type,"experiment_definition");
            testCase.verifyTrue(all(ismember(required, ...
                string(screen.acquisitions.events.Properties.VariableNames))));
            testCase.verifyFalse(ismember("target_cell_id", ...
                string(screen.acquisitions.events.Properties.VariableNames)));
            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",1,"PulsesPerTrain",3);
            stf=adaptive_optopatch.generate_stf_protocol(conditions);
            testCase.verifyTrue(all(ismember(required, ...
                string(stf.acquisitions.events.Properties.VariableNames))));
            testCase.verifyTrue(adaptive_optopatch.validate_protocol(stf).passed);
        end

        function generatesNonoverlappingScreenSchedule(testCase)
            p=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",200,"PulseDurationMs",5, ...
                "DarkIntervalMs",[45 55],"RandomSeed",9);
            events=p.acquisitions.events;
            gaps=1000*(events.onset_s(2:end)-events.offset_s(1:end-1));
            testCase.verifyGreaterThanOrEqual(min(gaps),45);
            testCase.verifyLessThanOrEqual(max(gaps),55);
            testCase.verifyEqual(events.onset_s(1),0.1,"AbsTol",1e-12);
            testCase.verifyEqual(p.acquisitions.acquisition_duration_s, ...
                events.offset_s(end)+0.1,"AbsTol",1e-12);
        end

        function allowsLongSinglePulseDurations(testCase)
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"PulseDurationMs",250, ...
                "DarkIntervalMs",[50 50]);
            testCase.verifyEqual(protocol.acquisitions.events.duration_s,0.25*ones(2,1));
        end

        function randomizesMixedStfConditions(testCase)
            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",4,"PulsesPerTrain",3);
            p=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[100 120],"RandomSeed",2);
            events=p.acquisitions.events;
            testCase.verifyEqual(height(events),28);
            testCase.verifyEqual(sum(events.frequency_hz==100),12);
            testCase.verifyLessThanOrEqual(max(events.frequency_hz,[],"omitnan"),100);
            testCase.verifyTrue(all(events.onset_s(2:end)>=events.offset_s(1:end-1)));
        end

        function buildsPilotSingleAndTenPulseProtocol(testCase)
            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",50,"PulsesPerTrain",10, ...
                "PulseDurationMs",5,"CommandVoltageV",0.1);
            definition=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[450 550],"RandomSeed",1001);
            protocol=AoFixtures.resolvedProtocol(definition,"2p_spiral");
            pulses=adaptive_optopatch.flatten_pulse_schedule(protocol);
            testCase.verifyEqual(height(protocol.events),1050);
            testCase.verifyEqual(height(pulses),1050);
            testCase.verifyEqual(sum(protocol.events.pulse_in_train==1),150);
            testCase.verifyEqual(sum(protocol.events.frequency_hz==100),500);
            testCase.verifyEqual(sort(unique(protocol.events.frequency_hz(~isnan( ...
                protocol.events.frequency_hz)))),[50;100]);
            trials=table(1,"2p_spiral","cell_001",false,1,{protocol}, ...
                protocol.acquisition_duration_s,"mixed","planned","", ...
                'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
                'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
                'output_tag','acquisition_status','experiment_directory'});
            report=adaptive_optopatch.validate_2p_release_level( ...
                struct("trials",trials),"pilot_mixed_trains", ...
                "ConfirmTrajectoryTest",true,"ConfirmLiveOutput",true, ...
                "ModulatorVoltageOverride",0.1);
            testCase.verifyTrue(report.passed);
        end

        function allowsStfFrequencyAbove100HzWhenPhysicallyValid(testCase)
            frequency_hz=200; pulse_duration_ms=2; % 2 ms < 5 ms period
            conditions=table("train_200hz",frequency_hz,3,pulse_duration_ms,1,0.1,false, ...
                'VariableNames',{'condition_id','frequency_hz', ...
                'pulses_per_train','pulse_duration_ms','repeats', ...
                'command_voltage_v','is_null'});
            definition=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[450 550]);
            events=definition.acquisitions.events;
            testCase.verifyEqual(height(events),3);
            testCase.verifyEqual(events.frequency_hz,repmat(frequency_hz,3,1));
            expectedOnsets=events.onset_s(1)+(0:2)'/frequency_hz;
            testCase.verifyEqual(events.onset_s,expectedOnsets,"AbsTol",1e-9);
        end

        function rejectsOverlappingStfPulseTrain(testCase)
            conditions=table("train_overlap",200,3,10,1,0.1,false, ...
                'VariableNames',{'condition_id','frequency_hz', ...
                'pulses_per_train','pulse_duration_ms','repeats', ...
                'command_voltage_v','is_null'});
            testCase.verifyError(@()adaptive_optopatch.generate_stf_protocol( ...
                conditions,"EventDarkIntervalMs",[450 550]), ...
                "adaptive_optopatch:OverlappingStfPulses");
        end

        function flattensScreenAndStfPulseSchedules(testCase)
            screen=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",4,"ModulatorVoltage",1.25,"RandomSeed",3);
            screen=AoFixtures.resolvedProtocol(screen,"1p_dmd");
            pulses=adaptive_optopatch.flatten_pulse_schedule(screen);
            testCase.verifyEqual(height(pulses),4);
            testCase.verifyEqual(pulses.modulator_voltage,1.25*ones(4,1));
            testCase.verifyFalse(any(pulses.is_null));

            conditions=adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",1,"PulsesPerTrain",3, ...
                "CommandVoltageV",2);
            stf=adaptive_optopatch.generate_stf_protocol(conditions, ...
                "EventDarkIntervalMs",[100 100],"RandomSeed",4);
            stf=AoFixtures.resolvedProtocol(stf,"1p_dmd");
            stfPulses=adaptive_optopatch.flatten_pulse_schedule(stf);
            expected=sum(conditions.pulses_per_train);
            testCase.verifyEqual(height(stfPulses),expected);
            testCase.verifyTrue(all(diff(stfPulses.onset_s)>=0));
        end

        function generatesAscendingArbitraryVoltageRamp(testCase)
            levels=[0.5 0.75 1.15 1.6];
            definition=adaptive_optopatch.generate_single_cell_ramp_protocol( ...
                levels,"RepeatsPerVoltage",3, ...
                "PulseDurationMs",10,"DarkIntervalMs",90);
            protocol=AoFixtures.resolvedProtocol(definition,"1p_dmd");
            testCase.verifyEqual(height(protocol.events),12);
            testCase.verifyEqual(protocol.events.command_voltage_v, ...
                repelem(levels(:),3));
            testCase.verifyEqual(unique(protocol.events.target_cell_id),"cell_001");
            testCase.verifyEqual(protocol.events.onset_s(2:end)- ...
                protocol.events.onset_s(1:end-1),0.1*ones(11,1),"AbsTol",1e-12);
            review=adaptive_optopatch.summarize_ramp_response(protocol, ...
                [zeros(3,1);ones(3,1);2*ones(3,1);ones(3,1)], ...
                [zeros(9,1);ones(3,1)],nan(12,1));
            testCase.verifyEqual(review.exactly_one_spike_fraction,[0;1;0;1]);
            testCase.verifyEqual(review.neighbor_spike_fraction,[0;0;0;1]);
        end

        function roundRobinDefaultsToOneHundredPulsesPerCell(testCase)
            definition=adaptive_optopatch.generate_round_robin_protocol();
            testCase.verifyEqual( ...
                definition.acquisitions.target_repetitions,100);
            overridden=adaptive_optopatch.generate_round_robin_protocol( ...
                "PulsesPerCell",7);
            testCase.verifyEqual( ...
                overridden.acquisitions.target_repetitions,7);

            [fovState,~]=AoFixtures.fovState();
            for k=1:numel(fovState.cells)
                fovState=adaptive_optopatch.update_cell_calibration(fovState, ...
                    string(fovState.cells(k).cell_id),"CommandVoltageV",0.8);
            end
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,AoFixtures.guiDefaults(),"Mode","1p_dmd");
            resolved=resolved{1};
            counts=groupcounts(resolved.events.target_cell_id);
            testCase.verifyEqual(counts,100*ones(size(counts)));
            testCase.verifyEqual(height(resolved.events),100*numel(counts));
        end
    end
end
