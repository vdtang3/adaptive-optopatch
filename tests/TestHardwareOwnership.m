classdef TestHardwareOwnership < matlab.unittest.TestCase
    %TESTHARDWAREOWNERSHIP What Adaptive Optopatch owns during an acquisition.
    %   AO used to run inside the operator's own Luminos acquisition: it
    %   inherited DAQ.global_props from whatever the Waveforms tab was left
    %   on, inherited the Camera tab's frame cadence, and inherited the
    %   mod594 record that illuminated the preparation. All three were
    %   configuration the experiment depended on and nothing in AO stated.
    %
    %   AO now owns the acquisition. This suite holds the three halves of
    %   that: what AO sets, that AO puts every one of them back, and that
    %   what is still genuinely inherited - the camera ROI and the spatial
    %   calibrations - is not touched.
    %
    %   THE RESTORE ASSERTIONS ARE THE POINT. Taking a camera out of
    %   free-running is easy; giving it back exactly as it was found, on a
    %   run that threw halfway, is the part that rots. Every ownership test
    %   below has a failure-path twin.

    methods (Test)
        % -----------------------------------------------------------------
        % A rig where Waveforms was never opened
        % -----------------------------------------------------------------
        function aFreshLuminosHasNoWaveformSettingsAtAll(testCase)
            % The precondition every test below rests on, asserted so a
            % simulator change cannot quietly make them vacuous.
            sim=fresh_rig();
            daq=sim.getDevice("DAQ","name","Dev1");
            testCase.verifyEmpty(fieldnames(daq.global_props), ...
                "A fresh Luminos carries no global_props.");
            testCase.verifyEmpty(daq.wfm_data);
        end

        function hardwareResolvesWithNoWaveformProtocolLoaded(testCase)
            % The gate this whole change removes. resolve_luminos_1p_hardware
            % used to raise NoActiveLuminosWaveform here and AO could not
            % start until somebody opened another tab.
            sim=fresh_rig();
            hardware=adaptive_optopatch.resolve_luminos_1p_hardware( ...
                sim,AoFixtures.onePhotonProfile());
            testCase.verifyNotEmpty(hardware.ao_global_props);
            testCase.verifyTrue(hardware.owns_camera_timing);
            testCase.verifyTrue(hardware.owns_orange_illumination);
        end

        function aoBuildsTheVirtualUprightTimingItself(testCase)
            profile=AoFixtures.onePhotonProfile();
            [props,provenance]=adaptive_optopatch.build_luminos_global_props( ...
                profile,2.5);

            testCase.verifyEqual(props.rate,200000);
            testCase.verifyEqual(props.total_time,2.5);
            testCase.verifyEqual(string(props.clock_source),"Internal Dev1");
            testCase.verifyTrue(logical(props.daq_master));
            testCase.verifyEqual(string(props.completion_trigger),"None");
            % The real VU multi-DAQ topology, not a single-card
            % simplification: both start-trigger terminals and both ends of
            % the clock bridge survive.
            testCase.verifyEqual(reshape(string(props.trigger_source),1,[]), ...
                ["Dev1/PFI9","Dev2/PFI1"]);
            testCase.verifyEqual(provenance.clock_bridge, ...
                ["Dev1/PFI12","Dev2/PFI0"]);
            testCase.verifyEqual(provenance.sample_count,500000);
            % The six fields Luminos actually reads, and no more: a seventh
            % would configure nothing and would read as though it did.
            testCase.verifyEqual(sort(string(fieldnames(props))), ...
                sort(["total_time";"rate";"clock_source";"daq_master"; ...
                "completion_trigger";"trigger_source"]));
        end

        function theResolvedTimingIsArchivedAsProvenance(testCase)
            % Including what it displaced, so a later reader asking "what
            % rate was this recorded at, and did somebody's tab decide it"
            % does not have to infer the answer from sample counts.
            profile=AoFixtures.onePhotonProfile();
            previous=struct("rate",100000,"total_time",9, ...
                "clock_source","Dev1/PFI0","trigger_source","Dev1/PFI9", ...
                "daq_master",0);
            [~,provenance]=adaptive_optopatch.build_luminos_global_props( ...
                profile,1,"PreviousGlobalProps",previous);
            testCase.verifyTrue(provenance.replaced_active_waveform_settings);
            testCase.verifyEqual(provenance.previous.rate,100000);
            testCase.verifyEqual(provenance.sample_rate_hz,200000, ...
                "The profile decides the rate, not what it replaced.");

            [~,fresh]=adaptive_optopatch.build_luminos_global_props(profile,1);
            testCase.verifyFalse(fresh.replaced_active_waveform_settings);
        end

        function aProfileWithoutARateIsRefusedRatherThanGuessed(testCase)
            % 1e5 is Luminos's fallback for an empty Waveforms field, not a
            % statement about any rig, so there is no honest default here.
            profile=AoFixtures.onePhotonProfile();
            profile.daq=rmfield(profile.daq,"sample_rate_hz");
            testCase.verifyError( ...
                @()adaptive_optopatch.build_luminos_global_props(profile,1), ...
                "adaptive_optopatch:ProfileDeclaresNoSampleRate");
        end

        function aSimulatedRunCompletesWithNoWaveformProtocol(testCase)
            % End to end, which is the claim that matters: Luminos starts
            % fresh, Waveforms is never opened, and an acquisition runs.
            [run,sim]=run_on_fresh_rig(testCase);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyEqual(numel(sim.AcquisitionHistory),1);

            summary=run.trials.waveform_summary{1};
            testCase.verifyEqual(summary.sample_rate_hz,200000);
            testCase.verifyEqual(summary.daq_timing.clock_source,"Internal Dev1");
        end

        function aOnePhotonRunStillBuildsNoTaskOnTheGalvoCard(testCase)
            % The existing safety rule, re-asserted on the new path: owning
            % the timing must not have smuggled a Dev2 record back in.
            [run,~]=run_on_fresh_rig(testCase);
            summary=run.trials.waveform_summary{1};
            terminals=summary.pulses;
            testCase.verifyNotEmpty(terminals);
            accounting=run.trials.stimulation_accounting{1};
            devices=arrayfun(@(t)extractBefore(t+"/","/"), ...
                string(accounting.terminals.canonical_terminal));
            testCase.verifyFalse(any(devices=="Dev2"), ...
                "A 1P-only acquisition must stay off the galvo card.");
        end

        % -----------------------------------------------------------------
        % Camera ownership
        % -----------------------------------------------------------------
        function aFreeRunningCameraIsPutIntoPerFrameTriggering(testCase)
            % Found in the wrong state deliberately: free-running, at a
            % period AO does not want, with a live-view exposure. Before
            % this change AO read these and a free-running camera fell
            % through to Camera.AutoN - an untriggered recording whose
            % frame rate the archive could only estimate.
            [run,~]=run_on_fresh_rig(testCase, ...
                "CameraTriggerSource","Off","CameraFrameRateHz",50);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");

            plan=run.trials.waveform_summary{1}.camera_acquisition_state;
            testCase.verifyEqual(string(plan.frame_trigger_source),"DAQ");
            testCase.verifyEqual(plan.frame_period_ms,1.000,"AbsTol",0);
            testCase.verifyEqual(plan.frame_rate_hz,1000,"AbsTol",0);
            testCase.verifyEqual(plan.acquisition_exposure_s,0.001,"AbsTol",0);
            % frametrigger_source IS the readout-mode switch; recorded so
            % the archive says which Hamamatsu mode the frames came from.
            testCase.verifyEqual(plan.readout_mode_expected,1);
            % And the frame count follows the AO cadence, not the 50 Hz the
            % camera was found at.
            testCase.verifyEqual(plan.frames_requested, ...
                ceil(plan.acquisition_duration_s*1000));
            % And the camera was actually asked for them. Read off the
            % archived camera frame plan, which set_camera_frames_for_duration
            % produced from the cadence AO had just applied.
            cameraPlan=run.trials.waveform_summary{1}.camera_frame_plan;
            voltage=cameraPlan(string({cameraPlan.camera_name})=="Orca Fusion");
            testCase.assertNumElements(voltage,1);
            testCase.verifyEqual(voltage.frames_requested,plan.frames_requested);
            testCase.verifyEqual(voltage.trigger_period_ms,1.000,"AbsTol",0);
        end

        function theCameraCadenceIsRestoredAfterASuccessfulRun(testCase)
            sim=fresh_rig("CameraTriggerSource","Off","CameraFrameRateHz",50);
            before=camera_cadence(sim);
            run_manifest_on(testCase,sim);
            testCase.verifyEqual(camera_cadence(sim),before, ...
                "The camera was not returned to the state it was found in.");
        end

        function theCameraCadenceIsRestoredAfterAFailedRun(testCase)
            % The path that rots. Cleanup runs from onCleanup, while an
            % exception is already propagating.
            sim=fresh_rig("CameraTriggerSource","Off","CameraFrameRateHz",50);
            before=camera_cadence(sim);
            sim.FailOnAcquisitionNumber=1;
            testCase.verifyError(@()run_manifest_on(testCase,sim), ...
                ?MException);
            testCase.verifyEqual(camera_cadence(sim),before, ...
                "A failed acquisition left the camera in AO's state.");
        end

        function theCameraRoiAndBinningAreNeverWritten(testCase)
            % The half that stays the Camera tab's. AO reads them - the
            % reference geometry is expressed in them, and
            % validate_camera_geometry refuses a run where the two have
            % parted company - and never writes them.
            sim=fresh_rig();
            camera=voltage_camera(sim);
            roi=camera.ROI; bin=camera.bin;
            run_manifest_on(testCase,sim);
            testCase.verifyEqual(camera.ROI,roi);
            testCase.verifyEqual(camera.bin,bin);
        end

        function aProfileAskingForAnImpossibleExposureIsRefused(testCase)
            % In synchronous readout a frame ends when the next trigger
            % arrives, so an exposure longer than the period describes a
            % frame the camera cannot deliver.
            profile=AoFixtures.onePhotonProfile();
            profile.camera.acquisition_exposure_s=0.002;
            testCase.verifyError( ...
                @()adaptive_optopatch.camera_cadence_for_profile(profile), ...
                "adaptive_optopatch:ExposureExceedsFramePeriod");
        end

        function aRigWhoseProfileDeclaresNoCadenceStillInherits(testCase)
            % The Spinning Upright's camera is counter-triggered through a
            % different path and nothing has been checked on it, so its
            % profile declares no cadence and AO leaves the Camera tab
            % alone there. Opting in is per rig, not by analogy.
            cadence=adaptive_optopatch.camera_cadence_for_profile( ...
                adaptive_optopatch.spinning_upright_1p_profile());
            testCase.verifyFalse(cadence.declared);
        end

        % -----------------------------------------------------------------
        % Orange recording illumination
        % -----------------------------------------------------------------
        function theRunInstallsExactlyOneConstantOnMod594(testCase)
            for ambient=["none","stale_constant","unrelated"]
                wfm=ambient_waveforms(ambient);
                profile=AoFixtures.onePhotonProfile();
                [props,configured]= ...
                    adaptive_optopatch.build_luminos_mixed_waveform_config( ...
                    adaptive_optopatch.build_luminos_global_props(profile,0.5), ...
                    wfm,one_photon_protocol(),"OnePhotonProfile",profile);

                records=records_on(configured.ao,"Dev1/ao1");
                testCase.assertNumElements(records,1, ...
                    "ambient '"+ambient+"' left "+numel(records)+" mod594 records.");
                testCase.verifyEqual(string(records.wavefile),"awfm_constant");
                testCase.verifyEqual(records.params{1}, ...
                    AoFixtures.orangeRecordingVoltage(),"AbsTol",0);

                % Compiled to samples, because the parameter is what was
                % asked for and the samples are what reaches the wire. The
                % final sample is excluded: Luminos forces data(end)=0 on
                % every terminal in Build_Waveforms_DevicePartitioned, so
                % that zero is the acquisition ending rather than a
                % modulation AO applied.
                samples=compiled_samples(props,configured.ao,"Dev1/ao1");
                testCase.verifyTrue(all(samples(1:end-1)== ...
                    AoFixtures.orangeRecordingVoltage()), ...
                    "ambient '"+ambient+"': orange was not constant.");
                testCase.verifyGreaterThan(numel(samples),1);
            end
        end

        function anUnrelatedAmbientRecordIsNotDisturbed(testCase)
            profile=AoFixtures.onePhotonProfile();
            [~,configured]= ...
                adaptive_optopatch.build_luminos_mixed_waveform_config( ...
                adaptive_optopatch.build_luminos_global_props(profile,0.5), ...
                ambient_waveforms("unrelated"),one_photon_protocol(), ...
                "OnePhotonProfile",profile);
            unrelated=records_on(configured.ao,"Dev1/ao6");
            testCase.assertNumElements(unrelated,1);
            testCase.verifyEqual(unrelated.params{1},3.3);
        end

        function anUnsetOrangeVoltageIsRefusedRatherThanGuessed(testCase)
            % Zero would record a black movie and look like a configuration
            % that worked; any other number would change somebody's
            % photobleaching silently.
            profile=adaptive_optopatch.virtual_upright_1p_profile();
            testCase.verifyTrue(isnan(profile.orange_modulator.recording_v), ...
                "The shipped profile must declare no recording level.");
            testCase.verifyError( ...
                @()adaptive_optopatch.orange_recording_voltage(profile), ...
                "adaptive_optopatch:OrangeRecordingVoltageUnset");
        end

        function theOrangeVoltageIsCheckedAgainstTheRigsOwnRange(testCase)
            profile=AoFixtures.onePhotonProfile();
            testCase.verifyEqual(profile.orange_modulator.minimum_v,0);
            testCase.verifyEqual(profile.orange_modulator.maximum_v,5);
            for bad=[-0.1 5.1]
                profile.orange_modulator.recording_v=bad;
                testCase.verifyError( ...
                    @()adaptive_optopatch.orange_recording_voltage(profile), ...
                    "adaptive_optopatch:OrangeRecordingVoltageOutOfRange");
            end
        end

        function theLiveViewOrangeLevelIsRestoredAfterTheRun(testCase)
            % AO drives a buffered constant onto Dev1/ao1 and the channel
            % keeps its last sample once the task releases it, so without
            % an explicit restore the live view comes back at the recording
            % voltage instead of where the operator had it.
            sim=fresh_rig();
            modulator=sim.getDevice("NI_DAQ_Modulator","name","mod594");
            before=modulator.level;
            testCase.assertNotEqual(before,AoFixtures.orangeRecordingVoltage());
            run_manifest_on(testCase,sim);
            testCase.verifyEqual(modulator.level,before);
        end

        function theLiveViewOrangeLevelIsRestoredAfterAFailure(testCase)
            sim=fresh_rig();
            modulator=sim.getDevice("NI_DAQ_Modulator","name","mod594");
            before=modulator.level;
            sim.FailOnAcquisitionNumber=1;
            testCase.verifyError(@()run_manifest_on(testCase,sim),?MException);
            testCase.verifyEqual(modulator.level,before);
        end

        % -----------------------------------------------------------------
        % Orange shutter
        % -----------------------------------------------------------------
        function noBufferedRecordHoldsTheOrangeShutter(testCase)
            % An NI_DAQ_Shutter is an on-demand digital write and the
            % runner drives it imperatively, so a buffered record would be
            % a second runtime owner of one line.
            profile=AoFixtures.onePhotonProfile();
            wfm=ambient_waveforms("none");
            wfm.do=constant_record("shutter594","shutter594",1);
            [~,configured]= ...
                adaptive_optopatch.build_luminos_mixed_waveform_config( ...
                adaptive_optopatch.build_luminos_global_props(profile,0.5), ...
                wfm,one_photon_protocol(),"OnePhotonProfile",profile);
            testCase.verifyEmpty(records_on(configured.do,"Dev1/port0/line1"));
        end

        function theOrangeShutterIsClosedAfterSuccessAndAfterFailure(testCase)
            % CLOSED, not restored to what it was. Cleanup runs when a run
            % ended, failed, was aborted or was interrupted, and the state
            % that is right in all four is closed - the rule shutter488 has
            % always followed. An open shutter put back because the
            % operator happened to have one open would mean a failed run
            % leaving the preparation illuminated.
            profile=AoFixtures.onePhotonProfile();
            for failing=[false true]
                sim=fresh_rig();
                shutter=sim.getDevice("NI_DAQ_Shutter","name","shutter594");
                shutter.State=profile.orange_shutter.open_state;
                if failing, sim.FailOnAcquisitionNumber=1; end
                if failing
                    testCase.verifyError(@()run_manifest_on(testCase,sim), ...
                        ?MException);
                else
                    run_manifest_on(testCase,sim);
                end
                testCase.verifyEqual(logical(shutter.State), ...
                    logical(profile.orange_shutter.closed_state), ...
                    "failing="+string(failing)+": the orange shutter was left open.");
            end
        end

        % -----------------------------------------------------------------
        % The Orange DMD recording-mask preview
        % -----------------------------------------------------------------
        function thePreviewIsUnavailableUntilThereIsAMaskToShow(testCase)
            controller=fresh_controller();
            testCase.verifyFalse(controller.legalActions().show_recording_mask);
            testCase.verifyError(@()controller.showRecordingMask(), ...
                "adaptive_optopatch:NoReferenceForRecordingMask");
        end

        function thePreviewProjectsTheRecordingMaskThroughTheOrangeCalibration(testCase)
            [controller,sim]=populated_controller(testCase);
            controller.showRecordingMask();

            dmd=sim.getDevice("DMD","name","DMD_Orange");
            [~,targets]=controller.buildSpatialArtifacts();
            expected=adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
                logical(targets.orange_combined_mask), ...
                targets.reference_camera,dmd,"DMD_Orange");
            testCase.verifyEqual(logical(dmd.Target>.5),logical(expected>.5), ...
                "The preview is not the acquisition's own mask.");

            state=controller.getState().recording_mask_preview;
            testCase.verifyTrue(state.active);
            testCase.verifyEqual(state.dmd_name,"DMD_Orange");
            testCase.verifyFalse(state.applies_recording_voltage);
        end

        function thePreviewAppliesNoOrangePower(testCase)
            % The whole workflow depends on this: the operator tunes
            % brightness with the ordinary Luminos control while the mask
            % is up, and then types what they chose into AO. A preview that
            % applied AO's level would be showing them the answer.
            [controller,sim]=populated_controller(testCase);
            modulator=sim.getDevice("NI_DAQ_Modulator","name","mod594");
            shutter=sim.getDevice("NI_DAQ_Shutter","name","shutter594");
            level=modulator.level; state=shutter.State;

            controller.showRecordingMask();
            testCase.verifyEqual(modulator.level,level);
            testCase.verifyEqual(shutter.State,state);

            % And editing the AO value while previewing changes neither the
            % live level nor the projection.
            target=dmd_pattern(sim);
            controller.setPlanParameter("orange_recording_voltage_v",1.9);
            testCase.verifyEqual(modulator.level,level, ...
                "Editing the AO field changed the live-view orange level.");
            testCase.verifyTrue(controller.getState().recording_mask_preview.active, ...
                "Editing the orange level must not take the mask down.");
            testCase.verifyEqual(dmd_pattern(sim),target);
        end

        function clearingThePreviewBlanksTheDeviceAndReleasesIt(testCase)
            [controller,sim]=populated_controller(testCase);
            controller.showRecordingMask();
            testCase.assertTrue(any(dmd_pattern(sim),"all"));

            controller.clearRecordingMask();
            testCase.verifyFalse(any(dmd_pattern(sim),"all"), ...
                "The DMD was left showing a stale mask.");
            testCase.verifyFalse(controller.getState().recording_mask_preview.active);
            testCase.verifyFalse(controller.legalActions().clear_recording_mask);
        end

        function aTargetChangeTakesTheStalePreviewDown(testCase)
            % Every edit that changes what would be recorded comes through
            % markEditableChanged, so this covers the soma edits, the
            % spatial parameters and the protocol as well.
            [controller,sim]=populated_controller(testCase);
            controller.showRecordingMask();
            cells=controller.getState().cells;
            controller.setCellEligibility(cells(1).cell_id, ...
                "RecordingEnabled",false);
            testCase.verifyFalse(controller.getState().recording_mask_preview.active);
            testCase.verifyFalse(any(dmd_pattern(sim),"all"));
        end

        function aNewFieldOfViewTakesThePreviewDown(testCase)
            [controller,sim]=populated_controller(testCase);
            controller.showRecordingMask();
            controller.startNewFov();
            testCase.verifyFalse(controller.getState().recording_mask_preview.active);
            testCase.verifyFalse(any(dmd_pattern(sim),"all"));
        end

        function runningClearsThePreviewBeforeTakingTheDevice(testCase)
            % Two live ownership claims on one DMD is a state neither can
            % release cleanly, so the preview's claim is given back by the
            % code that took it, before any acquisition machinery starts.
            %
            % Preparing a plan deliberately does NOT clear it: updatePlan
            % reads the session rather than changing what would be
            % recorded, and an operator who has just lined the mask up
            % should not lose it by pressing Update plan.
            [controller,sim]=populated_controller(testCase);
            controller.updatePlan();
            controller.showRecordingMask();
            testCase.assertTrue( ...
                controller.getState().recording_mask_preview.active);

            controller.runPreparedPlan();
            testCase.verifyFalse( ...
                controller.getState().recording_mask_preview.active, ...
                "Run must take the preview down before claiming the DMD.");
            testCase.verifyNotEmpty(sim.AcquisitionHistory);
        end

        % -----------------------------------------------------------------
        % What the interface is told
        % -----------------------------------------------------------------
        function theStateSaysWhoOwnsWhat(testCase)
            [controller,~]=populated_controller(testCase);
            ownership=controller.getState().hardware_ownership;

            testCase.verifyEqual(ownership.camera_name,"Orca Fusion");
            testCase.verifyTrue(ownership.owns_camera_timing);
            testCase.verifyEqual(ownership.frame_period_ms,1.000,"AbsTol",0);
            testCase.verifyEqual(ownership.sample_rate_hz,200000);
            testCase.verifyEqual(ownership.clock_source,"Internal Dev1");
            testCase.verifyTrue(ownership.owns_orange_illumination);
            testCase.verifyEqual(ownership.orange_minimum_v,0);
            testCase.verifyEqual(ownership.orange_maximum_v,5);
            testCase.verifyFalse(ownership.requires_waveforms_protocol);

            % The inherited half, read off the live camera rather than
            % remembered, in Luminos's own ROI ordering.
            testCase.verifyTrue(ownership.camera_state_readable);
            testCase.verifyEqual(ownership.camera_roi_order, ...
                ["left","width","top","height"]);
            testCase.verifyNumElements(ownership.camera_roi,4);
        end

        function anUnsetOrangeVoltageBlocksThePlanAndSaysSo(testCase)
            controller=fresh_controller();
            issues=controller.planBlockingIssues();
            testCase.verifyTrue(any(issues=="Set the Orange recording voltage."));
        end

        function theStateSnapshotStillSerializesAsJson(testCase)
            [controller,~]=populated_controller(testCase);
            controller.showRecordingMask();
            testCase.verifyWarningFree(@()jsonencode(controller.getState()));
        end
    end
