% 4 PULSES + RAMP — an ordinary, non-dithered 1P protocol.
%
% ALL Stim-enabled cells at once, through one static union mask, relative
% to the start of stimulation:
%
%     0.000-0.500 s   pulse 1   pulse_voltage_v
%     0.500-1.000 s   dark
%     1.000-1.500 s   pulse 2   pulse_voltage_v
%     1.500-2.000 s   dark
%     2.000-2.500 s   pulse 3   pulse_voltage_v
%     2.500-3.000 s   dark
%     3.000-3.500 s   pulse 4   pulse_voltage_v
%     3.500-4.000 s   dark
%     4.000-5.000 s   ramp      0 V rising linearly to ramp_end_voltage_v
%
% ONE MASK, ONE WAVEFORM. The Blue pattern is the pixelwise union of every
% Stim-enabled cell's mask, written once, and the pulse/ramp train runs
% once over all of them. Nothing sequences through cells.
%
% NO BLANKET DITHERING. This protocol carries no blanket_depolarization
% block, so there is no 20/80 cycle, no blanket mask, no millisecond DMD
% alternation and no target-onset guard. The Blue DMD holds that one static
% mask for the whole acquisition and mod488 alone shapes the intensity,
% which is the ordinary 1P path every other non-dithered protocol uses.
%
% The ramp is a continuous rise on mod488, not the stepped voltage SERIES
% that create_whole_fov_ramp_protocol and the single-cell ramp deliver.
%
% ---- EXPERIMENTAL DESIGN (edit these) --------------------------------------
pulse_voltage_v=NaN;        % REQUIRED: the four squares' mod488 command, (0,5] V
ramp_end_voltage_v=NaN;     % REQUIRED: where the ramp finishes, (0,5] V
pulse_duration_s=0.500;
gap_duration_s=0.500;
pulse_count=4;
ramp_duration_s=1.000;
pre_delay_s=0.100;          % dark recording before the first pulse
post_delay_s=0.100;         % dark recording after the ramp
% ---------------------------------------------------------------------------
%
% Both voltages are REQUIRED. One waveform drives a union of cells with
% different Blue calibrations, so there is no per-cell voltage for an unset
% one to defer to; picking one cell's would silently apply it to all.

if ~isfinite(pulse_voltage_v) || ~isfinite(ramp_end_voltage_v)
    error("Set pulse_voltage_v and ramp_end_voltage_v before generating " + ...
        "this protocol. It stimulates every Stim-enabled cell through one " + ...
        "union mask, so both amplitudes are global and neither has a " + ...
        "per-cell value to fall back to.");
end
protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory,protocol_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
protocol=adaptive_optopatch.generate_four_pulse_ramp_protocol( ...
    "PulseVoltageV",pulse_voltage_v, ...
    "RampEndVoltageV",ramp_end_voltage_v, ...
    "PulseDurationS",pulse_duration_s,"GapDurationS",gap_duration_s, ...
    "PulseCount",pulse_count,"RampDurationS",ramp_duration_s, ...
    "PreDelayS",pre_delay_s,"PostDelayS",post_delay_s);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);

stimulus=pulse_count*(pulse_duration_s+gap_duration_s)+ramp_duration_s;
fprintf("Saved %s\n",output_path);
fprintf("4 pulses + ramp (no blanket dithering)\n");
fprintf("  %d x %.0f ms pulses, %.0f ms gaps, then a %.0f ms ramp\n", ...
    pulse_count,1000*pulse_duration_s,1000*gap_duration_s,1000*ramp_duration_s);
fprintf("  stimulus %.3f s; acquisition %.3f s (pre %.0f ms + post %.0f ms)\n", ...
    stimulus,protocol.acquisitions(1).acquisition_duration_s, ...
    1000*pre_delay_s,1000*post_delay_s);
fprintf("  pulse amplitude %.3f V, ramp endpoint %.3f V\n", ...
    pulse_voltage_v,ramp_end_voltage_v);
fprintf("  targets: all Stim-enabled cells at once, one static union mask\n");
