% Create evenly spaced pulses at one fixed repetition rate.

pulse_count=200;
pulse_duration_ms=5;
repetition_rate_hz=2;
pre_delay_ms=100;
post_delay_ms=100;
random_seed=1;
protocol_id="regular_2hz_200_pulses";

period_ms=1000/repetition_rate_hz;
dark_interval_ms=period_ms-pulse_duration_ms;
if dark_interval_ms<=0
    error("Pulse duration must be shorter than the repetition period.");
end

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
    "DarkIntervalMs",[dark_interval_ms dark_interval_ms], ...
    "PreDelayMs",pre_delay_ms, ...
    "PostDelayMs",post_delay_ms, ...
    "RandomSeed",random_seed);
protocol.protocol_id=protocol_id;
protocol.repetition_rate_hz=repetition_rate_hz;

output_path=fullfile(protocol_output_directory,protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s\n",output_path);
