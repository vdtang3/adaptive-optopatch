classdef TestBlanketCalibrationSweeps < matlab.unittest.TestCase
    %TESTBLANKETCALIBRATIONSWEEPS The two blanket calibration helper protocols.
    %   Both reuse the blanket state table, the wrapping FLUT playlist and
    %   the waveform builders, so these tests check what is new: the logical
    %   segments, the levels each one delivers, the union target mask, the
    %   playlist the sweeps actually program, and that a completed sweep
    %   opens in inspect_acquisition.
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
        % ---------------------------------------------------------------
        % Recruitment sweep
        % ---------------------------------------------------------------

        function oneSecondStepIsExactlyOneThousandCycles(testCase)
            [protocol,targets]=recruitment(testCase,[0.4;0.8]); %#ok<ASGLU>
            table=adaptive_optopatch.build_blanket_state_table(protocol,200000,0.001);
            first=table.states(table.states.segment_index==1,:);
            testCase.verifyEqual(height(first),2000);
            testCase.verifyEqual(max(first.cycle_in_segment),1000);
            testCase.verifyEqual(first.state_type,repmat(["blanket";"dark"],1000,1));
            testCase.verifyEqual(sum(first.duration_samples)/200000,1.0,"AbsTol",1e-12);
        end

        function stateDurationsAreFortyAndOneHundredSixtySamples(testCase)
            protocol=recruitment(testCase,[0.4;0.8]);
            table=adaptive_optopatch.build_blanket_state_table(protocol,200000,0.001);
            blanketStates=table.states(table.states.state_type=="blanket",:);
            darkStates=table.states(table.states.state_type=="dark",:);
            testCase.verifyEqual(unique(blanketStates.duration_samples),40);
            testCase.verifyEqual(unique(darkStates.duration_samples),160);
            testCase.verifyEqual(unique(darkStates.mod488_v),0);
            testCase.verifyEqual(unique(darkStates.mask_key),"blank");
        end

        function stepsChangeExactlyOnOneSecondBoundaries(testCase)
            levels=[0.4;0.8;1.2];
            [protocol,targets]=recruitment(testCase,levels);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            [props,wfm]=waveforms(protocol,plan);
            [mod488,~]=compiled_lines(props,wfm);
            start=plan.state_table.round_start_sample;
            testCase.verifyEqual(start,200000);              % the 1 s dark baseline
            testCase.verifyEqual(mod488(1:start),zeros(1,start));
            for k=1:numel(levels)
                window=start+(k-1)*200000+(1:200000);
                step=mod488(window);
                testCase.verifyEqual(unique(step),[0 levels(k)]);
                % The first sample of the step is already at its own level,
                % and the previous level ends exactly at the boundary.
                testCase.verifyEqual(step(1),levels(k));
                testCase.verifyEqual(sum(step>0),1000*40);
            end
        end

        function theSweepEndsAfterTheFinalStep(testCase)
            levels=[0.4;0.8;1.2];
            protocol=recruitment(testCase,levels);
            table=adaptive_optopatch.build_blanket_state_table(protocol,200000,0.001);
            testCase.verifyEqual(protocol.acquisition_duration_s,1+3*1.0, ...
                "AbsTol",1e-12);
            testCase.verifyEqual(table.final_sample, ...
                round(protocol.acquisition_duration_s*200000));
            % Nothing is held at the top level after the sweep.
            testCase.verifyEqual(table.states.level_v(end),levels(end));
            testCase.verifyEqual(table.states.start_sample(end)+ ...
                table.states.duration_samples(end),table.round_samples);
        end

        function logicalSegmentsAreVoltageStepsNotCycles(testCase)
            levels=[0.4;0.8;1.2];
            protocol=recruitment(testCase,levels);
            testCase.verifyEqual(height(protocol.events),3);
            testCase.verifyTrue(all(protocol.events.is_null));
            testCase.verifyEqual(protocol.events.duration_s,ones(3,1));
            segments=protocol.blanket_depolarization.sweep.segments;
            testCase.verifyEqual(double(segments.level_v),levels);
            testCase.verifyEqual(double(segments.pulse_id),protocol.events.pulse_id);
            table=adaptive_optopatch.build_blanket_state_table(protocol,200000,0.001);
            testCase.verifyEqual(height(table.states),6000);
            testCase.verifyEqual(numel(unique(table.states.logical_pulse_id)),3);
        end

        function everyStateDeliversItsStepLevelThroughTheBlanketMask(testCase)
            levels=[0.4;0.8;1.2];
            [protocol,targets]=recruitment(testCase,levels);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            [props,wfm]=waveforms(protocol,plan);
            [mod488,trigger]=compiled_lines(props,wfm);
            delivered=walk_wrapped_playlist(plan,mod488,trigger,0);
            testCase.verifyEqual(numel(delivered.slot),plan.expected_trigger_count);
            blanketSlot=find(plan.slot_mask_keys=="blanket");
            states=plan.state_table.states;
            for k=1:numel(delivered.slot)
                level=delivered.levels{k};
                if delivered.slot(k)==blanketSlot
                    testCase.verifyEqual(unique(level),states.level_v(k));
                else
                    testCase.verifyEqual(unique(level),0);
                end
            end
        end

        function theSweepProgramsTwoMasksAndATwoEntryPlaylist(testCase)
            [protocol,targets]=recruitment(testCase,[0.4;0.8;1.2]);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            dmd=simulated_dmd(targets.reference_camera);
            configuration=adaptive_optopatch.prepare_luminos_dmd_sequence( ...
                dmd,plan,"DryRun",false);
            % The masks never change between steps, so the ALP wraps two
            % entries for the whole sweep however long it is.
            testCase.verifyEqual(plan.programmed_playlist_length,2);
            testCase.verifyEqual(plan.playlist_repeats_per_round,3000);
            testCase.verifyEqual(plan.expected_trigger_count,6000);
            testCase.verifyEqual(dmd.playlist,plan.programmed_playlist_slots);
            testCase.verifyEqual(dmd.slot_write_count,2);
            testCase.verifyEqual(configuration.execution_mode,"flut_playlist");
            testCase.verifyTrue(all(dmd.slot_patterns{ ...
                plan.slot_mask_keys=="blanket"}(:)));
        end

        function levelListIsValidatedAndNeverExtrapolated(testCase)
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_recruitment_sweep_protocol( ...
                [0.8;0.4]),"adaptive_optopatch:InvalidBlanketSweepLevels");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_recruitment_sweep_protocol( ...
                [0.4;5.5]),"adaptive_optopatch:InvalidBlanketSweepLevels");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_recruitment_sweep_protocol( ...
                [0;0.4]),"adaptive_optopatch:InvalidBlanketSweepLevels");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_recruitment_sweep_protocol( ...
                zeros(0,1)),"adaptive_optopatch:InvalidAcquisitionScheduler");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_recruitment_sweep_protocol( ...
                [0.4;0.8],"StepDurationS",1.0005), ...
                "adaptive_optopatch:BlanketTimingNotWholeCycles");
            % Repeating a level is allowed; the sweep only must not go down.
            protocol=adaptive_optopatch.generate_blanket_recruitment_sweep_protocol([0.4;0.4;0.8]);
            testCase.verifyEqual(numel(protocol.acquisitions(1).scheduler.levels_v),3);
        end

        % ---------------------------------------------------------------
        % Population-target sweep
        % ---------------------------------------------------------------

        function theTargetMaskIsExactlyTheUnionOfTheCellMasks(testCase)
            [protocol,targets]=population(testCase,[1;2],3);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            slot=find(plan.slot_mask_keys=="population");
            testCase.verifyNumElements(slot,1);
            union=plan.unique_camera_masks(:,:,slot);
            expected=any(targets.canonical_roi_masks,3);
            testCase.verifyEqual(union,expected);
            sweep=protocol.blanket_depolarization.sweep;
            testCase.verifyEqual(sweep.population_cell_ids, ...
                string({targets.targets.cell_id})');
            testCase.verifyEqual(sweep.population_target_indices,(1:3)');
            % Not the whole field of view: only the blanket mask is all-on.
            testCase.verifyLessThan(nnz(union),numel(union));
            testCase.verifyTrue(all(plan.unique_camera_masks(:,:, ...
                plan.slot_mask_keys=="blanket"),"all"));
        end

        function targetPhasesUseTheUnionAndGapsKeepModulating(testCase)
            [protocol,targets]=population(testCase,[1;2],3);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            [props,wfm]=waveforms(protocol,plan);
            [mod488,trigger]=compiled_lines(props,wfm);
            delivered=walk_wrapped_playlist(plan,mod488,trigger,0);
            states=plan.state_table.states;
            keys=plan.slot_mask_keys(delivered.slot);
            guard=plan.state_table.target_onset_guard_samples;
            blanketV=protocol.blanket_depolarization.mod488_v;
            for k=1:numel(keys)
                level=delivered.levels{k};
                switch keys(k)
                    case "blanket"
                        testCase.verifyEqual(unique(level),blanketV);
                    case "blank"
                        testCase.verifyEqual(unique(level),0);
                    case "population"
                        testCase.verifyEqual(level(1:guard),zeros(1,guard));
                        testCase.verifyEqual(unique(level(guard+1:end)), ...
                            states.level_v(k));
                end
            end
            % Both phases keep running between epochs: every gap cycle is a
            % blanket state and a dark state, never continuous blanket.
            gap=states(states.segment=="gap",:);
            testCase.verifyEqual(unique(gap.state_type),["blanket";"dark"]);
            testCase.verifyEqual(unique(gap.mask_key),["blank";"blanket"]);
        end

        function epochTimingAndGuardMatchTheRoundRobin(testCase)
            [protocol,targets]=population(testCase,[1;2],3);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            table=plan.state_table;
            blanket=adaptive_optopatch.blanket_depolarization_spec(protocol);
            testCase.verifyEqual(table.blanket_samples,40);
            testCase.verifyEqual(table.target_samples,160);
            testCase.verifyEqual(table.target_onset_guard_samples,10);
            testCase.verifyEqual(blanket.target_onset_guard_s, ...
                adaptive_optopatch.blanket_depolarization_spec( ...
                    adaptive_optopatch.generate_blanket_round_robin_protocol( ...
                    "BlanketMod488V",1)).target_onset_guard_s);
            epoch=table.states(table.states.segment=="epoch" & ...
                table.states.segment_index==1,:);
            testCase.verifyEqual(height(epoch),40);
            testCase.verifyEqual(epoch.state_type,repmat(["blanket";"target"],20,1));
        end

        function logicalTrialsAreEpochsAndKeepTheirLevel(testCase)
            levels=[1;2;3]; repetitions=4;
            protocol=population(testCase,levels,3,repetitions);
            events=protocol.events;
            testCase.verifyEqual(height(events),numel(levels)*repetitions);
            testCase.verifyEqual(unique(events.target_cell_id),"population");
            testCase.verifyEqual(unique(events.duration_s),0.020);
            testCase.verifyEqual(events.command_voltage_v, ...
                repelem(levels,repetitions));
            segments=protocol.blanket_depolarization.sweep.segments;
            testCase.verifyEqual(double(segments.level_index), ...
                repelem((1:numel(levels))',repetitions));
            testCase.verifyEqual(double(segments.repetition_index), ...
                repmat((1:repetitions)',numel(levels),1));
            % The DMD states are an implementation detail of those trials.
            table=adaptive_optopatch.build_blanket_state_table(protocol,200000,0.001);
            testCase.verifyEqual(height(table.states), ...
                numel(levels)*repetitions*2*(20+80));
            testCase.verifyEqual(numel(unique(table.states.logical_pulse_id)), ...
                numel(levels)*repetitions);
        end

        function onePlaylistSlotCoversEveryLevel(testCase)
            [protocol,targets]=population(testCase,[1;2;3],3,4);
            plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
                "SampleRateHz",200000,"CameraFramePeriodS",0.001);
            % The masks are the same at every level, so the playlist is one
            % epoch plus its gap and the ALP wraps it for the whole sweep.
            testCase.verifyEqual(plan.programmed_playlist_length,200);
            testCase.verifyEqual(plan.playlist_repeats_per_round,12);
            testCase.verifyEqual(plan.unique_mask_count,3);
            testCase.verifyEqual(plan.expected_trigger_count,2400);
            [props,wfm]=waveforms(protocol,plan);
            [~,trigger]=compiled_lines(props,wfm);
            testCase.verifyEqual(numel(rising_edges(trigger)), ...
                plan.expected_trigger_count);
        end

        function aBlanketVoltageIsRequired(testCase)
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_population_target_sweep_protocol( ...
                [1;2]),"adaptive_optopatch:InvalidBlanketDepolarization");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_population_target_sweep_protocol( ...
                [2;1],"BlanketMod488V",1),"adaptive_optopatch:InvalidBlanketSweepLevels");
            testCase.verifyError(@()adaptive_optopatch.generate_blanket_population_target_sweep_protocol( ...
                [1;2],"BlanketMod488V",1,"InterEpochGapS",0.0805), ...
                "adaptive_optopatch:BlanketTimingNotWholeCycles");
        end

        % ---------------------------------------------------------------
        % Both sweeps run, archive and open
        % ---------------------------------------------------------------

        function bothSweepsRunInSimulationAndVerifyTheirAdvances(testCase)
            for schedule=["recruitment","population"]
                if schedule=="recruitment"
                    definition=adaptive_optopatch.generate_blanket_recruitment_sweep_protocol( ...
                        [0.4;0.8],"StepDurationS",0.1,"PreDarkS",0.1);
                    expected=2*0.1*1000*2;
                else
                    definition=adaptive_optopatch.generate_blanket_population_target_sweep_protocol( ...
                        [1;2],"BlanketMod488V",0.5,"RepetitionsPerLevel",2);
                    expected=2*2*2*(20+80);
                end
                [manifest,targets,app,runRoot]=run_fixture(testCase,definition,3);
                run=adaptive_optopatch.run_1p_manifest(manifest,targets,app, ...
                    "ConfirmLiveOutput",true,"ShutterSettleTimeS",0, ...
                    "BlankDmdAfterTrial",false,"OutputDirectory",runRoot);
                testCase.verifyEqual(run.trials.acquisition_status,"completed");
                record=load(fullfile(run.trials.experiment_directory(1), ...
                    "output_data.mat"),"adaptive_optopatch_record").adaptive_optopatch_record;
                testCase.verifyEqual(record.blanket_validity,"valid");
                testCase.verifyEqual( ...
                    record.dmd_advance_verification.expected_advance_count,expected);
                testCase.verifyEqual( ...
                    record.dmd_advance_verification.reported_advance_count,expected);
                if schedule=="recruitment"
                    expectedSchedule="recruitment_sweep";
                else
                    expectedSchedule="population_target_sweep";
                end
                testCase.verifyEqual( ...
                    record.waveform_summary.blanket_depolarization.schedule, ...
                    expectedSchedule);
            end
        end

        function aCompletedSweepOpensInInspectAcquisition(testCase)
            for schedule=["recruitment","population"]
                if schedule=="recruitment"
                    definition=adaptive_optopatch.generate_blanket_recruitment_sweep_protocol( ...
                        [0.4;0.8],"StepDurationS",0.1,"PreDarkS",0.1);
                else
                    definition=adaptive_optopatch.generate_blanket_population_target_sweep_protocol( ...
                        [1;2],"BlanketMod488V",0.5,"RepetitionsPerLevel",2);
                end
                folder=completed_acquisition(testCase,definition);
                inspection=inspect_acquisition(folder,"GenerateFigure",false);
                command=inspection.stimulation;
                testCase.verifyEqual(command.mode,"1p_dmd");
                testCase.verifyTrue(contains(command.source,"state_table"));
                testCase.verifyNotEmpty(command.time_s);
                testCase.verifyEqual(numel(command.time_s),numel(command.command_v));
                testCase.verifyTrue(issorted(command.time_s));
                if schedule=="recruitment"
                    % One bar per voltage step, at the level it delivered.
                    testCase.verifyEqual(command.blanket_schedule,"recruitment_sweep");
                    testCase.verifyEqual(height(command.events),2);
                    testCase.verifyEqual(double(command.events.command_voltage_v), ...
                        [0.4;0.8]);
                    testCase.verifyEqual(max(command.command_v),0.8);
                else
                    % One bar per target epoch, two at each of two levels.
                    testCase.verifyEqual(command.blanket_schedule, ...
                        "population_target_sweep");
                    testCase.verifyEqual(height(command.events),4);
                    testCase.verifyEqual(double(command.events.command_voltage_v), ...
                        [1;1;2;2]);
                    testCase.verifyEqual(max(command.command_v),2);
                end
            end
        end

        % ---------------------------------------------------------------
        % Feature-off parity
        % ---------------------------------------------------------------

        function anOrdinaryProtocolIsUnaffected(testCase)
            protocol=adaptive_optopatch.generate_connectivity_chunked_protocol( ...
                "TotalPulsesPerCell",4,"PulsesPerCellPerChunk",2);
            testCase.verifyFalse( ...
                adaptive_optopatch.blanket_depolarization_spec(protocol).enabled);
            testCase.verifyFalse(isfield(protocol,"blanket_depolarization"));
            ramp=adaptive_optopatch.generate_whole_fov_ramp_protocol([1 2]);
            testCase.verifyFalse( ...
                adaptive_optopatch.blanket_depolarization_spec(ramp).enabled);
        end
    end
end

% -----------------------------------------------------------------------
% Fixtures
% -----------------------------------------------------------------------

function [reference,fov,targets,gui]=sweep_fov(nCells)
image=zeros(40,8*nCells+8); masks=false([size(image),nCells]);
polygons=cell(1,nCells); ids=compose("cell_%03d",(1:nCells)');
for k=1:nCells
    column=4+(k-1)*8;
    masks(10:14,column:column+4,k)=true;
    polygons{k}=[column 10;column+4 10;column+4 14;column 14];
end
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","blanket_sweep_test","CellIds",ids,"RoiPolygons",polygons);
fov=adaptive_optopatch.create_fov_state(reference,polygons,"StimulationMode","1p_dmd");
for k=1:nCells
    fov=adaptive_optopatch.update_cell_calibration(fov,ids(k), ...
        "CommandVoltageV",2+0.25*k);
end
targets=adaptive_optopatch.build_target_bundle(fov.reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1,"BlueMaskAdjustmentPixels",0);
gui=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function [protocol,targets]=resolve_definition(definition,nCells)
[reference,fov,targets,gui]=sweep_fov(nCells);
manifest=adaptive_optopatch.build_manifest(reference,targets,definition, ...
    "Mode","1p_dmd","FovState",fov,"GuiDefaults",gui);
protocol=manifest.trials.pulse_schedule{1};
end

function [protocol,targets]=recruitment(~,levels)
definition=adaptive_optopatch.generate_blanket_recruitment_sweep_protocol(levels);
[protocol,targets]=resolve_definition(definition,3);
end

function [protocol,targets]=population(~,levels,nCells,repetitions)
if nargin<4, repetitions=3; end
definition=adaptive_optopatch.generate_blanket_population_target_sweep_protocol( ...
    levels,"BlanketMod488V",0.5,"RepetitionsPerLevel",repetitions);
[protocol,targets]=resolve_definition(definition,nCells);
end

function [manifest,targets,app,runRoot]=run_fixture(testCase,definition,nCells)
[reference,fov,targets,gui]=sweep_fov(nCells);
manifest=adaptive_optopatch.build_manifest(reference,targets,definition, ...
    "Mode","1p_dmd","FovState",fov,"GuiDefaults",gui);
% Its own directory per run: a shared one would resume the previous run's
% checkpoint and report that run's trial as this one's.
runRoot=fullfile(testCase.OutputRoot,"run_"+string(definition.protocol_type));
if ~isfolder(runRoot), mkdir(runRoot); end
app=adaptive_optopatch.testing.make_simulated_luminos( ...
    "SimulationOutputRoot",runRoot, ...
    "CameraRoi",targets.reference_camera.roi);
end

function folder=completed_acquisition(testCase,definition)
%COMPLETED_ACQUISITION An acquisition folder of the shape inspect_acquisition reads.
%   The archived record carries the real resolved protocol and the real
%   waveform summary - state table included - so what is inspected is what
%   the runner would have written.
[reference,fov,targets,gui]=sweep_fov(2);
manifest=adaptive_optopatch.build_manifest(reference,targets,definition, ...
    "Mode","1p_dmd","FovState",fov,"GuiDefaults",gui);
protocol=manifest.trials.pulse_schedule{1};
plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets, ...
    "SampleRateHz",200000,"CameraFramePeriodS",0.001);
[~,~,summary]=waveforms(protocol,plan);
summary.dmd_sequence=rmfield(plan,"unique_camera_masks");

root=fullfile(testCase.OutputRoot,"inspect_"+string(definition.protocol_type));
runDirectory=fullfile(root,"run"); folder=string(fullfile(root,"experiment"));
mkdir(runDirectory); mkdir(folder);
save(fullfile(runDirectory,"reference_model.mat"),"reference");

trial=table(1,"1p_dmd",'VariableNames',{'trial_id','stimulation_mode'});
adaptive_optopatch_record=struct("trial",trial,"pulse_schedule",protocol, ...
    "waveform_summary",summary,"run_directory",string(runDirectory), ...
    "reference_model_path",string(fullfile(runDirectory,"reference_model.mat"))); %#ok<NASGU>
imageSize=double(reference.image_size);
frames=round(protocol.acquisition_duration_s*1000);
camera=struct("deviceType","Camera","name","Orca Fusion","cam_id","S/N: 001125", ...
    "ROI",[0 imageSize(2) 0 imageSize(1)],"bin",1,"bit_depth",16, ...
    "frames_requested",frames,"frametrigger_source","DAQ", ...
    "daqtrig_period_ms",1,"exposuretime",1,"frame_rate",1000);
Device_Data={struct("rigName","Virtual_Upright"),camera, ...
    struct("deviceType","DMD","name","DMD_Blue")}; %#ok<NASGU>
save(fullfile(folder,"output_data.mat"),"Device_Data","adaptive_optopatch_record");
file=fopen(fullfile(folder,"frames1.bin"),"w","ieee-le");
for k=1:frames
    fwrite(file,permute(uint16(1000*ones(imageSize)),[2 1]),"uint16");
end
fclose(file);
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

function props=live_props()
props=struct("rate",200000,"total_time",1, ...
    "clock_source","Internal Dev1","trigger_source",["Dev1/PFI9" "Dev2/PFI1"], ...
    "completion_trigger","None","daq_master",true);
end

function wfm=empty_wfm()
wfm=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
end

function [props,wfm,summary]=waveforms(protocol,plan)
props=live_props();
[props,wfm,summary]=adaptive_optopatch.build_luminos_mixed_waveform_config( ...
    props,empty_wfm(),protocol,"DmdSequencePlan",plan, ...
    "OnePhotonProfile",adaptive_optopatch.virtual_upright_1p_profile(), ...
    "Manifest",adaptive_optopatch.virtual_upright_stimulation_manifest());
end

function [mod488,trigger]=compiled_lines(props,wfm)
profile=adaptive_optopatch.virtual_upright_1p_profile();
aliases=adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list;
ao=compile_wfm_data_to_samples(props,wfm.ao,"AliasList",aliases);
do=compile_wfm_data_to_samples(props,wfm.do,"AliasList",aliases);
mod488=ao([ao.canonical_terminal]==adaptive_optopatch.canonical_terminal( ...
    profile.modulator.port,aliases)).samples;
trigger=do([do.canonical_terminal]==adaptive_optopatch.canonical_terminal( ...
    profile.dmd.trigger_port,aliases)).samples;
mod488=reshape(double(mod488),1,[]); trigger=reshape(double(trigger),1,[]);
end

function edges=rising_edges(line)
edges=find(diff([0 line>0.5])==1);
end

function delivered=walk_wrapped_playlist(plan,mod488,trigger,slip)
edges=rising_edges(trigger);
L=plan.programmed_playlist_length;
stops=[edges(2:end)-1 plan.state_table.final_sample];
k=(1:numel(edges))'+slip;
delivered.slot=plan.programmed_playlist_slots(mod(k-1,L)+1);
delivered.levels=arrayfun(@(a,b)mod488(a:b),edges(:),stops(:),"UniformOutput",false);
end
