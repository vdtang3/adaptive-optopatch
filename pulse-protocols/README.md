# Pulse protocols

Pulse-protocol files describe experimental intent without naming cells. Load a
generated `protocol.mat` in Adaptive Optopatch; when the plan is built, the
current FOV's **Stim** checkboxes select the cells and the resolver freezes one
or more concrete acquisition schedules. Runners execute those schedules
literally.

Generated artifacts use protocol schema `3.0.0`. Older protocol files are
intentionally rejected and must be regenerated from their source scripts.

## Included generators

| Script | Intent | Target policy | Event order |
|---|---|---|---|
| `create_connectivity_screen_protocol.m` | Screen pulses with reproducible interval jitter | `each_stimulation_enabled_cell` | ordered |
| `create_regular_pulse_protocol.m` | Fixed-rate pulse train | `each_stimulation_enabled_cell` | ordered |
| `create_single_cell_ramp_protocol.m` | Ascending explicit Blue-voltage blocks | `each_stimulation_enabled_cell` | ordered |
| `create_blue_dmd_mask_titration_protocol.m` | Multiple Blue-mask adjustments within each cell's acquisition | `each_stimulation_enabled_cell` | randomized |
| `create_stf_frequency_mix_protocol.m` | Mixed single, 50 Hz, and 100 Hz trains | `each_stimulation_enabled_cell` | randomized |
| `create_paired_pulse_protocol.m` | Mixed paired-pulse intervals | `each_stimulation_enabled_cell` | randomized |
| `create_round_robin_protocol.m` | One continuous, interleaved multi-cell acquisition | `multi_target_continuous` | randomized |
| `create_custom_event_protocol.m` | Minimal hand-written schema-3 example | `each_stimulation_enabled_cell` | ordered |

Scripts write to `pulse-protocols/generated/` by default and leave the
definition in the workspace as `protocol`. Generated MAT files are experiment
inputs and are ignored by Git; retain the source script and archive the exact
definition and frozen acquisition schedules with the run.

## Target policies

`each_stimulation_enabled_cell` applies every explicit acquisition definition
separately to every executable Stim-enabled cell. One acquisition definition
and eight selected cells therefore resolve to eight actual acquisitions. A
two-entry definition resolves to sixteen. Voltage ramps, Blue-mask titrations,
connectivity screens, and STF use this policy.

`multi_target_continuous` produces one actual multi-target acquisition for each
explicit acquisition definition. Targets vary event-by-event. Round robin uses
this policy.

These are the only policies. Reusable definitions never contain
`target_cell_id`; biological identity comes from the current FOV at plan-build
time. Record and Stim are independent: Record controls Orange-mask inclusion,
while Stim controls target selection.

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
`selected_blue_voltage_v=NaN`; an explicit-voltage ramp still resolves. A
round-robin definition supplies no voltage, so every selected cell must have a
positive finite Blue voltage in the FOV.

Typical sources are:

| Experiment | Voltage | Blue mask | Orange mask | Targets |
|---|---|---|---|---|
| Ramp | protocol events | GUI | GUI | Stim checkboxes |
| Blue-mask titration | per-cell FOV | protocol events | GUI | Stim checkboxes |
| Round robin | per-cell FOV | GUI | GUI | Stim checkboxes |

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
protocol.schema_version = "3.0.0";
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
onset_s
duration_s
is_null
command_voltage_v
blue_mask_adjustment_pixels
```

Use `NaN` for a value that should fall through precedence. Do not add cell IDs.
Set `event_order_realized=true` when the generator has already materialized the
requested order. A sequencing template such as round robin may set it false so
the resolver materializes target order once, using the seed.

Validate and save with:

```matlab
protocol = adaptive_optopatch.normalize_protocol(protocol);
adaptive_optopatch.save_protocol(output_path,protocol);
```

The frozen `resolved_acquisition` schema adds concrete target IDs and indices,
concrete values, source columns, acquisition parameters, and acquisition
duration. Only this resolved form is passed to an acquisition runner.
