classdef TestWaveformOwnershipRegressions < matlab.unittest.TestCase
    %TESTWAVEFORMOWNERSHIPREGRESSIONS Stale ambient records must not survive.
    %   Every assertion here compiles the candidate configuration to the
    %   samples that would reach the wire. Asserting that the right records
    %   exist would pass for all of these bugs: they happen after the
    %   records leave AO, when Luminos resolves an alias and combines what
    %   it finds on one terminal.

    methods (Test)
        % -----------------------------------------------------------------
        % 1P: the DMD Trigger alias hole
        % -----------------------------------------------------------------
        function staleDmdTriggerAliasCannotCombineWithTheAdvanceTrain(testCase)
            [plan,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            % The exact spelling Waveforms stores: the rig alias, not the
            % terminal. This is what used to survive AO's filtering.
            ambient.do=constant("Legacy DMD pulse","DMD Trigger",1);

            [globalProps,withAmbient]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol, ...
                adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);
            [~,clean]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),empty_wfm_data(),protocol, ...
                adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);

            line4=terminal_samples(testCase,globalProps,withAmbient.do, ...
                "Dev1/port0/line4");
            intended=terminal_samples(testCase,globalProps,clean.do, ...
                "Dev1/port0/line4");
            % Exactly AO's train, sample for sample, and nothing else.
            testCase.verifyEqual(line4.samples,intended.samples);
            testCase.verifyEqual(line4.record_count,1, ...
                "The stale alias record must be gone, not merely outvoted.");
            testCase.verifyGreaterThan(sum(intended.samples>0),0, ...
                "The fixture must actually command advances, or this proves nothing.");
        end

        function staleDmdTriggerAliasCannotSurviveATrialThatAdvancesNothing(testCase)
            % A single-target trial installs no advance train at all, and
            % used to leave whatever was on the line in place.
            [~,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            ambient.do=constant("Legacy DMD pulse","DMD Trigger",1);
            [globalProps,configured]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol);
            line4=terminal_samples(testCase,globalProps,configured.do, ...
                "Dev1/port0/line4");
            testCase.verifyEqual(line4.record_count,1);
            testCase.verifyTrue(all(line4.samples==0), ...
                "An uncommanded advance line must hold its declared low state.");
        end

        % -----------------------------------------------------------------
        % 1P: stale 2P records, written under alias/slash/case variants
        % -----------------------------------------------------------------
        function staleTwoPhotonRecordsAreNeutralizedDuringAOnePhotonRun(testCase)
            [~,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            ambient.ao=[constant("legacy galvo x","/Dev2/AO0",3.1), ...
                constant("legacy galvo y","dev2/AO1",-2.7), ...
                constant("legacy pockels","2P mod",4.4)];
            [globalProps,configured]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol);

            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            for role=["galvo_x","galvo_y","two_photon_modulator"]
                entry=declaration(manifest,role);
                measured=terminal_samples(testCase,globalProps,configured.ao, ...
                    entry.terminal);
                testCase.verifyEqual(measured.record_count,1, ...
                    "A stale spelling survived onto "+entry.terminal+".");
                testCase.verifyTrue( ...
                    all(measured.samples==double(entry.neutral_value)), ...
                    entry.terminal+" did not hold its declared neutral.");
            end
        end

        % -----------------------------------------------------------------
        % 1P: the shutter488 ownership hazard
        % -----------------------------------------------------------------
        function ambientShutterWaveformCannotContendWithImperativeControl(testCase)
            % A 1P run opens and closes shutter488 imperatively around the
            % armed window, so a buffered record on the same line is a
            % second runtime owner of it. The record is removed; AO does not
            % install one of its own, because driving the line from the
            % buffer would change when light reaches the preparation.
            [~,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            ambient.do=constant("legacy shutter","shutter488",1);
            [globalProps,configured,summary]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol);
            compiled=adaptive_optopatch.compile_output_samples( ...
                globalProps,configured.do);
            canonical=adaptive_optopatch.canonical_terminal("Dev1/port0/line0");
            testCase.verifyFalse(any([compiled.canonical_terminal]==canonical), ...
                "No buffered record may own the 488 shutter during a 1P run.");
            testCase.verifyEqual(summary.blue_shutter_runtime_owner,"imperative");
        end

        % -----------------------------------------------------------------
        % 2P: stale 1P records
        % -----------------------------------------------------------------
        function staleOnePhotonRecordsCannotStimulateDuringATwoPhotonRun(testCase)
            ambient=empty_wfm_data();
            ambient.ao=constant("legacy mod488","MOD488",3.9);
            ambient.do=[constant("legacy dmd","DMD Trigger",1), ...
                constant("legacy shutter","/DEV1/PORT0/LINE0",1)];
            [globalProps,configured]= ...
                adaptive_optopatch.build_luminos_2p_waveform_config( ...
                live_global_props(200000),ambient,two_photon_waveforms());

            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            analog=declaration(manifest,"blue_modulator");
            measured=terminal_samples(testCase,globalProps,configured.ao, ...
                analog.terminal);
            testCase.verifyEqual(measured.record_count,1);
            testCase.verifyTrue(all(measured.samples==double(analog.neutral_value)));

            for role=["blue_dmd_advance_trigger","blue_shutter"]
                entry=declaration(manifest,role);
                measured=terminal_samples(testCase,globalProps,configured.do, ...
                    entry.terminal);
                testCase.verifyEqual(measured.record_count,1, ...
                    "A stale spelling survived onto "+entry.terminal+".");
                testCase.verifyTrue( ...
                    all(measured.samples==double(entry.neutral_value)));
            end
        end

        % -----------------------------------------------------------------
        % Inherited imaging infrastructure survives
        % -----------------------------------------------------------------
        function deliberatelyInheritedImagingOutputsSurviveBothBuilders(testCase)
            [~,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            ambient.ao=constant("mod594","mod594",0.35);
            ambient.do=constant("shutter594","shutter594",1);

            [globalProps,onePhoton]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol);
            measured=terminal_samples(testCase,globalProps,onePhoton.ao, ...
                "Dev1/ao1");
            testCase.verifyEqual(max(measured.samples),0.35, ...
                "AO must not clear the operator's orange illumination.");

            [globalProps,twoPhoton]= ...
                adaptive_optopatch.build_luminos_2p_waveform_config( ...
                live_global_props(200000),ambient,two_photon_waveforms());
            measured=terminal_samples(testCase,globalProps,twoPhoton.ao, ...
                "Dev1/ao1");
            testCase.verifyEqual(max(measured.samples),0.35);

            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,twoPhoton,"Modality","2p_spiral");
            row=accounting_row(report,"Dev1/ao1");
            testCase.verifyEqual(row.classification,"inherited_non_stimulation");
            testCase.verifyEqual(row.role,"orange_modulator");
        end

        % -----------------------------------------------------------------
        % Pure-run semantics are unchanged
        % -----------------------------------------------------------------
        function onePhotonPulseTimingAndVoltageAreUnchanged(testCase)
            % The pass may close stale-record holes. It may not move a pulse
            % or change a command voltage, so the commanded line is compared
            % against the schedule itself rather than against a snapshot.
            [~,protocol]=screen_sequence_plan();
            rate=200000;
            [globalProps,configured,summary]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(rate),empty_wfm_data(),protocol);
            measured=terminal_samples(testCase,globalProps,configured.ao, ...
                "Dev1/ao2");
            pulses=summary.pulses;
            % The same time vector Calculate_tvec builds, not an equivalent
            % one: linspace and (0:n-1)/rate differ in the last bits, which
            % is enough to move a sample across a pulse boundary.
            n=numel(measured.samples);
            tvec=linspace(0,(n-1)/rate,n);
            expected=zeros(size(measured.samples));
            for k=1:height(pulses)
                span=tvec>=pulses.onset_s(k) & tvec<pulses.offset_s(k);
                expected(span)=pulses.modulator_voltage(k);
            end
            expected(end)=0;
            testCase.verifyEqual(measured.samples,expected, ...
                "1P pulse timing or amplitude moved.");
        end

        function twoPhotonCommandSamplesAreUnchanged(testCase)
            waveforms=two_photon_waveforms();
            [globalProps,configured]= ...
                adaptive_optopatch.build_luminos_2p_waveform_config( ...
                live_global_props(200000),empty_wfm_data(),waveforms);
            expected={"Dev2/ao0",waveforms.x_v; "Dev2/ao1",waveforms.y_v; ...
                "Dev1/ao3",waveforms.pockels_v};
            for k=1:size(expected,1)
                measured=terminal_samples(testCase,globalProps,configured.ao, ...
                    expected{k,1});
                want=reshape(expected{k,2},1,[]);
                want(end)=0;
                testCase.verifyEqual(measured.samples,want, ...
                    "2P command samples moved on "+expected{k,1});
            end
        end

        % -----------------------------------------------------------------
        % Ownership tagging
        % -----------------------------------------------------------------
        function everyRecordAOAddsCarriesTheLuminosOwnershipTag(testCase)
            [plan,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            ambient.ao=constant("mod594","mod594",0.35);
            [~,configured]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol,...
                adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);
            owner=adaptive_optopatch.script_owner_tag();
            records=[configured.ao configured.do];
            tags=strings(1,numel(records));
            for k=1:numel(records)
                if ~isempty(records(k).script_owner)
                    tags(k)=string(records(k).script_owner);
                end
            end
            testCase.verifyEqual(sum(tags==owner),5, ...
                "mod488, both galvos, the Pockels neutral and the DMD train.");
            % The operator's own record is left untagged, so dropping AO's
            % entries can never take it with them.
            inherited=configured.ao(string({configured.ao.name})=="mod594");
            testCase.verifyEmpty(inherited.script_owner);
        end

        function staleAORecordsFromACrashedRunAreTakenBackOut(testCase)
            [~,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            stale=constant("AdaptiveOptopatch DMD trigger","Dev1/port0/line4",1);
            stale.script_owner=char(adaptive_optopatch.script_owner_tag());
            orphan=constant("Adaptive2P_X","Dev2/ao0",4.8);
            orphan.script_owner=char(adaptive_optopatch.script_owner_tag());
            ambient.do=stale;
            ambient.ao=orphan;

            [globalProps,configured]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol);
            galvo=terminal_samples(testCase,globalProps,configured.ao,"Dev2/ao0");
            testCase.verifyEqual(galvo.record_count,1);
            testCase.verifyTrue(all(galvo.samples==0));
            trigger=terminal_samples(testCase,globalProps,configured.do, ...
                "Dev1/port0/line4");
            testCase.verifyEqual(trigger.record_count,1);
        end

        % -----------------------------------------------------------------
        % The two compile implementations must agree
        % -----------------------------------------------------------------
        function theTestOracleAndTheRuntimeCompilerAgree(testCase)
            % compile_output_samples (runtime, used by accounting) and
            % compile_wfm_data_to_samples (this directory's independent
            % transcription of DAQ.Build_Waveforms) are deliberately written
            % twice. This is what stops them drifting apart in silence.
            [plan,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            ambient.ao=[constant("mod594","mod594",0.35), ...
                constant("legacy pockels","2P mod",4.4)];
            ambient.do=constant("legacy dmd","DMD Trigger",1);
            [globalProps,configured]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol, ...
                adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);
            for field=["ao","do"]
                runtime=adaptive_optopatch.compile_output_samples( ...
                    globalProps,configured.(field));
                oracle=compile_wfm_data_to_samples(globalProps,configured.(field));
                testCase.verifyEqual([runtime.port],[oracle.port]);
                for k=1:numel(runtime)
                    testCase.verifyEqual(runtime(k).samples,oracle(k).samples, ...
                        "Compilers disagree on "+runtime(k).port);
                end
            end
        end

        function theOracleReportsATerminalCollisionRatherThanMergingIt(testCase)
            % Two spellings that survive aliasing as different strings do
            % not combine in Luminos; it resolves two channels onto one
            % physical line. The oracle has to say that, not average them.
            globalProps=live_global_props(1000);
            globalProps.total_time=0.01;
            records=[constant("first","Dev2/ao0",1), ...
                constant("second","/Dev2/AO0",2)];
            compiled=compile_wfm_data_to_samples(globalProps,records);
            testCase.verifyNumElements(compiled,2);
            testCase.verifyEqual(compiled(1).canonical_terminal, ...
                compiled(2).canonical_terminal);
            testCase.verifyEqual(compiled(1).collides_with,"/Dev2/AO0");
            testCase.verifyEqual(compiled(2).collides_with,"Dev2/ao0");
        end
    end
