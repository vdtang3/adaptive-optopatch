% Create randomly interleaved single and paired-pulse recovery conditions.

pulse_duration_ms=5;
repeats_per_condition=50;
event_dark_interval_ms=[950 1050];
pre_delay_ms=100;
post_delay_ms=100;
random_seed=2001;
protocol_id="paired_pulse_10_20_50_100hz_seed_2001";

condition_id=["single";"pair_10hz";"pair_20hz";"pair_50hz";"pair_100hz"];
frequency_hz=[NaN;10;20;50;100];
pulses_per_train=[1;2;2;2;2];
pulse_duration_ms_by_condition=repmat(pulse_duration_ms,5,1);
repeats=repmat(repeats_per_condition,5,1);
amplitude_fraction=ones(5,1);
is_null=false(5,1);
conditions=table(condition_id,frequency_hz,pulses_per_train, ...
    pulse_duration_ms_by_condition,repeats,amplitude_fraction,is_null, ...
    'VariableNames',{'condition_id','frequency_hz','pulses_per_train', ...
    'pulse_duration_ms','repeats','amplitude_fraction','is_null'});

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory);
if ~exist("protocol_output_directory","var") || ...
        strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end

protocol=adaptive_optopatch.generate_stf_protocol(conditions, ...
    "EventDarkIntervalMs",event_dark_interval_ms, ...
    "PreDelayMs",pre_delay_ms, ...
    "PostDelayMs",post_delay_ms, ...
    "RandomSeed",random_seed);
protocol.protocol_id=protocol_id;

output_path=fullfile(protocol_output_directory,protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s\n",output_path);
