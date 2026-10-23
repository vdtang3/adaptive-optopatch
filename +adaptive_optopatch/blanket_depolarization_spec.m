function spec=blanket_depolarization_spec(protocol)
%BLANKET_DEPOLARIZATION_SPEC A protocol's blanket-depolarization block, normalized.
%   spec=BLANKET_DEPOLARIZATION_SPEC(protocol) returns the normalized
%   blanket_depolarization block of a schema-4 definition or resolved
%   acquisition. A protocol without the block returns enabled=false, which is
%   the default: nothing about an existing protocol changes unless it asks.
%
%   WHAT IT IS. Inhibitory-cell round robins want every cell slightly
%   depolarized so IPSPs have driving force. Blanket mode gives the whole
%   camera FOV a short Blue pulse at the start of every modulation cycle and
%   spends the rest of the cycle on the target (during a target epoch) or in
%   the dark (between epochs):
%
%       target epoch:  [union mask, mod488_v  ][target mask, cell Vstim]
%       gap:           [union mask, mod488_v  ][blank mask,  0 V       ]
%
%   The blanket dose is set by blanket_fraction, a duty cycle, rather than by
%   a lower AOTF voltage, so it never depends on the AOTF's nonlinear
%   transfer curve. The cycle is locked to the camera frame and the DAQ
%   clock; build_blanket_state_table turns it into DAQ samples.
%
%   FIELDS (seconds, like every other protocol duration)
%     enabled               false unless the protocol says true
%     mod488_v              blanket-phase command, (0,5] V, required when on,
%                           except for a recruitment sweep, whose blanket
%                           level is what its steps change
%     cycle_period_s        0.001; must equal the camera frame period
%     blanket_fraction      0.20; strictly between 0 and 1
%     target_onset_guard_s  50e-6; mod488 is held at 0 V for this long at the
%                           start of every target state, because the DMD
%                           shows the new mask only after its trigger-to-
%                           display latency, and until then the blanket
%                           union is still up. Without a guard that latency
%                           puts the target's Vstim on every cell at once,
%                           once per cycle. 50 us covers the 44 us ALP
%                           minimum picture time; set it from the commissioning
%                           photodiode measurement.
%     schedule              which blanket schedule this protocol runs;
%                           "round_robin" by default. See SCHEDULES.
%     mask                  resolved only: which cells the blanket phase
%                           illuminates - the union of the Stim-enabled
%                           cells' own masks, never the whole field of view
%     round                 round_robin, resolved only: the realized fixed
%                           order and timing (start_s, period_s, count,
%                           cell_ids, epoch_duration_s, inter_epoch_gap_s)
%     sweep                 the two calibration schedules, resolved only:
%                           their explicit levels and realized timing
%
%   SCHEDULES. All three share one cycle, one set of masks, one guard, one
%   state table, the wrapping FLUT playlist, the waveform builders and the
%   DMD advance checks. They differ only in what the programmed unit
%   contains and which mod488 level each cycle carries.
%
%     round_robin               the experiment. One fixed round of target
%                               epochs, wrapped.
%
%     recruitment_sweep         blanket only, no target phase: the cycle is
%                               [blanket mask at this step's level][blank
%                               mask at 0 V]. One logical segment per
%                               voltage step, each a whole number of cycles,
%                               after a dark baseline. The steps are short
%                               by design, because the sweep cannot be
%                               stopped once it is running.
%
%     population_target_sweep   the blanket round robin's cycle with one
%                               target: the union of every selected cell's
%                               mask, stepped through target voltages. One
%                               logical epoch per repetition.
%
%   Definition rules checked here: blanket mode belongs to
%   multi_target_continuous protocols whose every acquisition uses the
%   matching blanket scheduler, and those schedulers are never used without
%   blanket mode. Every segment, epoch, gap and delay is a whole number of
%   cycles; a round-robin gap is at least one cycle, so logical epochs never
%   merge into one recorded epoch downstream.
%
%   See also BUILD_BLANKET_STATE_TABLE, GENERATE_BLANKET_ROUND_ROBIN_PROTOCOL,
%   GENERATE_BLANKET_RECRUITMENT_SWEEP_PROTOCOL,
%   GENERATE_BLANKET_POPULATION_TARGET_SWEEP_PROTOCOL.
arguments
    protocol (1,1) struct
