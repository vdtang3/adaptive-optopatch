% BLANKET RECRUITMENT SWEEP (calibration helper, Virtual Upright).
%
% Steps the blanket level upward, one short step at a time, so you can see
% where the blanket alone starts to make cells fire. No cell is targeted
% individually: every Stim-enabled cell receives the same blanket.
%
% Each 1 ms cycle, throughout:
%
%     0.2 ms  Stim-enabled union at this step's level
%     0.8 ms  blank mask at 0 V
%
% which is the same flickered blanket the connectivity experiment delivers,
% not a continuous low AOTF voltage.
%
% Structure:
%
%     pre_dark_s dark
%     levels_v(1) for step_duration_s
%     levels_v(2) for step_duration_s
%     ...
%     ends with the last step
%
% WHY THE STEPS ARE SHORT. The sweep cannot be stopped once it starts, so no
% level is held for more than one step and there is no hold at the highest
% level afterwards.
%
% LEVELS ARE EXPLICIT and must not decrease. Nothing is extrapolated. Start
% low; add levels rather than raising the top of the list by guesswork.
%
% ---- EXPERIMENTAL DESIGN (edit these) --------------------------------------
levels_v=[0.2 0.4 0.6 0.8 1.0 1.2];   % blanket mod488 commands, (0,5] V
step_duration_s=1.0;                   % whole modulation cycles
pre_dark_s=1.0;                        % whole cycles, dark baseline
cycle_period_s=0.001;                  % must equal the camera frame period
blanket_fraction=0.20;
% ---------------------------------------------------------------------------

protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory,protocol_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
protocol=adaptive_optopatch.generate_blanket_recruitment_sweep_protocol( ...
    levels_v(:),"StepDurationS",step_duration_s,"PreDarkS",pre_dark_s, ...
    "CyclePeriodS",cycle_period_s,"BlanketFraction",blanket_fraction);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);

fprintf("Saved %s\n",output_path);
fprintf("Blanket recruitment sweep\n");
fprintf("  %d steps of %.3g s: %s V\n",numel(levels_v),step_duration_s, ...
    strjoin(compose("%.3g",levels_v(:)'),", "));
fprintf("  %.0f%% of each %.3g ms cycle is blanket; the rest is dark\n", ...
    100*blanket_fraction,1000*cycle_period_s);
fprintf("  %.3g s dark baseline, then %.3g s of stepping, then the end\n", ...
    pre_dark_s,numel(levels_v)*step_duration_s);
fprintf("  no cell is targeted; every logical segment is one voltage step\n");
