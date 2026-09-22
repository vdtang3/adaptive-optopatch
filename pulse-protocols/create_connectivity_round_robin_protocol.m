% Canonical chunked 1P CONNECTIVITY SCREEN.
%
% This script defines the EXPERIMENT, not the field of view. It names no
% cell, needs no FOV, no Luminos session and no Adaptive Optopatch
% controller, and the artifact it saves is reusable on every field of view
% you run it on.
%
% Three things used to be one thing, and separating them is the whole point:
%
%   WHICH CELLS      the Stim checkboxes in Adaptive Optopatch, read when
%                    Update plan is pressed
%   THE DESIGN       this file, and the .mat it saves
%   WHAT ACTUALLY    the frozen resolved acquisitions written into the run
%   RAN              folder by Update plan
%
% Each chunk stores a random seed rather than a realized schedule. Update
% plan builds that chunk's schedule from the seed and the cells you selected,
% freezes the literal event table, and the runner executes it verbatim -
% nothing is randomized again at execution time. The same definition and the
% same selection always produce the same schedule.
%
% Keep AO Repeats at 1. Repeating this artifact repeats its chunks; raise
% total_pulses_per_cell to get more independently randomized ones.
%
% ---- EXPERIMENTAL DESIGN (edit these) --------------------------------------
total_pulses_per_cell=1000;
pulses_per_cell_per_chunk=100;
pulse_duration_s=0.010;
preferred_global_spacing_s=0.020;
minimum_same_cell_post_pulse_gap_s=0.100;
pre_delay_s=0.100;
post_delay_s=0.100;
base_random_seed=randi(2^31-1); % Save this value to reproduce every chunk.
flut_max_entries=4096;
% ---------------------------------------------------------------------------
%
% NaN leaves the event tier unresolved, so every pulse takes the calibrated
% selected_blue_voltage_v of the cell it addresses. A finite value in (0,5]
% is an explicit protocol-wide override. There is no GUI fallback: a selected
% cell with no Blue V makes Update plan fail and names the cell.
command_voltage_v=NaN;

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory,protocol_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
protocol=adaptive_optopatch.generate_connectivity_chunked_protocol( ...
    "TotalPulsesPerCell",total_pulses_per_cell, ...
    "PulsesPerCellPerChunk",pulses_per_cell_per_chunk, ...
    "PulseDurationS",pulse_duration_s, ...
    "PreferredGlobalSpacingS",preferred_global_spacing_s, ...
    "MinimumSameCellPostPulseGapS",minimum_same_cell_post_pulse_gap_s, ...
    "PreDelayS",pre_delay_s,"PostDelayS",post_delay_s, ...
    "BaseRandomSeed",base_random_seed,"CommandVoltageV",command_voltage_v, ...
    "FlutMaxEntries",flut_max_entries);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);

chunk_count=numel(protocol.acquisitions);
fprintf("Saved %s\n",output_path);
fprintf("Connectivity round robin\n");
fprintf("  %d chunks\n",chunk_count);
fprintf("  %d pulses/cell/chunk (%d per cell in total)\n", ...
    pulses_per_cell_per_chunk,total_pulses_per_cell);
% Deliberately NOT a target count. Nothing here knows how many cells will be
% selected, and printing a number would be inventing one.
fprintf("  targets: current Stim-enabled AO cells at Update Plan\n");
fprintf("  chunk seeds: %d-%d\n",base_random_seed,base_random_seed+chunk_count-1);
if isfinite(command_voltage_v)
    fprintf("  voltage: %.3f V, explicit protocol override\n",command_voltage_v);
else
    fprintf("  voltage: per-cell selected Blue calibration\n");
end
fprintf("  %.0f ms pulses\n",pulse_duration_s*1000);
fprintf("  %.0f ms preferred cadence\n",preferred_global_spacing_s*1000);
fprintf("  %.0f ms post-pulse same-cell gap\n", ...
    minimum_same_cell_post_pulse_gap_s*1000);
fprintf("  >=%.0f ms same-cell onset interval\n", ...
    (pulse_duration_s+minimum_same_cell_post_pulse_gap_s)*1000);
fprintf("  FLUT capacity is checked at Update Plan, against the number of " + ...
    "cells actually selected.\n");
