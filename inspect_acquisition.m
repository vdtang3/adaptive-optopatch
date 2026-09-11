function viewer=inspect_acquisition(experimentDirectory,options)
%INSPECT_ACQUISITION Show raw canonical-ROI traces and executed stimulation.
arguments
    experimentDirectory (1,1) string = ""
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
    options.Force (1,1) logical = false
end
INSPECTION_SCHEMA_VERSION=1;

if strlength(experimentDirectory)==0
    selected=uigetdir(pwd,"Select a completed Luminos experiment");
    if isequal(selected,0)
        error("adaptive_optopatch:NoExperimentSelected", ...
            "No Luminos experiment was selected.");
    end
    experimentDirectory=string(selected);
end
if ~isfolder(experimentDirectory) || ...
        ~isfile(fullfile(experimentDirectory,"output_data.mat"))
    error("adaptive_optopatch:InvalidExperimentDirectory", ...
        "Select the exact Luminos experiment folder containing output_data.mat: %s", ...
        experimentDirectory);
end
cachePath=fullfile(experimentDirectory,"inspection_analysis.mat");
pngPath=fullfile(experimentDirectory,"inspection.png");
[inspection,cacheHit]=load_cached_inspection( ...
    cachePath,INSPECTION_SCHEMA_VERSION,options.Force);
if ~cacheHit
    inspection=analyze_acquisition(experimentDirectory, ...
        INSPECTION_SCHEMA_VERSION);
    save(cachePath,"inspection","-v7.3");
end
[figureHandle,traceLines,roiLines,axesHandles]=build_figure( ...
    inspection.reference,inspection.traces,inspection.cell_ids, ...
    inspection.stimulation,options.Visible);
exportapp(figureHandle,pngPath);

viewer=struct( ...
    "schema_version","1.0.0", ...
    "experiment_directory",experimentDirectory, ...
    "reference_model_path",inspection.reference_model_path, ...
    "roi_source","reference.roi_masks", ...
    "cell_ids",inspection.cell_ids, ...
    "traces",inspection.traces, ...
    "display_dff",inspection.display_dff, ...
    "stimulation",inspection.stimulation, ...
    "cache_path",string(cachePath), ...
    "png_path",string(pngPath), ...
    "cache_hit",cacheHit, ...
    "figure",figureHandle, ...
    "trace_axes",axesHandles.trace, ...
    "stimulation_axes",axesHandles.stimulation, ...
    "reference_axes",axesHandles.reference, ...
    "trace_lines",traceLines, ...
    "roi_lines",roiLines);
end

function [inspection,cacheHit]=load_cached_inspection(path,schemaVersion,force)
inspection=struct; cacheHit=false;
if force || ~isfile(path), return; end
saved=load(path,"inspection");
required=["schema_version","reference_model_path","reference", ...
    "cell_ids","traces","display_dff","stimulation"];
if ~isfield(saved,"inspection") || ...
        ~all(isfield(saved.inspection,cellstr(required))) || ...
        ~isequal(saved.inspection.schema_version,schemaVersion)
    return
end
inspection=saved.inspection;
cacheHit=true;
end

function inspection=analyze_acquisition(experimentDirectory,schemaVersion)
saved=load(fullfile(experimentDirectory,"output_data.mat"), ...
    "adaptive_optopatch_record");
if ~isfield(saved,"adaptive_optopatch_record")
    error("adaptive_optopatch:AcquisitionRecordMissing", ...
        "output_data.mat has no adaptive_optopatch_record linkage.");
end
record=saved.adaptive_optopatch_record;
referencePath=adaptive_optopatch.resolve_reference_path( ...
    record,experimentDirectory);
linked=load(referencePath,"reference");
if ~isfield(linked,"reference") || ~isfield(linked.reference,"roi_masks") || ...
        ~isfield(linked.reference,"cells")
    error("adaptive_optopatch:InvalidLinkedReference", ...
        "The linked reference_model.mat has no canonical reference and ROI masks: %s", ...
        referencePath);
end
reference=linked.reference;
cellIds=string({reference.cells.cell_id})';
if size(reference.roi_masks,3)~=numel(cellIds)
    error("adaptive_optopatch:InvalidLinkedReference", ...
        "The linked canonical ROI count does not match its cell IDs.");