end

% =====================================================================
% Fixtures
% =====================================================================

function sim=fresh_rig(varargin)
%FRESH_RIG A Virtual Upright where the Waveforms tab was never opened.
sim=adaptive_optopatch.testing.make_simulated_luminos( ...
    "WaveformsNeverOpened",true,"CameraRoi",[0 9 0 8], ...
    "SimulationOutputRoot",tempname,varargin{:});
end

function [run,sim]=run_on_fresh_rig(testCase,varargin)
sim=fresh_rig(varargin{:});
run=run_manifest_on(testCase,sim);
end

function run=run_manifest_on(testCase,sim)
[targets,protocol]=one_photon_targets();
trials=table(1,"1p_dmd","cell_001",false,1,{protocol}, ...
    protocol.acquisition_duration_s,"ownership","planned","", ...
    'VariableNames',{'trial_id','stimulation_mode','target_cell_id', ...
    'is_null','target_index','pulse_schedule','acquisition_duration_s', ...
    'output_tag','acquisition_status','experiment_directory'});
folder=tempname;
testCase.addTeardown(@()AoFixtures.removeFolder(folder));
run=adaptive_optopatch.run_1p_manifest(struct("trials",trials),targets,sim, ...
    "Profile",AoFixtures.onePhotonProfile(),"ConfirmLiveOutput",true, ...
    "ShutterSettleTimeS",0,"OutputDirectory",folder);
