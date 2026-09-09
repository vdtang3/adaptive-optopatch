% Create a schema-3 definition from explicit event onsets and durations.

protocol_id="custom_example";
random_seed=0;
post_delay_s=0.5;

condition_id=["full";"half";"full";"null"];
onset_s=[0.1;0.6;1.1;1.6];
duration_s=[0.005;0.010;0.005;0.005];
command_voltage_v=[1;0.5;1;0];
pulse_id=(1:numel(onset_s))';
is_null=command_voltage_v==0;
blue_mask_adjustment_pixels=nan(numel(onset_s),1);
events=table(pulse_id,condition_id,onset_s,duration_s,is_null, ...
    command_voltage_v,blue_mask_adjustment_pixels);

acquisition=struct("acquisition_id","custom", "events",events, ...
    "parameters",struct,"event_order_realized",true, ...
    "target_repetitions",1, ...
    "acquisition_duration_s",max(onset_s+duration_s)+post_delay_s);
protocol=struct("schema_version","3.0.0", ...
    "artifact_type","experiment_definition", ...
    "protocol_id",protocol_id,"protocol_type","custom_events", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "target_policy","each_stimulation_enabled_cell", ...
    "event_order","ordered","random_seed",random_seed, ...
    "parameters",struct,"acquisitions",acquisition);

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory);
if ~exist("protocol_output_directory","var") || ...
        strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end

output_path=fullfile(protocol_output_directory,protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
protocol=adaptive_optopatch.load_protocol(output_path);
fprintf("Saved %s\n",output_path);
