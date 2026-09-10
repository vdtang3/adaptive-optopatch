%% Create 2P power-series pulse-train protocol

stim_power_v = [0.05 0.10 0.15];   % 2P Pockels command voltages
repeats_per_power = 5;              % trains at each power

pulse_number = 10;                  % pulses per train
pulse_duration_ms = 5;              % pulse duration
inter_pulse_interval_ms = 95;       % OFF time between pulses

inter_train_interval_ms = 500;      % OFF time between trains
pre_delay_ms = 100;
post_delay_ms = 100;

%% Estimated run length

n_powers = numel(stim_power_v);
n_trains = n_powers * repeats_per_power;

pulse_period_ms = pulse_duration_ms + inter_pulse_interval_ms;

train_duration_ms = ...
    pulse_number * pulse_duration_ms + ...
    (pulse_number - 1) * inter_pulse_interval_ms;

estimated_run_length_ms = ...
    pre_delay_ms + ...
    n_trains * train_duration_ms + ...
    (n_trains - 1) * inter_train_interval_ms + ...
    post_delay_ms;

estimated_run_length_s = estimated_run_length_ms / 1000;

fprintf("2P power-series protocol\n");
fprintf("Stim powers: %s V\n",mat2str(stim_power_v));
fprintf("Repeats per power: %d\n",repeats_per_power);
fprintf("Total trains: %d\n",n_trains);
fprintf("Pulses per train: %d\n",pulse_number);
fprintf("Pulse period: %.3f ms (%.2f Hz)\n", ...
    pulse_period_ms,1000/pulse_period_ms);
fprintf("Train duration: %.3f ms\n",train_duration_ms);
fprintf("Estimated acquisition length: %.3f s (%.2f min)\n", ...
    estimated_run_length_s,estimated_run_length_s/60);

%% Set up protocol output

protocol_directory = fileparts(mfilename("fullpath"));
project_directory = fileparts(protocol_directory);
addpath(project_directory);

if ~exist("protocol_output_directory","var") || ...
        strlength(string(protocol_output_directory)) == 0
    protocol_output_directory = fullfile(protocol_directory,"generated");
end

if ~isfolder(protocol_output_directory)
    mkdir(protocol_output_directory);
end

%% Build all trains into one event table

total_pulses = n_trains * pulse_number;

pulse_id = (1:total_pulses)';
condition_id = strings(total_pulses,1);
onset_s = zeros(total_pulses,1);
duration_s = repmat(pulse_duration_ms/1000,total_pulses,1);
is_null = false(total_pulses,1);
command_voltage_v = zeros(total_pulses,1);
blue_mask_adjustment_pixels = nan(total_pulses,1);

power_index = zeros(total_pulses,1);
repeat_index = zeros(total_pulses,1);
train_index = zeros(total_pulses,1);
pulse_in_train = zeros(total_pulses,1);

event_index = 0;
current_time_ms = pre_delay_ms;
current_train = 0;

for p = 1:n_powers

    power_v = stim_power_v(p);

    for r = 1:repeats_per_power

        current_train = current_train + 1;

        for pulse = 1:pulse_number

            event_index = event_index + 1;

            condition_id(event_index) = ...
                "power_" + replace(compose("%.4gV",power_v),".","p");

            onset_s(event_index) = current_time_ms / 1000;
            command_voltage_v(event_index) = power_v;

            power_index(event_index) = p;
            repeat_index(event_index) = r;
            train_index(event_index) = current_train;
            pulse_in_train(event_index) = pulse;

            current_time_ms = current_time_ms + pulse_duration_ms;

            if pulse < pulse_number
                current_time_ms = ...
                    current_time_ms + inter_pulse_interval_ms;
            end

        end

        if current_train < n_trains
            current_time_ms = ...
                current_time_ms + inter_train_interval_ms;
        end

    end

end

events = table( ...
    pulse_id, ...
    condition_id, ...
    onset_s, ...
    duration_s, ...
    is_null, ...
    command_voltage_v, ...
    blue_mask_adjustment_pixels, ...
    power_index, ...
    repeat_index, ...
    train_index, ...
    pulse_in_train);

%% Build single acquisition

acquisition_duration_s = ...
    max(onset_s + duration_s) + post_delay_ms/1000;

acquisition = struct( ...
    "acquisition_id","2p_power_series", ...
    "events",events, ...
    "parameters",struct, ...
    "event_order_realized",true, ...
    "target_repetitions",1, ...
    "acquisition_duration_s",acquisition_duration_s);

%% Build protocol

protocol = struct( ...
    "schema_version","3.0.0", ...
    "artifact_type","experiment_definition", ...
    "protocol_id","2p_power_series", ...
    "protocol_type","2p_power_series", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "target_policy","each_stimulation_enabled_cell", ...
    "event_order","ordered", ...
    "random_seed",1, ...
    "parameters",struct( ...
        "stim_power_v",stim_power_v, ...
        "repeats_per_power",repeats_per_power, ...
        "pulse_number",pulse_number, ...
        "pulse_duration_ms",pulse_duration_ms, ...
        "inter_pulse_interval_ms",inter_pulse_interval_ms, ...
        "inter_train_interval_ms",inter_train_interval_ms), ...
    "acquisitions",acquisition);

protocol = adaptive_optopatch.normalize_protocol(protocol);

%% Save protocol

output_path = fullfile( ...
    protocol_output_directory, ...
    protocol.protocol_id + ".mat");

adaptive_optopatch.save_protocol(output_path,protocol);

fprintf("\nSaved 2P protocol:\n%s\n",output_path);