end
traces=adaptive_optopatch.extract_roi_traces( ...
    experimentDirectory,reference, ...
    "BackgroundMode","none", ...
    "MotionCorrection","none", ...
    "PhotobleachCorrection","none");
command=executed_command(record,traces.tvec);
displayReference=struct("reference_image",reference.reference_image, ...
    "roi_masks",reference.roi_masks);
inspection=struct("schema_version",schemaVersion, ...
    "reference_model_path",referencePath,"reference",displayReference, ...
    "cell_ids",cellIds,"traces",traces,"display_dff",-traces.dff, ...
    "stimulation",command);
end

function command=executed_command(record,traceTime)
if ~isfield(record,"pulse_schedule") || ...
        ~isfield(record.pulse_schedule,"events")
    error("adaptive_optopatch:ExecutedPulseScheduleMissing", ...
        "The acquisition record does not contain its executed pulse_schedule.");
end
events=record.pulse_schedule.events;
required=["onset_s","duration_s","is_null","command_voltage_v"];
if ~all(ismember(required,string(events.Properties.VariableNames)))
    error("adaptive_optopatch:InvalidExecutedPulseSchedule", ...
        "The executed pulse schedule lacks timing or command-voltage fields.");
end
mode="";
if isfield(record,"trial") && ...
        ismember("stimulation_mode",string(record.trial.Properties.VariableNames))
    mode=string(record.trial.stimulation_mode(1));
end
if mode=="1p_dmd"
    label="mod488 command (V)";
elseif mode=="2p_spiral"
    label="Pockels command (V)";
else
    error("adaptive_optopatch:UnknownRecordedStimulationMode", ...
        "The acquisition record does not identify a supported stimulation mode.");
end

active=~events.is_null;
events=events(active,:);
[~,order]=sort(events.onset_s);
events=events(order,:);
timeS=0;
commandV=0;
for k=1:height(events)
    onset=double(events.onset_s(k));
    offset=onset+double(events.duration_s(k));
    amplitude=double(events.command_voltage_v(k));
    timeS=[timeS;onset;onset;offset;offset]; %#ok<AGROW>
    commandV=[commandV;0;amplitude;amplitude;0]; %#ok<AGROW>
end
if isempty(traceTime), traceEnd=0; else, traceEnd=double(traceTime(end)); end
scheduleEnd=0;
if isfield(record.pulse_schedule,"acquisition_duration_s")
    scheduleEnd=double(record.pulse_schedule.acquisition_duration_s);
end
timeS(end+1)=max([traceEnd,scheduleEnd,timeS(end)]);
commandV(end+1)=0;
targetIds=strings(height(events),1);
if ismember("target_cell_id",string(events.Properties.VariableNames))
    targetIds=string(events.target_cell_id);
end
command=struct( ...
    "source","adaptive_optopatch_record.pulse_schedule", ...
    "mode",mode,"label",label,"events",events, ...
    "target_cell_ids",targetIds,"time_s",timeS,"command_v",commandV);
end

function [fig,traceLines,roiLines,axesHandles]=build_figure( ...
        reference,traces,cellIds,command,visible)
nCells=numel(cellIds);
fig=uifigure("Name","Adaptive Optopatch acquisition quick look", ...
    "Position",[100 100 1200 760],"Visible",visible);
layout=uigridlayout(fig,[1 2]);
layout.ColumnWidth={"3x","2x"}; layout.Padding=[8 8 8 8];
plotLayout=uigridlayout(layout,[2 1]);
plotLayout.Layout.Row=1; plotLayout.Layout.Column=1;
plotLayout.RowHeight={"3x","1x"}; plotLayout.Padding=[0 0 0 0];

traceAxes=uiaxes(plotLayout); traceAxes.Layout.Row=1; traceAxes.Layout.Column=1;
traceAxes.Tag="AdaptiveOptopatchTraceAxes";
displayPercent=-100*traces.dff;
spans=max(displayPercent,[],1,"omitnan")-min(displayPercent,[],1,"omitnan");
spacing=max([spans,1],[],"omitnan")*1.25;
offsets=(nCells-1:-1:0)*spacing;
colors=lines(nCells);
hold(traceAxes,"on");
traceLines=gobjects(nCells,1);
for k=1:nCells
    traceLines(k)=plot(traceAxes,traces.tvec,displayPercent(:,k)+offsets(k), ...
        "Color",colors(k,:),"LineWidth",0.9, ...
        "ButtonDownFcn",@(~,~)highlight(k));
