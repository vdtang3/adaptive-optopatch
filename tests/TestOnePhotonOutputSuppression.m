classdef TestOnePhotonOutputSuppression < matlab.unittest.TestCase
    %TESTONEPHOTONOUTPUTSUPPRESSION What a 1P run owns, suppresses and inherits.
    %   A 1P-only acquisition used to append constant records for the three
    %   inactive 2P outputs. Two of them live on the galvo card, so the
    %   configuration contained buffered Dev2 records, and a buffered record
    %   on a second card is what makes Luminos build a hardware-timed AO
    %   task there - which then has to take its sample clock and start
    %   trigger from Dev1 and failed to route during a 1P-only run. Nothing
    %   in a 1P acquisition commands those outputs, so the correct
    %   configuration is the one they are absent from.
    %
    %   The distinction this class exists to hold is between two different
    %   reasons AO does not command an output:
    %
    %     inactive 2P hardware  - removed from the temporary run and NOT
    %                             replaced. AO owns the terminal and has
    %                             nothing to say on it this run.
    %     orange recording      - removed and REPLACED with AO's own
    %                             constant at the Orange recording voltage.
    %                             AO owns the terminal for the length of
    %                             the acquisition because there is no
    %                             longer a Waveforms protocol to inherit a
    %                             recording level from.
    %
    %   The orange half of that used to read the other way round, and the
    %   tests below used to assert it: the operator set recording power by
    %   putting a mod594 constant in the Waveforms tab and AO left it alone.
    %   That stopped being true when AO started building its own
    %   global_props, because a run that inherits nothing would record in
    %   the dark.
    %
    %   Both builders are checked. build_luminos_1p_waveform_config is the
    %   commissioning/parity builder; build_luminos_mixed_waveform_config
    %   is what run_1p_manifest actually calls, and its has2p==false branch
    %   is the live 1P-only path. A fix in one of them is not a fix.

    properties (Constant)
        % The three outputs a 1P acquisition suppresses, and the terminals
        % they resolve to. Ports come from the rig profile rather than being
        % restated here.
        SuppressedRoles = ["galvo_x","galvo_y","two_photon_modulator"]
    end

    methods (Test)
        % -----------------------------------------------------------------
        % A, B, C, D: the inactive 2P outputs leave the run
        % -----------------------------------------------------------------
        function ambientGalvoXIsSuppressedFromTheRun(testCase)
            for builder=both_builders()
                configured=build(builder,ambient_with(galvo_x_record()));
                verify_absent(testCase,configured,"Dev2/ao0",builder);
            end
        end

        function ambientGalvoYIsSuppressedFromTheRun(testCase)
            for builder=both_builders()
                configured=build(builder,ambient_with(galvo_y_record()));
                verify_absent(testCase,configured,"Dev2/ao1",builder);
            end
        end

        function ambientTwoPhotonModulatorIsSuppressedFromTheRun(testCase)
            % Stored under the rig alias "2P mod", which is the spelling
            % Waveforms actually writes, not the terminal.
            for builder=both_builders()
                configured=build(builder, ...
                    ambient_with(constant("legacy pockels","2P mod",4.4)));
                verify_absent(testCase,configured,"Dev1/ao3",builder);
            end
        end

        function noConstantReplacementIsAddedForAnInactiveModality(testCase)
            % The point of the change: not merely that the stale record is
            % gone, but that nothing was put in its place. An empty ambient
            % configuration is the clearest statement of it - there was
            % never anything to remove, so any record on these terminals is
            % one this builder manufactured.
            for builder=both_builders()
                configured=build(builder,empty_wfm_data());
                for terminal=["Dev2/ao0","Dev2/ao1","Dev1/ao3"]
                    verify_absent(testCase,configured,terminal,builder);
                end
                % And no record names them either, whatever port it carries.
                names=record_names(configured.ao);
                testCase.verifyFalse(any(ismember( ...
                    ["Adaptive2P_X","Adaptive2P_Y","2P mod"],names)), ...
                    builder+" manufactured an inactive-2P record.");
            end
        end

        function aOnePhotonRunBuildsNoWaveformOnTheGalvoCard(testCase)
            % The routing conflict, stated as the property that fixes it:
            % after suppression no AO record resolves to Dev2 at all, so
            % Luminos has no second-card AO task to clock or trigger.
            for builder=both_builders()
                configured=build(builder,ambient_with([galvo_x_record() ...
                    galvo_y_record()]));
                devices=terminal_devices(configured.ao);
                testCase.verifyFalse(any(devices=="Dev2"), ...
                    builder+" left a buffered AO record on "+ ...
                    strjoin(unique(devices),", ")+".");
            end
        end

        % -----------------------------------------------------------------
        % E: mod488 stays AO's
        % -----------------------------------------------------------------
        function mod488RemainsAoOwnedAndReplacesTheAmbientRecord(testCase)
            % Unchanged behaviour, asserted here because it is the contrast
            % the whole change turns on: AO owns and replaces mod488, and
            % inherits mod594.
            ambient=ambient_with(constant("legacy mod488","mod488",3.9));
            for builder=both_builders()
                configured=build(builder,ambient);
                records=records_on(configured.ao,"Dev1/ao2");
                testCase.assertNumElements(records,1, ...
                    builder+" must leave exactly one mod488 record.");
                testCase.verifyEqual(string(records.wavefile), ...
                    "adaptive_optopatch.luminos_event_waveform", ...
                    "The ambient constant must be replaced, not kept.");
                testCase.verifyEqual(string(records.script_owner), ...
                    adaptive_optopatch.script_owner_tag());
                % Timing and voltage are the protocol's, unchanged: the
                % fixture commands 1.25 V and the pulse train reaches it.
                samples=compiled_samples(configured.ao,"Dev1/ao2");
                testCase.verifyEqual(max(samples),1.25,"AbsTol",1e-12);
                testCase.verifyEqual(samples(1),0,"AbsTol",1e-12, ...
                    "mod488 must start dark.");
                testCase.verifyGreaterThan(sum(samples>0),0);
            end
        end

        % -----------------------------------------------------------------
        % F, G: AO owns the orange recording illumination
        % -----------------------------------------------------------------
        function ambientMod594IsReplacedByTheAoRecordingConstant(testCase)
            % The operator used to set recording power by putting a mod594
            % constant in the Waveforms tab. AO now drives it, so whatever
            % is ambient on Dev1/ao1 has to GO: Luminos combines two records
            % that resolve to one terminal, so leaving the old one beside
            % AO's would illuminate at the sum of two voltages.
            staleImagingPower=1.37;
            expected=AoFixtures.orangeRecordingVoltage();
            ambient=ambient_with(constant("mod594","mod594",staleImagingPower));
            configured=build("mixed",ambient);
            records=records_on(configured.ao,"Dev1/ao1");
            testCase.assertNumElements(records,1, ...
                "Exactly one mod594 record must survive the build.");
            testCase.verifyEqual(string(records.wavefile),"awfm_constant");
            testCase.verifyEqual(records.params{1},expected,"AbsTol",0);
            testCase.verifyEqual(string(records.script_owner), ...
                adaptive_optopatch.script_owner_tag(), ...
                "AO must claim the record it installed.");
            % Every sample that would reach the wire, not just the
            % parameter. The final sample is excluded because Luminos
            % itself forces data(end)=0 on every terminal in
            % Build_Waveforms_DevicePartitioned; that zero is the
            % acquisition ending, not a modulation AO applied.
            samples=compiled_samples(configured.ao,"Dev1/ao1");
            testCase.verifyTrue(all(samples(1:end-1)==expected), ...
                "The orange recording level must be constant.");
        end

        function theLegacyBuilderStillInheritsMod594(testCase)
            % build_luminos_1p_waveform_config is a frozen reference of how
            % a run was built when AO inherited the operator's Waveforms
            % protocol, and TestMixedStimulationTimeline compares the live
            % builder against it. It is deliberately NOT updated: a frozen
            % reference that moves with the code it is meant to pin is not
            % a reference. Asserted so that is a decision rather than an
            % oversight somebody later "fixes".
            imagingPower=1.37;
            ambient=ambient_with(constant("mod594","mod594",imagingPower));
            configured=build("1p",ambient);
            records=records_on(configured.ao,"Dev1/ao1");
            testCase.assertNumElements(records,1);
            testCase.verifyEqual(records.params{1},imagingPower,"AbsTol",0);
            testCase.verifyEmpty(records.script_owner);
        end

        function ambientShutter594IsClearedForImperativeOwnership(testCase)
            % An NI_DAQ_Shutter is an on-demand digital write and the runner
            % opens and closes it around the armed window, so no buffered
            % record may own the line - exactly the rule shutter488 has
            % always followed. Cleared, not replaced with a constant: a
            % constant would be the second owner.
            ambient=empty_wfm_data();
            ambient.do=constant("shutter594","shutter594",1);
            configured=build("mixed",ambient);
            testCase.verifyEmpty(records_on(configured.do,"Dev1/port0/line1"), ...
                "No buffered record may hold shutter594 during a 1P run.");
        end

        function theOrangeOutputsAreOwnedButNotStimulation(testCase)
            % The declaration both builders and the accounting read. The
            % distinction that has to survive is OWNERSHIP without
            % STIMULATION: AO drives these, and nothing may read 594 nm as
            % an optogenetic output.
            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            roles=string({manifest.recording_illumination.role});
            testCase.verifyTrue(all(ismember( ...
                ["orange_modulator","orange_shutter"],roles)));
            for role=["orange_modulator","orange_shutter"]
                entry=manifest.recording_illumination(roles==role);
                testCase.verifyEqual(entry.classification, ...
                    "ao_owned_recording_illumination");
                testCase.verifyFalse(entry.stimulation_capable, ...
                    "594 nm must never be classified as stimulation.");
            end
            testCase.verifyEqual( ...
                manifest.recording_illumination(roles=="orange_modulator").owner.one_photon, ...
                "buffered");
            testCase.verifyEqual( ...
                manifest.recording_illumination(roles=="orange_shutter").owner.one_photon, ...
                "imperative");
            % And they are not in the stimulation list, which is what keeps
            % suppression and neutralization away from them.
            testCase.verifyFalse(any(string({manifest.outputs.role})== ...
                "orange_modulator"));
            testCase.verifyEmpty(manifest.inherited, ...
                "Nothing is inherited from a Waveforms protocol any more.");
        end

        % -----------------------------------------------------------------
        % H: unrelated ambient records are left alone
        % -----------------------------------------------------------------
        function anUnrelatedAmbientWaveformSurvivesUntouched(testCase)
            % A 1P build is not a rebuild of the Luminos configuration. It
            % removes the terminals it owns or suppresses, and leaves the
            % rest of the operator's acquisition exactly as it found it.
            ambient=ambient_with(constant("unrelated","Dev1/ao7",4.2));
            ambient.do=constant("unrelated digital","Dev1/port0/line6",1);
            for builder=both_builders()
                configured=build(builder,ambient);
                analog=records_on(configured.ao,"Dev1/ao7");
                testCase.assertNumElements(analog,1);
                testCase.verifyEqual(analog.params{1},4.2);
                digital=records_on(configured.do,"Dev1/port0/line6");
                testCase.assertNumElements(digital,1);
                testCase.verifyEqual(digital.params{1},1);
            end
        end

        % -----------------------------------------------------------------
        % I: the whole representative configuration, in one assertion
        % -----------------------------------------------------------------
        function aRepresentativeAmbientConfigurationIsPartitionedCorrectly(testCase)
            % One incoming Luminos waveform configuration containing every
            % kind of record at once, and the four different things that
            % must happen to them: suppressed, replaced, cleared, and left
            % alone. Only the live builder: the frozen 1P reference does
            % not own the orange terminals, so running it through the same
            % assertions would be asking it to behave like the code it
            % exists to pin.
            ambient=empty_wfm_data();
            ambient.ao=[galvo_x_record() galvo_y_record() ...
                constant("legacy pockels","2P mod",4.4), ...
                constant("mod594","mod594",1.37), ...
                constant("legacy mod488","mod488",3.9), ...
                constant("unrelated","Dev1/ao7",4.2)];
            ambient.do=[constant("shutter594","shutter594",1), ...
                constant("unrelated digital","Dev1/port0/line6",1)];

            builder="mixed";
            configured=build(builder,ambient);

            % Suppressed: absent, and not replaced.
            for terminal=["Dev2/ao0","Dev2/ao1","Dev1/ao3"]
                verify_absent(testCase,configured,terminal,builder);
            end
            % Replaced: the operator's stale orange constant is gone and
            % AO's own recording level is in its place.
            orange=records_on(configured.ao,"Dev1/ao1");
            testCase.assertNumElements(orange,1);
            testCase.verifyEqual(orange.params{1}, ...
                AoFixtures.orangeRecordingVoltage(),"AbsTol",0);
            % Cleared: the orange shutter has one imperative owner.
            verify_absent(testCase,configured,"Dev1/port0/line1",builder);
            % Untouched: anything AO does not own is the operator's still.
            testCase.verifyEqual( ...
                records_on(configured.ao,"Dev1/ao7").params{1},4.2);
            testCase.verifyEqual( ...
                records_on(configured.do,"Dev1/port0/line6").params{1},1);
            % AO-owned: replaced by AO's own pulse train.
            mod488=records_on(configured.ao,"Dev1/ao2");
            testCase.assertNumElements(mod488,1);
            testCase.verifyEqual(string(mod488.wavefile), ...
                "adaptive_optopatch.luminos_event_waveform");

            % Exactly two AO analog records: the blue stimulus command and
            % the orange recording level. Nothing else on an analog
            % terminal belongs to AO during a 1P run - in particular not
            % the galvo card.
            owned=configured.ao(record_owners(configured.ao)== ...
                adaptive_optopatch.script_owner_tag());
            testCase.verifyEqual(sort(string({owned.name})), ...
                sort(["mod488","mod594"]), ...
                "AO installed an analog record it does not own.");
        end

        function accountingAcceptsTheRepresentativeConfiguration(testCase)
            % End to end through the check that actually gates a run: the
            % operator's own orange records are inherited rather than
            % flagged, and nothing is unaccounted or in violation.
            ambient=empty_wfm_data();
            ambient.ao=[galvo_x_record() ...
                constant("mod594","mod594",1.37), ...
                constant("legacy mod488","mod488",3.9)];
            ambient.do=constant("shutter594","shutter594",1);
            [globalProps,configured]=build_with_props("mixed",ambient);
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,configured,"Modality","1p_dmd", ...
                "Policy","fail_closed");
            testCase.verifyEmpty(report.violations);
            testCase.verifyEmpty(report.unaccounted_terminals);
            testCase.verifyTrue(report.passed, ...
                "A representative 1P configuration must pass even " + ...
                "fail_closed: everything in it is declared.");
            orange=report.terminals(report.terminals.role=="orange_modulator",:);
            testCase.verifyEqual(orange.classification,"commanded");
            testCase.verifyTrue(orange.ao_owned_records, ...
                "AO must own the orange record it installed.");
            testCase.verifyEqual(orange.runtime_owner,"buffered");
            % The ambient 1.37 V is gone and AO's own level is what the
            % terminal measures.
            testCase.verifyEqual(orange.measured_maximum, ...
                AoFixtures.orangeRecordingVoltage(),"AbsTol",1e-12);
        end

        % -----------------------------------------------------------------
        % Provenance
        % -----------------------------------------------------------------
        function theSummarySaysTheOutputsWereSuppressedNotDriven(testCase)
            [~,protocol]=one_photon_fixture();
            [~,~,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(),empty_wfm_data(),protocol);
            inactive=summary.inactive_two_photon_outputs;
            testCase.verifyEqual(inactive.disposition,"suppressed_from_run");
            testCase.verifyEqual(inactive.galvo_x_port,"Dev2/ao0");
            testCase.verifyEqual(inactive.galvo_y_port,"Dev2/ao1");
            testCase.verifyEqual(inactive.pockels_port,"Dev1/ao3");
            % The fields that recorded values AO applied are gone, because
            % AO applied none. A consumer reading them would have been told
            % the galvos were driven somewhere.
            testCase.verifyFalse(isfield(inactive,"galvo_stationary_v"));
            testCase.verifyFalse(isfield(inactive,"pockels_dark_v"));
        end

        function theManifestSaysWhoOwnsEachOutputPerModality(testCase)
            % Implementation and declaration have to agree, or accounting
            % is checking the build against the wrong statement.
            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            roles=string({manifest.outputs.role});
            for role=TestOnePhotonOutputSuppression.SuppressedRoles
                entry=manifest.outputs(roles==role);
                testCase.verifyEqual(entry.owner.one_photon,"suppressed", ...
                    role+" is suppressed during a 1P acquisition.");
                testCase.verifyEqual(entry.owner.two_photon,"buffered");
                testCase.verifyEqual(entry.owner.mixed,"buffered", ...
                    role+" is driven from planned waveforms in a mixed run.");
                % The neutral is still declared, and is asserted by the
                % modality that drives the output. TestOnePhotonModality-
                % Isolation is where "a 1P run asserts nothing here" is
                % checked against the actual device calls.
                testCase.verifyNotEmpty(entry.neutral_source);
            end
            % mod488 is the contrast, and is unchanged.
            blue=manifest.outputs(roles=="blue_modulator");
            testCase.verifyEqual(blue.owner.one_photon,"buffered");
        end

        % -----------------------------------------------------------------
        % Mixed acquisitions are untouched
        % -----------------------------------------------------------------
        function aMixedAcquisitionStillDrivesTheGalvosAndPockels(testCase)
            % Suppression is the has2p==false path only. An acquisition
            % containing 2P events must still install all three sampled
            % records, or this change has broken 2P targeting.
            [globalProps,wfmData]=mixed_build();
            for terminal=["Dev2/ao0","Dev2/ao1","Dev1/ao3"]
                records=records_on(wfmData.ao,terminal);
                testCase.assertNumElements(records,1, ...
                    terminal+" must be driven during a mixed acquisition.");
                testCase.verifyEqual(string(records.wavefile), ...
                    "adaptive_optopatch.luminos_sampled_waveform");
                testCase.verifyEqual(string(records.script_owner), ...
                    adaptive_optopatch.script_owner_tag());
            end
            report=adaptive_optopatch.account_stimulation_outputs( ...
                globalProps,wfmData,"Modality","mixed");
            testCase.verifyEmpty(report.violations, ...
                "A mixed run drives these outputs and must not be " + ...
                "flagged for the suppression invariant.");
        end
    end