end
spec=struct("schema_version","1.1.0","enabled",false,"mod488_v",NaN, ...
    "cycle_period_s",0.001,"blanket_fraction",0.20, ...
    "target_onset_guard_s",50e-6,"schedule","round_robin");
[scheduled,schedulerTypes]=blanket_scheduled_acquisitions(protocol);
if ~isfield(protocol,"blanket_depolarization") || ...
        isempty(protocol.blanket_depolarization)
    if any(scheduled)
        error("adaptive_optopatch:BlanketSchedulerWithoutBlanketMode", ...
            "A %s acquisition requires an enabled blanket_depolarization " + ...
            "block on the protocol.",schedulerTypes(find(scheduled,1)));
    end
    return
end
raw=protocol.blanket_depolarization;
if ~isstruct(raw) || ~isscalar(raw)
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "blanket_depolarization must be one scalar struct.");
end
known=["schema_version","enabled","mod488_v","cycle_period_s", ...
    "blanket_fraction","target_onset_guard_s","schedule","mask","round","sweep"];
unknown=setdiff(string(fieldnames(raw))',known);
if ~isempty(unknown)
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "blanket_depolarization has unknown field(s): %s. Known fields: %s.", ...
        strjoin(unknown,", "),strjoin(known(2:end),", "));
end
if isfield(raw,"enabled")
    enabled=raw.enabled;
    if ~(islogical(enabled) || isnumeric(enabled)) || ~isscalar(enabled) || ...
            ~ismember(double(enabled),[0 1])
        error("adaptive_optopatch:InvalidBlanketDepolarization", ...
            "blanket_depolarization.enabled must be true or false.");
    end
    spec.enabled=logical(enabled);
end
if isfield(raw,"schedule") && ~isempty(raw.schedule)
    schedule=string(raw.schedule);
    if ~isscalar(schedule) || ~ismember(schedule, ...
            ["round_robin","recruitment_sweep","population_target_sweep"])
        error("adaptive_optopatch:InvalidBlanketDepolarization", ...
            "blanket_depolarization.schedule must be round_robin, " + ...
            "recruitment_sweep or population_target_sweep.");
    end
    spec.schedule=schedule;
end
for name=["mod488_v","cycle_period_s","blanket_fraction","target_onset_guard_s"]
    if isfield(raw,name) && ~isempty(raw.(name))
        value=raw.(name);
        if ~isnumeric(value) || ~isscalar(value)
            error("adaptive_optopatch:InvalidBlanketDepolarization", ...
                "blanket_depolarization.%s must be a numeric scalar.",name);
        end
        spec.(name)=double(value);
    end
end
if ~spec.enabled
    if any(scheduled)
        error("adaptive_optopatch:BlanketSchedulerWithoutBlanketMode", ...
            "A %s acquisition requires blanket_depolarization.enabled=true.", ...
            schedulerTypes(find(scheduled,1)));
    end
    return
end

if spec.schedule=="recruitment_sweep"
    % Its whole point is that the blanket level changes from step to step,
    % so there is no one blanket command; the steps are the scheduler's.
    if isfinite(spec.mod488_v)
        error("adaptive_optopatch:InvalidBlanketDepolarization", ...
            "A blanket recruitment sweep steps its blanket level, so it " + ...
            "must not also declare a single blanket_depolarization.mod488_v.");
    end
elseif ~isfinite(spec.mod488_v) || spec.mod488_v<=0 || spec.mod488_v>5
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "blanket_depolarization.mod488_v must be an explicit blanket " + ...
        "command in (0,5] V. There is no default blanket voltage.");
end
if ~isfinite(spec.cycle_period_s) || spec.cycle_period_s<=0
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "blanket_depolarization.cycle_period_s must be positive.");
end
if ~isfinite(spec.blanket_fraction) || spec.blanket_fraction<=0 || ...
        spec.blanket_fraction>=1
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "blanket_depolarization.blanket_fraction must lie strictly " + ...
        "between 0 and 1.");