end
traceAxes.YTick=fliplr(offsets);
traceAxes.YTickLabel=flipud(cellstr(cellIds));
xlabel(traceAxes,"Time (s)"); ylabel(traceAxes,"Cell / inverted dF/F (%)");
title(traceAxes,"Canonical soma ROI traces (voltage activity upward)");
grid(traceAxes,"on");

referenceAxes=uiaxes(layout); referenceAxes.Layout.Row=1; referenceAxes.Layout.Column=2;
referenceAxes.Tag="AdaptiveOptopatchReferenceAxes";
imagesc(referenceAxes,reference.reference_image); colormap(referenceAxes,gray);
axis(referenceAxes,"image"); referenceAxes.XTick=[]; referenceAxes.YTick=[];
title(referenceAxes,"Canonical ROIs"); hold(referenceAxes,"on");
roiLines=gobjects(nCells,1);
for k=1:nCells
    boundaries=bwboundaries(reference.roi_masks(:,:,k));
    boundary=boundaries{1};
    roiLines(k)=plot(referenceAxes,boundary(:,2),boundary(:,1), ...
        "Color",colors(k,:),"LineWidth",1.5,"HitTest","off");
    center=mean(boundary,1);
    text(referenceAxes,center(2),center(1),cellIds(k), ...
        "Color","yellow","FontSize",8,"HorizontalAlignment","center", ...
        "HitTest","off");
end

stimAxes=uiaxes(plotLayout); stimAxes.Layout.Row=2; stimAxes.Layout.Column=1;
stimAxes.Tag="AdaptiveOptopatchStimulationAxes";
plot(stimAxes,command.time_s,command.command_v, ...
    "Color",[0.75 0.75 0.75],"LineWidth",0.8);
hold(stimAxes,"on");
labelled=false(nCells,1);
for k=1:height(command.events)
    targetCellId=command.target_cell_ids(k);
    cellIndex=find(cellIds==targetCellId,1);
    if isempty(cellIndex), pulseColor=[0.2 0.2 0.2]; else, pulseColor=colors(cellIndex,:); end
    onset=double(command.events.onset_s(k));
    offset=onset+double(command.events.duration_s(k));
    amplitude=double(command.events.command_voltage_v(k));
    pulse=plot(stimAxes,[onset onset offset offset], ...
        [0 amplitude amplitude 0],"Color",pulseColor,"LineWidth",1.5);
    pulse.UserData=targetCellId;
    pulse.Tag="AdaptiveOptopatchStimulusPulse";
    if ~isempty(cellIndex) && ~labelled(cellIndex)
        text(stimAxes,(onset+offset)/2,amplitude,cellIds(cellIndex), ...
            "Color",pulseColor,"FontSize",8,"FontWeight","bold", ...
            "HorizontalAlignment","center","VerticalAlignment","bottom", ...
            "HitTest","off","Tag","AdaptiveOptopatchStimulusLabel");
        labelled(cellIndex)=true;
    end
end
xlabel(stimAxes,"Time (s)"); ylabel(stimAxes,command.label);
title(stimAxes,"Executed stimulation command (labels mark each cell's first pulse)");
grid(stimAxes,"on");
endTime=max(command.time_s(end),eps);
xlim(traceAxes,[0 endTime]); xlim(stimAxes,[0 endTime]);
linkaxes([traceAxes stimAxes],"x");
axesHandles=struct("trace",traceAxes,"stimulation",stimAxes, ...
    "reference",referenceAxes);

    function highlight(selected)
        for index=1:nCells
            if index==selected
                traceLines(index).LineWidth=1.8;
                roiLines(index).LineWidth=2.5;
            else
                traceLines(index).LineWidth=0.9;
                roiLines(index).LineWidth=1.5;
            end
        end
        title(referenceAxes,"Canonical ROI — "+cellIds(selected));
    end
end