end

% =====================================================================
% Fixtures
% =====================================================================

function names=both_builders()
%BOTH_BUILDERS The parity builder and the one run_1p_manifest calls.
names=["1p","mixed"];
end

function configured=build(builder,ambient)
[~,configured]=build_with_props(builder,ambient);
end

function [globalProps,configured]=build_with_props(builder,ambient)
[~,protocol]=one_photon_fixture();
switch builder
    case "1p"
        [globalProps,configured]= ...
            adaptive_optopatch.build_luminos_1p_waveform_config( ...
            live_global_props(),ambient,protocol);
    case "mixed"
        [globalProps,configured]= ...
            adaptive_optopatch.build_luminos_mixed_waveform_config( ...
            live_global_props(),ambient,protocol, ...
            "OnePhotonProfile",AoFixtures.onePhotonProfile());
end
end

function [globalProps,wfmData]=mixed_build()
% Genuinely mixed: two 1P events and one 2P event in one acquisition, so
% has1p and has2p are both true and the shutter stays imperatively owned.
[~,protocol]=one_photon_fixture("1p_dmd",["1p_dmd","1p_dmd","2p_spiral"]);
rate=200000; n=rate;
wave=struct("sample_rate_hz",rate, ...
    "x_v",linspace(0,0.4,n)',"y_v",linspace(0,-0.3,n)', ...
    "pockels_v",[zeros(n-1000,1);0.8*ones(1000,1)], ...
    "preflight",struct("passed",true),"per_pulse",struct([]));
