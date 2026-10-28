classdef TestFourPulseRampProtocol < matlab.unittest.TestCase
    %TESTFOURPULSERAMPPROTOCOL Four 500 ms pulses and a 1 s ramp, undithered.
    %   The protocol's whole point is that it is ORDINARY: a static Blue
    %   mask held for the acquisition while mod488 shapes the intensity.
    %   Two things therefore have to be true at once, and both are asserted
    %   at the sample level rather than from the event table:
    %
    %     the timeline is exactly what the protocol says it is, and
    %     nothing about blanket dithering is anywhere near it.
    %
    %   Sample level, because an event table is a statement of intent and
    %   what reaches the preparation is the compiled waveform. A test that
    %   read back onset_s would pass on a builder that emitted nothing.

    properties (Constant)
        % The rate AO imposes on the Virtual Upright. One sample is 5 us.
        Rate = 200000
    end

    methods (Test)
        % -----------------------------------------------------------------
        % The timeline
        % -----------------------------------------------------------------
        function theDefinitionCarriesTheRequestedTimeline(testCase)
            protocol=adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
                "PulseVoltageV",1.2,"RampEndVoltageV",3.4, ...
                "PreDelayS",0,"PostDelayS",0);
            events=protocol.acquisitions(1).events;

            testCase.assertEqual(height(events),5);
            testCase.verifyEqual(events.onset_s, ...
                [0;1;2;3;4],"AbsTol",0);
            testCase.verifyEqual(events.duration_s, ...
                [0.5;0.5;0.5;0.5;1.0],"AbsTol",0);
            testCase.verifyEqual(string(events.command_waveform), ...
                ["rectangular";"rectangular";"rectangular";"rectangular"; ...
                 "linear_ramp"]);
            testCase.verifyEqual(events.command_voltage_v, ...
                [1.2;1.2;1.2;1.2;3.4],"AbsTol",0);
            testCase.verifyEqual( ...
                protocol.acquisitions(1).acquisition_duration_s,5,"AbsTol",0);
        end

        function theDefaultPreAndPostWindowsAreAosOwn(testCase)
            % 100 ms each, which is what every other 1P generator here
            % defaults to. The STIMULUS is 5 s; the ACQUISITION is not.
            protocol=adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
                "PulseVoltageV",1,"RampEndVoltageV",2);
            events=protocol.acquisitions(1).events;
            testCase.verifyEqual(events.onset_s(1),0.100,"AbsTol",0);
            testCase.verifyEqual(events.onset_s(end),4.100,"AbsTol",0);
            testCase.verifyEqual( ...
                protocol.acquisitions(1).acquisition_duration_s,5.2,"AbsTol",1e-12);
        end

        function anAmplitudeOutsideTheModulatorRangeIsRefused(testCase)
            for bad=[0 -1 5.1]
                testCase.verifyError( ...
                    @()adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
                        "PulseVoltageV",bad,"RampEndVoltageV",1), ...
                    "adaptive_optopatch:InvalidFourPulseRampVoltage");
                testCase.verifyError( ...
                    @()adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
                        "PulseVoltageV",1,"RampEndVoltageV",bad), ...
                    "adaptive_optopatch:InvalidFourPulseRampVoltage");
            end
        end

        function anUnsetAmplitudeIsRefusedRatherThanDeferred(testCase)
            % Every other 1P protocol lets NaN fall through to the target
            % cell's own selected_blue_voltage_v. This one drives a UNION
            % of cells with one waveform, so there is no per-cell voltage
            % to fall back to and picking one would silently apply it to
            % all of them.
            testCase.verifyError( ...
                @()adaptive_optopatch.generate_four_pulse_ramp_protocol(), ...
                "adaptive_optopatch:InvalidFourPulseRampVoltage");
            testCase.verifyError( ...
                @()adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
                    "PulseVoltageV",1.2), ...
                "adaptive_optopatch:InvalidFourPulseRampVoltage");
            % And no fov_cell tier is offered for it either.
            protocol=adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
                "PulseVoltageV",1.2,"RampEndVoltageV",3.4);
            testCase.verifyFalse(any( ...
                protocol.parameter_sources.command_voltage_v=="fov_cell"));
        end

        % -----------------------------------------------------------------
        % All Stim-enabled cells at once, through one union mask
        % -----------------------------------------------------------------
        function theWholeExperimentIsOneAcquisitionNotOnePerCell(testCase)
            % Three Stim-enabled cells, one acquisition. Were this per-cell
            % the pulse/ramp train would run three times.
            definition=adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
                "PulseVoltageV",1.2,"RampEndVoltageV",3.4);
            testCase.verifyEqual(string(definition.target_policy), ...
                "simultaneous_stimulation_enabled_cells");

            [protocol,~,~]=resolved_protocol(1.2,3.4,[true true true]);
            testCase.verifyTrue( ...
                adaptive_optopatch.is_simultaneous_protocol(protocol));
            testCase.verifyEqual(height(protocol.events),5, ...
                "The pulse/ramp train must appear exactly once.");
            testCase.verifyNumElements( ...
                protocol.simultaneous_target_cell_ids,3);
        end

        function theDmdMaskIsExactlyTheUnionOfTheEnabledCells(testCase)
            % Middle cell Stim-disabled, so "the union of the enabled ones"
            % is distinguishable from "all of them" and from "the first".
            [protocol,targets,fovState]=resolved_protocol(1.2,3.4, ...
                [true false true]);
            enabled=[fovState.cells.stimulation_enabled];
            testCase.assertEqual(enabled(:)',[true false true]);

            mask=adaptive_optopatch.build_simultaneous_blue_mask( ...
                protocol,targets);
            expected=false(size(mask));
            for k=find(enabled)
                expected=expected|adaptive_optopatch.apply_blue_mask_adjustment( ...
                    targets.canonical_roi_masks(:,:,k), ...
                    protocol.parameters.blue_mask_adjustment_pixels);
            end
            testCase.verifyEqual(mask,expected, ...
                "The Blue pattern must be the union of the enabled masks.");

            % And the disabled cell is genuinely absent from it: its own
            % mask must contain a pixel the union does not.
            disabled=adaptive_optopatch.apply_blue_mask_adjustment( ...
                targets.canonical_roi_masks(:,:,2), ...
                protocol.parameters.blue_mask_adjustment_pixels);
            testCase.verifyTrue(any(disabled&~mask,"all"), ...
                "A Stim-disabled cell must not be lit by the union.");
            testCase.verifyFalse(any(ismember( ...
                string(protocol.simultaneous_target_cell_ids), ...
                string(fovState.cells(2).cell_id))));
        end

        function theDmdIsWrittenOnceAndHeldForTheAcquisition(testCase)
            % The runner's own branch: a simultaneous protocol takes
            % prepare_luminos_target with WriteDmdImmediately, which writes
            % one static pattern. No sequence plan, so no advance.
            [protocol,~,~]=resolved_protocol(1.2,3.4);
            testCase.verifyTrue( ...
                adaptive_optopatch.is_simultaneous_protocol(protocol));
            testCase.verifyTrue(all(protocol.events.target_cell_id=="multiple"), ...
                "A simultaneous acquisition names no single cell.");
            testCase.verifyTrue(all(protocol.events.target_index==0));
        end

        % -----------------------------------------------------------------
        % The compiled mod488 waveform
        % -----------------------------------------------------------------
        function theCompiledWaveformIsExactlyTheRequestedTimeline(testCase)
            for amplitudes=[1.2 3.4; 0.35 4.9]'
                pulseV=amplitudes(1); rampV=amplitudes(2);
                [samples,props]=compiled_modulator(testCase,pulseV,rampV);
                rate=testCase.Rate;

                testCase.verifyEqual(props.total_time,5.2,"AbsTol",1e-12);
                testCase.verifyEqual(numel(samples),round(5.2*rate));

                % Four square epochs, each exactly 500 ms, at the pulse
                % amplitude and nothing else.
                [starts,stops]=epochs_at(samples,pulseV);
                testCase.assertEqual(numel(starts),4, ...
                    sprintf("%.3g V: expected four square epochs.",pulseV));
                testCase.verifyEqual(stops-starts+1, ...
                    repmat(0.5*rate,1,4), ...
                    "Every square ON epoch must be 500 ms.");
                testCase.verifyEqual(starts, ...
                    round(rate*[0.1 1.1 2.1 3.1])+1, ...
                    "The squares must start where the protocol says.");

                % Every OFF interval between them, and the one before the
                % ramp, exactly 500 ms.
                for k=1:3
                    testCase.verifyEqual(starts(k+1)-stops(k)-1,0.5*rate, ...
                        "Inter-pulse OFF must be 500 ms.");
                end
                rampFirst=round(rate*4.1)+1;
                testCase.verifyEqual(rampFirst-stops(4)-1,0.5*rate, ...
                    "Pulse 4 to ramp OFF must be 500 ms.");

                % The ramp: starts at zero, rises monotonically, reaches
                % the endpoint on its last sample, 1.000 s long.
                rampLast=round(rate*5.1);
                ramp=samples(rampFirst:rampLast);
                testCase.verifyEqual(numel(ramp),rate, ...
                    "The ramp must be exactly 1.000 s.");
                testCase.verifyEqual(ramp(1),0,"AbsTol",0, ...
                    "The ramp must start at zero.");
                testCase.verifyEqual(ramp(end),rampV,"AbsTol",1e-12, ...
                    "The ramp must reach the configured endpoint.");
                testCase.verifyTrue(all(diff(ramp)>0), ...
                    "The ramp must rise monotonically.");
                % Linear, not merely monotonic.
                testCase.verifyEqual(ramp,rampV*(0:rate-1)'/(rate-1), ...
                    "AbsTol",1e-12);

                % And nothing outside the intended epochs.
                dark=true(size(samples));
                for k=1:4, dark(starts(k):stops(k))=false; end
                dark(rampFirst:rampLast)=false;
                testCase.verifyEqual(max(abs(samples(dark))),0, ...
                    "mod488 must be dark outside the intended epochs.");
            end
        end

        function theRampIsOneRecordOnOneTerminal(testCase)
            % Accounting refuses two records resolving to one physical
            % terminal, so a ramp cannot arrive as a second mod488 record
            % beside the rectangles.
            [~,~,configured]=compiled_modulator(testCase,1.2,3.4);
            records=modulator_records(configured);
            testCase.assertNumElements(records,1);
            testCase.verifyEqual(string(records.wavefile), ...
                "adaptive_optopatch.luminos_sampled_waveform");
            testCase.verifyEqual(string(records.script_owner), ...
                adaptive_optopatch.script_owner_tag());
        end

        function aRectangleOnlyProtocolStillUsesTheEventRecord(testCase)
            % The sampled path is taken ONLY when something needs a shape
            % luminos_event_waveform cannot draw. Every protocol written
            % before this one keeps the record it has always had, which is
            % what the hardened-builder parity test compares against.
            protocol=AoFixtures.resolvedProtocol( ...
                adaptive_optopatch.generate_screen_protocol("PulseCount",2, ...
                "ModulatorVoltage",1),"1p_dmd");
            profile=AoFixtures.onePhotonProfile();
            [~,configured]= ...
                adaptive_optopatch.build_luminos_mixed_waveform_config( ...
                adaptive_optopatch.build_luminos_global_props(profile, ...
                    protocol.acquisition_duration_s), ...
                empty_wfm(),protocol,"OnePhotonProfile",profile);
            records=modulator_records(configured);
            testCase.assertNumElements(records,1);
            testCase.verifyEqual(string(records.wavefile), ...
                "adaptive_optopatch.luminos_event_waveform");
        end

        % -----------------------------------------------------------------
        % It is not a dithered protocol, and must never become one
        % -----------------------------------------------------------------
        function blanketDepolarizationIsNotEnabled(testCase)
            protocol=resolved_protocol(1.2,3.4);
            blanket=adaptive_optopatch.blanket_depolarization_spec(protocol);
            testCase.verifyFalse(blanket.enabled);
            testCase.verifyFalse(isfield(protocol,"blanket_depolarization"), ...
                "The protocol must carry no blanket block at all.");
        end

        function thePlannerRefusesToBuildAStateTableForIt(testCase)
            % The strongest statement available: the blanket planner itself
            % says this acquisition is not one of its own. A protocol that
            % quietly grew a blanket block would stop failing here.
            protocol=resolved_protocol(1.2,3.4);
            testCase.verifyError( ...
                @()adaptive_optopatch.build_blanket_state_table( ...
                    protocol,testCase.Rate,0.001), ...
                "adaptive_optopatch:BlanketDepolarizationDisabled");
        end

        function theRunnerTakesTheStaticMaskPathNotTheSequencePath(testCase)
            % What decides it in run_1p_manifest: is_simultaneous_protocol
            % is tested FIRST, and takes prepare_luminos_target with the
            % union mask. A DMD sequence plan would mean the Blue DMD being
            % stepped between patterns, which is what this must not do.
            protocol=resolved_protocol(1.2,3.4);
            testCase.verifyTrue( ...
                adaptive_optopatch.is_simultaneous_protocol(protocol));
            oneRows=protocol.events.stimulation_source=="1p_dmd";
            adjustments=unique( ...
                protocol.events.blue_mask_adjustment_pixels(oneRows));
            testCase.verifyNumElements(adjustments,1, ...
                "A varying Blue mask would force a DMD sequence.");
        end

        function theWaveformSummaryReportsNoBlanketDelivery(testCase)
            [~,~,~,summary]=compiled_modulator(testCase,1.2,3.4);
            testCase.verifyFalse(isfield(summary,"blanket_depolarization"));
            testCase.verifyFalse(isfield(summary,"dmd_sequence"), ...
                "No DMD sequence plan may be installed for this protocol.");
            testCase.verifyFalse(ismember("blue_delivery", ...
                string(summary.pulses.Properties.VariableNames)), ...
                "blue_delivery is the blanket path's annotation.");
        end

        function theDmdTriggerIsHeldAtItsNeutralThroughout(testCase)
            % The advance line carries its declared neutral and nothing
            % else: no pattern is stepped during this acquisition.
            [~,props,configured]=compiled_modulator(testCase,1.2,3.4);
            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            roles=string({manifest.outputs.role});
            neutral=manifest.outputs(roles=="blue_dmd_advance_trigger").neutral_value;
            samples=terminal_samples(props,configured.do,"Dev1/port0/line4");
            testCase.assertNotEmpty(samples);
            testCase.verifyEqual(unique(samples),double(neutral));
        end
    end
end

% =====================================================================
% Helpers
% =====================================================================

function [protocol,targets,fovState]=resolved_protocol(pulseV,rampV,enabled)
%RESOLVED_PROTOCOL Resolve against a FOV with some cells enabled, some not.
%   AoFixtures.resolvedProtocol enables exactly one cell, which cannot
%   exercise a union. Three cells with the middle one Stim-disabled is the
%   smallest FOV that distinguishes "the union of the enabled ones" from
%   "all of them" and from "the first one".
arguments
    pulseV (1,1) double
    rampV (1,1) double
    enabled (1,:) logical = [true false true]
end
definition=adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
    "PulseVoltageV",pulseV,"RampEndVoltageV",rampV);
