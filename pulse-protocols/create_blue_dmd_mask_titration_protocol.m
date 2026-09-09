% Create a randomized Blue DMD-mask titration for every Stim-enabled cell.

blue_mask_adjustments_pixels=[-4 -3 -2 -1 0];
repeats_per_adjustment=10;
pulse_duration_ms=10;
dark_interval_ms=90;
random_seed=2001;

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory);
if ~exist("protocol_output_directory","var") || ...
        strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end

protocol=adaptive_optopatch.generate_blue_mask_titration_protocol( ...
    blue_mask_adjustments_pixels, ...
    "RepeatsPerAdjustment",repeats_per_adjustment, ...
    "PulseDurationMs",pulse_duration_ms, ...
    "DarkIntervalMs",dark_interval_ms, ...
    "EventOrder","randomized","RandomSeed",random_seed);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s | voltage resolves per cell from the current FOV\n",output_path);
