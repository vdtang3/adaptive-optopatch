# Pulse protocols

Pulse-protocol files own experimental design and emit explicit event timing.
Most reusable protocols do not name cells: the current FOV's **Stim**
checkboxes select their targets when a plan is frozen. The two constrained
round-robin screens are deliberately FOV-specific and contain their literal
target order and onset times. Adaptive Optopatch maps those schedules to
hardware without changing their timing, balance, recovery rule, or
randomization.

Generated artifacts use protocol schema `4.0.0`. Every event explicitly owns
`stimulation_source` (`1p_dmd`, `2p_spiral`, or `none`). Older protocol files are
intentionally rejected and must be regenerated from their source scripts.

## Included generators

| Script | Intent | Target policy | Event order |
|---|---|---|---|
| `create_single_cell_ramp_protocol.m` | Core: ascending explicit Blue-voltage blocks, 10 ms | `each_stimulation_enabled_cell` | ordered |
| `create_connectivity_round_robin_protocol.m` | Core: connectivity screen, 10 ms single pulses | `multi_target_continuous` | randomized |
| `create_stp_screen_protocol.m` | Core: short-term plasticity screen, 5 pulses at 20 Hz | `multi_target_continuous` | randomized |
| `create_blue_dmd_mask_titration_protocol.m` | Multiple Blue-mask adjustments within each cell's acquisition | `each_stimulation_enabled_cell` | randomized |
| `create_dmd_flut_wrap_test.m` | Three-slot/eight-trigger FLUT wrap hardware diagnostic | `multi_target_continuous` | ordered |
| `create_custom_event_protocol.m` | Minimal hand-written schema-4 example | `each_stimulation_enabled_cell` | ordered |
| `create_mixed_1p_2p_test_protocol.m` | Conservative interleaved 1P/2P commissioning acquisition | `each_stimulation_enabled_cell` | ordered |

## The three core 1P experiments

They share a 10 ms Blue pulse on purpose: the per-cell voltage the calibration
ramp stores is then the calibration for the pulse the screens actually use.

Connectivity (`create_connectivity_round_robin_protocol.m`):

```matlab
target_cell_ids = compose("cell_%03d", (1:10)');
pulses_per_cell = 1000;                     % 1500 for the higher-SNR version
pulse_duration_s = 0.010;
preferred_global_spacing_s = 0.020;
minimum_same_cell_post_pulse_gap_s = 0.100; % after the pulse ENDS
```

A cell is revisited no sooner than 110 ms after its previous onset. Ten cells
at the preferred 20 ms cadence keep the timeline continuously occupied:
10 000 events, about 200 s.

Short-term plasticity (`create_stp_screen_protocol.m`):

```matlab
target_cell_ids = compose("cell_%03d", (1:10)');
trains_per_cell = 300;                        % n at each of P1..P5
pulses_per_train = 5;
frequency_hz = 20;
pulse_duration_s = 0.010;
preferred_inter_train_gap_s = 0.020;          % to a DIFFERENT cell's P1
minimum_same_cell_post_train_gap_s = 1.000;   % after this cell's own P5 ENDS
```

A default train runs 0 / 50 / 100 / 150 / 200 ms and ends at 210 ms, so a cell
starts another train no sooner than 1.210 s after its previous train started.
Six or more cells keep the timeline continuously occupied; ten cells give
3000 trains, 15 000 events, about 690 s.

The name is STP rather than STF because the screen measures facilitation **or**
depression.

### Train granularity, and why

Different targets are interleaved at TRAIN granularity only. One cell's whole
P1..P5 train completes before another cell's train begins, and the schedule
deliberately never contains

```text
ROI1-P1, ROI2-P1, ROI1-P2, ROI2-P2, ...
```

Pulse-level interleaving would repeat a millisecond-scale spike pairing between
the same two stimulated neurons hundreds of times, which is an STDP induction
protocol. The code models no plasticity; it only preserves the whole-train
scheduling decision, and `TestStpScreenProtocol` asserts that every train is an
uninterrupted block on the timeline.

