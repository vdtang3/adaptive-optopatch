classdef TestHardwareTimingInvariants < matlab.unittest.TestCase
%TESTHARDWARETIMINGINVARIANTS Physical timing limits that a frozen 1P
%schedule must satisfy on the live hardware before output is armed.
    methods (Test)
        function unavailableDmdCapabilityIsRecordedNotInvented(testCase)
            [plan,~]=screen_sequence_plan();
            dmd=simulated_blue_dmd();
            testCase.verifyTrue(isnan(dmd.minimum_picture_time_us));
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            testCase.verifyTrue(configuration.loaded);
            testCase.verifyFalse(configuration.pattern_advance.validated);
            testCase.verifyTrue(isnan( ...
                configuration.pattern_advance.minimum_picture_time_s));
        end

        function dmdRejectsAdvanceFasterThanItsMinimumPictureTime(testCase)
            [plan,~]=screen_sequence_plan();
            shortest=min(diff(plan.dmd_trigger_s));
            dmd=simulated_blue_dmd();
            dmd.minimum_picture_time_us=1e6*shortest*1.5;
            testCase.verifyError( ...
                @()adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false), ...
                "adaptive_optopatch:DmdPatternAdvanceTooFast");
        end

        function dmdAcceptsAdvanceAtItsMinimumPictureTime(testCase)
            [plan,~]=screen_sequence_plan();
            shortest=min(diff(plan.dmd_trigger_s));
            dmd=simulated_blue_dmd();
            dmd.minimum_picture_time_us=1e6*shortest;
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            testCase.verifyTrue(configuration.pattern_advance.validated);
            testCase.verifyEqual( ...
                configuration.pattern_advance.requested_minimum_interval_s, ...
                shortest,"AbsTol",1e-12);
        end

        function frozenPulsesMustSurviveTheLiveWaveformSampleRate(testCase)
            [~,protocol]=screen_sequence_plan();
            profile=adaptive_optopatch.virtual_upright_1p_profile();
            wfm=empty_wfm_data();

            fast=live_global_props(200000);
            [~,~,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                fast,wfm,protocol,profile);
            testCase.verifyEqual(summary.pulse_realization.realized_duration_s, ...
                protocol.events.duration_s,"AbsTol",1e-9);

            % 100 Hz cannot resolve a 5 ms pulse at all, so the commanded
            % light would simply not exist.
            slow=live_global_props(100);
            testCase.verifyError( ...
                @()adaptive_optopatch.build_luminos_1p_waveform_config( ...
                slow,wfm,protocol,profile), ...
                "adaptive_optopatch:PulseShorterThanWaveformSample");
        end

        function frozenDarkIntervalsMustSurviveTheLiveSampleRate(testCase)
            [fovState,targets]=single_cell_fixture();
            % 5 ms pulses separated by 1 ms of dark: at 500 Hz each pulse
            % still lands on a sample but the dark interval does not, so the
            % two commanded pulses would fuse into one.
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",3,"PulseDurationMs",5,"DarkIntervalMs",[1 1], ...
                "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1);
            resolved=adaptive_optopatch.resolve_protocol(definition,fovState, ...
                targets,gui_defaults(),"Mode","1p_dmd");
            protocol=resolved{1};
            profile=adaptive_optopatch.virtual_upright_1p_profile();
            wfm=empty_wfm_data();
            testCase.verifyError( ...
                @()adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(500),wfm,protocol,profile), ...
                "adaptive_optopatch:DarkIntervalShorterThanWaveformSample");
            [~,~,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),wfm,protocol,profile);
            testCase.verifyGreaterThanOrEqual( ...
                min(summary.pulse_realization.dark_interval_sample_count),1);
        end

        function changingCameraGeometryAfterFreezingBlocksExecution(testCase)
            outputRoot=tempname;
            cleanup=onCleanup(@()remove_folder(outputRoot)); %#ok<NASGU>
            [fovState,targets]=single_cell_fixture();
            fovState=adaptive_optopatch.update_cell_calibration( ...
                fovState,"cell_001","CommandVoltageV",1);
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"PulseDurationMs",5,"PreDelayMs",10, ...
                "PostDelayMs",10,"ModulatorVoltage",1);
            manifest=adaptive_optopatch.build_manifest(fovState.reference, ...
                targets,definition,"Mode","1p_dmd","FovState",fovState, ...
                "GuiDefaults",gui_defaults());
            roi=targets.reference_camera.roi;
            sim=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",outputRoot,"CameraRoi",roi);

            run=adaptive_optopatch.run_1p_manifest(manifest,targets,sim, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            testCase.verifyTrue(run.camera_geometry.passed);
            acquisitions=numel(sim.AcquisitionHistory);

            % Rebinning the voltage camera after freezing changes what a
            % frozen camera pixel means, so execution must stop before any
            % light is delivered rather than recording an unusable movie.
            camera=sim.getDevice("Camera");
            camera.bin=2;
            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,sim,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"Resume",false), ...
                "adaptive_optopatch:CameraGeometryChangedSinceFreeze");
            camera.bin=1;
            camera.ROI=roi+[7 0 0 0];
            testCase.verifyError(@()adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,sim,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"Resume",false), ...
                "adaptive_optopatch:CameraGeometryChangedSinceFreeze");
            testCase.verifyEqual(numel(sim.AcquisitionHistory),acquisitions, ...
                "No acquisition may start once the frozen grid is invalid.");
        end

        function dmdAdvanceTriggerMustNotOverlapLight(testCase)
            [plan,protocol]=screen_sequence_plan();
            profile=adaptive_optopatch.virtual_upright_1p_profile();
            wfm=empty_wfm_data();
            [~,~,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(200000),wfm,protocol,profile, ...
                "DmdSequencePlan",plan);
            testCase.verifyEqual(summary.dmd_sequence.pattern_count, ...
                height(protocol.events));

            % A trigger is at least three samples wide, so a low enough rate
            % pushes the second advance into the pulse it selects.
            narrow=protocol;
            narrow.events.onset_s(2:end)=narrow.events.onset_s(2:end)- ...
                (narrow.events.onset_s(2)-narrow.events.offset_s(1))+0.004;
            narrow.events.onset_s(3)=narrow.events.onset_s(2)+ ...
                narrow.events.duration_s(2)+0.05;
            narrow=adaptive_optopatch.normalize_protocol(narrow);
            narrowPlan=adaptive_optopatch.build_dmd_sequence_plan(narrow,targets_for(narrow));
            testCase.verifyError( ...
                @()adaptive_optopatch.build_luminos_1p_waveform_config( ...
                live_global_props(500),wfm,narrow,profile, ...
                "DmdSequencePlan",narrowPlan), ...
                "adaptive_optopatch:DmdAdvanceOverlapsLight");
        end
    end
