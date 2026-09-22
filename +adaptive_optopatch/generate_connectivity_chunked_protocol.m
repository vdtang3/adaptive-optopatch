function protocol=generate_connectivity_chunked_protocol(options)
%GENERATE_CONNECTIVITY_CHUNKED_PROTOCOL The chunked 1P connectivity screen.
%
%   protocol=GENERATE_CONNECTIVITY_CHUNKED_PROTOCOL(...) returns a
%   FIELD-OF-VIEW-INDEPENDENT schema-4 experiment definition: the design of a
%   connectivity screen, naming no cell.
%
%   WHY IT NAMES NO CELL. It used to take targetCellIds and realize every
%   chunk's schedule immediately, which meant the experiment had to be
%   written after the field of view was drawn and could not be reused on the
%   next one. It also meant the saved artifact recorded cell_001..cell_010
%   as though those were the experiment rather than whatever happened to be
%   selected. The three things that were tangled together are now separate:
%
%     WHICH CELLS      the Stim checkboxes, read at Update plan
%     THE DESIGN       this artifact
%     WHAT RAN         the frozen resolved acquisitions in the run folder
%
%   So each chunk carries a SCHEDULER SPECIFICATION - see
%   acquisition_scheduler_spec - and resolve_protocol realizes it against
%   the selected cells. The stored per-chunk seed is what makes that
%   reproducible: the same definition and the same selection produce the
%   same schedule, on any day and on any field of view.
%
%   TIMING IS UNCHANGED. Every chunk is realized by
%   generate_constrained_round_robin_schedule with the same rules it has
%   always applied: each selected cell receives exactly
%   PulsesPerCellPerChunk pulses, the cadence advances by
%   PreferredGlobalSpacingS while any target is eligible, a cell is never
%   revisited before its pulse has ended plus MinimumSameCellPostPulseGapS,
%   and idle time is inserted only when nothing is eligible. With the
%   canonical 10 ms pulse and 100 ms recovery that is a 110 ms minimum
%   same-cell onset interval, and it is never weakened to hit the cadence.
%
%   Chunk i uses BaseRandomSeed + i - 1, so the chunks are independently
%   randomized and the whole set is reproducible from one recorded number.
%
%   CommandVoltageV is NaN by default, which is the canonical choice: it
%   leaves the event tier unresolved so each pulse takes the calibrated
%   selected_blue_voltage_v of the cell it addresses. A finite value is an
%   explicit protocol-wide override in (0,5] V.
%
%   FLUT capacity is NOT checked here. It depends on how many cells are
%   selected, which this artifact deliberately does not know; the check
%   happens at resolution, where the real number is. What IS checked here is
%   everything target-independent: divisibility, timing, and the seed.
%
%   Keep AO Repeats at 1. Repeating this artifact repeats its chunks;
%   increase TotalPulsesPerCell to get more independently randomized ones.
%
%   See also RESOLVE_PROTOCOL, ACQUISITION_SCHEDULER_SPEC,
%   GENERATE_CONSTRAINED_ROUND_ROBIN_SCHEDULE.
arguments
    options.TotalPulsesPerCell (1,1) double {mustBePositive,mustBeInteger} = 1000
    options.PulsesPerCellPerChunk (1,1) double {mustBePositive,mustBeInteger} = 100
    options.PulseDurationS (1,1) double {mustBePositive} = 0.010
    options.PreferredGlobalSpacingS (1,1) double {mustBePositive} = 0.020
    options.MinimumSameCellPostPulseGapS (1,1) double {mustBeNonnegative} = 0.100
    options.PreDelayS (1,1) double {mustBeNonnegative} = 0.100
    options.PostDelayS (1,1) double {mustBeNonnegative} = 0.100
    options.BaseRandomSeed (1,1) double {mustBeNonnegative,mustBeInteger} = 3001
    options.CommandVoltageV (1,1) double = NaN
    options.FlutMaxEntries (1,1) double {mustBePositive,mustBeInteger} = 4096