Scripts write to `pulse-protocols/generated/` by default and leave the
definition in the workspace as `protocol`. Generated MAT files are experiment
inputs and are ignored by Git; retain the source script and archive the exact
definition and frozen acquisition schedules with the run.

## Target policies

`each_stimulation_enabled_cell` applies every explicit acquisition definition
separately to every executable Stim-enabled cell. One acquisition definition
and eight selected cells therefore resolve to eight actual acquisitions. A
two-entry definition resolves to sixteen. The Blue voltage ramp and Blue-mask
titrations use this policy.

`multi_target_continuous` produces one actual multi-target acquisition for each
explicit acquisition definition. Targets vary event-by-event. The connectivity
and STP generators write those target IDs and all event times explicitly; every
named target must be stimulation-enabled in the selected FOV. This is the
policy that makes the STP screen one continuous acquisition covering every
cell, rather than the whole 300-train experiment repeated once per cell.

These are the only policies. Reusable definitions normally omit
`target_cell_id`; a FOV-specific explicit multi-target schedule may contain it
when target order is part of the experimental design. Record and Stim are
independent: Record controls Orange-mask inclusion, while Stim determines
whether a named target is physically available for stimulation.

## Explicit acquisitions

Acquisition boundaries are always written by the experimenter and are never
inferred from parameter vectors. Every definition contains an `acquisitions`
struct array, and every entry becomes either one acquisition or one acquisition
per selected cell according to the target policy. One actual acquisition is
always one manifest row.

For example, an Orange expansion titration must explicitly define separate
entries:

```matlab
for k=1:numel([0 1 2 3 4])
    acquisitions(k)=base_acquisition;
    acquisitions(k).acquisition_id="orange_"+string(k-1);
    acquisitions(k).parameters.orange_expansion_pixels=k-1;
end
```

Setting `orange_expansion_pixels=[0 1 2 3 4]` is invalid. The resolver reports
the unsupported vector; it does not split or merge acquisitions.

## Parameter resolution

Every required value follows the same precedence:

```text
event override
    > acquisition override
    > protocol override
    > per-cell FOV value
    > GUI global default
    > error
```

The resolved schedule stores literal values and provenance such as `event`,
`acquisition`, `protocol`, `fov_cell`, or `gui`. No runner interprets placeholders
such as “use GUI value.” A cell may validly have `Stim=true` and
`selected_blue_voltage_v=NaN`; an explicit-voltage ramp still resolves. The
connectivity and STP screens deliberately leave `command_voltage_v = NaN` on
every event so resolution reaches `fov_cell`, so every selected cell must have
a positive finite Blue voltage in the FOV. The schedulers accept an explicit
per-target override, but the shipped scripts do not use it: NaN is never
silently converted into a voltage, and `resolve_protocol` keeps owning
precedence.

### `command_voltage_v` in a 2P protocol

For `2p_spiral` the command voltage is the Chameleon Pockels command, and it is
owned by the protocol artifact alone:

```text
event > acquisition > protocol > error
```

`fov_cell` and `gui` are not consulted. The `fov_cell` tier for this parameter
is `selected_blue_voltage_v`, a per-cell 488 nm calibration that must never
become a Pockels command, and a GUI default must never quietly stand in for a
missing 2P voltage. A definition cannot widen this back with its own
`parameter_sources`. A `2p_spiral` protocol that leaves its command
unspecified is rejected when the protocol is checked against the mode, before
any plan is frozen.

Typical sources are:

| Experiment | Voltage | Blue mask | Orange mask | Targets |
|---|---|---|---|---|
| Ramp | protocol events | GUI | GUI | Stim checkboxes |
| Blue-mask titration | per-cell FOV | protocol events | GUI | Stim checkboxes |
| Connectivity round robin | per-cell FOV | GUI | GUI | explicit `target_cell_ids` |
| STP screen | per-cell FOV | GUI | GUI | explicit `target_cell_ids` |

