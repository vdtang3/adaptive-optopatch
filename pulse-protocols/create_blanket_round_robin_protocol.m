% Fixed-order 1P ROUND ROBIN WITH BLANKET DEPOLARIZATION (commissioning).
%
% For inhibitory-cell round robins: every 1 ms cycle the whole camera FOV gets
% a short Blue pulse that slightly depolarizes every cell, and during a target
% epoch the rest of the cycle goes to the target at its own calibrated Blue
% voltage. Between epochs the rest of the cycle is dark.
%
%   target epoch, each cycle:  0.2 ms full-FOV mask at blanket_mod488_v
%                              0.8 ms target mask at the cell's Blue V
%                                     (first 50 us held at 0 V, see guard)
%   gap, each cycle:           0.2 ms full-FOV mask at blanket_mod488_v
%                              0.8 ms blank mask at 0 V
%
% The blanket dose is the DUTY CYCLE at one AOTF voltage, never a lower AOTF
% voltage. One round (cell 1 epoch, gap, ..., cell N epoch, gap) is stored
% as the DMD playlist and wraps; the acquisition is a whole number of rounds.
% Targets are the Stim-enabled cells at Update plan, in FOV order.
%
% COMMISSIONING STATUS. Virtual Upright only. Run it on a fluorescent slide
% before tissue: the DMD advance count is verified after each acquisition,
% but that counter model and the trigger-to-display latency the guard covers
% still need a hardware measurement. A cell's existing Blue V was calibrated
% with continuous 100%-duty pulses; here the target is lit for 80% of each
% cycle (75% with the guard), so that calibration does not transfer as is.
%
% ---- EXPERIMENTAL DESIGN (edit these) --------------------------------------
blanket_mod488_v=NaN;         % REQUIRED: blanket-phase mod488 command, (0,5] V
rounds=100;                   % epochs per cell in each acquisition
epoch_duration_s=0.020;       % whole cycles
inter_epoch_gap_s=0.010;      % whole cycles, at least one
cycle_period_s=0.001;         % must equal the camera frame period
blanket_fraction=0.20;
target_onset_guard_s=50e-6;   % mod488 at 0 V while the DMD leaves the blanket mask
pre_delay_s=0.100;            % whole cycles; dark, before the first round
post_delay_s=0.100;
acquisition_count=1;
% ---------------------------------------------------------------------------
%
% NaN defers each epoch's Vstim to the target cell's selected Blue voltage; a
% finite value in (0,5] is an explicit protocol-wide override.
command_voltage_v=NaN;

if ~isfinite(blanket_mod488_v)
    error("Set blanket_mod488_v to the blanket-phase mod488 command before " + ...
        "generating this protocol. There is no default blanket voltage.");
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
    "CyclePeriodS",cycle_period_s,"BlanketFraction",blanket_fraction, ...
    "TargetOnsetGuardS",target_onset_guard_s, ...
    "PreDelayS",pre_delay_s,"PostDelayS",post_delay_s, ...
    "AcquisitionCount",acquisition_count,"CommandVoltageV",command_voltage_v);
output_path=fullfile(protocol_output_directory,protocol.protocol_id+".mat");
adaptive_optopatch.save_protocol(output_path,protocol);

cycles_per_slot=round((epoch_duration_s+inter_epoch_gap_s)/cycle_period_s);
fprintf("Saved %s\n",output_path);
fprintf("Blanket round robin: %d acquisition(s) of %d rounds\n", ...
    acquisition_count,rounds);
fprintf("  blanket %.0f%% of each %.3g ms cycle at %.3f V\n", ...
    100*blanket_fraction,1000*cycle_period_s,blanket_mod488_v);
fprintf("  %.0f ms epochs, %.0f ms gaps; %d DMD states per cell per round\n", ...
    1000*epoch_duration_s,1000*inter_epoch_gap_s,2*cycles_per_slot);
fprintf("  targets: current Stim-enabled AO cells at Update Plan, FOV order\n");
