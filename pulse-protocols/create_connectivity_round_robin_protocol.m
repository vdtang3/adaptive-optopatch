% Canonical chunked 1P CONNECTIVITY SCREEN.
%
% The artifact contains every acquisition explicitly. Each chunk gets a
% fresh, deterministic constrained round-robin schedule (seed = base seed +
% chunk index - 1). Adaptive Optopatch executes those realized event tables
% literally; it does not recreate or randomize them at execution time.
%
% Keep normal AO Repeats at 1. Repeating this artifact repeats its already
% realized schedules; increase total_pulses_per_cell here to create more
% independently randomized chunks instead.
%
% ---- EXPERIMENTAL DESIGN (edit these) --------------------------------------
target_cell_ids=compose("cell_%03d",(1:10)'); % Must be Stim-enabled in the FOV.
total_pulses_per_cell=1000;
pulses_per_cell_per_chunk=100;
pulse_duration_s=0.010;
preferred_global_spacing_s=0.020;
minimum_same_cell_post_pulse_gap_s=0.100;
pre_delay_s=0.100;
post_delay_s=0.100;
base_random_seed=randi(2^31-1); % Save this value to reproduce every chunk.
% ---------------------------------------------------------------------------
%
% Blue voltage remains NaN so schema-4 resolution uses each cell's calibrated
% selected_blue_voltage_v from the FOV.
command_voltage_v=NaN;

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory,protocol_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
protocol=adaptive_optopatch.generate_connectivity_chunked_protocol( ...
    target_cell_ids,"TotalPulsesPerCell",total_pulses_per_cell, ...
    "PulsesPerCellPerChunk",pulses_per_cell_per_chunk, ...
    "PulseDurationS",pulse_duration_s, ...
    "PreferredGlobalSpacingS",preferred_global_spacing_s, ...
    "MinimumSameCellPostPulseGapS",minimum_same_cell_post_pulse_gap_s, ...
    "PreDelayS",pre_delay_s,"PostDelayS",post_delay_s, ...
    "BaseRandomSeed",base_random_seed,"CommandVoltageV",command_voltage_v);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);

fprintf("Saved %s\n",output_path);
fprintf("Connectivity round robin | %d cells | %d chunks | %d pulses/cell/chunk\n", ...
    numel(target_cell_ids),numel(protocol.acquisitions),pulses_per_cell_per_chunk);
for chunk_index=1:numel(protocol.acquisitions)
    metadata=protocol.acquisitions(chunk_index).scheduler_metadata;
    fprintf("  chunk %d: %d events | <= %d unique masks | FLUT capacity %d | valid\n", ...
        chunk_index,metadata.flut.event_count, ...
        metadata.flut.unique_mask_upper_bound,metadata.flut.playlist_capacity);
end
fprintf(["Timing unchanged: %.0f ms pulses | %.0f ms preferred cadence | " + ...
    "%.0f ms post-pulse same-cell gap (>= %.0f ms onset interval)\n"], ...
    pulse_duration_s*1000,preferred_global_spacing_s*1000, ...
    minimum_same_cell_post_pulse_gap_s*1000, ...
    (pulse_duration_s+minimum_same_cell_post_pulse_gap_s)*1000);