end
targetPhase=(1-spec.blanket_fraction)*spec.cycle_period_s;
if ~isfinite(spec.target_onset_guard_s) || spec.target_onset_guard_s<0 || ...
        spec.target_onset_guard_s>=targetPhase
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "blanket_depolarization.target_onset_guard_s must be at least 0 " + ...
        "and shorter than the %.4g ms target phase.",1000*targetPhase);
end

% The schedule and the acquisitions' scheduler are two spellings of one
% decision, so they are required to agree rather than one silently winning.
expectedScheduler="blanket_"+spec.schedule;
if any(scheduled) && any(schedulerTypes(scheduled)~=expectedScheduler)
    error("adaptive_optopatch:BlanketScheduleMismatch", ...
        "blanket_depolarization.schedule is %s, so every acquisition must " + ...
        "use the %s scheduler; this protocol has %s.",spec.schedule, ...
        expectedScheduler,strjoin(unique(schedulerTypes(scheduled)),", "));
end

type=string(protocol.artifact_type);
if type~="experiment_definition"
    spec.mask=validate_mask(raw);
end
if type=="experiment_definition"
    validate_definition(protocol,spec,scheduled);
elseif spec.schedule=="round_robin"
    spec.round=validate_round(raw,spec);
    require_one_photon_only(protocol);
else
    spec.sweep=validate_sweep(raw,spec);
    if spec.schedule=="recruitment_sweep"
        % Blanket only: no cell is targeted, so the logical segments are
        % null events and nothing may claim a target.
        if any(~protocol.events.is_null)
            error("adaptive_optopatch:InvalidBlanketDepolarization", ...
                "A blanket recruitment sweep delivers no targeted " + ...
                "stimulation, so every logical segment must be a null event.");
        end
    else
        require_one_photon_only(protocol);
    end
end
end

function require_one_photon_only(protocol)
if adaptive_optopatch.is_simultaneous_protocol(protocol) || ...
        any(protocol.events.stimulation_source~="1p_dmd")
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "Blanket depolarization supports serial 1P DMD target epochs only.");
end
end

function validate_definition(protocol,spec,scheduled)
if string(protocol.target_policy)~="multi_target_continuous"
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "Blanket depolarization requires target_policy multi_target_continuous.");
end
if ~all(scheduled)
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "With blanket depolarization enabled, every acquisition must use " + ...
        "a blanket scheduler: one programmed unit is what the DMD playlist " + ...
        "wraps, so an arbitrary event schedule cannot run.");
end
for k=1:numel(protocol.acquisitions)
    scheduler=adaptive_optopatch.acquisition_scheduler_spec(protocol.acquisitions(k));
    context="Acquisition "+string(protocol.acquisitions(k).acquisition_id);
    switch spec.schedule
        case "round_robin"
            require_whole_cycles(scheduler.epoch_duration_s,spec.cycle_period_s, ...
                context+" epoch_duration_s",1);
            require_whole_cycles(scheduler.inter_epoch_gap_s,spec.cycle_period_s, ...
                context+" inter_epoch_gap_s",1);
        case "recruitment_sweep"
            require_levels(scheduler.levels_v,context+" levels_v");
            require_whole_cycles(scheduler.step_duration_s,spec.cycle_period_s, ...
                context+" step_duration_s",1);
            require_whole_cycles(scheduler.pre_dark_s,spec.cycle_period_s, ...
                context+" pre_dark_s",0);
        otherwise
            require_levels(scheduler.levels_v,context+" levels_v");
            require_whole_cycles(scheduler.epoch_duration_s,spec.cycle_period_s, ...
                context+" epoch_duration_s",1);
            require_whole_cycles(scheduler.inter_epoch_gap_s,spec.cycle_period_s, ...
                context+" inter_epoch_gap_s",1);
    end
    require_whole_cycles(scheduler.pre_delay_s,spec.cycle_period_s, ...
        context+" pre_delay_s",0);
end
end

