function report=describe_blanket_commissioning(protocol,options)
%DESCRIBE_BLANKET_COMMISSIONING What a blanket run should do, trigger by trigger.
%   report=DESCRIBE_BLANKET_COMMISSIONING(protocol) builds the state table
%   the run would install and returns the EXPECTED sequence in the form a
%   person at the rig can check against a photodiode trace, a camera movie
%   or the ALP's own counters:
%
%     the pattern the DMD must already hold before the first trigger;
%     every external trigger, when it fires and which mask it selects;
%     how many advances the whole acquisition emits;
%     which mask is lit during each blue-on interval, and at what level;
%     where the playlist must be left when the acquisition ends.
%
%   It computes nothing of its own. Everything comes from
%   BUILD_BLANKET_STATE_TABLE and BUILD_BLANKET_DMD_SEQUENCE_PLAN, the same
%   two functions the runner uses, so a commissioning sheet that disagrees
%   with the rig is evidence about the rig rather than about this file.
%
%   NOT A MEASUREMENT. This is the intended sequence. What the DMD actually
%   did is read back by READ_DMD_PROJECTION_PROGRESS and checked by
%   VERIFY_DMD_ADVANCE_COUNT, and what the preparation actually saw is the
%   recording. Comparing those three is the commissioning.
%
%   See also BUILD_BLANKET_STATE_TABLE, VERIFY_DMD_ADVANCE_COUNT,
%   docs/commissioning/blanket-depolarization.md.
arguments
    protocol (1,1) struct
    options.SampleRateHz (1,1) double = 200000
    options.CameraFramePeriodS (1,1) double = 0.001
    options.Print (1,1) logical = true
    % How many triggers to list individually. The whole acquisition is
    % summarised whatever this is; listing tens of thousands of rows helps
    % nobody standing at a rig.
    options.MaximumListedTriggers (1,1) double {mustBePositive} = 24
    % The target bundle, when one is available. With it the real planner
    % answers the playlist questions; without it they are derived from the
    % mask-key sequence, which is the same rule applied to names instead of
    % pixels. Two different masks that happen to rasterise identically
    % would be deduplicated by the planner and not here, so a sheet printed
    % without a bundle can only over-estimate the playlist length.
    options.Targets struct = struct([])
end
protocol=adaptive_optopatch.normalize_protocol(protocol);
blanket=adaptive_optopatch.blanket_depolarization_spec(protocol);
if ~blanket.enabled
    error("adaptive_optopatch:BlanketDepolarizationDisabled", ...
        "This protocol does not enable blanket depolarization, so there " + ...
        "is no blanket sequence to describe.");
end
stateTable=adaptive_optopatch.build_blanket_state_table(protocol, ...
    options.SampleRateHz,options.CameraFramePeriodS);
rate=stateTable.sample_rate_hz;
states=stateTable.states;

% One row per state of the programmed unit: when its trigger fires, what
% the DMD shows afterwards, and what mod488 does while it is up.
unit=table;
unit.state_index=states.state_index;
unit.trigger_sample=stateTable.round_start_sample+states.start_sample;
unit.trigger_time_s=unit.trigger_sample/rate;
unit.state_type=states.state_type;
unit.mask_key=states.mask_key;
unit.duration_us=1e6*states.duration_samples/rate;
unit.mod488_v=states.mod488_v;
unit.dark_lead_us=1e6*states.mod488_guard_samples/rate;
unit.lit_us=1e6*(states.duration_samples-states.mod488_guard_samples)/rate;
unit.segment=states.segment;
unit.target_cell_id=states.target_cell_id;

report=struct("schema_version","1.0.0", ...
    "protocol_id",string(protocol.protocol_id), ...
    "schedule",string(stateTable.schedule), ...
    "sample_rate_hz",rate, ...
    "camera_frame_period_ms",1000*stateTable.camera_frame_samples/rate, ...
    "cycle_period_ms",1000*stateTable.cycle_samples/rate, ...
    "blanket_phase_ms",1000*stateTable.blanket_samples/rate, ...
    "target_phase_ms",1000*stateTable.target_samples/rate, ...
    "blanket_duty_fraction",stateTable.blanket_samples/stateTable.cycle_samples, ...
    "target_onset_guard_us",1e6*stateTable.target_onset_guard_samples/rate, ...
    "target_lit_fraction", ...
        (stateTable.target_samples-stateTable.target_onset_guard_samples)/ ...
        stateTable.cycle_samples, ...
    "dmd_trigger_width_us",1e6*stateTable.dmd_trigger_width_samples/rate, ...
    "dmd_trigger_lead_us",1e6*stateTable.dmd_trigger_lead_samples/rate, ...
    "blanket_mod488_v",stateTable.blanket_mod488_v, ...
    "states_per_unit",stateTable.states_per_round, ...
    "unit_repeats",stateTable.round_count, ...
    "expected_trigger_count",stateTable.expected_trigger_count, ...
    "acquisition_duration_s",double(protocol.acquisition_duration_s), ...
    "first_trigger_time_s",stateTable.round_start_sample/rate, ...
    "last_trigger_time_s",(stateTable.final_sample-states.duration_samples(end))/rate, ...
    "unit",unit);