end

function targets=targets_for(~)
[~,targets]=single_cell_fixture();
end

function props=live_global_props(rate)
props=struct("rate",rate,"total_time",1,"clock_source","Internal Dev1", ...
    "trigger_source","Dev1/PFI9","daq_master",true);
end

function data=empty_wfm_data()
data=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
end

function dmd=simulated_blue_dmd()
sim=adaptive_optopatch.testing.make_simulated_luminos();
dmd=sim.getDevice("DMD","name","DMD_Blue");
end

function [plan,protocol]=screen_sequence_plan()
[fovState,targets]=single_cell_fixture();
definition=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",3,"PulseDurationMs",5,"DarkIntervalMs",[50 50], ...
    "PreDelayMs",100,"PostDelayMs",100,"ModulatorVoltage",1);
resolved=adaptive_optopatch.resolve_protocol(definition,fovState,targets, ...
    gui_defaults(),"Mode","1p_dmd");
protocol=resolved{1};
plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
end

function [fovState,targets]=single_cell_fixture()
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","hardware_timing_test","CellIds","cell_001", ...
    "RoiPolygons",polygons);
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
fovState=adaptive_optopatch.update_cell_calibration( ...
    fovState,"cell_001","CommandVoltageV",1);
targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
end

function defaults=gui_defaults()
defaults=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function remove_folder(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
