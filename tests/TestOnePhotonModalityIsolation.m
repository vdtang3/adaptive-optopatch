classdef TestOnePhotonModalityIsolation < matlab.unittest.TestCase
    %TESTONEPHOTONMODALITYISOLATION A pure 1P run issues no 2P command at all.
    %   The waveform side of this invariant is TestOnePhotonOutputSuppression:
    %   a 1P acquisition installs no buffered record on the galvos or the
    %   Pockels cell. That left the other half open. Neutralization commanded
    %   every declared output every time, so a pure 1P run still issued
    %   explicit galvo updates and a Pockels dark-write at run start, before
    %   each trial, and during cleanup - hardware it had no business touching
    %   and, on a rig without a Chameleon, hardware that is not even present.
    %
    %   These tests assert the CALLS, not the end state. Parking the galvos at
    %   the stationary value they already hold changes nothing observable in
    %   galvox_wfm, so an end-state assertion passes whether the command was
    %   issued or not. ExplicitGalvoUpdateCount and a listener on the Pockels
    %   cell's level see the write itself; DeviceLookupLog sees whether the
    %   device was so much as resolved.
    %
    %   What an ACTIVE modality owns is unchanged, and is asserted here too -
    %   the point is isolation, not the removal of safety behaviour.

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
        % A. Run start
        % -----------------------------------------------------------------
        function pureOnePhotonNeutralizationCommandsNoTwoPhotonHardware(testCase)
            app=adaptive_optopatch.testing.make_simulated_luminos();
            probe=two_photon_probe(testCase,app);

            report=adaptive_optopatch.neutralize_all_stimulation(app, ...
                "Modality","1p_dmd","Context","unit test");

            testCase.verifyEqual(probe.galvoUpdates(),0, ...
                "A pure 1P neutralization issued an explicit galvo update.");
            testCase.verifyEqual(probe.pockelsWrites(),0, ...
                "A pure 1P neutralization wrote the Pockels cell level.");
            testCase.verifyTrue(report.all_succeeded);
            testCase.verifyEmpty(report.failures, ...
                "A suppressed output must never be reported as a failure.");
            testCase.verifyEqual(sort(report.suppressed), ...
                sort(["two_photon_modulator";"galvo_xy"]));
        end

        function suppressedOutputsAreNotEvenLookedUp(testCase)
            % D. "Suppressed" has to mean not touched, not resolved-then-
            % skipped. The lookup log is the difference.
            app=adaptive_optopatch.testing.make_simulated_luminos();
            app.DeviceLookupLog=strings(0,1);
            adaptive_optopatch.neutralize_all_stimulation(app,"Modality","1p_dmd");
            testCase.verifyFalse(any(contains(app.DeviceLookupLog,"Scanning_Device")), ...
                "The scanner was resolved during a pure 1P neutralization.");
            testCase.verifyFalse(any(app.DeviceLookupLog=="NI_DAQ_Modulator|2P mod"), ...
                "The Pockels cell was resolved during a pure 1P neutralization.");
        end

        function aRigWithNoTwoPhotonHardwareNeutralizesOnePhotonCleanly(testCase)
            % The consequence that matters on a rig that has no Chameleon:
            % an absent 2P device used to be a reported failure on every
            % single 1P run. Now there is nothing to be absent for.
            for missing=["2P mod","Scanning_Device"]
                app=adaptive_optopatch.testing.make_simulated_luminos( ...
                    "MissingDevice",missing);
                app.getDevice("NI_DAQ_Modulator","name","mod488").level=4.0;
                report=adaptive_optopatch.neutralize_all_stimulation(app, ...
                    "Modality","1p_dmd");
                testCase.verifyTrue(report.all_succeeded, ...
                    "Missing "+missing+" failed a pure 1P neutralization.");
                testCase.verifyEmpty(report.failures);
                testCase.verifyEqual( ...
                    app.getDevice("NI_DAQ_Modulator","name","mod488").level,0, ...
                    "1P hardware was not made safe.");
            end
        end

        % -----------------------------------------------------------------
        % E. The 1P outputs are still made safe
        % -----------------------------------------------------------------
        function onePhotonSafetyActionsStillHappen(testCase)
            app=adaptive_optopatch.testing.make_simulated_luminos();
            oneP=adaptive_optopatch.virtual_upright_1p_profile();
            twoP=adaptive_optopatch.virtual_upright_2p_profile();
            app.getDevice("NI_DAQ_Modulator","name","mod488").level=4.0;
            app.getDevice("NI_DAQ_Shutter","name","shutter488").State=true;
            app.getDevice("NI_DAQ_Shutter","name","DMD Trigger").State=true;
            dmd=app.getDevice("DMD","name",oneP.dmd.name);
            dmd.Target=true(dmd.Dimensions);

            adaptive_optopatch.neutralize_all_stimulation(app,"Modality","1p_dmd");

            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Modulator","name","mod488").level, ...
                double(oneP.modulator.dark_v));
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Shutter","name","shutter488").State, ...
                logical(oneP.shutter.closed_state));
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Shutter","name","DMD Trigger").State, ...
                logical(twoP.inactive_one_photon.dmd.trigger_safe_state));
            testCase.verifyFalse(any(dmd.Target(:)), ...
                "The Blue DMD was not blanked.");
        end

        % -----------------------------------------------------------------
        % F, G. Active modalities keep their safety behaviour
        % -----------------------------------------------------------------
        function mixedAndTwoPhotonStillCommandTheTwoPhotonHardware(testCase)
            % Suppression is keyed to the declaration, so an acquisition
            % that actually drives the galvos still parks them.
            for modality=["2p_spiral","mixed"]
                app=adaptive_optopatch.testing.make_simulated_luminos();
                probe=two_photon_probe(testCase,app);
                report=adaptive_optopatch.neutralize_all_stimulation(app, ...
                    "Modality",modality);
                testCase.verifyEqual(probe.galvoUpdates(),1, ...
                    modality+" did not park the galvos.");
                testCase.verifyEqual(probe.pockelsWrites(),1, ...
                    modality+" did not darken the Pockels cell.");
                testCase.verifyEmpty(report.suppressed, ...
                    modality+" suppressed an output it actually drives.");
            end
        end

        function theLegacyScopeStillCommandsEverything(testCase)
            % Unmigrated callers - the 2P runner, galvo calibration, galvo
            % dynamics - pass no modality and must keep what they had.
            app=adaptive_optopatch.testing.make_simulated_luminos();
            probe=two_photon_probe(testCase,app);
            report=adaptive_optopatch.neutralize_all_stimulation(app);
            testCase.verifyEqual(report.modality,"all");
            testCase.verifyEqual(probe.galvoUpdates(),1);
            testCase.verifyEqual(probe.pockelsWrites(),1);
            testCase.verifyEmpty(report.suppressed);
        end

        % -----------------------------------------------------------------
        % B, C. The whole 1P run: start, pre-arm and cleanup
        % -----------------------------------------------------------------
        function aPureOnePhotonRunNeverCommandsTwoPhotonHardware(testCase)
            % Start, per-trial pre-arm and cleanup in one pass, because the
            % invariant is about the run rather than about one call.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            probe=two_photon_probe(testCase,app);

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            testCase.verifyEqual(run.trials.acquisition_status(1),"completed", ...
                "The fixture must actually run, or this proves nothing.");
            testCase.verifyEqual(probe.galvoUpdates(),0, ...
                "A pure 1P run issued an explicit galvo update.");
            testCase.verifyEqual(probe.pockelsWrites(),0, ...
                "A pure 1P run wrote the Pockels cell level.");
            testCase.verifyEqual(run.initial_neutralization.modality,"1p_dmd");
            testCase.verifyEmpty(run.initial_neutralization.failures);
        end

        function aFailedOnePhotonRunCleansUpWithoutCommandingTwoPhotonHardware(testCase)
            % The cleanup path that matters most, because it runs while an
            % exception is already propagating and used to be the one place
            % the galvos were parked whatever had happened.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            app.FailOnAcquisitionNumber=1;
            probe=two_photon_probe(testCase,app);

            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot), ...
                ?MException);

            testCase.verifyEqual(probe.galvoUpdates(),0, ...
                "Failure cleanup parked the galvos during a pure 1P run.");
            testCase.verifyEqual(probe.pockelsWrites(),0, ...
                "Failure cleanup darkened the Pockels cell during a pure 1P run.");
            % 1P hardware is still left safe on the way out.
            testCase.verifyEqual( ...
                app.getDevice("NI_DAQ_Modulator","name","mod488").level,0);
            testCase.verifyFalse( ...
                app.getDevice("NI_DAQ_Shutter","name","shutter488").State);
        end

        function aPreArmFailureCleansUpWithoutCommandingTwoPhotonHardware(testCase)
            % The other exit: a failure before app.acquisition_active is
            % ever set, which takes the explicit restore call rather than
            % the onCleanup guard.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            app.getDevice("Laser_Device","name","488").FailOnStart=true;
            probe=two_photon_probe(testCase,app);

            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot), ...
                "adaptive_optopatch:SimulatedLaserStartFailure");

            testCase.verifyEqual(probe.galvoUpdates(),0);
            testCase.verifyEqual(probe.pockelsWrites(),0);
        end

        % -----------------------------------------------------------------
        % H. Waveform suppression and restoration, with no write in between
        % -----------------------------------------------------------------
        function anAmbientGalvoRecordIsNeitherExecutedNorImperativelyReplaced(testCase)
            % The two halves of the invariant in one test. The operator's
            % ambient galvo waveform does not run, AO does not write the
            % galvos itself instead, and the configuration comes back.
            [manifest,targets]=one_photon_manifest();
            app=simulated_rig(testCase,targets);
            daq=app.getDevice("DAQ");
            ambient=daq.wfm_data;
            ambient.ao=append_wfm_record(ambient.ao, ...
                constant("operator galvo x","Dev2/ao0",3.1));
            daq.wfm_data=ambient;
            probe=two_photon_probe(testCase,app);

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                "OutputDirectory",testCase.OutputRoot);

            % Not executed: no buffered record on the galvo card.
            declared=run.trials.stimulation_accounting{1}.declared;
            galvo=declared(declared.role=="galvo_x",:);
            testCase.verifyFalse(galvo.present);
            testCase.verifyEqual(galvo.runtime_owner,"suppressed");
            % Not imperatively replaced either.
            testCase.verifyEqual(probe.galvoUpdates(),0, ...
                "AO wrote the galvos imperatively instead of through wfm_data.");
            % And the operator's configuration is back, untouched.
            testCase.verifyEqual(daq.wfm_data,ambient);
        end

        % -----------------------------------------------------------------
        % The declaration this is all keyed to
        % -----------------------------------------------------------------
        function ownershipIsReadFromTheManifestRatherThanHardCoded(testCase)
            % If the manifest ever stopped declaring these suppressed, the
            % runtime behaviour would follow it rather than a list in
            % neutralize_all_stimulation. This is what makes that true.
            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            roles=string({manifest.outputs.role});
            for role=["galvo_x","galvo_y","two_photon_modulator"]
                owner=manifest.outputs(roles==role).owner;
                testCase.verifyEqual( ...
                    adaptive_optopatch.manifest_runtime_owner(owner,"1p_dmd"), ...
                    "suppressed");
                testCase.verifyEqual( ...
                    adaptive_optopatch.manifest_runtime_owner(owner,"2p_spiral"), ...
                    "buffered");
                testCase.verifyEqual( ...
                    adaptive_optopatch.manifest_runtime_owner(owner,"mixed"), ...
                    "buffered");
            end
            blue=manifest.outputs(roles=="blue_modulator").owner;
            testCase.verifyEqual( ...
                adaptive_optopatch.manifest_runtime_owner(blue,"1p_dmd"), ...
                "buffered","mod488 is still AO's during a 1P run.");
        end

        % -----------------------------------------------------------------
        % 9. The operator's imaging chain is still none of this function's
        %    business
        % -----------------------------------------------------------------
        function neutralizationNeverCommandsTheOrangeImagingChain(testCase)
            % mod594 is how the operator sets recording power. Nothing here
            % may start writing it, under any modality.
            for modality=["1p_dmd","2p_spiral","mixed","all"]
                app=adaptive_optopatch.testing.make_simulated_luminos();
                app.DeviceLookupLog=strings(0,1);
                adaptive_optopatch.neutralize_all_stimulation(app, ...
                    "Modality",modality);
                looked=app.DeviceLookupLog;
                testCase.verifyFalse(any(contains(looked,"mod594")), ...
                    modality+" resolved the orange modulator.");
                testCase.verifyFalse(any(contains(looked,"shutter594")), ...
                    modality+" resolved the orange shutter.");
            end
        end
    end
