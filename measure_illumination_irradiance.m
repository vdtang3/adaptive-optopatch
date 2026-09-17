function result=measure_illumination_irradiance(snapPath,options)
%MEASURE_ILLUMINATION_IRRADIANCE AOTF command voltage -> sample-plane irradiance.
%
%   A fast command-line rig-calibration utility. It takes one Luminos camera
%   snap of an isolated DMD illumination patch on a uniform fluorescent target,
%   segments the footprint the patch actually produced, converts it to a
%   physical area, and divides measured optical power by that area to get
%   irradiance.
%
%   The area comes from the snap's own saved transform:
%
%       pixel_area_um2 = abs(det(snap.pixel_to_sample_um))
%       area_mm2       = nnz(mask) * pixel_area_um2 / 1e6
%
%   so unequal X/Y scale, camera rotation and moderate shear are all handled
%   without collapsing the transform to a scalar um/pixel. Snaps written before
%   Luminos gained that field fail with a clear message rather than falling back
%   to any assumed scale.
%
%   WHAT THIS NUMBER IS. Total measured power divided by effective illuminated
%   area, i.e. the MEAN irradiance over the segmented footprint. It makes no
%   claim that illumination is uniform within the footprint; spatial flat-field
%   calibration is a separate measurement.
%
%   Usage
%     result = measure_illumination_irradiance()
%         Pick a snap, segment it, then type the paired readings into a dialog.
%
%     result = measure_illumination_irradiance("snap.mat")
%         Footprint and area only. Calibration fields come back empty.
%
%     result = measure_illumination_irradiance("snap.mat", ...
%         AOTF_V=[0.5 0.5 0.5 1 1 1], Power_mW=[0.12 0.13 0.12 0.41 0.40 0.42])
%         Everything, no dialogs. Repeated voltages are grouped automatically.
%
%   WHEN THE DIALOG APPEARS. Only when the snap was also chosen interactively,
%   i.e. the no-argument call. Naming a snap explicitly never blocks on a
%   dialog, so a scripted or repeated call is predictable and an area-only
%   measurement stays one line. To type readings against a known path, either
%   call with no arguments and pick the file, or pass AOTF_V and Power_mW.
%
%   Name-value arguments
%     AOTF_V             commanded voltages, one element per power reading
%     Power_mW           power-meter readings, same length as AOTF_V
%     ThresholdFraction  contrast fraction defining the footprint edge (0.5)
%     PlateauPercentile  percentile taken as "illuminated" (99). Suits any
%                        compact patch covering more than about 0.5% of the
%                        frame; use 99.5 below that.
%     BackgroundPercentile  percentile taken as background (20)
%     Visible            "off" suppresses the figures
%
%   Nothing is saved to disk, and no figure is written out.
%
%   See also adaptive_optopatch.segment_illumination_patch,
%   adaptive_optopatch.calculate_illuminated_area,
%   adaptive_optopatch.summarize_aotf_calibration

arguments
    snapPath (1,1) string = ""
    options.AOTF_V double = []
    options.Power_mW double = []
    % 0 < fraction < 1, spelled with the long-stable validators rather than
    % mustBeInRange (deprecated in R2026a) or mustBeBetween (too new for the
    % older releases this repository still branches for).
    options.ThresholdFraction (1,1) double ...
        {mustBeGreaterThan(options.ThresholdFraction,0), ...
         mustBeLessThan(options.ThresholdFraction,1)} = 0.5
    options.BackgroundPercentile (1,1) double = 20
    options.PlateauPercentile (1,1) double = 99
    options.Visible (1,1) string ...
        {mustBeMember(options.Visible,["on","off"])} = "on"
end

% Whether this is the fully interactive workflow, decided before the picker
% runs: it is what says if a dialog is wanted later.
choseSnapInteractively=strlength(snapPath)==0;
if choseSnapInteractively
    snapPath=pick_snap();
end

snap=adaptive_optopatch.load_calibration_snap(snapPath);

segmentation=adaptive_optopatch.segment_illumination_patch(snap.img, ...
    ThresholdFraction=options.ThresholdFraction, ...
    BackgroundPercentile=options.BackgroundPercentile, ...
    PlateauPercentile=options.PlateauPercentile);
area=adaptive_optopatch.calculate_illuminated_area( ...
    snap.pixel_to_sample_um,segmentation.mask);

show_segmentation_qc(snap,segmentation,area,options.Visible);

% Asked for only after the footprint is on screen - there is no point typing
% readings for a segmentation that is obviously wrong.
voltage=options.AOTF_V;
power=options.Power_mW;
if choseSnapInteractively && isempty(voltage) && isempty(power)
    [voltage,power]=ask_for_measurements();
