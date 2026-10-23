function viewer=inspect_acquisition(experimentDirectory,options)
%INSPECT_ACQUISITION Show raw canonical-ROI traces and executed stimulation.
%   inspect_acquisition(path) analyzes the acquisition, or reuses its cached
%   inspection_analysis.mat, then shows the quick-look figure and saves
%   inspection.png beside it.
%
%   inspect_acquisition(path,"GenerateFigure",false) only analyzes and
%   caches. No figure is built and no PNG is written, so a later interactive
%   call opens from the cache. Figure fields of the result are then empty.
%   "Visible","off" is different: it still builds and exports the figure,
%   just without showing it.
arguments
    experimentDirectory (1,1) string = ""
    options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
    options.Force (1,1) logical = false
    options.GenerateFigure (1,1) logical = true
end
INSPECTION_SCHEMA_VERSION=6;

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
if options.GenerateFigure
    [figureHandle,traceLines,roiLines,axesHandles]=build_figure( ...
        inspection.reference,inspection.traces,inspection.cell_ids, ...
        inspection.stimulation,inspection.spinning_disk_pattern, ...
        inspection.camera_timing,options.Visible);
    exportapp(figureHandle,pngPath);
else
    figureHandle=gobjects(0); traceLines=gobjects(0,1); roiLines=gobjects(0,1);
    axesHandles=struct("trace",gobjects(0),"stimulation",gobjects(0), ...
        "reference",gobjects(0));
    pngPath="";
end

viewer=struct( ...
    "schema_version","1.0.0", ...
    "experiment_directory",experimentDirectory, ...
    "reference_model_path",inspection.reference_model_path, ...
    "roi_source","reference.roi_masks", ...
    "fov_image_source","acquisition mean image", ...
    "cell_ids",inspection.cell_ids, ...
    "traces",inspection.traces, ...
    "display_dff",inspection.display_dff, ...
    "stimulation",inspection.stimulation, ...
    "camera_timing",inspection.camera_timing, ...
    "spinning_disk_pattern",inspection.spinning_disk_pattern, ...
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
    "cell_ids","traces","display_dff","stimulation", ...
    "spinning_disk_pattern","camera_timing"];
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
pattern=struct([]);
metadata=adaptive_optopatch.load_luminos_metadata( ...
    fullfile(experimentDirectory,"output_data.mat"));
[traces.tvec,cameraTiming]=adaptive_optopatch.align_camera_frames_to_daq( ...
    fullfile(experimentDirectory,"output_data.mat"), ...
    metadata.voltage_camera,traces.tvec);
if isfinite(cameraTiming.measured_frame_rate_hz)
    traces.frame_rate_hz=cameraTiming.measured_frame_rate_hz;
end
command=executed_command(record,traces.tvec,cameraTiming.daq_time_scale);
if metadata.rig_name=="Spinning_Upright"
    pattern=adaptive_optopatch.inspect_spinning_disk_pattern( ...
        traces.movie_path,reference.image_size, ...
        double(metadata.voltage_camera.bit_depth),numel(traces.tvec));
end
displayReference=struct("reference_image",traces.mean_image, ...
    "roi_masks",reference.roi_masks);
inspection=struct("schema_version",schemaVersion, ...
    "reference_model_path",referencePath,"reference",displayReference, ...
    "cell_ids",cellIds,"traces",traces,"display_dff",-traces.dff, ...
    "stimulation",command,"spinning_disk_pattern",pattern, ...
    "camera_timing",cameraTiming);
end

function command=executed_command(record,traceTime,daqTimeScale)
% Pulse schedules are written in nominal DAQ seconds; daqTimeScale puts
% them on the same physical time axis as the frames.
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
blanket=blanket_block(record);
if blanket.enabled
    command=blanket_command(record,blanket,events,traceTime,daqTimeScale,mode);
    return
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
    onset=daqTimeScale*double(events.onset_s(k));
    offset=onset+daqTimeScale*double(events.duration_s(k));
    amplitude=double(events.command_voltage_v(k));
    timeS=[timeS;onset;onset;offset;offset]; %#ok<AGROW>
    commandV=[commandV;0;amplitude;amplitude;0]; %#ok<AGROW>