end

% =====================================================================
% Fixtures
% =====================================================================

function entry=declaration(manifest,role)
entry=manifest.outputs(string({manifest.outputs.role})==string(role));
end

function row=accounting_row(report,terminal)
canonical=adaptive_optopatch.canonical_terminal(terminal);
match=report.terminals.canonical_terminal==canonical;
row=table2struct(report.terminals(match,:));
end

function measured=terminal_samples(testCase,globalProps,records,terminal)
compiled=compile_wfm_data_to_samples(globalProps,records);
canonical=adaptive_optopatch.canonical_terminal(terminal);
match=find([compiled.canonical_terminal]==canonical);
testCase.assertNumElements(match,1, ...
    "Expected exactly one compiled terminal for "+terminal+".");
measured=compiled(match);
end

function record=constant(name,port,value)
record=struct("name",char(name),"port",char(port), ...
    "wavefile","awfm_constant","params",{{double(value)}}, ...
    "operation","Multiplication","concatTime",[]);
end

function waveforms=two_photon_waveforms()
n=400; fs=200000;
waveforms=struct("sample_rate_hz",fs, ...
    "x_v",linspace(0,0.4,n)',"y_v",linspace(0,-0.3,n)', ...
    "pockels_v",[zeros(100,1);0.8*ones(100,1);zeros(200,1)], ...
    "preflight",struct("passed",true),"per_pulse",struct([]));