end

summary=adaptive_optopatch.summarize_aotf_calibration( ...
    voltage,power,area.area_mm2);

if summary.available
    show_calibration_plot(summary,options.Visible);
end

print_report(snapPath,segmentation,area,summary);

result=build_result(snapPath,segmentation,area,summary);
end


%% ---- interactive input ---------------------------------------------------

function snapPath=pick_snap()
[name,folder]=uigetfile({'*.mat','Luminos snap (*.mat)'}, ...
    'Select a Luminos calibration snap');
if isequal(name,0)
    error("adaptive_optopatch:NoCalibrationSnapSelected", ...
        "No snap was selected.");
end
snapPath=string(fullfile(folder,name));
end

% Paired readings, one dialog. Cancelling is not an error: the footprint results
% are already worth having on their own.
function [voltage,power]=ask_for_measurements()
voltage=[];
power=[];

answer=inputdlg( ...
    {'AOTF V:','Power (mW):'}, ...
    'Paired AOTF / power-meter readings', ...
    [1 70; 1 70]);
if isempty(answer)
    return
end

voltage=parse_number_list(answer{1},"AOTF V");
power=parse_number_list(answer{2},"Power (mW)");
end

% Whitespace or commas, in any mix. Parsed strictly: anything that is not a
% number is reported rather than silently dropped or truncated, because a
% mis-typed reading would otherwise become a wrong calibration point.
function values=parse_number_list(text,label)
tokens=regexp(strtrim(string(text)),'[,\s]+','split');
tokens=tokens(strlength(tokens)>0);
if isempty(tokens)
    values=[];
    return
end

values=str2double(tokens);
bad=isnan(values)&~strcmpi(tokens,"nan");
if any(bad)
    error("adaptive_optopatch:UnparsableMeasurementList", ...
        "Could not read %s as numbers: %s",label, ...
        strjoin("'"+tokens(bad)+"'",", "));
end
values=values(:)';
end


%% ---- figures ------------------------------------------------------------

function show_segmentation_qc(snap,segmentation,area,visible)
figureHandle=figure("Name","Illumination footprint","Visible",visible, ...
    "NumberTitle","off");
layout=tiledlayout(figureHandle,1,2,"TileSpacing","compact");

ax=nexttile(layout);
imagesc(ax,double(snap.img(:,:,1)));
colormap(ax,gray);
axis(ax,"image");
hold(ax,"on");
% Drawn rather than shaded so the operator can see the edge against the real
% intensity roll-off and judge whether the contour sits where they expect.
boundaries=bwboundaries(segmentation.mask);
for k=1:numel(boundaries)
    plot(ax,boundaries{k}(:,2),boundaries{k}(:,1),"r-","LineWidth",1.5);
end
hold(ax,"off");
title(ax,sprintf("%s\n%.0f%% contrast threshold = %.4g", ...
    "Snap with detected footprint", ...
    100*segmentation.threshold_fraction,segmentation.threshold_value));

ax=nexttile(layout);
imagesc(ax,segmentation.mask);
colormap(ax,gray);
axis(ax,"image");
title(ax,sprintf("Mask: %d px\n%.4g um^2  =  %.6g mm^2", ...
    area.illuminated_pixels,area.area_um2,area.area_mm2));

title(layout,sprintf("Bounding box %.1f x %.1f um   |   pixel area %.4g um^2", ...
    area.bounding_width_um,area.bounding_height_um,area.pixel_area_um2));
end

% Individual readings, the per-voltage means, and +/-1 SD. No fit line: the
% AOTF response is not assumed to have any particular shape.
function show_calibration_plot(summary,visible)
figureHandle=figure("Name","AOTF calibration","Visible",visible, ...
    "NumberTitle","off");
ax=axes(figureHandle);
hold(ax,"on");

scatter(ax,summary.aotf_voltage_V,summary.irradiance_mW_mm2,24,[0.6 0.6 0.6], ...
    "filled","DisplayName","individual readings");

sd=summary.std_irradiance_mW_mm2;
sd(isnan(sd))=0;   % N = 1: no bar to draw, but the mean still plots
errorbar(ax,summary.voltage_V,summary.mean_irradiance_mW_mm2,sd, ...
    "o-","LineWidth",1.5,"MarkerFaceColor","auto", ...
    "DisplayName","mean \pm 1 SD");

hold(ax,"off");
grid(ax,"on");
xlabel(ax,"AOTF command voltage (V)");
ylabel(ax,"Irradiance (mW/mm^2)");
title(ax,"AOTF voltage \rightarrow sample-plane irradiance");
legend(ax,"Location","northwest");
end


