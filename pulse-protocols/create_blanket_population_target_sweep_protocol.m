% BLANKET + POPULATION-TARGET SWEEP (calibration helper, Virtual Upright).
%
% Holds the blanket at a chosen level and steps the TARGET level, with every
% selected cell targeted at once, to find a useful target-voltage range under
% blanket depolarization.
%
% Each 1 ms cycle of a target epoch:
%
%     0.2 ms  union of Stim-enabled cells at blanket_mod488_v
%     0.8 ms  union of the selected cells' masks at this level
%             (its first 50 us at 0 V, the usual target-onset guard)
%
% and between epochs the ordinary blanket/dark cycle:
%
%     0.2 ms  union of Stim-enabled cells at blanket_mod488_v
%     0.8 ms  blank mask at 0 V
%
% Both phases light the same union of the Stim-enabled cells' own masks, at
% the blanket level and then at the sweep level. Tissue outside those cells is
% never illuminated, and the full FOV is never driven at the target level.
%
% NOT A PER-CELL CALIBRATION. Stimulating every inhibitory cell at once
% recruits the network's own inhibition, which the isolated-cell round robin
% does not. Use this for a target-voltage RANGE; a threshold found here may
% differ from the one a single cell shows.
%
% ---- EXPERIMENTAL DESIGN (edit these) --------------------------------------
blanket_mod488_v=NaN;                 % REQUIRED: blanket level, from the sweep above
levels_v=[1.0 1.5 2.0 2.5 3.0];       % target mod488 commands, (0,5] V
repetitions_per_level=8;              % brief epochs at each level
epoch_duration_s=0.020;               % whole cycles
inter_epoch_gap_s=0.080;              % whole cycles, at least one
cycle_period_s=0.001;                 % must equal the camera frame period
blanket_fraction=0.20;
pre_delay_s=0.100;
post_delay_s=0.100;
% ---------------------------------------------------------------------------

if ~isfinite(blanket_mod488_v)
    error("Set blanket_mod488_v to the blanket level you chose from the " + ...
        "recruitment sweep. There is no default blanket voltage.");
end
protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory,protocol_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
protocol=adaptive_optopatch.generate_blanket_population_target_sweep_protocol( ...
    levels_v(:),"BlanketMod488V",blanket_mod488_v, ...
    "RepetitionsPerLevel",repetitions_per_level, ...
    "EpochDurationS",epoch_duration_s,"InterEpochGapS",inter_epoch_gap_s, ...
    "CyclePeriodS",cycle_period_s,"BlanketFraction",blanket_fraction, ...
    "PreDelayS",pre_delay_s,"PostDelayS",post_delay_s);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);

epochs=numel(levels_v)*repetitions_per_level;
fprintf("Saved %s\n",output_path);
fprintf("Blanket + population-target sweep\n");
fprintf("  blanket %.3f V at %.0f%% duty of each %.3g ms cycle\n", ...
    blanket_mod488_v,100*blanket_fraction,1000*cycle_period_s);
fprintf("  %d target levels x %d epochs = %d epochs of %.0f ms\n", ...
    numel(levels_v),repetitions_per_level,epochs,1000*epoch_duration_s);
fprintf("  levels: %s V\n",strjoin(compose("%.3g",levels_v(:)'),", "));
fprintf("  target: union of the Stim-enabled AO cells at Update Plan\n");
fprintf("  this finds a voltage RANGE under blanket, not a per-cell threshold\n");
