% Create a protocol from explicit event onsets, durations, and amplitudes.

protocol_id="custom_example";
random_seed=0;
post_delay_s=0.5;

condition_id=["full";"half";"full";"null"];
onset_s=[0.1;0.6;1.1;1.6];
duration_s=[0.005;0.010;0.005;0.005];
amplitude_fraction=[1;0.5;1;0];
event_id=(1:numel(onset_s))';
events=table(event_id,condition_id,onset_s,duration_s,amplitude_fraction);

protocol=struct;
protocol.schema_version="1.0.0";
protocol.protocol_id=protocol_id;
protocol.protocol_type="custom_events";
protocol.created_at=string(datetime("now","TimeZone","local"));
protocol.random_seed=random_seed;
protocol.events=events;
protocol.acquisition_duration_s=max(onset_s+duration_s)+post_delay_s;
protocol.total_light_on_s=sum(duration_s.*amplitude_fraction);

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
