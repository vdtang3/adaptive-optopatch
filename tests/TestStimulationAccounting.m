classdef TestStimulationAccounting < matlab.unittest.TestCase
    %TESTSTIMULATIONACCOUNTING What the candidate waveform would actually do.
    %   Accounting exists to answer, before anything is installed: which
    %   stimulation-capable terminals exist, which are commanded, which are
    %   neutral, which are inherited, and which nothing has accounted for.

    methods (Test)
        function everyInactiveDeclaredOutputReadsBackAtItsDeclaredNeutral(testCase)
            % The sample-level read-back the whole pass is built around. A
            % record that merely looks like a zero constant is not evidence.
            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();

            % A 1P run suppresses the 2P outputs rather than holding them,
            % so there is no sample to read back on them at all - the
            % declared roll-up is what says so. mod488 and the advance line
            % are the 1P outputs a sample-level read-back applies to.
            [globalProps,onePhoton]=one_photon_configuration();
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,onePhoton,"Modality","1p_dmd");
            for role=["galvo_x","galvo_y","two_photon_modulator"]
                verify_suppressed(testCase,report,role);
            end
            verify_neutral(testCase,report,manifest,"blue_dmd_advance_trigger");

            [globalProps,twoPhoton]=two_photon_configuration();
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,twoPhoton,"Modality","2p_spiral");
            for role=["blue_modulator","blue_dmd_advance_trigger","blue_shutter"]
                verify_neutral(testCase,report,manifest,role);
            end
        end

        function commandedOutputsAreReportedAsCommandedNotNeutral(testCase)
            [globalProps,configured]=one_photon_configuration();
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd");
            mod488=row_for(report,"Dev1/ao2");
            testCase.verifyEqual(mod488.classification,"commanded");
            testCase.verifyEqual(mod488.role,"blue_modulator");
            testCase.verifyTrue(mod488.ao_owned_records);
            testCase.verifyEqual(string(mod488.ownership_tags), ...
                adaptive_optopatch.script_owner_tag());
            testCase.verifyFalse(mod488.neutral_verified);
            testCase.verifyGreaterThan(mod488.measured_maximum,0);
        end

        function aStaleRecordCommandingAnOwnedTerminalIsAViolation(testCase)
            % Report-only is about terminals AO cannot classify. A record
            % driving a terminal AO owns, and that AO did not write, is
            % something the code can prove unsafe, so it blocks either way.
            [globalProps,configured]=one_photon_configuration();
            configured.ao=append_wfm_record(configured.ao, ...
                constant("legacy pockels","2P mod",4.4));
            for policy=["report_only","fail_closed"]
                report=adaptive_optopatch.account_stimulation_outputs( ...
                    globalProps,configured,"Modality","1p_dmd","Policy",policy);
                testCase.verifyFalse(report.passed);
                testCase.verifyNotEmpty(report.violations);
                testCase.verifySubstring(char(strjoin(report.violations," ")), ...
                    "Dev1/ao3");
            end
        end

        function anAmbientSurveyReportsOwnershipRatherThanBlamingTheOperator(testCase)
            % Before a modality is chosen there is no answer to who should
            % own a line, so the operator's own live mod488 waveform is
            % what AO is about to replace, not a fault. Recorded, not
            % escalated.
            % An operator's own configuration: untagged, and driving a
            % terminal AO owns, which is the ordinary state of the rig
            % before AO builds anything.
            globalProps=live_global_props();
            ambient=empty_wfm_data();
            ambient.ao=constant("mod488","mod488",2.0);

            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,ambient,"Modality","unknown");
            testCase.verifyEmpty(report.violations);
            testCase.verifyTrue(report.passed);
            testCase.verifySubstring(char(strjoin(report.observations," ")), ...
                "ambient survey");
            % The measurement itself is unchanged: it still says mod488 is
            % commanding Dev1/ao2 at 2 V.
            mod488=row_for(report,"Dev1/ao2");
            testCase.verifyEqual(mod488.classification,"commanded");
            testCase.verifyEqual(mod488.measured_maximum,2.0);

            % The same record during a 1P run IS a fault, because then
            % there is an answer to who should own the line.
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,ambient,"Modality","1p_dmd");
            testCase.verifyNotEmpty(report.violations);

            % Duplicates are unsafe whoever wrote them, so a missing
            % modality does not excuse one.
            ambient.ao=append_wfm_record(ambient.ao, ...
                constant("second mod488","Dev1/ao2",0));
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,ambient,"Modality","unknown");
            testCase.verifyNotEmpty(report.violations);
        end

        function duplicateRecordsOnOneOwnedTerminalAreDetected(testCase)
            [globalProps,configured]=one_photon_configuration();
            % Same terminal, same spelling: Luminos combines these into one
            % waveform that neither record describes. Asserted on mod488,
            % which is the AO-owned analog output a 1P build actually
            % installs - the galvo and Pockels terminals are suppressed
            % from a 1P run, so a single record there is not a duplicate of
            % anything.
            configured.ao=append_wfm_record(configured.ao, ...
                constant("second mod488","mod488",0));
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd");
            row=row_for(report,"Dev1/ao2");
            testCase.verifyTrue(row.duplicate_records);
            testCase.verifyEqual(row.record_count,2);
            testCase.verifyFalse(report.passed);
            testCase.verifySubstring(char(strjoin(report.violations," ")), ...
                "2 records resolve to");
        end

        function twoSpellingsOfOneOwnedTerminalAreDetectedAsACollision(testCase)
            % AO installs mod488 under the rig alias, which de-aliases to
            % Dev1/ao2. A slash-and-case spelling of the same terminal does
            % NOT de-alias, so Luminos groups it separately and resolves
            % two channels onto one physical line.
            [globalProps,configured]=one_photon_configuration();
            configured.ao=append_wfm_record(configured.ao, ...
                constant("legacy mod488","/DEV1/AO2",0));
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd");
            testCase.verifyFalse(report.passed);
            testCase.verifySubstring(char(strjoin(report.violations," ")), ...
                "name the same physical terminal");
        end

        function aBufferedRecordOnAnImperativelyOwnedLineIsAViolation(testCase)
            % The shutter488 hazard stated as an invariant: during a 1P run
            % the line is driven imperatively, so any buffered record on it
            % is a second runtime owner.
            [globalProps,configured]=one_photon_configuration();
            configured.do=append_wfm_record(configured.do, ...
                constant("legacy shutter","shutter488",0));
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd");
            testCase.verifyFalse(report.passed);
            testCase.verifySubstring(char(strjoin(report.violations," ")), ...
                "drives imperatively");

            % The very same record is correct during a 2P run, where the
            % buffered constant IS the owner.
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","2p_spiral");
            testCase.verifyEmpty(strfind( ...
                char(strjoin(report.violations," ")),"drives imperatively"));
        end

        function unaccountedTerminalsWarnUnderReportOnlyAndBlockWhenClosed(testCase)
            [globalProps,configured]=one_photon_configuration();
            configured.ao=append_wfm_record(configured.ao, ...
                constant("mystery box","Dev1/ao6",2.5));

            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd","Policy","report_only");
            testCase.verifyTrue(report.passed, ...
                "Pass 3A must not block a real rig on a terminal it has " + ...
                "simply never been told about.");
            testCase.verifyNotEmpty(report.warnings);
            testCase.verifyTrue(any(report.unaccounted_terminals== ...
                adaptive_optopatch.canonical_terminal("Dev1/ao6")));

            % Not silently passed through: it is in the terminal table with
            % its record named, and what it would output was measured.
            row=row_for(report,"Dev1/ao6");
            testCase.verifyEqual(row.classification,"unaccounted");
            testCase.verifyEqual(string(row.record_names),"mystery box");
            testCase.verifyEqual(row.measured_maximum,2.5);

            closed=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd","Policy","fail_closed");
            testCase.verifyFalse(closed.passed);
            testCase.verifyNotEmpty(closed.blocking);
        end

        function anUnaccountedTerminalTheRigDescribesCarriesThatContext(testCase)
            % Dev1/port0/line5 is unaccounted, but the report should hand
            % over what the rig file says rather than leave a commissioning
            % session to go and look it up.
            [globalProps,configured]=one_photon_configuration();
            configured.do=append_wfm_record(configured.do, ...
                constant("something","Dev1/port0/line5",1));
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd");
            row=row_for(report,"Dev1/port0/line5");
            testCase.verifyEqual(row.classification,"unaccounted");
            testCase.verifyEqual(row.role,"general_shutter");
            testCase.verifySubstring(char(strjoin(report.warnings," ")), ...
                "General Shutter");
        end

        function aCameraTriggeredRecordOnAnOwnedTerminalIsRefused(testCase)
            [globalProps,configured]=one_photon_configuration();
            configured.ao_camera_triggered=constant("feedback","2P mod",1);
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd");
            testCase.verifyFalse(report.passed);
            testCase.verifySubstring(char(strjoin(report.violations," ")), ...
                "ao_camera_triggered");
        end

        function everyDeclaredOutputAppearsEvenWhenNothingDrivesIt(testCase)
            % A terminal missing from the configuration compiles to no row
            % at all, so without the declared roll-up an output AO forgot to
            % neutralise would simply not be in the report.
            [globalProps,configured]=one_photon_configuration();
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd");
            declared=report.declared;
            testCase.verifyEqual(height(declared),6);
            shutter=declared(declared.role=="blue_shutter",:);
            testCase.verifyFalse(shutter.present, ...
                "A 1P run installs no buffered record for the 488 shutter.");
            testCase.verifyEqual(shutter.classification,"absent");
            testCase.verifyEqual(shutter.runtime_owner,"imperative");
            % present=false is read together with runtime_owner: for a
            % suppressed output it is the intended result, and for the
            % imperatively owned shutter above it is too.
            galvo=declared(declared.role=="galvo_x",:);
            testCase.verifyFalse(galvo.present, ...
                "A 1P run installs no buffered record on the galvo card.");
            testCase.verifyEqual(galvo.classification,"absent");
            testCase.verifyEqual(galvo.runtime_owner,"suppressed");
            testCase.verifyFalse(galvo.neutral_verified);
            % The neutral is still declared, because the modality that
            % DOES drive this output asserts it. A 1P run does not - it
            % neither installs a record nor writes the device.
            testCase.verifyEqual(galvo.declared_neutral,0);
        end

        function theReportCarriesWhatAnArchiveNeedsToBeReadLater(testCase)
            [globalProps,configured]=one_photon_configuration();
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd","Context","unit test");
            testCase.verifyEqual(report.context,"unit test");
            testCase.verifyEqual(report.modality,"1p_dmd");
            testCase.verifyEqual(report.policy,"report_only");
            testCase.verifyEqual(report.rig_name,"Virtual_Upright");
            testCase.verifyEqual(report.sample_count, ...
                round(globalProps.total_time*globalProps.rate));
            testCase.verifyTrue(all(ismember(["subsystem","port", ...
                "canonical_terminal","role","classification","record_names", ...
                "wavefiles","record_count","ownership_tags","declared_neutral", ...
                "neutral_source","measured_minimum","measured_maximum", ...
                "neutral_verified","duplicate_records","reason"], ...
                string(report.terminals.Properties.VariableNames))));
        end
    end
