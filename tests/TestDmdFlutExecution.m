classdef TestDmdFlutExecution < matlab.unittest.TestCase
    properties
        ProtocolPath string
    end

    methods (TestClassSetup)
        function addProtocolFolder(testCase)
            root=fileparts(fileparts(mfilename("fullpath")));
            testCase.ProtocolPath=fullfile(root,"pulse-protocols");
            addpath(testCase.ProtocolPath);
        end
    end

    methods (TestClassTeardown)
        function removeProtocolFolder(testCase)
            rmpath(testCase.ProtocolPath);
        end
    end

    methods (Test)
        function thirtyFourMasksProgramOnceForThirtyFourHundredEvents(testCase)
            sequence=repmat((1:34)',100,1);
            [targets,protocol]=fixture(34,sequence,zeros(3400,1));
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=simulated_dmd(targets.reference_camera);
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            testCase.verifyEqual(plan.unique_mask_count,34);
            testCase.verifyEqual(plan.event_count,3400);
            testCase.verifyEqual(dmd.slot_write_count,34);
            testCase.verifyEqual(numel(dmd.playlist),3400);
            testCase.verifyEqual(configuration.physical_upload_count,34);
            testCase.verifyEqual(configuration.playlist_entry_count,3400);
        end

        function dryRunCapacityCheckDoesNotUploadAnything(testCase)
            [targets,protocol]=fixture(34,repmat((1:34)',121,1),zeros(4114,1));
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=simulated_dmd(targets.reference_camera);
            testCase.verifyError(@()adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",true), ...
                "adaptive_optopatch:FlutPlaylistTooLong");
            testCase.verifyEqual(dmd.slot_write_count,0);
            testCase.verifyEqual(dmd.reserved_slot_count,0);
        end

        function tenMasksProgramTenUploadsAndOneThousandPlaylistEntries(testCase)
            [targets,protocol]=fixture(10,repmat((1:10)',100,1),zeros(1000,1));
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=simulated_dmd(targets.reference_camera);
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);

            testCase.verifyEqual(plan.unique_mask_count,10);
            testCase.verifyEqual(plan.event_count,1000);
            testCase.verifyEqual(plan.event_slot_indices,repmat((1:10)',100,1));
            testCase.verifyEqual(plan.programmed_playlist_slots, ...
                plan.event_slot_indices);
            testCase.verifyEqual(dmd.reserved_slot_count,10);
            testCase.verifyEqual(dmd.slot_write_count,10);
            testCase.verifyEqual(dmd.playlist,plan.event_slot_indices);
            testCase.verifyEqual(dmd.playlist_mode,"slave");
            testCase.verifyEqual(configuration.execution_mode,"flut_playlist");
            testCase.verifyEqual(configuration.physical_upload_count,10);
        end

        function tenThousandEventPlaylistExceedsLuminosTransferLimit(testCase)
            [targets,protocol]=fixture(10,repmat((1:10)',1000,1),zeros(10000,1));
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=simulated_dmd(targets.reference_camera);
            dmd.flut_max_entries=12000;
            testCase.verifyEqual(plan.unique_mask_count,10);
            testCase.verifyError(@()adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false), ...
                "adaptive_optopatch:FlutPlaylistTooLong");
            testCase.verifyEqual(dmd.slot_write_count,0);
        end

        function deduplicationUsesActualPixelsNotTargetIdentity(testCase)
            [targets,protocol]=fixture(2,[1;2;1;2],zeros(4,1));
            targets.canonical_roi_masks(:,:,2)=targets.canonical_roi_masks(:,:,1);
            targets.dmd_camera_masks(:,:,2)=targets.canonical_roi_masks(:,:,1);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            testCase.verifyEqual(plan.unique_mask_count,1);
            testCase.verifyEqual(plan.event_slot_indices,ones(4,1));
        end

        function adjustedMasksRemainDistinct(testCase)
            [targets,protocol]=fixture(1,[1;1],[0;1]);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            testCase.verifyEqual(plan.unique_mask_count,2);
            testCase.verifyEqual(plan.event_slot_indices,[1;2]);
            testCase.verifyNotEqual(plan.unique_camera_masks(:,:,1), ...
                plan.unique_camera_masks(:,:,2));
        end

        function flutCapacityOverflowIsAHardwareError(testCase)
            [targets,protocol]=fixture(1,ones(6,1),zeros(6,1));
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=simulated_dmd(targets.reference_camera);
            dmd.flut_max_entries=5;
            testCase.verifyError(@()adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false), ...
                "adaptive_optopatch:FlutPlaylistTooLong");
            testCase.verifyEqual(dmd.slot_write_count,0);
        end

        function nonFlutDeviceUsesExplicitPhysicalStackFallback(testCase)
            [targets,protocol]=fixture(2,[1;2;1;2],[0;0;0;0]);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=simulated_dmd(targets.reference_camera);
            dmd.supports_flut=false;
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            testCase.verifyEqual(configuration.execution_mode,"physical_event_stack");
            testCase.verifyEqual(configuration.physical_upload_count,4);
            testCase.verifyEqual(dmd.StackWriteCount,1);
            testCase.verifyEqual(size(dmd.pattern_stack,3),4);
            testCase.verifyEqual(dmd.pattern_stack(:,:,1),dmd.pattern_stack(:,:,3));
            testCase.verifyEqual(dmd.pattern_stack(:,:,2),dmd.pattern_stack(:,:,4));
        end

        function wrapDiagnosticProgramsThreeEntriesForEightTriggers(testCase)
            [targets,protocol]=fixture(3,[1;2;3;1;2;3;1;2],zeros(8,1));
            protocol.dmd_diagnostic=wrap_diagnostic();
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=simulated_dmd(targets.reference_camera);
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);

            testCase.verifyEqual(dmd.reserved_slot_count,3);
            testCase.verifyEqual(dmd.slot_write_count,3);
            testCase.verifyEqual(dmd.playlist,[1;2;3]);
            testCase.verifyEqual(numel(plan.dmd_trigger_s),8);
            testCase.verifyEqual(plan.dmd_diagnostic.expected_wrapped_slots, ...
                [1;2;3;1;2;3;1;2]);
            testCase.verifyEqual(plan.dmd_diagnostic.slot_target_cell_ids, ...
                ["cell_001";"cell_002";"cell_003"]);
            testCase.verifyEqual(configuration.playlist_entry_count,3);
            testCase.verifyEqual(configuration.execution_mode,"flut_playlist");
            testCase.verifyTrue(configuration.supports_flut);
            testCase.verifyEqual(configuration.flut_max_entries,4096);
            testCase.verifyEqual(plan.dmd_diagnostic.event_onset_s, ...
                protocol.events.onset_s);
            testCase.verifyEqual(plan.dmd_diagnostic.pulse_duration_s,0.01);
            testCase.verifyEqual(plan.dmd_diagnostic.command_voltage_v,1);

            globalProps=struct("rate",200000,"total_time",1, ...
                "clock_source","Internal Dev1","trigger_source","Dev1/PFI9", ...
                "daq_master",true);
            wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
                "ao_camera_triggered",[],"do_camera_triggered",[]);
            [~,configured,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,protocol, ...
                adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);
            trigger=find(string({configured.do.name})== ...
                "AdaptiveOptopatch DMD trigger",1);
            testCase.verifyEqual(numel(configured.do(trigger).params{1}),8);
            testCase.verifyEqual(summary.dmd_sequence.programmed_playlist_slots, ...
                [1;2;3]);
        end

        function wrapDiagnosticRejectsNonFlutHardware(testCase)
            [targets,protocol]=fixture(3,[1;2;3;1;2;3;1;2],zeros(8,1));
            protocol.dmd_diagnostic=wrap_diagnostic();
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=simulated_dmd(targets.reference_camera);
            dmd.supports_flut=false;
            testCase.verifyError(@()adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false), ...
                "adaptive_optopatch:DmdFlutDiagnosticRequiresFlut");
            testCase.verifyEqual(dmd.StackWriteCount,0);
        end

        function diagnosticScriptSavesResolvableExplicitProvenance(testCase)
            protocol_output_directory=tempname;
            mkdir(protocol_output_directory);
            cleanup=onCleanup(@()remove_directory(protocol_output_directory));
            run(fullfile(testCase.ProtocolPath,"create_dmd_flut_wrap_test.m"));

            diagnostic=protocol.acquisitions.dmd_diagnostic;
            testCase.verifyEqual(diagnostic.diagnostic_name,"dmd_flut_wrap");
            testCase.verifyEqual(diagnostic.base_playlist_slots,[1;2;3]);
            testCase.verifyEqual(diagnostic.base_playlist_length,3);
            testCase.verifyEqual(diagnostic.dmd_trigger_count,8);
            testCase.verifyEqual(diagnostic.expected_wrapped_slots, ...
                [1;2;3;1;2;3;1;2]);

            [fov,targets,gui]=diagnostic_fov();
            resolved=adaptive_optopatch.resolve_protocol(protocol,fov,targets,gui, ...
                "Mode","1p_dmd");
            testCase.verifyNumElements(resolved,1);
            testCase.verifyEqual(resolved{1}.dmd_diagnostic,diagnostic);
            plan=adaptive_optopatch.build_dmd_sequence_plan(resolved{1},targets);
            testCase.verifyEqual(plan.programmed_playlist_slots,[1;2;3]);
            testCase.verifyEqual(numel(plan.dmd_trigger_s),8);
        end

        % ---------------------------------------------------------------
        % The hardware-timed advance train the playlist is stepped by
        % ---------------------------------------------------------------
        function buildsHardwareTimedDmdSequenceAtPulseOffsets(testCase)
            [fovState,~]=AoFixtures.fovState();
            for k=1:3
                fovState=adaptive_optopatch.update_cell_calibration(fovState, ...
                    compose("cell_%03d",k),"CommandVoltageV",0.5+0.2*k);
            end
            fovState.blue_mask_adjustment_pixels=0;
            protocol=adaptive_optopatch.generate_round_robin_protocol( ...
                "PulsesPerCell",2,"RandomSeed",7);
            targets=adaptive_optopatch.build_target_bundle(fovState.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
            manifest=adaptive_optopatch.build_manifest(fovState.reference,targets, ...
                protocol,"Mode","1p_dmd","FovState",fovState, ...
                "GuiDefaults",AoFixtures.guiDefaults());
            resolved=manifest.trials.pulse_schedule{1};
            plan=adaptive_optopatch.build_dmd_sequence_plan(resolved,targets);
            testCase.verifyEqual(plan.pattern_activation_s, ...
                [0;resolved.events.offset_s(1:end-1)]);
            testCase.verifyEqual(plan.advance_onset_s, ...
                resolved.events.offset_s(1:end-1));
            testCase.verifyTrue(plan.no_artificial_settle_interval);
            for k=1:height(resolved.events)
                index=resolved.events.target_index(k);
                slot=plan.event_slot_indices(k);
                testCase.verifyEqual(plan.unique_camera_masks(:,:,slot), ...
                    targets.blue_camera_masks(:,:,index));
            end
            sim=adaptive_optopatch.testing.make_simulated_luminos();
            dmd=sim.getDevice("DMD","name","DMD_Blue");
            config=adaptive_optopatch.prepare_luminos_dmd_sequence(dmd,plan, ...
                "DryRun",false);
            testCase.verifyTrue(config.loaded);
            testCase.verifyEqual(dmd.playlist_mode,"slave");
            testCase.verifyEqual(dmd.slot_write_count,plan.unique_mask_count);
            testCase.verifyEqual(dmd.playlist,plan.event_slot_indices);
            globalProps=struct("rate",200000,"total_time",1, ...
                "clock_source","Internal Dev1","trigger_source","Dev1/PFI9", ...
                "daq_master",true);
            wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
                "ao_camera_triggered",[],"do_camera_triggered",[]);
            [~,configured,summary]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,resolved,adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);
            trigger=find(string({configured.do.name})=="AdaptiveOptopatch DMD trigger",1);
            testCase.verifyNotEmpty(trigger);
            testCase.verifyEqual(configured.do(trigger).params{1}, ...
                [0;resolved.events.offset_s(1:end-1)]);
            testCase.verifyEqual(summary.dmd_sequence.dmd_trigger_s, ...
                [0;resolved.events.offset_s(1:end-1)]);
            testCase.verifyEqual(summary.dmd_sequence.trigger_associated_pulse_id, ...
                resolved.events.pulse_id);
            testCase.verifyEqual(summary.dmd_sequence.stack_pattern_number, ...
                plan.event_slot_indices);
            testCase.verifyLessThan(plan.initialization_trigger_s, ...
                resolved.events.onset_s(1));
            triggerWaveform=adaptive_optopatch.luminos_event_waveform( ...
                [0 1/globalProps.rate],configured.do(trigger).params{:});
            testCase.verifyEqual(triggerWaveform(1),1);
            noPreDelay=resolved;
            shift=noPreDelay.events.onset_s(1);
            noPreDelay.events.onset_s=noPreDelay.events.onset_s-shift;
            noPreDelay.acquisition_duration_s=noPreDelay.acquisition_duration_s-shift;
            noPrePlan=adaptive_optopatch.build_dmd_sequence_plan(noPreDelay,targets);
            testCase.verifyError(@()adaptive_optopatch.build_luminos_1p_waveform_config( ...
                globalProps,wfm,noPreDelay,adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",noPrePlan), ...
                "adaptive_optopatch:DmdInitializationNotDark");
        end
    end
end

function [targets,protocol]=fixture(nTargets,targetSequence,adjustments)
imageSize=[24 32]; masks=false([imageSize,nTargets]);
for k=1:nTargets
    row=2+mod(k-1,10)*2; column=2+floor((k-1)/10)*2;
    masks(row:row+1,column:column+1,k)=true;
end
ids=compose("cell_%03d",(1:nTargets)');
targetRecords=repmat(struct("cell_id",""),nTargets,1);
for k=1:nTargets, targetRecords(k).cell_id=ids(k); end
camera=struct("name","Orca Fusion","image_size",imageSize, ...
    "origin_xy",[0 0],"bin",1,"roi",[0 imageSize(2) 0 imageSize(1)]);
targets=struct("blank_dmd_mask",false(imageSize), ...
    "canonical_roi_masks",masks,"dmd_camera_masks",masks, ...
    "blue_camera_masks",masks,"targets",targetRecords, ...
    "reference_camera",camera);

targetSequence=double(targetSequence(:)); n=numel(targetSequence);
pulse_id=(1:n)'; condition_id=repmat("test",n,1);
stimulation_source=repmat("1p_dmd",n,1);
target_cell_id=ids(targetSequence); target_index=targetSequence;
onset_s=0.1+(0:n-1)'*0.02; duration_s=0.01*ones(n,1);
is_null=false(n,1); command_voltage_v=ones(n,1);
blue_mask_adjustment_pixels=double(adjustments(:));
dmd_pattern_index=targetSequence;
command_voltage_source=repmat("event",n,1);
pulse_duration_source=repmat("event",n,1);
blue_mask_adjustment_source=repmat("event",n,1);
events=table(pulse_id,condition_id,stimulation_source,target_cell_id,target_index,onset_s, ...
    duration_s,is_null,command_voltage_v,blue_mask_adjustment_pixels, ...
    dmd_pattern_index,command_voltage_source,pulse_duration_source, ...
    blue_mask_adjustment_source);
parameters=struct("orange_expansion_pixels",2,"spiral_radius_um",2, ...
    "spiral_density_points_per_volt",10);
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","resolved_acquisition","protocol_id","flut_test", ...
    "protocol_type","test","source_protocol_id","flut_test", ...
    "acquisition_id","test","target_policy","multi_target_continuous", ...
    "event_order","ordered","random_seed",1,"events",events, ...
    "parameters",parameters,"parameter_sources",struct, ...
    "acquisition_duration_s",max(onset_s+duration_s)+0.1);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function dmd=simulated_dmd(camera)
dmd=adaptive_optopatch.testing.SimulatedLuminosDevice("DMD","DMD_Blue");
dmd.Dimensions=camera.image_size([2 1]);
dmd.refimage=struct("img",zeros(camera.image_size,"uint16"),"bin",1, ...
    "ref2d",struct("ImageSize",camera.image_size, ...
    "XWorldLimits",[0 camera.image_size(2)], ...
    "YWorldLimits",[0 camera.image_size(1)]));
adaptive_optopatch.testing.calibrate_simulated_dmd(dmd,camera);
end

function value=wrap_diagnostic()
value=struct("diagnostic_name","dmd_flut_wrap", ...
    "base_playlist_slots",[1;2;3],"base_playlist_length",3, ...
    "dmd_trigger_count",8, ...
    "expected_wrapped_slots",[1;2;3;1;2;3;1;2]);
end

function [fov,targets,gui]=diagnostic_fov()
image=zeros(30,45); masks=false(30,45,3);
masks(3:7,3:7,1)=true;
masks(12:16,20:24,2)=true;
masks(21:25,36:40,3)=true;
polygons={[3 3;7 3;7 7;3 7], ...
    [20 12;24 12;24 16;20 16], ...
    [36 21;40 21;40 25;36 25]};
metadata=struct("rig_name","test", ...
    "voltage_camera",struct("name","Camera 1","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","flut_wrap_test","CellIds", ...
    ["cell_001";"cell_002";"cell_003"],"RoiPolygons",polygons);
fov=adaptive_optopatch.create_fov_state(reference,polygons);
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1,"BlueMaskAdjustmentPixels",0);
gui=struct("command_voltage_v",0.2,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function remove_directory(path)
if isfolder(path), rmdir(path,"s"); end
end