end

function value=camera_cadence(sim)
camera=voltage_camera(sim);
value=struct("frametrigger_source",string(camera.frametrigger_source), ...
    "daqtrig_period_ms",double(camera.daqtrig_period_ms), ...
    "acquisition_exposuretime",double(camera.acquisition_exposuretime), ...
    "frames_requested",double(camera.frames_requested));
end

function camera=voltage_camera(sim)
cameras=sim.getDevice("Camera");
serial=string(adaptive_optopatch.virtual_upright_1p_profile().camera.serial);
for k=1:numel(cameras)
    if strip(erase(string(cameras(k).cam_id),"S/N: "))==serial
        camera=cameras(k); return
    end
end
error("No voltage camera in the simulated rig.");
end

function value=dmd_pattern(sim)
value=logical(sim.getDevice("DMD","name","DMD_Orange").Target>.5);
end

function controller=fresh_controller()
controller=adaptive_optopatch.AdaptiveOptopatchController( ...
    "LuminosApp",fresh_rig());
end

function [controller,sim]=populated_controller(testCase)
%POPULATED_CONTROLLER A session with a FOV, two somata and a protocol.
%   Built the way the controller suites build one - setReferenceData with a
%   reference whose metadata names the camera geometry - rather than from a
%   saved FOV, because what these tests need is a live session on a rig
%   where Waveforms was never opened.
root=tempname; mkdir(root);
testCase.addTeardown(@()AoFixtures.removeFolder(root));
sim=fresh_rig("CameraRoi",[974 100 984 80]);
controller=adaptive_optopatch.AdaptiveOptopatchController("LuminosApp",sim, ...
    "RunRoot",root);
