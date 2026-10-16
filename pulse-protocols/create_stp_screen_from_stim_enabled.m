% Reusable 20 Hz STP screen: targets come from the Stim checkboxes at Update plan.
% Whole five-pulse trains, not individual pulses, are interleaved across cells.
% Change these design parameters before generating an experimental protocol.
total_trains_per_cell=300;
trains_per_cell_per_chunk=50;
base_random_seed=randi(2^31-1);

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory,protocol_directory);
if ~exist("protocol_output_directory","var") || ...
        strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
protocol=adaptive_optopatch.generate_stp_chunked_protocol( ...
    "TotalTrainsPerCell",total_trains_per_cell, ...
    "TrainsPerCellPerChunk",trains_per_cell_per_chunk, ...
    "BaseRandomSeed",base_random_seed);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);
fprintf("Saved %s\n",output_path);
fprintf("%d chunks; %d trains per Stim-enabled cell; 5 pulses at 20 Hz per train.\n", ...
    numel(protocol.acquisitions),total_trains_per_cell);
fprintf("Targets and FLUT capacity are checked at Update plan. Keep AO Repeats at 1.\n");
