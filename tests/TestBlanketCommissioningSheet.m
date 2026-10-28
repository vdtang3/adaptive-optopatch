classdef TestBlanketCommissioningSheet < matlab.unittest.TestCase
    %TESTBLANKETCOMMISSIONINGSHEET The expected sequence a rig is checked against.
    %   describe_blanket_commissioning prints what a blanket run SHOULD do,
    %   trigger by trigger, so somebody at the Virtual Upright can compare
    %   it with a photodiode trace and the ALP's counters.
    %
    %   What these tests protect is that the sheet is derived from the same
    %   two functions the runner uses rather than restating their arithmetic.
    %   A sheet that computed its own timing would agree with itself and
    %   disagree with the rig, which is the one failure mode that would make
    %   commissioning actively misleading.

    properties (Constant)
        Rate = 200000
        FramePeriodS = 0.001
    end

    methods (Test)
        function theSheetReportsTheImplementedCycle(testCase)
            % The numbers docs/commissioning/blanket-depolarization.md
            % quotes. If an edit changes the implemented cycle, this is
            % what says the document is now wrong.
            sheet=commissioning_sheet(testCase);
            testCase.verifyEqual(sheet.cycle_period_ms,1.0,"AbsTol",0);
            testCase.verifyEqual(sheet.camera_frame_period_ms,1.0,"AbsTol",0);
            testCase.verifyEqual(sheet.blanket_phase_ms,0.2,"AbsTol",1e-12);
            testCase.verifyEqual(sheet.target_phase_ms,0.8,"AbsTol",1e-12);
            testCase.verifyEqual(sheet.blanket_duty_fraction,0.20,"AbsTol",1e-12);
            testCase.verifyEqual(sheet.target_onset_guard_us,50,"AbsTol",1e-9);
            testCase.verifyEqual(sheet.target_lit_fraction,0.75,"AbsTol",1e-12);
            testCase.verifyEqual(sheet.dmd_trigger_width_us,20,"AbsTol",1e-9);
            testCase.verifyEqual(sheet.dmd_trigger_lead_us,0,"AbsTol",0);
        end

        function everyStateIsOneTriggerAndTheCountIsTheRunners(testCase)
            sheet=commissioning_sheet(testCase);
            testCase.verifyEqual(height(sheet.unit),sheet.states_per_unit);
            testCase.verifyEqual(sheet.expected_trigger_count, ...
                sheet.states_per_unit*sheet.unit_repeats);

            % The same number the state table gives the runner, asked of
            % the state table directly rather than recomputed here.
            protocol=blanket_protocol();
            stateTable=adaptive_optopatch.build_blanket_state_table( ...
                protocol,testCase.Rate,testCase.FramePeriodS);
            testCase.verifyEqual(sheet.expected_trigger_count, ...
                stateTable.expected_trigger_count);
        end

        function theTriggerTimesAreTheStateTablesOwn(testCase)
            protocol=blanket_protocol();
            stateTable=adaptive_optopatch.build_blanket_state_table( ...
                protocol,testCase.Rate,testCase.FramePeriodS);
            sheet=commissioning_sheet(testCase);
            expected=stateTable.round_start_sample+ ...
                stateTable.states.start_sample;
            testCase.verifyEqual(sheet.unit.trigger_sample,expected);
            testCase.verifyEqual(sheet.unit.trigger_time_s, ...
                expected/testCase.Rate,"AbsTol",0);
        end

        function theStatesAlternateBlanketAndSomethingElse(testCase)
            % What makes the alternation legible on a slide: every odd
            % state is the blanket and every even one is the thing being
            % distinguished from it.
            sheet=commissioning_sheet(testCase);
            types=string(sheet.unit.state_type);
            testCase.verifyTrue(all(types(1:2:end)=="blanket"));
            testCase.verifyTrue(all(ismember(types(2:2:end), ...
                ["target","dark"])));
            % Only the target states carry the guard.
            guard=sheet.unit.dark_lead_us;
            testCase.verifyTrue(all(guard(types=="target")==50));
            testCase.verifyTrue(all(guard(types~="target")==0));
        end

        function theBlanketIsLitInEveryCycleIncludingGaps(testCase)
            % The claim the slide test rests on: both ROIs see blanket
            % light in every cycle, so a frame where neither does is a
            % missed trigger rather than a gap.
            sheet=commissioning_sheet(testCase);
            blanket=sheet.unit(string(sheet.unit.state_type)=="blanket",:);
            testCase.verifyTrue(all(blanket.mod488_v==blanket_voltage()));
            testCase.verifyTrue(all(blanket.lit_us==200));
            testCase.verifyTrue(any(string(blanket.segment)=="gap"), ...
                "Gap cycles must still carry a blanket state.");
        end

        function thePlaylistPeriodMatchesTheRealPlanner(testCase)
            % The sheet derives the playlist length from the mask-key
            % sequence when it has no target bundle. That has to agree
            % with what build_blanket_dmd_sequence_plan works out from
            % pixels, or a commissioning sheet would predict the wrong
            % final playlist entry.
            [protocol,targets]=blanket_protocol();
            withoutTargets=adaptive_optopatch.describe_blanket_commissioning( ...
                protocol,"SampleRateHz",testCase.Rate, ...
                "CameraFramePeriodS",testCase.FramePeriodS,"Print",false);
            withTargets=adaptive_optopatch.describe_blanket_commissioning( ...
                protocol,"SampleRateHz",testCase.Rate, ...
                "CameraFramePeriodS",testCase.FramePeriodS,"Print",false, ...
                "Targets",targets);
            testCase.verifyEqual(withoutTargets.playlist_source, ...
                "mask_key period");
            testCase.verifyEqual(withTargets.playlist_source, ...
                "build_blanket_dmd_sequence_plan");
            testCase.verifyEqual(withoutTargets.playlist_length, ...
                withTargets.playlist_length);
        end

        function aNonBlanketProtocolIsRefusedRatherThanDescribed(testCase)
            protocol=AoFixtures.resolvedProtocol( ...
                adaptive_optopatch.generate_screen_protocol("PulseCount",1, ...
                "ModulatorVoltage",1),"1p_dmd");
            testCase.verifyError( ...
                @()adaptive_optopatch.describe_blanket_commissioning( ...
                    protocol,"Print",false), ...
                "adaptive_optopatch:BlanketDepolarizationDisabled");
        end

        function theSheetPrintsWithoutThrowing(testCase)
            % It is read at a rig, so printing is the feature.
            protocol=blanket_protocol();
            printed=evalc( ...
                "adaptive_optopatch.describe_blanket_commissioning(protocol," + ...
                """SampleRateHz"",200000,""CameraFramePeriodS"",0.001);");
            testCase.verifySubstring(printed,"Blanket commissioning sheet");
            testCase.verifySubstring(printed,"external triggers");
            testCase.verifySubstring(printed,"BEFORE THE FIRST TRIGGER");
        end
    end
end

% =====================================================================

function value=blanket_voltage()
value=0.8;
end

function [protocol,targets]=blanket_protocol()
%BLANKET_PROTOCOL A two-cell commissioning round robin, resolved.
%   Deliberately the shape the slide procedure asks for: two cells, so the
%   round is [blanket|cell1][blanket|gap][blanket|cell2][blanket|gap].
definition=adaptive_optopatch.generate_blanket_round_robin_protocol( ...
    "BlanketMod488V",blanket_voltage(),"Rounds",3, ...
    "EpochDurationS",0.020,"InterEpochGapS",0.010, ...
    "PreDelayS",0.100,"PostDelayS",0.100, ...
    "CommandVoltageV",1.5,"ProtocolId","blanket_commissioning");
% Two Stim-enabled cells, which is the shape the slide procedure asks for:
% the round is [blanket|cell1][blanket|gap][blanket|cell2][blanket|gap].
[fovState,~]=AoFixtures.fovState();
for k=1:numel(fovState.cells)
    fovState.cells(k).stimulation_enabled=k<=2;
end
fovState.reference.cells=fovState.cells;
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
resolved=adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
    AoFixtures.guiDefaults(),"Mode","1p_dmd");
protocol=resolved{1};
end

function sheet=commissioning_sheet(testCase)
sheet=adaptive_optopatch.describe_blanket_commissioning(blanket_protocol(), ...
    "SampleRateHz",testCase.Rate, ...
    "CameraFramePeriodS",testCase.FramePeriodS,"Print",false);
end