function require_levels(levels,label)
levels=double(levels(:));
if isempty(levels) || any(~isfinite(levels)) || any(levels<=0) || any(levels>5)
    error("adaptive_optopatch:InvalidBlanketSweepLevels", ...
        "%s must be an explicit, nonempty list of mod488 commands in " + ...
        "(0,5] V. No level is extrapolated or generated.",label);
end
if any(diff(levels)<0)
    error("adaptive_optopatch:InvalidBlanketSweepLevels", ...
        "%s must not decrease: the sweep steps upward so it can be " + ...
        "stopped at the first level that recruits cells.",label);
end
end

function mask=validate_mask(raw)
%VALIDATE_MASK The frozen blanket geometry of a resolved acquisition.
required=["source","cell_ids","target_indices","blue_mask_adjustment_pixels"];
if ~isfield(raw,"mask") || ~isstruct(raw.mask) || ~isscalar(raw.mask) || ...
        ~all(isfield(raw.mask,cellstr(required)))
    error("adaptive_optopatch:InvalidBlanketMask", ...
        "A resolved blanket acquisition must carry the cells its blanket " + ...
        "illuminates: %s.",strjoin(required,", "));
end
mask=raw.mask;
mask.source=string(mask.source);
mask.cell_ids=reshape(string(mask.cell_ids),[],1);
mask.target_indices=reshape(double(mask.target_indices),[],1);
mask.blue_mask_adjustment_pixels=double(mask.blue_mask_adjustment_pixels);
if mask.source~="stim_enabled_union"
    error("adaptive_optopatch:InvalidBlanketMask", ...
        "This build delivers the blanket through the Stim-enabled cells' " + ...
        "union; '%s' is not a geometry it knows.",mask.source);
end
if isempty(mask.cell_ids) || ...
        numel(mask.cell_ids)~=numel(mask.target_indices) || ...
        numel(unique(mask.cell_ids))~=numel(mask.cell_ids) || ...
        any(~isfinite(mask.target_indices) | mask.target_indices<1 | ...
            fix(mask.target_indices)~=mask.target_indices)
    error("adaptive_optopatch:InvalidBlanketMask", ...
        "The blanket union needs at least one cell, each named once with " + ...
        "a positive integer target index.");
end
if ~isscalar(mask.blue_mask_adjustment_pixels) || ...
        ~isfinite(mask.blue_mask_adjustment_pixels) || ...
        fix(mask.blue_mask_adjustment_pixels)~=mask.blue_mask_adjustment_pixels
    error("adaptive_optopatch:InvalidBlanketMask", ...
        "The blanket union's Blue mask adjustment must be a finite integer.");
end
end

function sweep=validate_sweep(raw,spec)
required=["start_s","levels_v","segment_duration_s","segments"];
if ~isfield(raw,"sweep") || ~isstruct(raw.sweep) || ~isscalar(raw.sweep) || ...
        ~all(isfield(raw.sweep,cellstr(required)))
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "A resolved blanket %s must carry its realized sweep: %s.", ...
        spec.schedule,strjoin(required,", "));
end
sweep=raw.sweep;
sweep.start_s=double(sweep.start_s);
sweep.levels_v=reshape(double(sweep.levels_v),[],1);
sweep.segment_duration_s=double(sweep.segment_duration_s);
require_levels(sweep.levels_v,"The realized sweep's levels_v");
require_whole_cycles(sweep.segment_duration_s,spec.cycle_period_s, ...
    "The realized segment duration",1);
require_whole_cycles(sweep.start_s,spec.cycle_period_s,"The realized sweep start",0);
segments=sweep.segments;
if ~istable(segments) || isempty(segments) || ...
        ~all(ismember(["segment_index","level_index","level_v","pulse_id"], ...
        string(segments.Properties.VariableNames)))
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "The realized sweep must list its segments with segment_index, " + ...
        "level_index, level_v and pulse_id.");
