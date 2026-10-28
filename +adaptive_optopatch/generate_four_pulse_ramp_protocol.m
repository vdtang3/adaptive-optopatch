function protocol=generate_four_pulse_ramp_protocol(options)
%GENERATE_FOUR_PULSE_RAMP_PROTOCOL Four 500 ms pulses, then a 1 s linear ramp.
%
%   protocol=GENERATE_FOUR_PULSE_RAMP_PROTOCOL(...) returns a
%   field-of-view-independent schema-4 definition delivering, to EVERY
%   Stim-enabled cell at once, on the ordinary non-dithered 1P path:
%
%       0.000-0.500 s   pulse 1 at PulseVoltageV
%       0.500-1.000 s   dark
%       1.000-1.500 s   pulse 2 at PulseVoltageV
%       1.500-2.000 s   dark
%       2.000-2.500 s   pulse 3 at PulseVoltageV
%       2.500-3.000 s   dark
%       3.000-3.500 s   pulse 4 at PulseVoltageV
%       3.500-4.000 s   dark
%       4.000-5.000 s   linear ramp, 0 V to RampEndVoltageV
%
%   relative to the start of stimulation. PreDelayS shifts all of it and
%   PostDelayS extends the recording past it, which is AO's existing
%   pre/post convention and why the ACQUISITION is longer than 5 s.
%
%   ONE MASK, ONE WAVEFORM, EVERY CELL. The target policy is
%   simultaneous_stimulation_enabled_cells, so resolution produces ONE
%   acquisition whose Blue pattern is the pixelwise union of every
%   Stim-enabled cell's adjusted mask - BUILD_SIMULTANEOUS_BLUE_MASK - and
%   the pulse/ramp train runs once over all of them. Nothing sequences
%   through cells, so the DMD is written once and holds that pattern for
%   the whole acquisition while its advance line sits at its declared
%   neutral.
%
%   NOT A DITHERED PROTOCOL, and deliberately so. It carries no
%   blanket_depolarization block, so blanket_depolarization_spec reports it
%   disabled, no blanket state table is built, the DMD holds one static
%   stimulation mask for the whole acquisition, and mod488 alone shapes the
%   intensity. Keeping that true is what
%   TestFourPulseRampProtocol asserts; see also BLANKET_DEPOLARIZATION_SPEC
%   for the mode this one is not.
%
%   THE RAMP IS A WAVEFORM, NOT A STAIRCASE. The existing "ramp" protocols -
%   GENERATE_WHOLE_FOV_RAMP_PROTOCOL and GENERATE_SINGLE_CELL_RAMP_PROTOCOL -
%   are series of short rectangular pulses at stepped voltages with dark
%   gaps between them, which is a ramp in the sense of a voltage SERIES.
%   This one is a continuous linear rise on mod488, so it is a different
%   thing and says so with an explicit event column rather than by being a
%   staircase with the gaps removed. See BUILD_LUMINOS_MIXED_WAVEFORM_CONFIG
%   for how the two event kinds become one mod488 record.
%
%   AMPLITUDES ARE GLOBAL AND REQUIRED. Both are mod488 command volts in
%   (0,5], the one amplitude unit this package has; nothing here applies an
%   absolute calibration. The four squares share PulseVoltageV; the ramp
%   starts at 0 V and reaches RampEndVoltageV on the last sample it owns.
%
%   Neither may be left unset. Every other 1P protocol lets NaN fall
%   through to the target cell's own selected_blue_voltage_v, which works
%   because every event names one cell. Here one waveform drives a union of
%   cells with different calibrations, so there is no per-cell voltage to
%   fall back TO - picking one cell's would silently apply it to all of
%   them. The protocol says what it commands, or it is refused.
%
%   See also GENERATE_WHOLE_FOV_RAMP_PROTOCOL, RESOLVE_PROTOCOL.
arguments
    options.PulseVoltageV (1,1) double = NaN
    options.RampEndVoltageV (1,1) double = NaN
    options.PulseDurationS (1,1) double {mustBePositive} = 0.500
    options.GapDurationS (1,1) double {mustBePositive} = 0.500
    options.PulseCount (1,1) double {mustBePositive,mustBeInteger} = 4
    options.RampDurationS (1,1) double {mustBePositive} = 1.000
    options.PreDelayS (1,1) double {mustBeNonnegative} = 0.100
    options.PostDelayS (1,1) double {mustBeNonnegative} = 0.100
    options.ProtocolId (1,1) string = "four_pulse_ramp"
end
% Both required, and both checked against the (0,5] mod488 range the rig
% profile declares. See the AMPLITUDES note above for why an unset voltage
% cannot mean "defer to the cell" here.
validate_voltage(options.PulseVoltageV,"PulseVoltageV");
validate_voltage(options.RampEndVoltageV,"RampEndVoltageV");

n=options.PulseCount;
slot=options.PulseDurationS+options.GapDurationS;
pulseOnset=options.PreDelayS+(0:n-1)'*slot;
rampOnset=options.PreDelayS+n*slot;

pulse_id=(1:n+1)';
condition_id=[repmat("square",n,1);"ramp"];
stimulation_source=repmat("1p_dmd",n+1,1);
onset_s=[pulseOnset;rampOnset];
duration_s=[repmat(options.PulseDurationS,n,1);options.RampDurationS];
is_null=false(n+1,1);
command_voltage_v=[repmat(options.PulseVoltageV,n,1);options.RampEndVoltageV];
blue_mask_adjustment_pixels=nan(n+1,1);
% The one column that distinguishes the two kinds. "rectangular" is the
% default everywhere it is absent, so every protocol written before this
% one still means exactly what it meant.
command_waveform=[repmat("rectangular",n,1);"linear_ramp"];
events=table(pulse_id,condition_id,stimulation_source,onset_s,duration_s, ...
    is_null,command_voltage_v,blue_mask_adjustment_pixels,command_waveform);

acquisition=struct("acquisition_id","four_pulse_ramp", ...
    "events",events,"parameters",struct, ...
    "event_order_realized",true,"target_repetitions",1, ...
    "acquisition_duration_s", ...
        rampOnset+options.RampDurationS+options.PostDelayS);
protocol=struct("schema_version","4.0.0", ...
    "artifact_type","experiment_definition", ...
    "protocol_id",options.ProtocolId, ...
    "protocol_type","four_pulse_ramp", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    ... % ONE acquisition for all of them, whose Blue pattern is the union
    ... % of every Stim-enabled cell's mask. That is what makes the DMD
    ... % hold a single static pattern for the whole acquisition and the
    ... % pulse/ramp train run once rather than once per cell.
    "target_policy","simultaneous_stimulation_enabled_cells", ...
    "event_order","ordered","random_seed",0, ...
    ... % No fov_cell tier: a union of cells has no single per-cell
    ... % calibration to resolve against, which is why the amplitudes are
    ... % required above.
    "parameter_sources",struct("command_voltage_v", ...
        ["event","acquisition","protocol"]), ...
    "parameters",struct,"acquisitions",acquisition);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function validate_voltage(value,name)
if ~isfinite(value) || value<=0 || value>5
    error("adaptive_optopatch:InvalidFourPulseRampVoltage", ...
        "%s must be an explicit mod488 command in (0,5] V. This " + ...
        "protocol drives every Stim-enabled cell through one union mask " + ...
        "with one waveform, so there is no per-cell Blue calibration for " + ...
        "an unset voltage to defer to.",name);
end
end