## Parameter scopes

Scope is centrally defined by `adaptive_optopatch.protocol_parameter_metadata`.

- Event-scoped: command voltage, pulse duration, Blue DMD-mask adjustment, and
  resolved target identity.
- Acquisition-scoped: Orange DMD-mask expansion, 2P spiral radius, and 2P
  spiral density.
- Run/rig-scoped: camera ROI and frame rate, DAQ routing, coordinate transforms,
  and permission to extrapolate calibration.

An acquisition-scoped parameter cannot appear as a varying event column. For
example, event-level Orange expansion fails with: “Orange DMD mask expansion
cannot vary within one acquisition. Define separate acquisition entries
explicitly.”

## Ordering and seeds

`event_order` is required and is either `ordered` or `randomized`.

- `ordered` preserves generator order. The voltage ramp uses ascending voltage
  blocks.
- `randomized` requests a reproducible shuffle using `random_seed`.

The presence of a seed does not request shuffling. Ordered protocols may still
use the seed to realize jittered dark intervals. Requested shuffles and interval
jitter are realized while generating or resolving the schedule, before
acquisition. Frozen events therefore contain their actual order, target,
voltage, onset, duration, mask adjustment, and realized interval. Preview,
freeze, run, and resume do not draw new random values.

## Definition schema

A new generator returns one scalar struct with these fields:

```matlab
protocol.schema_version = "4.0.0";
protocol.artifact_type = "experiment_definition";
protocol.protocol_id = "my_protocol";
protocol.protocol_type = "my_experiment_type";
protocol.target_policy = "each_stimulation_enabled_cell";
protocol.event_order = "ordered";
protocol.random_seed = 1;
protocol.parameters = struct;       % optional protocol-level overrides
protocol.acquisitions = acquisition;
```

Each acquisition requires `acquisition_id`, `parameters`, and an `events`
table. Event tables require:

```text
pulse_id
condition_id
stimulation_source
onset_s
duration_s
is_null
command_voltage_v
blue_mask_adjustment_pixels
```

Use `NaN` for a value that should fall through precedence. Add cell IDs only to
an already realized, FOV-specific `multi_target_continuous` schedule.
Set `event_order_realized=true` when the generator has already materialized the
requested order. AO never reshuffles an explicit target schedule.

## Constrained round-robin schedulers

Two pure helpers in the `adaptive_optopatch` package realize the screens:

- `generate_constrained_round_robin_schedule` schedules single pulses for the
  connectivity screen.
- `generate_constrained_stp_round_robin_schedule` schedules whole trains for
  the STP screen.

Both give every target an exact quota, select randomly among the eligible
targets with the largest remaining quota using a protocol-local `RandStream`,
use other targets while one is inside its recovery window, and advance time
only when nothing is eligible. The scripts record the realized order, onset and
offset of every event plus spacing, idle-time, and seed metadata. AO performs
hardware checks but does not recreate or repair these schedules.

## FLUT wrap hardware diagnostic

`create_dmd_flut_wrap_test.m` creates a deliberately diagnostic-only schedule:
three distinct target masks are uploaded and the programmed playlist is exactly
`[1 2 3]`, while the DAQ emits eight event triggers. The expected cyclic result
is `[1 2 3 1 2 3 1 2]`. The runner records both vectors separately and refuses
to run this diagnostic on a non-FLUT DMD. Software tests verify configuration,
not physical wrap behavior; run it only on a fluorescent slide or safe test
preparation and inspect the acquired target sequence.

Validate and save with:

```matlab
protocol = adaptive_optopatch.normalize_protocol(protocol);
adaptive_optopatch.save_protocol(output_path,protocol);
```

The frozen `resolved_acquisition` schema adds concrete target IDs and indices,
concrete values, source columns, acquisition parameters, and acquisition
duration. Only this resolved form is passed to an acquisition runner.