end

% =====================================================================

function verify_neutral(testCase,report,manifest,role)
entry=manifest.outputs(string({manifest.outputs.role})==role);
row=row_for(report,entry.terminal);
testCase.verifyEqual(row.classification,"neutral", ...
    entry.terminal+" was not measured neutral.");
testCase.verifyTrue(row.neutral_verified);
testCase.verifyEqual(row.declared_neutral,double(entry.neutral_value));
testCase.verifyEqual(row.neutral_source,entry.neutral_source);
testCase.verifyEqual(row.measured_minimum,double(entry.neutral_value));
testCase.verifyEqual(row.measured_maximum,double(entry.neutral_value));
end

function verify_suppressed(testCase,report,role)
%VERIFY_SUPPRESSED The output is absent from the run, by declaration.
declared=report.declared(report.declared.role==role,:);
testCase.verifyFalse(declared.present, ...
    role+" must not appear in a configuration that suppresses it.");
testCase.verifyEqual(declared.classification,"absent");
testCase.verifyEqual(declared.runtime_owner,"suppressed");
end

function row=row_for(report,terminal)
canonical=adaptive_optopatch.canonical_terminal(terminal);
row=table2struct(report.terminals( ...
    report.terminals.canonical_terminal==canonical,:));
end

function record=constant(name,port,value)
record=struct("name",char(name),"port",char(port), ...
    "wavefile","awfm_constant","params",{{double(value)}}, ...
    "operation","Multiplication","concatTime",[]);
