function spec=acquisition_scheduler_spec(acquisition)
%ACQUISITION_SCHEDULER_SPEC The scheduler an acquisition asks for, normalized.
%   spec=ACQUISITION_SCHEDULER_SPEC(acquisition) returns the normalized
%   scheduler specification of one schema-4 acquisition, or an empty struct
%   when the acquisition carries an explicit event schedule instead.
%
%   WHAT THIS IS FOR. A schema-4 acquisition normally states every event it
%   will run. That works when the experiment names its targets, and it does
%   not work for connectivity: the targets are whichever cells are
%   Stim-enabled when Update plan is pressed, which the experiment design
%   cannot know and must not have to. So an acquisition may instead say HOW
%   ITS SCHEDULE IS BUILT, and resolve_protocol builds it against the cells
%   that are actually selected.
%
%   The definition therefore contains no FOV cell ID, and one saved
%   connectivity experiment is reusable across every field of view.
%
%   AN EXPLICIT FIELD, NOT AN INFERENCE. The acquisition says
%   scheduler.type; nothing dispatches on protocol_id or protocol_type
%   strings. An acquisition with no scheduler field is an ordinary explicit
%   schema-4 acquisition and is untouched by any of this - which is what
%   keeps every already-saved protocol working exactly as before.
%
%   WHAT A SCHEDULER-BACKED ACQUISITION STILL CARRIES is one untargeted
%   TEMPLATE event. It is not a pulse and must never be counted as one; it
%   is where the event tier of the parameter-precedence chain lives, so an
%   event-level command_voltage_v or blue_mask_adjustment_pixels override
%   still means what it means everywhere else. NaN on the template is the
%   normal case and falls through to the per-cell calibration.
%
%   FIELDS, for type "constrained_round_robin":
%
%     type                                "constrained_round_robin"
%     pulses_per_cell                     per selected cell, this acquisition
%     pulse_duration_s
%     preferred_global_spacing_s          cadence when a target is eligible
%     minimum_same_cell_post_pulse_gap_s  recovery before the SAME cell again
%     pre_delay_s
%     random_seed                         this chunk's stored seed
%     flut_max_entries                    checked against the real target
%                                         count at resolution, not here
%     chunk_index, chunk_count            provenance for the archive
%
%   FIELDS, for type "blanket_round_robin" (requires the protocol's
%   blanket_depolarization block; see BLANKET_DEPOLARIZATION_SPEC):
%
%     rounds               complete fixed-order rounds, = epochs per cell
%     epoch_duration_s     whole modulation cycles
%     inter_epoch_gap_s    whole cycles, at least one
%     pre_delay_s          whole cycles, dark
%
%   See also RESOLVE_PROTOCOL, GENERATE_CONSTRAINED_ROUND_ROBIN_SCHEDULE,
%   GENERATE_CONNECTIVITY_CHUNKED_PROTOCOL.
arguments
    acquisition (1,1) struct
end
spec=struct([]);
if ~isfield(acquisition,"scheduler") || isempty(acquisition.scheduler)
    return
end
raw=acquisition.scheduler;
if ~isstruct(raw) || ~isscalar(raw)
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "An acquisition scheduler must be one scalar struct.");
end
if ~isfield(raw,"type")
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "An acquisition scheduler must name its type.");
end
type=string(raw.type);
if type=="blanket_round_robin"
    % One FIXED round, cell by cell in FOV order, repeated `rounds` times.
    % Fixed because the DMD playlist holds exactly one round and wraps it;
    % whole-cycle timing is checked against blanket_depolarization, which
    % this scheduler cannot be used without (blanket_depolarization_spec).
    spec=struct("schema_version","1.0.0","type",type, ...
        "rounds",required_count(raw,"rounds"), ...
        "epoch_duration_s",required_positive(raw,"epoch_duration_s"), ...
        "inter_epoch_gap_s",required_positive(raw,"inter_epoch_gap_s"), ...
        "pre_delay_s",optional_nonnegative(raw,"pre_delay_s",0), ...
        "chunk_index",optional_count(raw,"chunk_index",1), ...
        "chunk_count",optional_count(raw,"chunk_count",1), ...
        "pulses_per_cell",double(raw.rounds));
    return
end
if type=="blanket_recruitment_sweep"
    % Blanket only, stepped upward. Every step is one logical segment and
    % the DMD sequence is the same two masks throughout, so the step list is
    % the whole design. Explicit levels only: nothing here invents a voltage.
    spec=struct("schema_version","1.0.0","type",type, ...
        "levels_v",reshape(double(required_vector(raw,"levels_v")),[],1), ...
        "step_duration_s",required_positive(raw,"step_duration_s"), ...
        "pre_dark_s",optional_nonnegative(raw,"pre_dark_s",0), ...
        "pre_delay_s",0, ...
        "chunk_index",optional_count(raw,"chunk_index",1), ...
        "chunk_count",optional_count(raw,"chunk_count",1), ...
        "pulses_per_cell",numel(required_vector(raw,"levels_v")));
    return
