% Create a connectivity-screen protocol with randomized dark gaps.

pulse_count=2000;
pulse_duration_ms=5;
dark_interval_ms=[45 55];
pre_delay_ms=100;
post_delay_ms=100;
random_seed=42;
protocol_id="connectivity_random_20hz_seed_42";

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory);
if ~exist("protocol_output_directory","var") || ...
        strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end

protocol=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",pulse_count, ...
    "PulseDurationMs",pulse_duration_ms, ...
    "DarkIntervalMs",dark_interval_ms, ...
    "PreDelayMs",pre_delay_ms, ...
    "PostDelayMs",post_delay_ms, ...
    "RandomSeed",random_seed);
protocol.protocol_id=protocol_id;

output_path=fullfile(protocol_output_directory,protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s\n",output_path);