end
if ~isequal(double(segments.segment_index(:)),(1:height(segments))') || ...
        any(double(segments.level_index)<1) || ...
        any(double(segments.level_index)>numel(sweep.levels_v)) || ...
        any(abs(double(segments.level_v)- ...
            sweep.levels_v(double(segments.level_index)))>1e-12)
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "The realized sweep segments do not index their own level list.");
end
if spec.schedule=="population_target_sweep"
    if ~isfield(sweep,"population_cell_ids") || ...
            isempty(sweep.population_cell_ids)
        error("adaptive_optopatch:InvalidBlanketDepolarization", ...
            "A population-target sweep must archive the cells whose masks " + ...
            "form its union target.");
    end
    sweep.population_cell_ids=reshape(string(sweep.population_cell_ids),[],1);
    sweep.population_target_indices= ...
        reshape(double(sweep.population_target_indices),[],1);
    if numel(sweep.population_cell_ids)~=numel(sweep.population_target_indices)
        error("adaptive_optopatch:InvalidBlanketDepolarization", ...
            "Each population cell needs one target index.");
    end
end
end

function realized=validate_round(raw,spec)
required=["start_s","period_s","count","cell_ids","epoch_duration_s", ...
    "inter_epoch_gap_s"];
if ~isfield(raw,"round") || ~isstruct(raw.round) || ~isscalar(raw.round) || ...
        ~all(isfield(raw.round,cellstr(required)))
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "A resolved blanket acquisition must carry its realized round: %s.", ...
        strjoin(required,", "));
end
realized=raw.round;
realized.start_s=double(realized.start_s);
realized.period_s=double(realized.period_s);
realized.count=double(realized.count);
realized.cell_ids=reshape(string(realized.cell_ids),[],1);
realized.epoch_duration_s=double(realized.epoch_duration_s);
realized.inter_epoch_gap_s=double(realized.inter_epoch_gap_s);
if ~isscalar(realized.count) || realized.count<1 || fix(realized.count)~=realized.count
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "The realized round count must be a positive integer.");
end
if isempty(realized.cell_ids) || numel(unique(realized.cell_ids))~=numel(realized.cell_ids)
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "The realized round must name each target cell exactly once.");
end
require_whole_cycles(realized.epoch_duration_s,spec.cycle_period_s,"epoch_duration_s",1);
require_whole_cycles(realized.inter_epoch_gap_s,spec.cycle_period_s,"inter_epoch_gap_s",1);
require_whole_cycles(realized.start_s,spec.cycle_period_s,"round start",0);
expectedPeriod=numel(realized.cell_ids)*(realized.epoch_duration_s+realized.inter_epoch_gap_s);
if abs(realized.period_s-expectedPeriod)>1e-9
    error("adaptive_optopatch:InvalidBlanketDepolarization", ...
        "The realized round period %.6g s does not equal cells x " + ...
        "(epoch + gap) = %.6g s.",realized.period_s,expectedPeriod);
end
end

function require_whole_cycles(value,cycle,label,minimum)
cycles=value/cycle;
if ~isfinite(cycles) || abs(cycles-round(cycles))>1e-9*max(1,abs(cycles)) || ...
        round(cycles)<minimum
    error("adaptive_optopatch:BlanketTimingNotWholeCycles", ...
        "%s is %.6g ms, which must be a whole number (at least %d) of " + ...
        "%.6g ms modulation cycles.",label,1000*value,minimum,1000*cycle);
end
end

function [scheduled,types]=blanket_scheduled_acquisitions(protocol)
blanketTypes=["blanket_round_robin","blanket_recruitment_sweep", ...
    "blanket_population_target_sweep"];
scheduled=false(0,1); types=strings(0,1);
if ~isfield(protocol,"acquisitions") || ~isstruct(protocol.acquisitions)
    return
end
scheduled=false(numel(protocol.acquisitions),1);
types=strings(numel(protocol.acquisitions),1);
for k=1:numel(protocol.acquisitions)
    acquisition=protocol.acquisitions(k);
    if isfield(acquisition,"scheduler") && isstruct(acquisition.scheduler) && ...
            ~isempty(acquisition.scheduler) && isfield(acquisition.scheduler,"type")
        types(k)=string(acquisition.scheduler.type);
        scheduled(k)=ismember(types(k),blanketTypes);
    end
end
end
