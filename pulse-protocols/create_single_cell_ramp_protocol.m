% Create an ascending-block Blue-light power ramp for one cell.

pulse_duration_ms=10;
voltage_levels_v=[]; % REQUIRED, for example [0.5 0.75 1.0 1.15 1.3]
repeats_per_voltage=10;
dark_interval_ms=90;
pre_delay_ms=100;
post_delay_ms=100;
target_cell_id=""; % REQUIRED, for example "cell_004"

if isempty(voltage_levels_v) || strlength(target_cell_id)==0
    error("Set voltage_levels_v and target_cell_id near the top of this script.");
end
protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory); addpath(project_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
fprintf(['Ramp target %s | %.3g ms | %d levels (%.3g-%.3g V) | ' ...
    '%d repeats/level | %d pulses\n'],target_cell_id,pulse_duration_ms, ...
    numel(voltage_levels_v),min(voltage_levels_v),max(voltage_levels_v), ...
    repeats_per_voltage,numel(voltage_levels_v)*repeats_per_voltage);
protocol=adaptive_optopatch.generate_single_cell_ramp_protocol( ...
    target_cell_id,voltage_levels_v,"RepeatsPerVoltage",repeats_per_voltage, ...
    "PulseDurationMs",pulse_duration_ms,"DarkIntervalMs",dark_interval_ms, ...
    "PreDelayMs",pre_delay_ms,"PostDelayMs",post_delay_ms);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s | duration %.3f s\n",output_path,protocol.acquisition_duration_s);
