% Create a hardware diagnostic for cyclic FLUT playback in slave mode.

% Edit these explicit test settings for the current FOV. The three named cells
% must exist, be stimulation-enabled, and have distinct executable Blue masks.
target_cell_ids=["cell_001";"cell_002";"cell_003"];
command_voltage_v=0.2;
pulse_duration_s=0.005;
event_spacing_s=0.100;
pre_delay_s=0.100;
post_delay_s=0.100;

diagnostic_name="dmd_flut_wrap";
base_playlist_slots=(1:3)';
expected_wrapped_slots=[1;2;3;1;2;3;1;2];
dmd_trigger_count=numel(expected_wrapped_slots);

event_index=(1:dmd_trigger_count)';
pulse_id=event_index;
condition_id=repmat(diagnostic_name,dmd_trigger_count,1);
stimulation_source=repmat("1p_dmd",dmd_trigger_count,1);
target_cell_id=target_cell_ids(expected_wrapped_slots);
onset_s=pre_delay_s+(0:dmd_trigger_count-1)'*event_spacing_s;
duration_s=repmat(pulse_duration_s,dmd_trigger_count,1);
is_null=false(dmd_trigger_count,1);
command_voltage_v=repmat(command_voltage_v,dmd_trigger_count,1);
blue_mask_adjustment_pixels=nan(dmd_trigger_count,1);
events=table(event_index,pulse_id,condition_id,stimulation_source,target_cell_id,onset_s, ...
    duration_s,is_null,command_voltage_v,blue_mask_adjustment_pixels);

dmd_diagnostic=struct("diagnostic_name",diagnostic_name, ...
    "base_playlist_slots",base_playlist_slots, ...
    "base_playlist_length",numel(base_playlist_slots), ...
    "dmd_trigger_count",dmd_trigger_count, ...
    "expected_wrapped_slots",expected_wrapped_slots);
acquisition=struct("acquisition_id",diagnostic_name,"events",events, ...
    "parameters",struct,"event_order_realized",true,"target_repetitions",1, ...
    "post_delay_s",post_delay_s,"dmd_diagnostic",dmd_diagnostic);
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition", ...
    "protocol_id",diagnostic_name,"protocol_type","hardware_diagnostic", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "target_policy","multi_target_continuous", ...
    "event_order","ordered","random_seed",0, ...
    "parameter_sources",struct("command_voltage_v","event"), ...
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

summary=table(event_index,expected_wrapped_slots, ...
    target_cell_ids(expected_wrapped_slots),onset_s, ...
    'VariableNames',["event_index","expected_slot","expected_cell_id","onset_s"]);
disp(summary);
fprintf("Saved %s\n",output_path);
fprintf("Hardware check: eight slave triggers should show slots 1,2,3,1,2,3,1,2.\n");
