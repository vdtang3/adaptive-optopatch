classdef TestDmdStaticTargetExecutionState < matlab.unittest.TestCase
    % What the device was actually playing when a static 1P target was
    % programmed, as distinct from what MATLAB's Target said.
    %
    % The question behind these tests: a single-cell ramp showed broad
    % off-target illumination while every archived AO artifact - camera
    % mask, cropped-FOV remapping, transform matrices, Blue DMD Target -
    % was correct, and the run had begun with a failed DMD blank. Could a
    % stale FLUT/slave playback state have survived into the static write?

    properties
        OutputRoot string
    end

    methods (TestMethodSetup)
        function makeOutputRoot(testCase)
            testCase.OutputRoot=string(tempname);
            mkdir(testCase.OutputRoot);
            testCase.addTeardown(@()rmdir(testCase.OutputRoot,"s"));
        end
    end

    methods (Test)
        % --- A: a stale FLUT/slave sequence before a static target --------

        function flutSlaveStateIsReplacedByAStaticMasterSequence(testCase)
            [app,targets,row]=static_fixture(testCase);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            load_flut_playlist(dmd);

            before=adaptive_optopatch.read_dmd_execution_state(dmd);
            testCase.verifyEqual(before.projection_mode_name,"slave");
            testCase.verifyEqual(before.sequence_pictures,3);
            testCase.verifyEqual(before.verdict,"contradicts_static");

            result=adaptive_optopatch.prepare_luminos_target(app,targets,row, ...
                "DryRun",false,"WriteDmdImmediately",true);

            after=result.dmd_state_after_programming;
            testCase.verifyEqual(after.projection_mode_name,"master");
            testCase.verifyEqual(after.sequence_pictures,1);
            testCase.verifyTrue(after.static_single_pattern_confirmed);
            testCase.verifyFalse(after.contradicts_static_mode);
            testCase.verifyEqual(after.verdict,"confirmed_static");
        end

        % --- B: a stale pattern before a static target --------------------

        function stalePatternIsReplacedByTheProgrammedAoMask(testCase)
            [app,targets,row]=static_fixture(testCase);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            canvas=adaptive_optopatch.dmd_pattern_canvas_size(dmd);
            dmd.Target=true(canvas);

            result=adaptive_optopatch.prepare_luminos_target(app,targets,row, ...
                "DryRun",false,"WriteDmdImmediately",true);

            testCase.verifyTrue(any(dmd.Target,"all"), ...
                "The programmed target is empty, so this proves nothing.");
            testCase.verifyFalse(all(dmd.Target(:)), ...
                "The stale field-wide pattern survived the static write.");
            testCase.verifyEqual(logical(dmd.Target), ...
                logical(result.dmd_reference_mask));
            testCase.verifyLessThan( ...
                result.dmd_device_mask_summary.mirrors_on_fraction,0.5);
        end

        % --- C: a failed blank, then a static target ----------------------

        function aFailedBlankLeavesStaleStateThatStaticProgrammingClears(testCase)
            [app,targets,row]=static_fixture(testCase);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            load_flut_playlist(dmd);

            % The blanking failure that started the real run. ALP_DMD
            % clears its own bookkeeping and then throws before
            % Project_Image, so Target updates and the device keeps playing.
            dmd.FailOnStaticWrite=true;
            report=adaptive_optopatch.neutralize_all_stimulation(app, ...
                "Modality","1p_dmd");
            testCase.verifyFalse(report.all_succeeded);
            testCase.verifyFalse(any(dmd.Target,"all"), ...
                "Target should already read as blank after the failed write.");
            stale=adaptive_optopatch.read_dmd_execution_state(dmd);
            testCase.verifyEqual(stale.projection_mode_name,"slave", ...
                "A failed blank must not be able to fix the playback mode.");
            testCase.verifyEqual(stale.verdict,"contradicts_static");

            % The acquisition's own static write is what recovers it.
            dmd.FailOnStaticWrite=false;
            result=adaptive_optopatch.prepare_luminos_target(app,targets,row, ...
                "DryRun",false,"WriteDmdImmediately",true);
            testCase.verifyEqual( ...
                result.dmd_state_after_programming.verdict,"confirmed_static");
        end

        % --- D: the invariant fires when the reset does not happen --------

        function staticProgrammingIsRefusedIfTheDeviceStaysInSlaveMode(testCase)
            [app,targets,row]=static_fixture(testCase);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            load_flut_playlist(dmd);
            % A device whose static write does not restore master mode. The
            % real ALP_DMD::Project always does; this is what would happen
            % if it stopped.
            dmd.StaticWriteSkipsModeReset=true;

            testCase.verifyError(@() ...
                adaptive_optopatch.prepare_luminos_target(app,targets,row, ...
                    "DryRun",false,"WriteDmdImmediately",true), ...
                "adaptive_optopatch:DmdNotInStaticMode");
        end

        function aMultiPictureSequenceAlsoContradictsStaticMode(testCase)
            dmd=adaptive_optopatch.testing.SimulatedLuminosDevice("DMD","DMD_Blue");
            dmd.Dimensions=[1024 768];
            dmd.projection_mode_code=2301;
            dmd.sequence_pictures=7;
            state=adaptive_optopatch.read_dmd_execution_state(dmd);
            testCase.verifyTrue(state.contradicts_static_mode);
            testCase.verifyFalse(state.static_single_pattern_confirmed);
            testCase.verifyEqual(state.verdict,"contradicts_static");
        end

        % --- E: the FLUT multi-target path is unchanged --------------------

        function flutMultiTargetProgrammingKeepsItsCountsAndSlaveMode(testCase)
            [targets,protocol]=flut_fixture(3,repmat((1:3)',4,1));
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
            dmd=flut_dmd(targets.reference_camera);

            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);

            testCase.verifyEqual(configuration.execution_mode,"flut_playlist");
            testCase.verifyEqual(configuration.physical_upload_count,3);
            testCase.verifyEqual(configuration.playlist_entry_count,12);
            testCase.verifyEqual(dmd.slot_write_count,3);
            testCase.verifyEqual(numel(dmd.playlist),12);
            testCase.verifyEqual(dmd.playlist_mode,"slave");
            % The FLUT path is deliberately left in slave mode with its
            % picture pool loaded: the static invariant belongs to the
            % static path and must not be applied here.
            state=adaptive_optopatch.read_dmd_execution_state(dmd);
            testCase.verifyEqual(state.projection_mode_name,"slave");
            testCase.verifyEqual(state.sequence_pictures,3);
        end

        % --- Readback limits and the inversion the readback does expose ----

        function anUnprovableReadbackIsArchivedWithoutFailing(testCase)
            % A device with no Get_State at all: recorded as unproven, never
            % treated as contradictory.
            stub=struct("Dimensions",[1024 768], ...
                "Target",false(768,1024),"invert_output",false);
            state=adaptive_optopatch.read_dmd_execution_state(stub);
            testCase.verifyFalse(state.readback_available);
            testCase.verifyNotEmpty(state.readback_error);
            testCase.verifyEqual(state.verdict,"unproven");
            testCase.verifyFalse(state.contradicts_static_mode);
            testCase.verifyFalse(state.static_single_pattern_confirmed);
            testCase.verifyEqual(state.canvas_size,[768 1024]);
        end

        function unansweredInquiriesReadAsUnavailableRatherThanZero(testCase)
            dmd=adaptive_optopatch.testing.SimulatedLuminosDevice("DMD","DMD_Blue");
            dmd.Dimensions=[1024 768];
            % Nothing written yet, so the simulated controller answers -1
            % for every projection inquiry, as a real one does.
            state=adaptive_optopatch.read_dmd_execution_state(dmd);
            testCase.verifyTrue(isnan(state.projection_mode));
            testCase.verifyEqual(state.projection_mode_name,"unavailable");
            testCase.verifyEqual(state.verdict,"unproven");
        end

        function invertedOutputShowsAsAFieldWideMirrorPattern(testCase)
            % The one configuration that reproduces the reported symptom
            % while leaving every other archived artifact correct:
            % invert_output is applied only in DMD.Device_Pattern, so Target
            % stays localized and the mirrors go field-wide.
            [app,targets,row]=static_fixture(testCase);
            dmd=app.getDevice("DMD","name","DMD_Blue");
            dmd.invert_output=true;

            result=adaptive_optopatch.prepare_luminos_target(app,targets,row, ...
                "DryRun",false,"WriteDmdImmediately",true);

            summary=result.dmd_device_mask_summary;
            testCase.verifyEqual(summary.device_pattern_source,"Device_Pattern");
            testCase.verifyLessThan(summary.target_on_fraction,0.5, ...
                "Target itself should stay localized.");
            testCase.verifyGreaterThan(summary.mirrors_on_fraction,0.5, ...
                "The mirrors were not field-wide, so the symptom is unmodelled.");
            testCase.verifyEqual(summary.target_on_pixels+summary.mirrors_on_pixels, ...
                prod(summary.size));
            testCase.verifyEqual(result.dmd_state_after_programming.invert_output,1);
            % Mode is still correct: inversion is not a mode fault, which is
            % exactly why the mode invariant cannot catch it.
            testCase.verifyEqual( ...
                result.dmd_state_after_programming.verdict,"confirmed_static");
        end

        function aCorrectRigArchivesMatchingTargetAndMirrorCounts(testCase)
            [app,targets,row]=static_fixture(testCase);
            result=adaptive_optopatch.prepare_luminos_target(app,targets,row, ...
                "DryRun",false,"WriteDmdImmediately",true);
            summary=result.dmd_device_mask_summary;
            testCase.verifyTrue(summary.available);
            testCase.verifyEqual(summary.target_on_pixels,summary.mirrors_on_pixels);
            testCase.verifyEqual(result.dmd_state_after_programming.invert_output,0);
            testCase.verifyGreaterThan(summary.target_on_pixels,0);
        end

        % --- The blank path records the same evidence ---------------------

        function aNullTrialBlankAlsoArchivesItsExecutionState(testCase)
            [app,targets,row]=static_fixture(testCase);
            row.is_null=true;
            result=adaptive_optopatch.prepare_luminos_target(app,targets,row, ...
                "DryRun",false,"WriteDmdImmediately",true);
            testCase.verifyEqual(result.action,"blank");
            testCase.verifyEqual( ...
                result.dmd_state_after_programming.verdict,"confirmed_static");
            testCase.verifyEqual(result.dmd_device_mask_summary.mirrors_on_pixels,0);
        end

        % --- The whole 1P run still archives the state --------------------

        function aFullOnePhotonRunArchivesTheStaticExecutionState(testCase)
            [manifest,targets]=one_photon_manifest();
            app=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",testCase.OutputRoot, ...
                "CameraRoi",targets.reference_camera.roi);
            run=adaptive_optopatch.run_1p_manifest( ...
                manifest,targets,app,"ConfirmLiveOutput",true, ...
                "ShutterSettleTimeS",0,"OutputDirectory",testCase.OutputRoot);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            configuration=run.trials.target_configuration{1};
            testCase.verifyTrue(isfield(configuration,"dmd_state_after_programming"));
            testCase.verifyEqual( ...
                configuration.dmd_state_after_programming.verdict,"confirmed_static");
            testCase.verifyTrue( ...
                configuration.dmd_device_mask_summary.available);
        end
    end