% Teardowns run last-added-first, so the delete is registered BEFORE the
% clear: the mask comes down while the controller is still valid.
testCase.addTeardown(@()delete(controller));
testCase.addTeardown(@()controller.clearRecordingMask());
controller.setPlanParameter("orange_recording_voltage_v", ...
    AoFixtures.orangeRecordingVoltage());
controller.setReferenceData(ones(80,100),controller_reference_info(root), ...
    {[25 25;40 25;40 40;25 40],[60 40;75 40;75 55;60 55]});
controller.setPlanParameter("stimulation_mode","1p_dmd");
controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",1,"ModulatorVoltage",1));
end

function info=controller_reference_info(root)
camera=struct("name","Orca Fusion","ROI",[974 100 984 80],"bin",1, ...
    "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
info=struct("snapshot_name","hardware_ownership_test", ...
    "snapshot_directory",string(root), ...
    "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
    "metadata",struct("rig_name","Virtual_Upright","voltage_camera",camera));
end

function [targets,protocol]=one_photon_targets()
%ONE_PHOTON_TARGETS A minimal single-cell bundle, shaped as the runner needs.
%   The same shape TestManifestExecution builds, with the Orange masks the
%   recording-mask path reads added.
mask=true(8,9,1);
target=struct("cell_id","cell_001","qc_pass",true, ...
    "stimulation_enabled",true,"recording_enabled",true);
targets=struct("targets",target,"dmd_camera_masks",mask, ...
    "canonical_roi_masks",mask,"blue_camera_masks",mask, ...
    "orange_camera_masks",mask,"orange_combined_mask",true(8,9), ...
    "blank_dmd_mask",false(8,9), ...
    "reference_camera",AoFixtures.frameCameraGeometry([8 9]), ...
    "parameters",struct("blue_mask_adjustment_pixels",0, ...
        "orange_expansion_pixels",2));
protocol=one_photon_protocol();
end

function protocol=one_photon_protocol()
pulse_id=1; condition_id="blue"; stimulation_source="1p_dmd";
target_cell_id="cell_001"; target_index=1; onset_s=0.05; duration_s=0.01;
is_null=false; command_voltage_v=1; blue_mask_adjustment_pixels=0;
dmd_pattern_index=1; command_voltage_source="event";
pulse_duration_source="event"; blue_mask_adjustment_source="event";
events=table(pulse_id,condition_id,stimulation_source,target_cell_id, ...
    target_index,onset_s,duration_s,is_null,command_voltage_v, ...
    blue_mask_adjustment_pixels,dmd_pattern_index,command_voltage_source, ...
    pulse_duration_source,blue_mask_adjustment_source);
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","resolved_acquisition","protocol_id","ownership", ...
    "protocol_type","test","source_protocol_id","ownership", ...
    "acquisition_id","ownership","target_policy","each_stimulation_enabled_cell", ...
    "event_order","ordered","random_seed",1,"events",events, ...
    "parameters",struct("orange_expansion_pixels",2), ...
    "parameter_sources",struct,"acquisition_duration_s",0.2);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function wfm=ambient_waveforms(kind)
wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
switch kind
    case "none"
    case "stale_constant"
        wfm.ao=constant_record("mod594","mod594",1.37);
    case "unrelated"
        wfm.ao=[constant_record("mod594","mod594",1.37) ...
            constant_record("something else","Dev1/ao6",3.3)];
end
end

function record=constant_record(name,port,value)
record=struct("name",char(name),"port",char(port), ...
    "wavefile","awfm_constant","params",{{double(value)}}, ...
    "operation","Multiplication","concatTime",[],"script_owner",[]);
end

function records=records_on(candidates,terminal)
records=candidates([]);
if isempty(candidates), return; end
manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
wanted=adaptive_optopatch.canonical_terminal(terminal,manifest.alias_list);
for k=1:numel(candidates)
    spellings=[string(candidates(k).name) string(candidates(k).port)];
    if any(adaptive_optopatch.canonical_terminal( ...
            spellings,manifest.alias_list)==wanted)
        records(end+1)=candidates(k); %#ok<AGROW>
    end
end
end

function samples=compiled_samples(globalProps,records,terminal)
manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
compiled=adaptive_optopatch.compile_output_samples( ...
    globalProps,records,manifest.alias_list);
wanted=adaptive_optopatch.canonical_terminal(terminal,manifest.alias_list);
samples=[];
for k=1:numel(compiled)
    if compiled(k).canonical_terminal==wanted
        samples=compiled(k).samples; return
    end
end
end