%% ---- report -------------------------------------------------------------

function print_report(snapPath,segmentation,area,summary)
[~,name,extension]=fileparts(snapPath);

fprintf("\nIllumination / AOTF calibration\n");
fprintf("-------------------------------\n\n");
fprintf("Snap:\n%s\n\n",name+extension);

fprintf("Footprint\n");
fprintf("---------\n");
fprintf("Illuminated pixels:  %s\n",with_commas(area.illuminated_pixels));
fprintf("Pixel area:          %.4f um^2\n",area.pixel_area_um2);
fprintf("Illuminated area:    %s um^2\n",with_commas(area.area_um2));
fprintf("Illuminated area:    %.6f mm^2\n",area.area_mm2);
fprintf("Equivalent square:   %.1f um\n",area.equivalent_square_side_um);
fprintf("Threshold:           %.0f%% contrast (level %.4g)\n", ...
    100*segmentation.threshold_fraction,segmentation.threshold_value);
fprintf("\nBounding box:\n%.1f x %.1f um\n", ...
    area.bounding_width_um,area.bounding_height_um);

if ~summary.available
    fprintf("\nNo AOTF / power readings were supplied, so no irradiance " + ...
        "calibration was computed.\n\n");
    return
end

fprintf("\nAOTF calibration\n");
fprintf("----------------\n\n");
fprintf("Voltage    N    Power (mW)          Irradiance (mW/mm^2)\n\n");
for k=1:numel(summary.voltage_V)
    fprintf("%.2f V     %d    %-19s %s\n", ...
        summary.voltage_V(k),summary.n_per_voltage(k), ...
        format_mean_sd(summary.mean_power_mW(k),summary.std_power_mW(k),3), ...
        format_mean_sd(summary.mean_irradiance_mW_mm2(k), ...
            summary.std_irradiance_mW_mm2(k),1));
end

fprintf("\nCalibrated range\n");
fprintf("----------------\n");
fprintf("Voltage:      %.2f - %.2f V\n", ...
    min(summary.voltage_V),max(summary.voltage_V));
fprintf("Irradiance:   %.1f - %.1f mW/mm^2\n", ...
    min(summary.mean_irradiance_mW_mm2), ...
    max(summary.mean_irradiance_mW_mm2));
if ~summary.monotonic
    fprintf("\nInverse lookup unavailable: %s\n",summary.monotonicity_note);
end
fprintf("\n");
end

% "0.123 +/- 0.006", or just the mean when a single reading gives no spread.
function text=format_mean_sd(meanValue,sdValue,decimals)
format="%."+string(decimals)+"f";
if isnan(sdValue)
    text=sprintf(format+" (n=1)",meanValue);
else
    text=sprintf(format+" +/- "+format,meanValue,sdValue);
end
end

function text=with_commas(value)
text=regexprep(sprintf("%d",round(value)),'(\d)(?=(\d{3})+$)','$1,');
end


%% ---- result -------------------------------------------------------------

function result=build_result(snapPath,segmentation,area,summary)
result=struct( ...
    "snap_path",string(snapPath), ...
    "mask",segmentation.mask, ...
    "threshold_fraction",segmentation.threshold_fraction, ...
    "threshold_value",segmentation.threshold_value, ...
    "background_level",segmentation.background_level, ...
    "plateau_level",segmentation.plateau_level, ...
    "pixel_to_sample_um",area.pixel_to_sample_um, ...
    "pixel_area_um2",area.pixel_area_um2, ...
    "illuminated_pixels",area.illuminated_pixels, ...
    "area_um2",area.area_um2, ...
    "area_mm2",area.area_mm2, ...
    "equivalent_square_side_um",area.equivalent_square_side_um, ...
    "bounding_width_um",area.bounding_width_um, ...
    "bounding_height_um",area.bounding_height_um, ...
    "aotf_voltage_V",summary.aotf_voltage_V, ...
    "power_mW",summary.power_mW, ...
    "irradiance_mW_mm2",summary.irradiance_mW_mm2, ...
    "calibration_table",summary.calibration_table, ...
    "voltage_V",summary.voltage_V, ...
    "n_per_voltage",summary.n_per_voltage, ...
    "mean_power_mW",summary.mean_power_mW, ...
    "std_power_mW",summary.std_power_mW, ...
    "mean_irradiance_mW_mm2",summary.mean_irradiance_mW_mm2, ...
    "std_irradiance_mW_mm2",summary.std_irradiance_mW_mm2, ...
    "monotonic",summary.monotonic, ...
    "irradiance_at_voltage",summary.irradiance_at_voltage, ...
    "voltage_for_irradiance",summary.voltage_for_irradiance);
end
