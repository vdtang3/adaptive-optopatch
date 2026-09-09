% Create an ROI-independent continuous round-robin experiment definition.

pulses_per_cell=100;
pulse_duration_ms=10;
dark_interval_ms=[90 110];
pre_delay_ms=100;
post_delay_ms=100;
random_seed=3001;

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory); addpath(project_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
protocol=adaptive_optopatch.generate_round_robin_protocol( ...
    "PulsesPerCell",pulses_per_cell,"PulseDurationMs",pulse_duration_ms, ...
    "DarkIntervalMs",dark_interval_ms,"PreDelayMs",pre_delay_ms, ...
    "PostDelayMs",post_delay_ms,"RandomSeed",random_seed);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s | targets and voltages resolve from the current FOV at freeze time\n", ...
    output_path);