end
if mod(options.TotalPulsesPerCell,options.PulsesPerCellPerChunk)~=0
    error("adaptive_optopatch:ConnectivityChunkSizeNotDivisible", ...
        "total_pulses_per_cell (%d) must be exactly divisible by " + ...
        "pulses_per_cell_per_chunk (%d).", ...
        options.TotalPulsesPerCell,options.PulsesPerCellPerChunk);
end
if options.PreferredGlobalSpacingS < options.PulseDurationS-1e-12
    error("adaptive_optopatch:OverlappingRoundRobinPulses", ...
        "Preferred global spacing must be at least the pulse duration.");
end
if isfinite(options.CommandVoltageV) && ...
        (options.CommandVoltageV<=0 || options.CommandVoltageV>5)
    error("adaptive_optopatch:InvalidRoundRobinVoltage", ...
        "CommandVoltageV must be NaN, which defers to each cell's own Blue " + ...
        "calibration, or an explicit override in (0,5] V.");
end
chunkCount=options.TotalPulsesPerCell/options.PulsesPerCellPerChunk;

acquisitionCells=cell(chunkCount,1);
for chunkIndex=1:chunkCount
    seed=options.BaseRandomSeed+chunkIndex-1;
    conditionId=sprintf("connectivity_round_robin_chunk_%02d",chunkIndex);
    scheduler=struct( ...
        "type","constrained_round_robin", ...
        "pulses_per_cell",options.PulsesPerCellPerChunk, ...
        "pulse_duration_s",options.PulseDurationS, ...
        "preferred_global_spacing_s",options.PreferredGlobalSpacingS, ...
        "minimum_same_cell_post_pulse_gap_s",options.MinimumSameCellPostPulseGapS, ...
        "pre_delay_s",options.PreDelayS, ...
        "random_seed",seed, ...
        "flut_max_entries",options.FlutMaxEntries, ...
        "chunk_index",chunkIndex, ...
        "chunk_count",chunkCount);
    acquisitionCells{chunkIndex}=struct( ...
        "acquisition_id",string(conditionId), ...
        "events",template_event(conditionId,options), ...
        "parameters",struct, ...
        "event_order_realized",true, ...
        "target_repetitions",1, ...
        "post_delay_s",options.PostDelayS, ...
        "scheduler",scheduler);
end
acquisitions=vertcat(acquisitionCells{:});

sources=struct("command_voltage_v",["event","acquisition","protocol","fov_cell"]);
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition", ...
    "protocol_id","connectivity_round_robin_chunks_"+options.BaseRandomSeed, ...
    "protocol_type","connectivity_round_robin", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "target_policy","multi_target_continuous", ...
    "event_order","randomized","random_seed",options.BaseRandomSeed, ...
    "parameter_sources",sources,"parameters",struct, ...
    "acquisitions",acquisitions);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function events=template_event(conditionId,options)
%TEMPLATE_EVENT The one untargeted event a scheduler-backed acquisition keeps.
%   NOT A PULSE. It exists so the event tier of parameter precedence has
%   somewhere to live: command_voltage_v and blue_mask_adjustment_pixels are
%   broadcast from here onto every realized pulse, so an explicit override
%   still outranks the acquisition, the protocol and the cell calibration.
%
%   onset_s is NaN, which is what says the schedule has not been realized.
%   Nothing may count this row as an executed event; summarize_protocol
%   reports scheduler-backed acquisitions by their design instead.
pulse_id=1;
condition_id=string(conditionId);
stimulation_source="1p_dmd";
onset_s=NaN;
duration_s=options.PulseDurationS;
is_null=false;
command_voltage_v=options.CommandVoltageV;
blue_mask_adjustment_pixels=NaN;
events=table(pulse_id,condition_id,stimulation_source,onset_s,duration_s, ...
    is_null,command_voltage_v,blue_mask_adjustment_pixels);
end