end
if type=="blanket_population_target_sweep"
    % The blanket round robin's cycle with one target: the union of every
    % selected cell's mask, stepped through target voltages.
    spec=struct("schema_version","1.0.0","type",type, ...
        "levels_v",reshape(double(required_vector(raw,"levels_v")),[],1), ...
        "repetitions_per_level",required_count(raw,"repetitions_per_level"), ...
        "epoch_duration_s",required_positive(raw,"epoch_duration_s"), ...
        "inter_epoch_gap_s",required_positive(raw,"inter_epoch_gap_s"), ...
        "pre_delay_s",optional_nonnegative(raw,"pre_delay_s",0), ...
        "chunk_index",optional_count(raw,"chunk_index",1), ...
        "chunk_count",optional_count(raw,"chunk_count",1), ...
        "pulses_per_cell",numel(required_vector(raw,"levels_v"))* ...
            double(raw.repetitions_per_level));
    return
end
if type=="constrained_stp_round_robin"
    spec=struct("schema_version","1.0.0","type",type, ...
        "trains_per_cell",required_count(raw,"trains_per_cell"), ...
        "pulses_per_train",required_count(raw,"pulses_per_train"), ...
        "frequency_hz",required_positive(raw,"frequency_hz"), ...
        "pulse_duration_s",required_positive(raw,"pulse_duration_s"), ...
        "preferred_inter_train_gap_s", ...
            optional_nonnegative(raw,"preferred_inter_train_gap_s",0), ...
        "minimum_same_cell_post_train_gap_s", ...
            optional_nonnegative(raw,"minimum_same_cell_post_train_gap_s",0), ...
        "pre_delay_s",optional_nonnegative(raw,"pre_delay_s",0), ...
        "random_seed",required_seed(raw), ...
        "flut_max_entries",optional_count(raw,"flut_max_entries",4096), ...
        "chunk_index",optional_count(raw,"chunk_index",1), ...
        "chunk_count",optional_count(raw,"chunk_count",1), ...
        "pulses_per_cell",double(raw.trains_per_cell)*double(raw.pulses_per_train));
    if spec.pulses_per_train>1 && ...
            spec.pulse_duration_s>=1/spec.frequency_hz-1e-12
        error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
            "STP pulse duration must be shorter than its pulse period.");
    end
    return
end
if type~="constrained_round_robin"
    error("adaptive_optopatch:UnknownAcquisitionScheduler", ...
        "Unknown acquisition scheduler type '%s'. This build realizes " + ...
        "constrained_round_robin, constrained_stp_round_robin, " + ...
        "blanket_round_robin, blanket_recruitment_sweep and " + ...
        "blanket_population_target_sweep.",type);
end

spec=struct("schema_version","1.0.0","type",type, ...
    "pulses_per_cell",required_count(raw,"pulses_per_cell"), ...
    "pulse_duration_s",required_positive(raw,"pulse_duration_s"), ...
    "preferred_global_spacing_s", ...
        required_positive(raw,"preferred_global_spacing_s"), ...
    "minimum_same_cell_post_pulse_gap_s", ...
        optional_nonnegative(raw,"minimum_same_cell_post_pulse_gap_s",0), ...
    "pre_delay_s",optional_nonnegative(raw,"pre_delay_s",0), ...
    "random_seed",required_seed(raw), ...
    "flut_max_entries",optional_count(raw,"flut_max_entries",4096), ...
    "chunk_index",optional_count(raw,"chunk_index",1), ...
    "chunk_count",optional_count(raw,"chunk_count",1));

if spec.preferred_global_spacing_s < spec.pulse_duration_s - 1e-12
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "preferred_global_spacing_s must be at least pulse_duration_s.");
end
end

function value=required_vector(raw,name)
if ~isfield(raw,name) || isempty(raw.(name))
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "A blanket sweep scheduler requires a nonempty %s.",name);
end
value=double(raw.(name));
if ~isvector(value) || any(~isfinite(value))
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "%s must be a vector of finite values.",name);
end
end

function value=required_count(raw,name)
if ~isfield(raw,name)
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "A constrained_round_robin scheduler requires %s.",name);
end
value=double(raw.(name));
if ~isscalar(value) || ~isfinite(value) || value<1 || fix(value)~=value
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "%s must be a positive integer.",name);
end
end

function value=optional_count(raw,name,fallback)
if ~isfield(raw,name) || isempty(raw.(name)), value=fallback; return; end
value=required_count(raw,name);
end

function value=required_positive(raw,name)
if ~isfield(raw,name)
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "A constrained_round_robin scheduler requires %s.",name);
end
value=double(raw.(name));
if ~isscalar(value) || ~isfinite(value) || value<=0
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "%s must be a positive, finite number.",name);
end
end

function value=optional_nonnegative(raw,name,fallback)
if ~isfield(raw,name) || isempty(raw.(name)), value=fallback; return; end
value=double(raw.(name));
if ~isscalar(value) || ~isfinite(value) || value<0
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "%s must be a nonnegative, finite number of seconds.",name);
end
end

function value=required_seed(raw)
if ~isfield(raw,"random_seed")
    error("adaptive_optopatch:InvalidAcquisitionScheduler", ...
        "A scheduler-backed acquisition requires a stored random_seed: it " + ...
        "is what makes the realized schedule reproducible across fields " + ...
        "of view and across runs.");
end
value=double(raw.random_seed);
if ~isscalar(value) || ~isfinite(value) || value<0 || fix(value)~=value
    error("adaptive_optopatch:InvalidRandomSeed", ...
        "A scheduler random_seed must be a nonnegative integer.");
end
end