end

function [globalProps,configured]=one_photon_configuration()
protocol=one_photon_protocol();
[globalProps,configured]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
    live_global_props(),empty_wfm_data(),protocol);
end

function [globalProps,configured]=two_photon_configuration()
n=400; fs=200000;
waveforms=struct("sample_rate_hz",fs, ...
    "x_v",linspace(0,0.4,n)',"y_v",linspace(0,-0.3,n)', ...
    "pockels_v",[zeros(100,1);0.8*ones(100,1);zeros(200,1)], ...
    "preflight",struct("passed",true),"per_pulse",struct([]));
[globalProps,configured]=adaptive_optopatch.build_luminos_2p_waveform_config( ...
    live_global_props(),empty_wfm_data(),waveforms);
end

function protocol=one_photon_protocol()
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","accounting_test","CellIds","cell_001","RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1.25);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
definition=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",3,"PulseDurationMs",5,"DarkIntervalMs",[50 50], ...
    "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1.25);
defaults=gui_defaults();
resolved=adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
    defaults,"Mode","1p_dmd");
protocol=resolved{1};
end

function props=live_global_props()
props=struct("rate",200000,"total_time",1,"clock_source","Internal Dev1", ...
    "trigger_source","Dev1/PFI9","completion_trigger","None","daq_master",true);
end

function data=empty_wfm_data()
data=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
end

function defaults=gui_defaults()
defaults=struct("command_voltage_v",1.25,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
