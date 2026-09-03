% Create randomized single-pulse, 50 Hz, and 100 Hz STF events.

repeats_per_condition=100;
pulses_per_train=10;
pulse_duration_ms=5;
event_dark_interval_ms=[450 550];
pre_delay_ms=100;
post_delay_ms=100;
random_seed=1001;
protocol_id="stf_single_50hz_100hz_seed_1001";

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory);
if ~exist("protocol_output_directory","var") || ...
        strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end

conditions=adaptive_optopatch.default_stf_conditions( ...
    "RepeatsPerCondition",repeats_per_condition, ...
    "PulsesPerTrain",pulses_per_train, ...
    "PulseDurationMs",pulse_duration_ms);
protocol=adaptive_optopatch.generate_stf_protocol(conditions, ...
    "EventDarkIntervalMs",event_dark_interval_ms, ...
    "PreDelayMs",pre_delay_ms, ...
    "PostDelayMs",post_delay_ms, ...
    "RandomSeed",random_seed);
protocol.protocol_id=protocol_id;

output_path=fullfile(protocol_output_directory,protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s\n",output_path);