end
if isempty(traceTime), traceEnd=0; else, traceEnd=double(traceTime(end)); end
scheduleEnd=0;
if isfield(record.pulse_schedule,"acquisition_duration_s")
    scheduleEnd=daqTimeScale*double(record.pulse_schedule.acquisition_duration_s);
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
    "target_cell_ids",targetIds,"time_s",timeS,"command_v",commandV, ...
    "time_scale_from_schedule_seconds",daqTimeScale);
end

function blanket=blanket_block(record)
%BLANKET_BLOCK The acquisition's blanket-depolarization settings, or off.
blanket=struct("enabled",false);
if isfield(record,"pulse_schedule") && ...
        isfield(record.pulse_schedule,"blanket_depolarization") && ...
        isstruct(record.pulse_schedule.blanket_depolarization) && ...
        isfield(record.pulse_schedule.blanket_depolarization,"enabled")
    blanket=record.pulse_schedule.blanket_depolarization;
    blanket.enabled=logical(blanket.enabled);
end
end

function command=blanket_command(record,blanket,events,traceTime,daqTimeScale,mode)
%BLANKET_COMMAND What a blanket acquisition actually put on mod488.
%   A blanket acquisition's mod488 is not the logical schedule: it alternates
%   between the blanket phase and the segment's own level every cycle, and a
%   recruitment sweep's logical segments are null and would otherwise draw
%   nothing at all. So the grey background trace is rebuilt from the
%   archived state table - the same one the DAQ waveform was built from -
%   and the coloured bars stay the LOGICAL units: one per target epoch, or
%   one per voltage step, at the level that step delivered.
schedule="round_robin";
if isfield(blanket,"schedule"), schedule=string(blanket.schedule); end
[timeS,commandV,source]=blanket_mod488_trace(record,daqTimeScale);

% The logical units, and the level each one carries.
if schedule=="recruitment_sweep"
    sweep=blanket.sweep;
    segments=sweep.segments;
    bars=table(double(segments.onset_s),double(segments.offset_s)- ...
        double(segments.onset_s),double(segments.level_v), ...
        'VariableNames',{'onset_s','duration_s','command_voltage_v'});
    targetIds=repmat("",height(bars),1);
    label="blanket level per step (mod488, V)";
else
    bars=events(~events.is_null,:);
    [~,order]=sort(bars.onset_s); bars=bars(order,:);
    targetIds=strings(height(bars),1);
    if ismember("target_cell_id",string(bars.Properties.VariableNames))
        targetIds=string(bars.target_cell_id);
    end
    if schedule=="population_target_sweep"
        label="population target level (mod488, V)";
    else
        label="target epochs, blanket-modulated (Vstim, V)";
    end
end
if isempty(timeS)
    % No archived state table (an older record, or a dry run): draw the
    % logical units alone rather than inventing a waveform.
    timeS=0; commandV=0;
    for k=1:height(bars)
        onset=daqTimeScale*double(bars.onset_s(k));
        offset=onset+daqTimeScale*double(bars.duration_s(k));
        amplitude=double(bars.command_voltage_v(k));
        timeS=[timeS;onset;onset;offset;offset]; %#ok<AGROW>
        commandV=[commandV;0;amplitude;amplitude;0]; %#ok<AGROW>
    end
    source="adaptive_optopatch_record.pulse_schedule";
end
traceEnd=0;
if ~isempty(traceTime), traceEnd=double(traceTime(end)); end
scheduleEnd=0;
if isfield(record.pulse_schedule,"acquisition_duration_s")
    scheduleEnd=daqTimeScale*double(record.pulse_schedule.acquisition_duration_s);