[fovState,~]=AoFixtures.fovState();
for k=1:numel(fovState.cells)
    fovState.cells(k).stimulation_enabled=k<=numel(enabled) && enabled(k);
end
fovState.reference.cells=fovState.cells;
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
resolved=adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
    AoFixtures.guiDefaults(),"Mode","1p_dmd");
% ONE acquisition for all of them, not one per cell. Asserted here rather
% than only in a test, because every test below indexes {1} and would
% quietly describe the first cell's acquisition if that stopped being true.
if numel(resolved)~=1
    error("Expected one simultaneous acquisition, got %d.",numel(resolved));
end
protocol=resolved{1};
end

function [samples,globalProps,configured,summary]=compiled_modulator( ...
        testCase,pulseV,rampV)
[protocol,~,~]=resolved_protocol(pulseV,rampV);
profile=AoFixtures.onePhotonProfile();
globalProps=adaptive_optopatch.build_luminos_global_props( ...
    profile,protocol.acquisition_duration_s);
testCase.assertEqual(globalProps.rate,testCase.Rate);
[globalProps,configured,summary]= ...
    adaptive_optopatch.build_luminos_mixed_waveform_config( ...
    globalProps,empty_wfm(),protocol,"OnePhotonProfile",profile);
samples=terminal_samples(globalProps,configured.ao,"Dev1/ao2");
end

function samples=terminal_samples(globalProps,records,terminal)
manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
compiled=adaptive_optopatch.compile_output_samples( ...
    globalProps,records,manifest.alias_list);
wanted=adaptive_optopatch.canonical_terminal(terminal,manifest.alias_list);
samples=[];
for k=1:numel(compiled)
    if compiled(k).canonical_terminal==wanted
        samples=compiled(k).samples(:); return
    end
end
end

function records=modulator_records(configured)
records=configured.ao([]);
manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
wanted=adaptive_optopatch.canonical_terminal("Dev1/ao2",manifest.alias_list);
for k=1:numel(configured.ao)
    spellings=[string(configured.ao(k).name) string(configured.ao(k).port)];
    if any(adaptive_optopatch.canonical_terminal( ...
            spellings,manifest.alias_list)==wanted)
        records(end+1)=configured.ao(k); %#ok<AGROW>
    end
end
end

function [starts,stops]=epochs_at(samples,level)
%EPOCHS_AT First and last sample index of every run held at one level.
on=abs(samples(:)-level)<1e-12;
edges=diff([false;on;false]);
starts=reshape(find(edges==1),1,[]);
stops=reshape(find(edges==-1)-1,1,[]);
end

function data=empty_wfm()
data=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
end
