% Create a calibrated pulse-by-pulse round-robin protocol from saved FOV state.

fov_state_path=""; % REQUIRED: path to fov_state.mat
pulses_per_cell=100;
pulse_duration_ms=10;
dark_interval_ms=[90 110];
pre_delay_ms=100;
post_delay_ms=100;
random_seed=3001;

if strlength(fov_state_path)==0
    error("Set fov_state_path near the top of this script.");
end
protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory); addpath(project_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
fov_state=adaptive_optopatch.load_fov_state(fov_state_path);
protocol=adaptive_optopatch.generate_round_robin_protocol(fov_state, ...
    "PulsesPerCell",pulses_per_cell,"PulseDurationMs",pulse_duration_ms, ...
    "DarkIntervalMs",dark_interval_ms,"PreDelayMs",pre_delay_ms, ...
    "PostDelayMs",post_delay_ms,"RandomSeed",random_seed);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s | %d cells | %d pulses | duration %.3f s\n", ...
    output_path,numel(protocol.eligible_cell_ids),height(protocol.events), ...
    protocol.acquisition_duration_s);
