classdef TestStimulationSafetyCleanup < matlab.unittest.TestCase
    %TESTSTIMULATIONSAFETYCLEANUP Neutral state, ordering, unwind, archive.
    %   These began as cover for the asymmetry where a 1P run ended with the
    %   Pockels cell and the galvos exactly as the last 2P run had left
    %   them, because cleanup only ever unwound the modality it was running.
    %   The remedy then was to command every declared output every time,
    %   which overshot: a pure 1P run has no business issuing galvo or
    %   Pockels writes at all. Neutralization is now scoped by the
    %   manifest's per-modality ownership, so what these assert is that an
    %   ACTIVE modality's hardware is still made safe while hardware
    %   declared suppressed for the run is left completely alone.

    properties
        OutputRoot string
    end

    methods (TestMethodSetup)
        function makeOutputRoot(testCase)
            testCase.OutputRoot=string(tempname);
            testCase.addTeardown(@()remove_tree(testCase.OutputRoot));
        end
    end

    methods (Test)
        % -----------------------------------------------------------------
        % Unified neutralization
        % -----------------------------------------------------------------
        function blueDmdBlankUsesDeviceCanvasOrientation(testCase)
            dmd=adaptive_optopatch.testing.SimulatedLuminosDevice("DMD","DMD_Blue");
            dmd.Dimensions=[1024 768];
            blank=adaptive_optopatch.blank_dmd_pattern(dmd);
            testCase.verifySize(blank,[768 1024]);
            testCase.verifyClass(blank,"logical");
            testCase.verifyFalse(any(blank,"all"));
        end

        function neutralizationWritesADeviceSpaceBlank(testCase)
            app=adaptive_optopatch.testing.make_simulated_luminos();
            dmd=app.getDevice("DMD","name","DMD_Blue");
            dmd.Dimensions=[1024 768];
            dmd.Target=true(768,1024);
            report=adaptive_optopatch.neutralize_all_stimulation(app, ...
                "Modality","1p_dmd");
            testCase.verifyTrue(report.all_succeeded);
            testCase.verifySize(dmd.Target,[768 1024]);
            testCase.verifyFalse(any(dmd.Target,"all"));
        end

        function successfulRunEndsWithADeviceSpaceBlank(testCase)
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            dmd.Dimensions=[1024 768];
            run=adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifySize(dmd.Target,[768 1024]);
            testCase.verifyFalse(any(dmd.Target,"all"));
        end

        function neutralizationDrivesEveryOwnedSystemToItsDeclaredValue(testCase)
            app=adaptive_optopatch.testing.make_simulated_luminos();
            oneP=adaptive_optopatch.virtual_upright_1p_profile();
            twoP=adaptive_optopatch.virtual_upright_2p_profile();
            % Leave every stimulation system live first, so a report of
            % success has something to have changed.
            app.getDevice("NI_DAQ_Modulator","name","mod488").level=4.0;
            app.getDevice("NI_DAQ_Modulator","name","2P mod").level=3.0;
            app.getDevice("NI_DAQ_Shutter","name","shutter488").State=true;
            app.getDevice("NI_DAQ_Shutter","name","DMD Trigger").State=true;
            scanner=app.getDevice("Scanning_Device","name",twoP.scanner.name);
            scanner.galvox_wfm=4.9; scanner.galvoy_wfm=-4.9;
            dmd=app.getDevice("DMD","name","DMD_Blue");
            dmd.Target=true(dmd.Dimensions);

            report=adaptive_optopatch.neutralize_all_stimulation(app);

            testCase.verifyTrue(report.all_succeeded, ...
                "Neutralization reported failures: "+strjoin(report.failures,", "));
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Modulator","name","mod488").level, ...
                double(oneP.modulator.dark_v));
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Modulator","name","2P mod").level, ...
                double(twoP.modulator.dark_v));
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Shutter","name","shutter488").State, ...
                logical(oneP.shutter.closed_state));
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Shutter","name","DMD Trigger").State, ...
                logical(twoP.inactive_one_photon.dmd.trigger_safe_state));
            stationary=double(oneP.inactive_two_photon.scanner.stationary_v);
            testCase.verifyEqual(scanner.galvox_wfm,stationary(1));
            testCase.verifyEqual(scanner.galvoy_wfm,stationary(2));
            testCase.verifyFalse(any(dmd.Target(:)));
        end

        function neutralizationSurvivesAMissingDeviceAndSaysWhichOneFailed(testCase)
            % It runs during cleanup, often while an exception is already
            % propagating. One absent device must not stop the rest being
            % made safe, and must not replace the original error either.
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "MissingDevice","2P mod");
            app.getDevice("NI_DAQ_Modulator","name","mod488").level=4.0;
            report=adaptive_optopatch.neutralize_all_stimulation(app);
            testCase.verifyFalse(report.all_succeeded);
            testCase.verifyEqual(report.failures,"two_photon_modulator");
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Modulator","name","mod488").level,0, ...
                "A missing device stopped the other systems being neutralized.");
        end

        function aPureOnePhotonRunOnARigWithoutTwoPhotonHardwareIsSilent(testCase)
            % This once asserted the opposite, and the change is the point.
            % An absent Pockels cell used to make every 1P run report a
            % neutralization failure and warn about it, because 1P cleanup
            % tried to darken hardware the rig did not have. A pure 1P run
            % does not command that output at all now, so there is nothing
            % to be absent for and nothing to warn about - and the archive
            % says "suppressed" rather than "failed", which is the
            % distinction that makes a real failure worth reading.
            [manifest,targets]=one_photon_manifest();
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot, ...
                "CameraRoi",targets.reference_camera.roi, ...
                "MissingDevice","2P mod");
            run=testCase.verifyWarningFree( ...
                @()adaptive_optopatch.run_1p_manifest( ...
                    manifest,targets,app,"ConfirmLiveOutput",true, ...
                    "ShutterSettleTimeS",0, ...
                    "OutputDirectory",testCase.OutputRoot));
            testCase.verifyEqual(run.trials.acquisition_status(1),"completed");
            testCase.verifyTrue(run.initial_neutralization.all_succeeded);
            testCase.verifyEmpty(run.initial_neutralization.failures);
            testCase.verifyTrue(any(run.initial_neutralization.suppressed== ...
                "two_photon_modulator"));
        end

        function suppressionDoesNotSwallowARealNeutralizationFailure(testCase)
            % The other half of that: an output the modality DOES drive is
            % still reported as a failure when it cannot be commanded. If
            % suppression had been implemented as "try, then ignore", this
            % is the test that would not be able to tell the difference.
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "MissingDevice","2P mod");
            report=adaptive_optopatch.neutralize_all_stimulation(app, ...
                "Modality","mixed");
            testCase.verifyFalse(report.all_succeeded);
            testCase.verifyEqual(report.failures,"two_photon_modulator");
            testCase.verifyEmpty(report.suppressed);
        end

        % -----------------------------------------------------------------
        % Pre-arm ordering
        % -----------------------------------------------------------------
        function neutralStateIsEstablishedBeforeSourcePowerIsRaised(testCase)
            % The 1P runner used to set the OBIS setpoint before mod488 was
            % known to be dark. The laser records the modulator level at the
            % moment its power is written, which is the only way to observe
            % an ordering rather than an end state.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            modulator=app.getDevice("NI_DAQ_Modulator","name","mod488");
            shutter=app.getDevice("NI_DAQ_Shutter","name","shutter488");
            modulator.level=4.2; shutter.State=true;
            observed=struct("level",NaN,"shutter",true);
            laser=app.getDevice("Laser_Device","name","488");
            listener=addlistener(laser,"SetPower","PostSet", ...
                @(~,~)record_state()); %#ok<NASGU>

            adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "LaserPowerW",0.01,"OutputDirectory",testCase.OutputRoot);

            testCase.verifyEqual(observed.level,0, ...
                "OBIS power was raised while mod488 still held a command.");
            testCase.verifyFalse(observed.shutter, ...
                "OBIS power was raised with the 488 shutter open.");

            function record_state()
                observed.level=modulator.level;
                observed.shutter=logical(shutter.State);
            end
        end

        % -----------------------------------------------------------------
        % Modality-scoped cleanup
        % -----------------------------------------------------------------
        function aPureOnePhotonRunLeavesTheTwoPhotonHardwareAlone(testCase)
            % The inverse of what this once asserted, and deliberately so.
            % A pure 1P acquisition does not use the Pockels cell or the
            % galvos, so it must not command them - not to park them, and
            % not to darken them. Whatever they held before the run they
            % still hold after it. Making 2P hardware safe belongs to the
            % run that actually drives it.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            pockels=app.getDevice("NI_DAQ_Modulator","name","2P mod");
            scanner=app.getDevice("Scanning_Device", ...
                "name","Chameleon (To friends: Ben)");
            pockels.level=2.5; scanner.galvox_wfm=4.0; scanner.galvoy_wfm=4.0;
            scanner.ExplicitGalvoUpdateCount=0;

            adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            testCase.verifyEqual(pockels.level,2.5, ...
                "A pure 1P run wrote the Pockels cell it never uses.");
            testCase.verifyEqual(scanner.ExplicitGalvoUpdateCount,0, ...
                "A pure 1P run issued an explicit galvo update.");
            testCase.verifyEqual(scanner.galvox_wfm,4.0);
            testCase.verifyEqual(scanner.galvoy_wfm,4.0);
        end

        function aFailedAcquisitionStillNeutralizesWhatTheRunOwned(testCase)
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            app.FailOnAcquisitionNumber=1;
            pockels=app.getDevice("NI_DAQ_Modulator","name","2P mod");
            modulator=app.getDevice("NI_DAQ_Modulator","name","mod488");
            shutter=app.getDevice("NI_DAQ_Shutter","name","shutter488");
            pockels.level=2.5;

            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:SimulatedAcquisitionFailure");

            testCase.verifyEqual(modulator.level,0);
            testCase.verifyFalse(logical(shutter.State), ...
                "A failed acquisition left the 488 shutter open.");
            % The 1P outputs the run owned are made safe on the way out.
            % The Pockels cell is not one of them, and an exception on the
            % unwind path is not a licence to start commanding hardware the
            % run never used.
            testCase.verifyEqual(pockels.level,2.5, ...
                "Failure cleanup wrote the Pockels cell during a pure 1P run.");
        end

        function completedAcquisitionWithBlankFailureIsNotReacquired(testCase)
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            % Initial blank, target write, then post-acquisition blank.
            dmd.FailOnStaticWriteNumber=3;
            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:PostAcquisitionCleanupFailed");
            testCase.verifyNumElements(app.AcquisitionHistory,1);
            checkpoint=load(fullfile(testCase.OutputRoot,"run_checkpoint.mat"),"run");
            testCase.verifyEqual( ...
                checkpoint.run.trials.acquisition_status(1), ...
                "completed_cleanup_failed");
            testCase.verifyNotEmpty( ...
                checkpoint.run.trials.cleanup_error_message(1));
            output=load(fullfile( ...
                checkpoint.run.trials.experiment_directory(1),"output_data.mat"), ...
                "adaptive_optopatch_cleanup");
            testCase.verifyTrue(output.adaptive_optopatch_cleanup.acquisition_completed);
            testCase.verifyFalse(output.adaptive_optopatch_cleanup.cleanup_completed);

            dmd.FailOnStaticWriteNumber=NaN;
            resumed=adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot);
            testCase.verifyNumElements(app.AcquisitionHistory,1, ...
                "Resume reacquired data that had already completed physically.");
            testCase.verifyEqual(resumed.trials.acquisition_status(1), ...
                "completed_cleanup_failed");
        end

        function aPreArmFailureNeutralizesEvenThoughNothingWasEverArmed(testCase)
            % The path that used to neutralise nothing: it fails before
            % app.acquisition_active is ever set, so the cleanup that keys
            % off that flag had nothing to do.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            pockels=app.getDevice("NI_DAQ_Modulator","name","2P mod");
            modulator=app.getDevice("NI_DAQ_Modulator","name","mod488");
            pockels.level=2.5; modulator.level=4.2;
            laser=app.getDevice("Laser_Device","name","488");
            laser.FailOnStart=true;

            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:SimulatedLaserStartFailure");
            testCase.verifyEqual(modulator.level,0);
            testCase.verifyEqual(pockels.level,2.5, ...
                "Pre-arm cleanup wrote the Pockels cell during a pure 1P run.");
            testCase.verifyFalse(logical(app.acquisition_active));
        end

        % -----------------------------------------------------------------
        % Restoration
        % -----------------------------------------------------------------
        function theOperatorsWaveformConfigurationIsRestoredWithoutDrivingIt(testCase)
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            daq=app.getDevice("DAQ");
            originalGlobal=daq.global_props;
            originalWfm=daq.wfm_data;

            adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            testCase.verifyEqual(daq.global_props,originalGlobal);
            testCase.verifyEqual(daq.wfm_data,originalWfm);
            testCase.verifyFalse(daq.waveforms_built, ...
                "Restoring the operator's configuration must not arm it.");
        end

        function theSuppressedGalvoRecordIsPutBackAfterTheRun(testCase)
            % Suppression is temporary and belongs to the acquisition. An
            % ambient galvo waveform must not execute during a 1P run, and
            % must still be in the operator's configuration afterwards -
            % AO borrows the React-tab configuration, it does not edit it.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            daq=app.getDevice("DAQ");
            ambient=daq.wfm_data;
            ambient.ao=append_wfm_record(ambient.ao, ...
                constant("operator galvo x","Dev2/ao0",3.1));
            daq.wfm_data=ambient;

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            % It did not run: the configuration that was installed had no
            % record on the galvo card at all.
            declared=run.trials.stimulation_accounting{1}.declared;
            galvo=declared(declared.role=="galvo_x",:);
            testCase.verifyFalse(galvo.present, ...
                "The ambient galvo waveform executed during a 1P run.");
            testCase.verifyEqual(galvo.runtime_owner,"suppressed");

            % And it is back, exactly as the operator left it.
            testCase.verifyEqual(daq.wfm_data,ambient, ...
                "AO permanently modified the operator's configuration.");
            testCase.verifyFalse(daq.waveforms_built);
        end

        function failClosedIsAvailableThroughTheRunnerButIsNotTheDefault(testCase)
            % Built now so that flipping the rig over is a policy decision
            % rather than a code change. It is not the default until the
            % VU's unresolved terminals have been classified.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            daq=app.getDevice("DAQ");
            wfm=daq.wfm_data;
            wfm.ao=append_wfm_record(wfm.ao,constant("mystery box","Dev1/ao6",2.5));
            daq.wfm_data=wfm;

            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot, ...
                "StimulationAccountingPolicy","fail_closed"), ...
                "adaptive_optopatch:StimulationAccountingFailed");

            % And the configuration that would have failed closed never
            % reached the DAQ: accounting runs before installation.
            testCase.verifyEqual(daq.wfm_data,wfm);
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Modulator","name","mod488").level,0);
        end

        % -----------------------------------------------------------------
        % Commissioning survey
        % -----------------------------------------------------------------
        function theCommissioningSurveyNamesEveryUnaccountedTerminal(testCase)
            % The step Pass 3A has to leave behind: read the configuration
            % that is loaded right now and say what is on every output,
            % without touching the rig.
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot);
            daq=app.getDevice("DAQ");
            wfm=daq.wfm_data;
            wfm.ao=append_wfm_record(wfm.ao,constant("mod594","mod594",0.4));
            wfm.do=append_wfm_record(wfm.do, ...
                constant("General Shutter","Dev1/port0/line5",1));
            daq.wfm_data=wfm;
            resets=daq.ResetCount;

            report=adaptive_optopatch.report_vu_stimulation_outputs(app, ...
                "Print",false);

            testCase.verifyEqual(report.modality,"unknown", ...
                "An ambient survey must not assume a modality.");
            testCase.verifyTrue(report.alias_list_matches_manifest, ...
                "The manifest's alias list no longer matches the rig's.");
            testCase.verifyTrue(any(report.unaccounted_terminals== ...
                adaptive_optopatch.canonical_terminal("Dev1/port0/line5")));
            testCase.verifySubstring(char(strjoin(report.warnings," ")), ...
                "Orange DMD");
            inherited=report.terminals( ...
                report.terminals.role=="orange_modulator",:);
            testCase.verifyEqual(inherited.classification, ...
                "inherited_non_stimulation");

            % Nothing was armed, reset, or driven.
            testCase.verifyEqual(daq.ResetCount,resets);
            testCase.verifyFalse(logical(app.acquisition_active));
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Modulator","name","mod488").level,0);
        end

        function theSurveyNoticesARigWhoseAliasListHasMovedOn(testCase)
            % The manifest transcribes the rig file. If the rig file changes
            % and the manifest does not, terminal identity resolves
            % differently on the rig than AO assumes, and the survey is
            % where that should be caught.
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot);
            daq=app.getDevice("DAQ");
            daq.alias_list=[daq.alias_list;{"Dev1/ao5","new modulator"}];
            report=adaptive_optopatch.report_vu_stimulation_outputs(app, ...
                "Print",false);
            testCase.verifyFalse(report.alias_list_matches_manifest);
        end

        % -----------------------------------------------------------------
        % Archiving
        % -----------------------------------------------------------------
        function measuredAccountingIsArchivedWithTheRun(testCase)
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            % An ambient terminal AO has never been told about, so the
            % archive has something unaccounted to carry.
            daq=app.getDevice("DAQ");
            wfm=daq.wfm_data;
            wfm.ao=append_wfm_record(wfm.ao,constant("mystery box","Dev1/ao6",2.5));
            daq.wfm_data=wfm;

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            accounting=run.stimulation_accounting;
            testCase.verifyEqual(accounting.policy,"report_only");
            testCase.verifyEqual(accounting.trial_count,height(run.trials));
            testCase.verifyTrue(any(accounting.unaccounted_terminals== ...
                adaptive_optopatch.canonical_terminal("Dev1/ao6")), ...
                "An unaccounted terminal vanished from the archive.");
            testCase.verifyTrue(accounting.passed, ...
                "Report-only must not fail the run on an unknown terminal.");

            % Measured, not a copy of the declaration: the report answers
            % what was commanded, what was neutral and whether that neutral
            % was actually verified in the compiled samples.
            perTrial=run.trials.stimulation_accounting{1};
            % The galvos are suppressed from a 1P run, so the archive says
            % they were absent by declaration rather than measured neutral.
            galvo=perTrial.declared(perTrial.declared.role=="galvo_x",:);
            testCase.verifyFalse(galvo.present);
            testCase.verifyEqual(galvo.runtime_owner,"suppressed");
            testCase.verifyFalse(galvo.neutral_verified);
            mod488=perTrial.terminals( ...
                perTrial.terminals.role=="blue_modulator",:);
            testCase.verifyEqual(mod488.classification,"commanded");
            testCase.verifyGreaterThan(mod488.measured_maximum,0);

            % And it reaches the acquisition's own output file, beside the
            % data it describes.
            saved=load(fullfile(run.trials.experiment_directory(1), ...
                "output_data.mat"),"adaptive_optopatch_record");
            testCase.verifyTrue(isfield( ...
                saved.adaptive_optopatch_record,"stimulation_accounting"));
            testCase.verifyEqual( ...
                saved.adaptive_optopatch_record.stimulation_accounting.modality, ...
                "1p_dmd");
        end
    end
