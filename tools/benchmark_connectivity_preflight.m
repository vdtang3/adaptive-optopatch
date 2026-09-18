function timings=benchmark_connectivity_preflight(targetCount,pulsesPerTarget)
%BENCHMARK_CONNECTIVITY_PREFLIGHT Time a realistic pure-1P preparation pass.
arguments
    targetCount (1,1) double {mustBePositive,mustBeInteger} = 34
    pulsesPerTarget (1,1) double {mustBePositive,mustBeInteger} = 100
end
root=fileparts(fileparts(mfilename("fullpath")));
addpath(root);
[fov,targets,gui]=fixture(targetCount);
ids=string({fov.cells.cell_id})';
[events,metadata]=adaptive_optopatch.generate_constrained_round_robin_schedule( ...
    ids,pulsesPerTarget,0.010,0.020,0.100,NaN,"RandomSeed",3001);
acquisition=struct("acquisition_id","benchmark","events",events, ...
    "parameters",struct,"event_order_realized",true,"target_repetitions",1, ...
    "post_delay_s",0.1,"scheduler_metadata",metadata);
definition=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition","protocol_id","benchmark", ...
    "protocol_type","connectivity_round_robin", ...
    "target_policy","multi_target_continuous","event_order","randomized", ...
    "random_seed",3001,"parameter_sources", ...
    struct("command_voltage_v",["event","acquisition","protocol","fov_cell"]), ...
    "parameters",struct,"acquisitions",acquisition);

started=tic;
resolved=adaptive_optopatch.resolve_protocol(definition,fov,targets,gui, ...
    "Mode","1p_dmd");
timings.resolve_protocol_s=toc(started);
protocol=resolved{1};

started=tic;
plan=adaptive_optopatch.build_dmd_sequence_plan(protocol,targets);
timings.build_dmd_sequence_plan_s=toc(started);
globalProps=struct("rate",200000,"total_time",1, ...
    "clock_source","Internal Dev1","trigger_source","Dev1/PFI9", ...
    "daq_master",true);
wfm=struct("ao",[],'do',[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
started=tic;
[configured,wfmData]=adaptive_optopatch.build_luminos_mixed_waveform_config( ...
    globalProps,wfm,protocol,"DmdSequencePlan",plan);
timings.build_mixed_waveform_config_s=toc(started);
started=tic;
adaptive_optopatch.account_stimulation_outputs(configured,wfmData, ...
    "Modality","1p_dmd");
timings.stimulation_accounting_s=toc(started);
timings.total_preflight_s=sum(struct2array(timings));
timings.event_count=height(events);
timings.unique_mask_count=plan.unique_mask_count;
timings.duration_s=protocol.acquisition_duration_s;

fprintf("Connectivity benchmark: %d targets x %d pulses = %d events, %.1f s\n", ...
    targetCount,pulsesPerTarget,height(events),protocol.acquisition_duration_s);
fprintf("  resolve protocol:        %.3f s\n",timings.resolve_protocol_s);
fprintf("  build DMD plan:          %.3f s\n",timings.build_dmd_sequence_plan_s);
fprintf("  build waveform config:   %.3f s\n",timings.build_mixed_waveform_config_s);
fprintf("  stimulation accounting:  %.3f s\n",timings.stimulation_accounting_s);
fprintf("  total measured preflight %.3f s\n",timings.total_preflight_s);
end

function [fov,targets,gui]=fixture(n)
side=ceil(sqrt(n)); imageSize=[side*8+4 side*8+4];
image=zeros(imageSize); masks=false([imageSize n]); polygons=cell(n,1);
for k=1:n
    row=3+floor((k-1)/side)*8; column=3+mod(k-1,side)*8;
    masks(row:row+3,column:column+3,k)=true;
    polygons{k}=[column row;column+3 row;column+3 row+3;column row+3];
end
ids=compose("cell_%03d",(1:n)');
metadata=struct("rig_name","benchmark", ...
    "voltage_camera",struct("name","Camera 1","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","connectivity_benchmark","CellIds",ids,"RoiPolygons",polygons);
fov=adaptive_optopatch.create_fov_state(reference,polygons);
for id=reshape(ids,1,[])
    fov=adaptive_optopatch.update_cell_calibration(fov,id, ...
        "CommandVoltageV",1,"PulseDurationMs",10);
end
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1,"BlueMaskAdjustmentPixels",0);
gui=struct("command_voltage_v",1,"pulse_duration_s",0.010, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end