end
timeS(end+1)=max([traceEnd,scheduleEnd,timeS(end)]);
commandV(end+1)=0;
command=struct("source",source,"mode",mode,"label",label,"events",bars, ...
    "target_cell_ids",targetIds,"time_s",timeS,"command_v",commandV, ...
    "time_scale_from_schedule_seconds",daqTimeScale, ...
    "blanket_schedule",schedule);
end

function [timeS,commandV,source]=blanket_mod488_trace(record,daqTimeScale)
%BLANKET_MOD488_TRACE The archived state table as a mod488 step trace.
%   Exact while it stays a reasonable number of points. A long acquisition
%   has hundreds of thousands of states, so beyond that the trace is the
%   per-camera-frame MAXIMUM instead - an envelope, which is what a quick
%   look can show of a 1 kHz modulation anyway, and it is labelled as one.
MAXIMUM_EXACT_STATES=100000;
timeS=[]; commandV=[]; source="";
if ~isfield(record,"waveform_summary") || ...
        ~isfield(record.waveform_summary,"dmd_sequence") || ...
        ~isfield(record.waveform_summary.dmd_sequence,"state_table")
    return
end
stateTable=record.waveform_summary.dmd_sequence.state_table;
states=stateTable.states;
rate=double(stateTable.sample_rate_hz);
repeats=double(stateTable.round_count);
unitSamples=double(stateTable.round_samples);
start=double(stateTable.round_start_sample);
total=height(states)*repeats;
scale=daqTimeScale/rate;
if total<=MAXIMUM_EXACT_STATES
    offsets=reshape(repmat((0:repeats-1)*unitSamples,height(states),1),[],1);
    starts=repmat(double(states.start_sample),repeats,1)+start+offsets;
    levels=repmat(double(states.mod488_v),repeats,1);
    guards=repmat(double(states.mod488_guard_samples),repeats,1);
    ends=starts+repmat(double(states.duration_samples),repeats,1);
    % Two constant segments per state at most: the guard at 0 V, then the
    % state's level. A staircase is two points per segment, so a segment
    % boundary is one vertical step.
    segmentStart=[starts;starts+guards];
    segmentEnd=[starts+guards;ends];
    segmentValue=[zeros(size(levels));levels];
    keep=segmentEnd>segmentStart;
    segmentStart=segmentStart(keep); segmentEnd=segmentEnd(keep);
    segmentValue=segmentValue(keep);
    [segmentStart,order]=sort(segmentStart);
    segmentEnd=segmentEnd(order); segmentValue=segmentValue(order);
    timeS=scale*reshape([segmentStart segmentEnd]',[],1);
    commandV=reshape([segmentValue segmentValue]',[],1);
    source="adaptive_optopatch_record.waveform_summary.dmd_sequence.state_table";
    return
end
frame=double(stateTable.camera_frame_samples);
frames=ceil((start+repeats*unitSamples)/frame);
envelope=zeros(1,frames);
starts=double(states.start_sample); levels=double(states.mod488_v);
for repeat=1:repeats
    index=floor((start+(repeat-1)*unitSamples+starts)/frame)+1;
    for k=1:numel(index)
        if levels(k)>envelope(index(k)), envelope(index(k))=levels(k); end
    end
end
edgeTimes=scale*(0:frames)*frame;
timeS=reshape([edgeTimes(1:end-1);edgeTimes(2:end)],[],1);
commandV=reshape([envelope;envelope],[],1);
source="adaptive_optopatch_record.waveform_summary.dmd_sequence.state_table " + ...
    "(per-camera-frame maximum)";
end

function [fig,traceLines,roiLines,axesHandles]=build_figure( ...
        reference,traces,cellIds,command,pattern,cameraTiming,visible)
nCells=numel(cellIds);
fig=uifigure("Name","Adaptive Optopatch acquisition quick look", ...
    "Position",[100 100 1200 760],"Visible",visible);
layout=uigridlayout(fig,[1 2]);
layout.ColumnWidth={"3x","2x"}; layout.Padding=[8 8 8 8];
% One tiledlayout column, not a nested grid of uiaxes: each uiaxes sizes its
% own tick-label margin, so equal XLim still put equal times at different
% screen x. Tiles in a column share one data-region left and right edge.
plotPanel=uipanel(layout,"BorderType","none");
plotPanel.Layout.Row=1; plotPanel.Layout.Column=1;
plotLayout=tiledlayout(plotPanel,4,1,"TileSpacing","compact","Padding","tight");

traceAxes=nexttile(plotLayout,[3 1]);
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
traceTitle="Canonical soma ROI traces (voltage activity upward)";
if cameraTiming.status=="camera_clocked_aligned"
    traceTitle=[traceTitle; sprintf( ...
        "Camera-clocked DAQ: %.2f Hz frames; schedule scaled x%.4f to physical time", ...
        cameraTiming.measured_frame_rate_hz,cameraTiming.daq_time_scale)];
elseif cameraTiming.status=="cadence_aligned_offset_unknown"
    traceTitle=[traceTitle; sprintf( ...
        "VSYNC cadence %.1f Hz; absolute start offset unverified", ...
        cameraTiming.measured_frame_rate_hz)];
end
title(traceAxes,traceTitle);
grid(traceAxes,"on");

referenceAxes=uiaxes(layout); referenceAxes.Layout.Row=1; referenceAxes.Layout.Column=2;
referenceAxes.Tag="AdaptiveOptopatchReferenceAxes";
imagesc(referenceAxes,reference.reference_image); colormap(referenceAxes,gray);
axis(referenceAxes,"image"); referenceAxes.XTick=[]; referenceAxes.YTick=[];
if isempty(pattern)
    title(referenceAxes,"Acquisition mean FOV");
else
    title(referenceAxes,sprintf( ...
        "Acquisition mean FOV (12-frame pattern peak RMS %.2f%%)", ...
        100*max(pattern.phase_rms_fraction)));
end
hold(referenceAxes,"on");
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

stimAxes=nexttile(plotLayout,[1 1]);
plot(stimAxes,command.time_s,command.command_v, ...
    "Color",[0.75 0.75 0.75],"LineWidth",0.8);
stimAxes.Tag="AdaptiveOptopatchStimulationAxes"; % after plot, which resets Axes tags
hold(stimAxes,"on");
labelled=false(nCells,1);
for k=1:height(command.events)
    targetCellId=command.target_cell_ids(k);
    cellIndex=find(cellIds==targetCellId,1);
    if isempty(cellIndex), pulseColor=[0.2 0.2 0.2]; else, pulseColor=colors(cellIndex,:); end
    scale=command.time_scale_from_schedule_seconds;
    onset=scale*double(command.events.onset_s(k));
    offset=onset+scale*double(command.events.duration_s(k));
    amplitude=double(command.events.command_voltage_v(k));
    pulse=plot(stimAxes,[onset onset offset offset], ...
        [0 amplitude amplitude 0],"Color",pulseColor,"LineWidth",1.5);
    pulse.UserData=targetCellId;
    pulse.Tag="AdaptiveOptopatchStimulusPulse";
    if ~isempty(cellIndex) && ~labelled(cellIndex)
        text(stimAxes,(onset+offset)/2,amplitude,cellIds(cellIndex), ...
            "Color",pulseColor,"FontUnits","pixels","FontSize",8, ... % uiaxes size
            "FontWeight","bold","HorizontalAlignment","center", ...
            "VerticalAlignment","bottom", ...
            "HitTest","off","Tag","AdaptiveOptopatchStimulusLabel");
        labelled(cellIndex)=true;
    end
end
xlabel(stimAxes,"Time (s)"); ylabel(stimAxes,command.label);
title(stimAxes,"Executed stimulation command (labels mark each cell's first pulse)");
grid(stimAxes,"on");
endTime=max([command.time_s(end),traces.tvec(end),eps]);
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
