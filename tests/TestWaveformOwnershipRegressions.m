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
        function staleTwoPhotonRecordsAreSuppressedDuringAOnePhotonRun(testCase)
            % Written under alias, slash and case variants, because that is
            % how Waveforms actually stores them. All three terminals must
            % leave the run: removed, and NOT replaced by a constant. A
            % constant on Dev2/ao0 or Dev2/ao1 is a buffered record on the
            % galvo card, which is what made Luminos build a Dev2 AO task
            % during a 1P-only acquisition and fail to route its clock.
            [~,protocol]=screen_sequence_plan();
            ambient=empty_wfm_data();
            ambient.ao=[constant("legacy galvo x","/Dev2/AO0",3.1), ...
                constant("legacy galvo y","dev2/AO1",-2.7), ...
                constant("legacy pockels","2P mod",4.4)];
            [globalProps,configured]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),ambient,protocol);

            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            compiled=adaptive_optopatch.compile_output_samples( ...
                globalProps,configured.ao,manifest.alias_list);
            for role=["galvo_x","galvo_y","two_photon_modulator"]
                entry=declaration(manifest,role);
                canonical=adaptive_optopatch.canonical_terminal( ...
                    entry.terminal,manifest.alias_list);
                testCase.verifyFalse( ...
                    any([compiled.canonical_terminal]==canonical), ...
                    entry.terminal+" must carry no record during a 1P run, " + ...
                    "neither a stale one nor an AO replacement.");
            end
            % Accounting reads the same configuration the same way.
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd");
            for role=["galvo_x","galvo_y","two_photon_modulator"]
                row=report.declared(report.declared.role==role,:);
                testCase.verifyFalse(row.present);
                testCase.verifyEqual(row.runtime_owner,"suppressed");
            end
            testCase.verifyEmpty(report.violations);
        end

        function aSurvivingGalvoRecordIsAViolationDuringAOnePhotonRun(testCase)
            % The runtime guard behind the removal above. A buffered record
            % on a suppressed output is an output nothing asked for, and on
            % the galvo card it is also the Dev2 AO task a 1P run must not
            % create - so it blocks whatever its samples measure, including
            % a constant sitting exactly on the declared neutral.
            [~,protocol]=screen_sequence_plan();
            [globalProps,configured]= ...
                adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),empty_wfm_data(),protocol);
            neutral=constant("stray galvo x","Dev2/ao0",0);
            neutral.script_owner=char(adaptive_optopatch.script_owner_tag());
            configured.ao=append_wfm_record(configured.ao,neutral);
            for policy=["report_only","fail_closed"]
                report=adaptive_optopatch.account_stimulation_outputs( ...
                    globalProps,configured,"Modality","1p_dmd","Policy",policy);
                testCase.verifyFalse(report.passed);
                testCase.verifySubstring( ...
                    char(strjoin(report.violations," ")),"suppresses from the run");
            end
            % A mixed acquisition genuinely drives the galvos, so the same
            % record there is not this fault.
            mixed=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","mixed");
            testCase.verifyEmpty(mixed.violations);
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
            testCase.verifyEqual(sum(tags==owner),2, ...
                "mod488 and the DMD train, and nothing else: the galvos " + ...
                "and the Pockels cell are suppressed rather than driven.");
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
            % The orphan galvo record is taken out and nothing takes its
            % place: a 1P run leaves the galvo card out of the acquisition.
            compiled=adaptive_optopatch.compile_output_samples( ...
                globalProps,configured.ao);
            testCase.verifyFalse(any([compiled.canonical_terminal]== ...
                adaptive_optopatch.canonical_terminal("Dev2/ao0")));
            % The advance line is the deliberate exception: it is AO's own
            % during a 1P run, so a stale record is replaced rather than
            % merely dropped.
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