end

% =====================================================================
% Fixtures
% =====================================================================

function probe=two_photon_probe(testCase,app)
%TWO_PHOTON_PROBE Count imperative commands reaching the 2P hardware.
%   Counts the CALL rather than the resulting value. Parking the galvos at
%   the stationary command they already hold, or darkening a Pockels cell
%   that is already dark, leaves nothing for an end-state assertion to see.
%
%   The accessors are NESTED function handles rather than anonymous ones on
%   purpose: an anonymous handle captures its variables by value when it is
%   created, so a counter read through one would be frozen at zero.
%
%   Tolerates either device being absent, so the same probe works against a
%   rig built without 2P hardware at all.
pockelsWrites=0;
scanner=app.getDevice("Scanning_Device");
if ~isempty(scanner)
    scanner=scanner(1);
    scanner.ExplicitGalvoUpdateCount=0;
else
    scanner=[];
end
pockels=app.getDevice("NI_DAQ_Modulator","name","2P mod");
if ~isempty(pockels)
    listener=addlistener(pockels(1),"level","PostSet",@(~,~)count_pockels_write());
    testCase.addTeardown(@()delete(listener));
end
probe=struct("galvoUpdates",@galvo_updates,"pockelsWrites",@pockels_written);

    function count_pockels_write()
        pockelsWrites=pockelsWrites+1;
    end

    function n=pockels_written()
        n=pockelsWrites;
    end

    function n=galvo_updates()
        % Read live from the handle, so the count reflects calls made after
        % the probe was built.
        if isempty(scanner), n=0; return; end
        n=scanner.ExplicitGalvoUpdateCount;
    end
end

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
    "FovId","modality_isolation_test","CellIds","cell_001", ...
    "RoiPolygons",polygons);
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
defaults=struct("command_voltage_v",1.25,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
manifest=adaptive_optopatch.build_manifest(reference,targets,protocol, ...
    "Mode","1p_dmd","FovState",fovState,"GuiDefaults",defaults);
end