[globalProps,wfmData]= ...
    adaptive_optopatch.build_luminos_mixed_waveform_config( ...
    live_global_props(),empty_wfm_data(),protocol, ...
    "TwoPhotonWaveforms",wave, ...
    "OnePhotonProfile",AoFixtures.onePhotonProfile());
end

function ambient=ambient_with(records)
ambient=empty_wfm_data();
ambient.ao=records;
end

function record=galvo_x_record()
% The slash-and-case spelling, which is what used to survive name matching.
record=constant("legacy galvo x","/Dev2/AO0",3.1);
end

function record=galvo_y_record()
record=constant("legacy galvo y","dev2/AO1",-2.7);
end

function record=constant(name,port,value)
record=struct("name",char(name),"port",char(port), ...
    "wavefile","awfm_constant","params",{{double(value)}}, ...
    "operation","Multiplication","concatTime",[],"script_owner",[]);
end

function verify_absent(testCase,configured,terminal,builder)
%VERIFY_ABSENT No record in either subsystem resolves to this terminal.
for subsystem=["ao","do"]
    testCase.verifyEmpty(records_on(configured.(subsystem),terminal), ...
        builder+" left a record on "+terminal+"."+ ...
        " A suppressed output must carry none.");
end
end

function records=records_on(records,terminal)
%RECORDS_ON Every record that resolves to this physical terminal.
%   By canonical terminal, not by name: a record stored under a rig alias
%   or a slash variant drives the same wire.
if isempty(records), records=records([]); return; end
target=canonical(terminal);
keep=false(size(records));
for k=1:numel(records)
    keep(k)=any(canonical([string(records(k).name) ...
        string(records(k).port)])==target);