end

function props=live_global_props(rate)
props=struct("rate",rate,"total_time",1,"clock_source","Internal Dev1", ...
    "trigger_source","Dev1/PFI9","completion_trigger","None","daq_master",true);
end

function data=empty_wfm_data()
data=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
end

function [plan,protocol]=screen_sequence_plan()
[fovState,targets]=two_cell_fixture();
definition=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",4,"PulseDurationMs",5,"DarkIntervalMs",[50 50], ...
    "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1.25);
resolved=adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
    gui_defaults(),"Mode","1p_dmd");
protocol=resolved{1};
plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
end

function [fovState,targets]=two_cell_fixture()
% Two stimulable cells, so a screen protocol produces a multi-target trial
% and therefore a real DMD advance train to compare against.
image=zeros(40,40); masks=false(40,40,2);
masks(6:15,6:15,1)=true; masks(24:33,24:33,2)=true;
polygons={[6 6;15 6;15 15;6 15],[24 24;33 24;33 33;24 33]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","waveform_ownership_test", ...
    "CellIds",["cell_001","cell_002"],"RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
for id=["cell_001","cell_002"]
    fovState=adaptive_optopatch.update_cell_calibration( ...
        fovState,id,"CommandVoltageV",1.25);
end
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
end

function defaults=gui_defaults()
defaults=struct("command_voltage_v",1.25,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
