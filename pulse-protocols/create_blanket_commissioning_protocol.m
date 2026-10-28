% BLANKET COMMISSIONING — a deliberately tiny dithered run for a slide.
%
% NOT AN EXPERIMENT. This exists to answer seven questions about the DMD on
% a uniform fluorescent slide, with as few triggers as will answer them:
%
%   1. is the DMD showing playlist entry 1 before the first trigger?
%   2. does every external trigger produce exactly one advance?
%   3. is the pattern sequence the one the sheet predicts?
%   4. is the total advance count right?
%   5. is the expected mask lit during each blue-on interval?
%   6. does any extra trigger occur?
%   7. where is the playlist left afterwards?
%
% HOW TO MAKE THE STATES LEGIBLE. Draw exactly TWO ROIs on the slide, well
% separated and very different in size:
%
%   a LARGE ROI - most of the field
%   a SMALL ROI - a compact spot far from the large one
%
% Enable Stim on both. The blanket is their union, so both are lit for
% 0.2 ms of every cycle; during cell 1's epoch the large ROI is
% additionally lit for the rest of the cycle, and during cell 2's the small
% one is. The camera runs at exactly 1 kHz with one cycle per frame, so
% each frame integrates one complete state pair and the per-frame intensity
% of each ROI says which state it was:
%
%   both ROIs dim                  gap cycle (blanket only)
%   large bright, small dim        cell 1 epoch
%   small bright, large dim        cell 2 epoch
%
% An off-by-one in the playlist shows up as those assignments being swapped
% or shifted by one frame, which is visible without any further analysis.
%
% ---- EXPERIMENTAL DESIGN (edit these) --------------------------------------
blanket_mod488_v=NaN;         % REQUIRED: blanket-phase mod488 command, (0,5] V
command_voltage_v=NaN;        % NaN defers to each ROI's own Blue calibration
rounds=3;                     % keep this small; the sheet lists every state
epoch_duration_s=0.020;
inter_epoch_gap_s=0.010;
pre_delay_s=0.100;
post_delay_s=0.100;
% ---------------------------------------------------------------------------
%
% With two ROIs and the defaults above: 2 cells x 30 cycles per slot x 2
% states per cycle = 120 states per round, 3 rounds = 360 triggers, and the
% acquisition is 0.1 + 3 x 0.060 + 0.1 = 0.380 s. Short enough to repeat
% while changing one thing at a time.

if ~isfinite(blanket_mod488_v)
    error("Set blanket_mod488_v before generating the commissioning protocol.");
end
protocol_directory=fileparts(mfilename("fullpath"));
project_directory=fileparts(protocol_directory);
addpath(project_directory,protocol_directory);
if ~exist("protocol_output_directory","var") || strlength(string(protocol_output_directory))==0
    protocol_output_directory=fullfile(protocol_directory,"generated");
end
protocol=adaptive_optopatch.generate_blanket_round_robin_protocol( ...
    "BlanketMod488V",blanket_mod488_v,"Rounds",rounds, ...
    "EpochDurationS",epoch_duration_s,"InterEpochGapS",inter_epoch_gap_s, ...
    "PreDelayS",pre_delay_s,"PostDelayS",post_delay_s, ...
    "AcquisitionCount",1,"CommandVoltageV",command_voltage_v, ...
    "ProtocolId","blanket_commissioning");
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);

fprintf("Saved %s\n",output_path);
fprintf("\nA commissioning SHEET for the run you are about to do cannot be\n");
fprintf("printed from the definition alone: it needs the Stim-enabled cells,\n");
fprintf("which is what makes the blanket union and the round. Load this\n");
fprintf("protocol, draw and enable the two ROIs, press Update plan, then:\n\n");
fprintf("    plan   = controller.ActiveRunPlan;\n");
fprintf("    sheet  = adaptive_optopatch.describe_blanket_commissioning( ...\n");
fprintf("                 plan.manifest.trials.pulse_schedule{1}, ...\n");
fprintf("                 \"Targets\",plan.targets);\n\n");
fprintf("and check the rig against what it prints. See\n");
fprintf("docs/commissioning/blanket-depolarization.md for the procedure.\n");
