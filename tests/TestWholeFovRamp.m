classdef TestWholeFovRamp < matlab.unittest.TestCase
    methods (Test)
        function generatorAndFrozenSelection(t)
            [fov,targets,definition]=fixture();
            t.verifyEqual(definition.schema_version,"4.0.0");
            scalar=adaptive_optopatch.generate_whole_fov_ramp_protocol(.5);
            t.verifyEqual(height(scalar.acquisitions.events),10);
            t.verifyFalse(adaptive_optopatch.validate_protocol_for_mode(definition,"2p_spiral").passed);
            t.verifyNumElements(definition.acquisitions,1);
            t.verifyFalse(isfield(definition,"simultaneous_target_cell_ids"));
            t.verifyEqual(definition.acquisitions.events.command_voltage_v,[.5;.5;1;1]);
            fov.cells(2).stimulation_enabled=false;
            resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,AoFixtures.guiDefaults());
            t.verifyNumElements(resolved,1); p=resolved{1};
            t.verifyEqual(p.simultaneous_target_cell_ids,["cell_001";"cell_003"]);
            t.verifyEqual(p.simultaneous_target_indices,[1;3]);
            fov.cells(1).stimulation_enabled=false;
            t.verifyEqual(p.simultaneous_target_cell_ids,["cell_001";"cell_003"]);
            t.verifyEqual(p.events.command_voltage_v,[.5;.5;1;1]);
            t.verifyEqual(p.events.target_index,zeros(4,1));
            t.verifyEqual(p.events.target_cell_id,repmat("multiple",4,1));
            single=adaptive_optopatch.resolve_protocol( ...
                adaptive_optopatch.generate_single_cell_ramp_protocol([.5 1]), ...
                fixture_fov(),targets,AoFixtures.guiDefaults());
            t.verifyNumElements(single,3);
        end
        function independentMorphologyAndPreview(t)
            [fov,targets,definition]=fixture(); fov.cells(2).stimulation_enabled=false;
            for adjustment=[-2 0 2]
                gui=AoFixtures.guiDefaults(); gui.blue_mask_adjustment_pixels=adjustment;
                result=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui); p=result{1};
                mask=adaptive_optopatch.build_simultaneous_blue_mask(p,targets);
                expected=false(size(mask));
                for idx=[1 3]
                    expected=expected | adaptive_optopatch.apply_blue_mask_adjustment( ...
                        targets.canonical_roi_masks(:,:,idx),adjustment);
                end
                t.verifyEqual(mask,expected);
                preview=adaptive_optopatch.build_target_preview(targets,"1p_dmd","ResolvedProtocols",result);
                t.verifyNumElements(preview.blue,1); t.verifyEqual(preview.blue.mask,mask);
                t.verifyFalse(any(mask & targets.canonical_roi_masks(:,:,2),"all"));
            end
        end
        function touchingMasksAreErodedSeparately(t)
            [fov,targets,definition]=fixture();
            fov.cells(3).stimulation_enabled=false;
            targets.canonical_roi_masks=false(70,90,3);
            targets.canonical_roi_masks(20:29,20:24,1)=true;
            targets.canonical_roi_masks(20:29,25:29,2)=true;
            gui=AoFixtures.guiDefaults(); gui.blue_mask_adjustment_pixels=-1;
            result=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui); p=result{1};
            combined=adaptive_optopatch.build_simultaneous_blue_mask(p,targets);
            merged=adaptive_optopatch.apply_blue_mask_adjustment( ...
                any(targets.canonical_roi_masks(:,:,1:2),3),-1);
            t.verifyNotEqual(combined,merged);
            t.verifyFalse(any(combined(:,24:25),"all"));
            bad=p; bad.simultaneous_target_indices=[2;1];
            t.verifyError(@()adaptive_optopatch.build_simultaneous_blue_mask(bad,targets), ...
                "adaptive_optopatch:InvalidSimultaneousTargets");
            bad=p; bad.parameters.blue_mask_adjustment_pixels=-20;
            t.verifyError(@()adaptive_optopatch.build_simultaneous_blue_mask(bad,targets), ...
                "adaptive_optopatch:EmptyBlueMaskAdjustment");
        end
        function invalidGroupsFail(t)
            [fov,targets,definition]=fixture();
            p=adaptive_optopatch.resolve_protocol(definition,fov,targets,AoFixtures.guiDefaults()); p=p{1};
            bad=targets; bad.canonical_roi_masks(:,:,2)=false;
            t.verifyError(@()adaptive_optopatch.build_simultaneous_blue_mask(p,bad), ...
                "adaptive_optopatch:EmptyBlueMask");
            bad=targets; bad.canonical_roi_masks=bad.canonical_roi_masks(:,:,1:2);
            t.verifyError(@()adaptive_optopatch.build_simultaneous_blue_mask(p,bad), ...
                "adaptive_optopatch:InvalidSimultaneousTargets");
            for k=1:3, fov.cells(k).stimulation_enabled=false; end
            t.verifyError(@()adaptive_optopatch.resolve_protocol(definition,fov,targets,AoFixtures.guiDefaults()), ...
                "adaptive_optopatch:NoAcceptedTargets");
            definition.acquisitions.events.stimulation_source(:)="2p_spiral";
            t.verifyFalse(adaptive_optopatch.validate_protocol(definition).passed);
        end
        function oneGuardedStaticWrite(t)
            [fov,targets,definition]=fixture();
            definition.parameters.blue_mask_adjustment_pixels=1;
            manifest=adaptive_optopatch.build_manifest(fov.reference,targets,definition, ...
                "FovState",fov,"GuiDefaults",AoFixtures.guiDefaults());
            p=manifest.trials.pulse_schedule{1};
            t.verifyEqual(p.parameters.blue_mask_adjustment_pixels,1);
            sim=adaptive_optopatch.testing.make_simulated_luminos("CameraRoi",targets.reference_camera.roi);
            dmd=sim.getDevice("DMD","name","DMD_Blue"); before=dmd.StaticWriteCount;
            config=adaptive_optopatch.prepare_luminos_target(sim,targets,manifest.trials, ...
                "SimultaneousProtocol",p,"DryRun",false,"WriteDmdImmediately",true);
            t.verifyEqual(dmd.StaticWriteCount-before,1);
            t.verifyEqual(dmd.sequence_pictures,1);
            t.verifyEqual(dmd.slot_write_count,0); t.verifyEmpty(dmd.playlist);
            t.verifyTrue(config.configured);
            t.verifyTrue(isfield(config,"owned_pattern_fingerprint"));
        end
        function simulatedStaticAcquisition(t)
            [fov,targets,definition]=fixture();
            manifest=adaptive_optopatch.build_manifest(fov.reference,targets,definition, ...
                "FovState",fov,"GuiDefaults",AoFixtures.guiDefaults());
            t.verifyEqual(height(manifest.trials),1); t.verifyEqual(manifest.trials.target_cell_id,"multiple");
            t.verifyTrue(adaptive_optopatch.preflight_trial(targets,manifest.trials).passed);
            dry=adaptive_optopatch.run_manifest(manifest,targets);
            t.verifyEqual(dry.trials.acquisition_status,"dry_run_complete");
            bad=targets; bad.canonical_roi_masks(:,:,2)=false;
            t.verifyFalse(adaptive_optopatch.preflight_trial(bad,manifest.trials).passed);
            frozen=manifest.trials.pulse_schedule{1};
            frozen.parameters.blue_mask_adjustment_pixels=-20;
            frozen.events.blue_mask_adjustment_pixels(:)=-20;
            badRow=manifest.trials; badRow.pulse_schedule={frozen};
            t.verifyFalse(adaptive_optopatch.preflight_trial(targets,badRow).passed);
            outputRoot=tempname; t.addTeardown(@()AoFixtures.removeFolder(outputRoot));
            mkdir(outputRoot); reference=fov.reference;
            save(fullfile(outputRoot,"reference_model.mat"),"reference");
            sim=adaptive_optopatch.testing.make_simulated_luminos("SimulationOutputRoot",outputRoot, ...
                "CameraRoi",targets.reference_camera.roi);
            run=adaptive_optopatch.run_1p_manifest(manifest,targets,sim, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0,"OutputDirectory",outputRoot);
            t.verifyEqual(run.trials.acquisition_status,"completed");
            t.verifyNumElements(sim.AcquisitionHistory,1);
            dmd=sim.getDevice("DMD","name","DMD_Blue");
            t.verifyEqual(dmd.slot_write_count,0); t.verifyEmpty(dmd.playlist);
            config=run.trials.target_configuration{1};
            t.verifyEqual(config.execution_mode,"static_simultaneous");
            t.verifyNumElements(config.simultaneous_target_cell_ids,3);
            t.verifyEqual(config.camera_mask,adaptive_optopatch.build_simultaneous_blue_mask( ...
                manifest.trials.pulse_schedule{1},targets));
            history=sim.AcquisitionHistory;
            analog=history.wfm_data.ao; blue=analog(string({analog.name})=="mod488");
            t.verifyEqual(blue.params{3},[.5;.5;1;1]);
            digital=history.wfm_data.do;
            trigger=digital(string({digital.name})=="AdaptiveOptopatch DMD trigger");
            t.verifyEqual(trigger.params{1},0);
            saved=load(fullfile(run.trials.experiment_directory,"output_data.mat"));
            t.verifyNumElements(saved.adaptive_optopatch_record.pulse_schedule.simultaneous_target_cell_ids,3);
            compiled=compile_wfm_data_to_samples(history.global_props,trigger);
            t.verifyEqual(compiled.samples,zeros(size(compiled.samples)));
            analogCompiled=compile_wfm_data_to_samples(history.global_props,blue);
            t.verifyEqual(unique(analogCompiled.samples),[0 .5 1]);
            p=manifest.trials.pulse_schedule{1};
            samples=round((p.events.onset_s+p.events.duration_s/2)*history.global_props.rate)+1;
            t.verifyEqual(reshape(analogCompiled.samples(samples),[],1),p.events.command_voltage_v);
        end
    end
end
function fov=fixture_fov()
fov=AoFixtures.fovState();
end
function [fov,targets,definition]=fixture()
fov=AoFixtures.fovState();
for k=1:3, fov.cells(k).selected_blue_voltage_v=.2*k; end
fov.reference.cells=fov.cells;
targets=adaptive_optopatch.build_target_bundle(fov.reference, ...
    "BlueMaskAdjustmentPixels",0,"SpiralRadiusUm",2,"ParkingClearancePixels",1);
definition=adaptive_optopatch.generate_whole_fov_ramp_protocol([.5 1], ...
    "RepeatsPerVoltage",2,"PreDelayMs",10,"PostDelayMs",10);
end