end
records=records(keep);
end

function value=canonical(identifiers)
value=adaptive_optopatch.canonical_terminal(identifiers, ...
    adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list);
end

function samples=compiled_samples(records,terminal)
%COMPILED_SAMPLES What would actually reach this wire.
compiled=adaptive_optopatch.compile_output_samples( ...
    live_global_props(),records, ...
    adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list);
samples=compiled([compiled.canonical_terminal]==canonical(terminal)).samples;
end

function devices=terminal_devices(records)
%TERMINAL_DEVICES Which DAQ cards these records would build tasks on.
devices=strings(1,0);
if isempty(records), return; end
compiled=adaptive_optopatch.compile_output_samples( ...
    live_global_props(),records, ...
    adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list);
for k=1:numel(compiled)
    parts=split(compiled(k).canonical_terminal,"/");
    devices(end+1)=parts(1); %#ok<AGROW>
end
end

function names=record_names(records)
names=strings(1,0);
if isempty(records), return; end
names=arrayfun(@(r)string(r.name),records);
end

function owners=record_owners(records)
owners=strings(1,numel(records));
for k=1:numel(records)
    if isfield(records,"script_owner") && ~isempty(records(k).script_owner)
        owners(k)=string(records(k).script_owner);
    end
end
end

function props=live_global_props()
props=struct("rate",200000,"total_time",1,"clock_source","Internal Dev1", ...
    "trigger_source","Dev1/PFI9","completion_trigger","None","daq_master",true);