end

function [app,targets,row]=static_fixture(testCase)
% A single-cell 1P fixture on the simulated rig, matching the shape
% run_1p_manifest takes through prepare_luminos_target.
[manifest,targets]=one_photon_manifest();
app=adaptive_optopatch.testing.make_simulated_luminos( ...
    "SimulationOutputRoot",testCase.OutputRoot, ...
    "CameraRoi",targets.reference_camera.roi);
row=manifest.trials(1,:);
end

function load_flut_playlist(dmd)
% Put the device into a genuine FLUT/slave playback state through the same
% device API prepare_luminos_dmd_sequence uses.
canvas=adaptive_optopatch.dmd_pattern_canvas_size(dmd);
dmd.Reserve_Slots(3);
for slot=1:3
    mask=false(canvas);
    mask(1:4,(slot-1)*4+1:slot*4)=true;
    dmd.Write_Pattern_To_Slot(slot,mask);
end
dmd.Set_Playlist([1;2;3;1;2;3],'slave');
end

function [manifest,targets]=one_photon_manifest()
image=zeros(30,30); masks=false(30,30);
masks(11:20,11:20)=true;
polygons={[11 11;20 11;20 20;11 20]};
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","static_state_test","CellIds","cell_001","RoiPolygons",polygons);
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

function [targets,protocol]=flut_fixture(nTargets,targetSequence)
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
blue_mask_adjustment_pixels=zeros(n,1);
dmd_pattern_index=targetSequence;
command_voltage_source=repmat("event",n,1);
pulse_duration_source=repmat("event",n,1);
blue_mask_adjustment_source=repmat("event",n,1);
events=table(pulse_id,condition_id,stimulation_source,target_cell_id, ...
    target_index,onset_s,duration_s,is_null,command_voltage_v, ...
    blue_mask_adjustment_pixels,dmd_pattern_index,command_voltage_source, ...
    pulse_duration_source,blue_mask_adjustment_source);
parameters=struct("orange_expansion_pixels",2,"spiral_radius_um",2, ...
    "spiral_density_points_per_volt",10);
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","resolved_acquisition","protocol_id","static_state_flut", ...
    "protocol_type","test","source_protocol_id","static_state_flut", ...
    "acquisition_id","test","target_policy","multi_target_continuous", ...
    "event_order","ordered","random_seed",1,"events",events, ...
    "parameters",parameters,"parameter_sources",struct, ...
    "acquisition_duration_s",max(onset_s+duration_s)+0.1);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function dmd=flut_dmd(camera)
dmd=adaptive_optopatch.testing.SimulatedLuminosDevice("DMD","DMD_Blue");
dmd.Dimensions=camera.image_size([2 1]);
dmd.refimage=struct("img",zeros(camera.image_size,"uint16"),"bin",1, ...
    "ref2d",struct("ImageSize",camera.image_size, ...
    "XWorldLimits",[0 camera.image_size(2)], ...
    "YWorldLimits",[0 camera.image_size(1)]));
adaptive_optopatch.testing.calibrate_simulated_dmd(dmd,camera);
end
