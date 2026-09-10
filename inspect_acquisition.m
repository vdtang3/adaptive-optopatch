function viewer=inspect_acquisition(experimentDirectory,options)
%INSPECT_ACQUISITION Show raw canonical-ROI traces and executed stimulation.
arguments
    experimentDirectory (1,1) string = ""
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
end

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

saved=load(fullfile(experimentDirectory,"output_data.mat"), ...
    "adaptive_optopatch_record");
if ~isfield(saved,"adaptive_optopatch_record")
    error("adaptive_optopatch:AcquisitionRecordMissing", ...
        "output_data.mat has no adaptive_optopatch_record linkage.");
end
record=saved.adaptive_optopatch_record;
referencePath=resolve_reference_path(record);
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
[figureHandle,traceLines,roiLines]=build_figure( ...
    reference,traces,cellIds,command,options.Visible);

viewer=struct( ...
    "schema_version","1.0.0", ...
    "experiment_directory",experimentDirectory, ...
    "reference_model_path",referencePath, ...
    "roi_source","reference.roi_masks", ...
    "cell_ids",cellIds, ...
    "traces",traces, ...
    "display_dff",-traces.dff, ...
    "stimulation",command, ...
    "figure",figureHandle, ...
    "trace_lines",traceLines, ...
    "roi_lines",roiLines);
end

function referencePath=resolve_reference_path(record)
candidates=strings(0,1);
if isfield(record,"reference_model_path") && ...
        strlength(string(record.reference_model_path))>0
    candidates(end+1)=string(record.reference_model_path); %#ok<AGROW>
end
if isfield(record,"run_directory") && strlength(string(record.run_directory))>0
    candidates(end+1)=fullfile(string(record.run_directory), ...
        "reference_model.mat"); %#ok<AGROW>
end
if isempty(candidates)
    error("adaptive_optopatch:AcquisitionReferenceLinkMissing", ...
        "The acquisition record does not identify its Adaptive Optopatch "+ ...
        "run/reference. Re-run with a current runner or add an explicit linkage.");
end
canonical=strings(size(candidates));
for k=1:numel(candidates)
    [exists,attributes]=fileattrib(candidates(k));
    if ~exists
        error("adaptive_optopatch:AcquisitionReferenceLinkBroken", ...
            "The acquisition links to a missing reference model: %s",candidates(k));
    end
    canonical(k)=string(attributes.Name);
end
if numel(unique(canonical))~=1
    error("adaptive_optopatch:AmbiguousAcquisitionReference", ...
        "The acquisition record contains conflicting reference-model links: %s", ...
        strjoin(canonical,", "));
end
referencePath=canonical(1);
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

function [fig,traceLines,roiLines]=build_figure(reference,traces,cellIds,command,visible)
nCells=numel(cellIds);
fig=uifigure("Name","Adaptive Optopatch acquisition quick look", ...
    "Position",[100 100 1200 760],"Visible",visible);
layout=uigridlayout(fig,[2 2]);
layout.RowHeight={"3x","1x"}; layout.ColumnWidth={"4x","1x"};
layout.Padding=[8 8 8 8];

traceAxes=uiaxes(layout); traceAxes.Layout.Row=1; traceAxes.Layout.Column=1;
displayPercent=-100*traces.dff;
spans=max(displayPercent,[],1,"omitnan")-min(displayPercent,[],1,"omitnan");
spacing=max([spans,1],[],"omitnan")*1.25;
offsets=(nCells-1:-1:0)*spacing;
hold(traceAxes,"on");
traceLines=gobjects(nCells,1);
for k=1:nCells
    traceLines(k)=plot(traceAxes,traces.tvec,displayPercent(:,k)+offsets(k), ...
        "Color",[0.15 0.15 0.15],"LineWidth",0.8, ...
        "ButtonDownFcn",@(~,~)highlight(k));
end
traceAxes.YTick=fliplr(offsets);
traceAxes.YTickLabel=flipud(cellstr(cellIds));
xlabel(traceAxes,"Time (s)"); ylabel(traceAxes,"Cell / inverted dF/F (%)");
title(traceAxes,"Canonical soma ROI traces (voltage activity upward)");
grid(traceAxes,"on");

referenceAxes=uiaxes(layout); referenceAxes.Layout.Row=1; referenceAxes.Layout.Column=2;
imagesc(referenceAxes,reference.reference_image); colormap(referenceAxes,gray);
axis(referenceAxes,"image"); referenceAxes.XTick=[]; referenceAxes.YTick=[];
title(referenceAxes,"Canonical ROIs"); hold(referenceAxes,"on");
roiLines=gobjects(nCells,1);
for k=1:nCells
    boundaries=bwboundaries(reference.roi_masks(:,:,k));
    boundary=boundaries{1};
    roiLines(k)=plot(referenceAxes,boundary(:,2),boundary(:,1), ...
        "Color",[0 0.8 1],"LineWidth",1,"HitTest","off");
    center=mean(boundary,1);
    text(referenceAxes,center(2),center(1),cellIds(k), ...
        "Color","yellow","FontSize",8,"HorizontalAlignment","center", ...
        "HitTest","off");
end

stimAxes=uiaxes(layout); stimAxes.Layout.Row=2; stimAxes.Layout.Column=[1 2];
plot(stimAxes,command.time_s,command.command_v,"k-","LineWidth",1.25);
xlabel(stimAxes,"Time (s)"); ylabel(stimAxes,command.label);
title(stimAxes,"Executed stimulation command"); grid(stimAxes,"on");
endTime=max(command.time_s(end),eps);
xlim(traceAxes,[0 endTime]); xlim(stimAxes,[0 endTime]);
linkaxes([traceAxes stimAxes],"x");

    function highlight(selected)
        for index=1:nCells
            if index==selected
                traceLines(index).Color=[0.85 0.2 0.1];
                traceLines(index).LineWidth=1.8;
                roiLines(index).Color=[1 0.2 0.1];
                roiLines(index).LineWidth=2.2;
            else
                traceLines(index).Color=[0.65 0.65 0.65];
                traceLines(index).LineWidth=0.7;
                roiLines(index).Color=[0 0.8 1];
                roiLines(index).LineWidth=1;
            end
        end
        title(referenceAxes,"Canonical ROI — "+cellIds(selected));
    end
end
