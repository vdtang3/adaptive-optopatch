function protocol=generate_blanket_recruitment_sweep_protocol(levelsV,options)
%GENERATE_BLANKET_RECRUITMENT_SWEEP_PROTOCOL Step the blanket up, briefly, to find recruitment.
%
%   protocol=GENERATE_BLANKET_RECRUITMENT_SWEEP_PROTOCOL(levelsV,...) returns
%   a field-of-view-independent schema-4 definition that presents each
%   blanket level in LEVELSV for StepDurationS, back to back, after a dark
%   baseline, and then ends.
%
%   WHAT IT DELIVERS. The same flickered blanket the experiment uses: each
%   1 ms cycle is 0.2 ms of the full-FOV mask at that step's level and
%   0.8 ms of the blank mask at 0 V, locked to the camera frame. No targeted
%   stimulation at any point, so every logical segment is a null event and
%   the step's level lives in the archived sweep block. The blanket dose is
%   a duty cycle at one AOTF voltage, never a continuous low voltage.
%
%   WHY THE STEPS ARE SHORT. The sweep cannot be stopped once it is running,
%   so a level that turns out to be suprathreshold is held for one step and
%   no longer, and the acquisition ends with the last step rather than
%   holding at the highest level.
%
%   LEVELSV IS EXPLICIT and must not decrease. Nothing here extrapolates a
%   range or invents a level, and the generator refuses a level outside
%   (0,5] V.
%
%   This protocol reports what was delivered. It makes no recommendation
%   about which level to use.
%
%   See also BLANKET_DEPOLARIZATION_SPEC,
%   GENERATE_BLANKET_POPULATION_TARGET_SWEEP_PROTOCOL.
arguments
    levelsV (:,1) double
    options.StepDurationS (1,1) double {mustBePositive} = 1.0
    options.PreDarkS (1,1) double {mustBeNonnegative} = 1.0
    options.CyclePeriodS (1,1) double {mustBePositive} = 0.001
    options.BlanketFraction (1,1) double = 0.20
    options.TargetOnsetGuardS (1,1) double {mustBeNonnegative} = 50e-6
    options.PostDelayS (1,1) double {mustBeNonnegative} = 0
    options.ProtocolId (1,1) string = "blanket_recruitment_sweep"
end
scheduler=struct("type","blanket_recruitment_sweep", ...
    "levels_v",levelsV, ...
    "step_duration_s",options.StepDurationS, ...
    "pre_dark_s",options.PreDarkS, ...
    "chunk_index",1,"chunk_count",1);
acquisition=struct("acquisition_id","blanket_recruitment_sweep", ...
    "events",template_event("blanket_recruitment_sweep",options.StepDurationS), ...
    "parameters",struct, ...
    "event_order_realized",true,"target_repetitions",1, ...
    "post_delay_s",options.PostDelayS,"scheduler",scheduler);
blanket=struct("enabled",true, ...
    ... % No single blanket command: the steps are the blanket levels.
    "mod488_v",NaN, ...
    "cycle_period_s",options.CyclePeriodS, ...
    "blanket_fraction",options.BlanketFraction, ...
    "target_onset_guard_s",options.TargetOnsetGuardS, ...
    "schedule","recruitment_sweep");
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition", ...
    "protocol_id",options.ProtocolId, ...
    "protocol_type","blanket_recruitment_sweep", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "target_policy","multi_target_continuous", ...
    "event_order","ordered","random_seed",0, ...
    "parameter_sources",struct("command_voltage_v", ...
        ["event","acquisition","protocol","fov_cell"]), ...
    "parameters",struct, ...
    "blanket_depolarization",blanket, ...
    "acquisitions",acquisition);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function events=template_event(conditionId,stepDurationS)
% The event tier of parameter resolution, not a segment. A recruitment
% sweep's segments are null, so this carries no voltage: the step levels are
% the scheduler's.
pulse_id=1;
condition_id=string(conditionId);
stimulation_source="none";
onset_s=NaN;
duration_s=stepDurationS;
is_null=true;
command_voltage_v=0;
blue_mask_adjustment_pixels=NaN;
events=table(pulse_id,condition_id,stimulation_source,onset_s,duration_s, ...
    is_null,command_voltage_v,blue_mask_adjustment_pixels);
end