% The playlist the ALP is left holding. The real planner needs a target
% bundle to rasterise masks with; this sheet is about timing, so the
% playlist LENGTH is derived from the same rule the planner uses - the
% shortest unit the mask-key sequence repeats, which must divide the unit
% or wrapping would not reproduce it. Pass a bundle to have the planner
% itself answer, which is what a commissioning run does.
report.playlist_length=mask_sequence_period(states.mask_key);
report.playlist_wraps=true;
report.unique_mask_count=numel(unique(states.mask_key));
report.playlist_source="mask_key period";
if ~isempty(options.Targets)
    plan=adaptive_optopatch.build_blanket_dmd_sequence_plan( ...
        protocol,options.Targets,stateTable);
    report.playlist_length=plan.programmed_playlist_length;
    report.playlist_wraps=plan.playlist_wraps;
    report.unique_mask_count=plan.unique_mask_count;
    report.playlist_source="build_blanket_dmd_sequence_plan";
end
% Where the playlist must sit when the run ends: the ALP advances on each
% trigger, so after N triggers of an L-entry wrapping playlist it holds
% entry mod(N, L) counted from the armed entry.
report.expected_final_playlist_entry= ...
    mod(report.expected_trigger_count,report.playlist_length)+1;

if options.Print
    print_report(report,options.MaximumListedTriggers);
end
end

function period=mask_sequence_period(keys)
%MASK_SEQUENCE_PERIOD The shortest unit the mask sequence repeats.
%   The same rule build_blanket_dmd_sequence_plan applies to slot indices:
%   the period must divide the unit, or wrapping the playlist would not
%   reproduce the sequence.
keys=reshape(string(keys),[],1); n=numel(keys); period=n;
for p=1:n
    if mod(n,p)~=0, continue; end
    if isequal(keys,repmat(keys(1:p),n/p,1)), period=p; return; end
end
end

function print_report(report,maximumRows)
fprintf("\n=== Blanket commissioning sheet: %s (%s) ===\n", ...
    report.protocol_id,report.schedule);
fprintf("  DAQ %.0f Hz; camera frame %.4g ms; cycle %.4g ms\n", ...
    report.sample_rate_hz,report.camera_frame_period_ms,report.cycle_period_ms);
fprintf("  blanket %.4g ms (%.1f%% duty) at %.3f V, then target %.4g ms\n", ...
    report.blanket_phase_ms,100*report.blanket_duty_fraction, ...
    report.blanket_mod488_v,report.target_phase_ms);
fprintf("  target-onset guard %.4g us; target lit %.1f%% of each cycle\n", ...
    report.target_onset_guard_us,100*report.target_lit_fraction);
fprintf("  DMD trigger %.4g us wide, %.4g us before its mod488 level\n", ...
    report.dmd_trigger_width_us,report.dmd_trigger_lead_us);
fprintf("\n  BEFORE THE FIRST TRIGGER the DMD must already show playlist\n");
fprintf("  entry 1 (%s). Set_Playlist re-arms there; a stray edge between\n", ...
    report.unit.mask_key(1));
fprintf("  arming and the first trigger shifts everything that follows.\n");
fprintf("\n  %d states per unit x %d repeat(s) = %d external triggers\n", ...
    report.states_per_unit,report.unit_repeats,report.expected_trigger_count);
fprintf("  playlist %d entries, wraps=%d, %d unique mask(s)\n", ...
    report.playlist_length,report.playlist_wraps,report.unique_mask_count);
fprintf("  first trigger %.6f s, last %.6f s, acquisition %.6f s\n", ...
    report.first_trigger_time_s,report.last_trigger_time_s, ...
    report.acquisition_duration_s);
fprintf("  after the run the playlist should hold entry %d\n", ...
    report.expected_final_playlist_entry);
rows=min(height(report.unit),maximumRows);
fprintf("\n  First %d trigger(s) of the programmed unit:\n",rows);
disp(report.unit(1:rows,:));
if height(report.unit)>rows
    fprintf("  ... %d further state(s) in the unit.\n", ...
        height(report.unit)-rows);
end
fprintf("  The unit then repeats %d time(s), identically.\n\n", ...
    report.unit_repeats);
end