end

function data=empty_wfm_data()
data=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
end

function [targets,protocol]=one_photon_fixture(mode,sources)
%ONE_PHOTON_FIXTURE One stimulable cell, one resolved trial.
%   A single target, so no DMD advance train is needed and the analog
%   partition is what the test is looking at.
%
%   sources sets the event table's stimulation_source, which under schema 4
%   is experimental intent carried by the protocol rather than anything
%   inferred from mode. generate_screen_protocol writes 1p_dmd events, so a
%   fixture wanting 2P events has to say so explicitly. Given one value it
%   applies to every light-emitting event; given one per event it makes a
%   mixed acquisition.
if nargin<1, mode="1p_dmd"; end
if nargin<2, sources=mode; end
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","suppression_test","CellIds","cell_001","RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode",mode);
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1.25);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
definition=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",3,"PulseDurationMs",5,"DarkIntervalMs",[50 50], ...
    "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1.25);
for k=1:numel(definition.acquisitions)
    events=definition.acquisitions(k).events;
    light=~events.is_null;
    if isscalar(sources)
        events.stimulation_source(light)=sources;
    else
        events.stimulation_source(light)=reshape(sources(1:sum(light)),[],1);
    end
    events.stimulation_source(events.is_null)="none";
    definition.acquisitions(k).events=events;
end
defaults=struct("command_voltage_v",1.25,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
resolved=adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
    defaults,"Mode",mode);
protocol=resolved{1};
end