end

% =====================================================================

function remove_tree(root)
if isfolder(root), rmdir(root,"s"); end
end

function record=constant(name,port,value)
record=struct("name",char(name),"port",char(port), ...
    "wavefile","awfm_constant","params",{{double(value)}}, ...
    "operation","Multiplication","concatTime",[]);
end

function app=simulated_rig(testCase,targets)
%SIMULATED_RIG A test double whose camera matches the fixture's grid.
%   run_1p_manifest validates that the live camera still describes the
%   frozen ROIs before it touches anything, so a simulated camera left at
%   its 2048x2048 default fails the run before any of the safety behaviour
%   under test here is reached.
app=adaptive_optopatch.testing.make_simulated_luminos( ...
    "SimulationOutputRoot",testCase.OutputRoot, ...
    "CameraRoi",targets.reference_camera.roi);
end

function [manifest,targets]=one_photon_manifest()
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","safety_cleanup_test","CellIds","cell_001","RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1.25);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
protocol=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",2,"PulseDurationMs",5,"DarkIntervalMs",[50 50], ...
    "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1.25);
defaults=gui_defaults();
manifest=adaptive_optopatch.build_manifest(reference,targets,protocol, ...
    "Mode","1p_dmd","FovState",fovState,"GuiDefaults",defaults);
end

function defaults=gui_defaults()
defaults=struct("command_voltage_v",1.25,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
