% Test the 488 nm light path with one long pulse and a static Blue DMD mask.
% Enable Stim for only one cell in the FOV. Use a safe test preparation.

command_voltage_v=1.0;
pulse_duration_s=0.5;
pre_delay_s=0.2;
post_delay_s=0.3;

pulse_id=1;
condition_id="static_blue_light_test";
stimulation_source="1p_dmd";
onset_s=pre_delay_s;
duration_s=pulse_duration_s;
is_null=false;
blue_mask_adjustment_pixels=NaN;
events=table(pulse_id,condition_id,stimulation_source,onset_s,duration_s, ...
    is_null,command_voltage_v,blue_mask_adjustment_pixels);

acquisition=struct("acquisition_id",condition_id,"events",events, ...
    "parameters",struct,"event_order_realized",true, ...
    "target_repetitions",1, ...
    "acquisition_duration_s",pre_delay_s+pulse_duration_s+post_delay_s);
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition", ...
    "protocol_id",condition_id,"protocol_type","hardware_diagnostic", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "target_policy","each_stimulation_enabled_cell", ...
    "event_order","ordered","random_seed",0, ...
    "parameters",struct,"acquisitions",acquisition);

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory);
if ~exist("protocol_output_directory","var") || ...
        strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
protocol=adaptive_optopatch.load_protocol(output_path);
fprintf("Saved %s\n",output_path);
fprintf("Spinning Upright adds 2 s of baseline: the pulse starts at 2.2 s.\n");
