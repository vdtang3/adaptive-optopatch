classdef RampReviewApp < handle
    %RAMPREVIEWAPP Lightweight manual review of a completed Blue ramp.
    properties (SetAccess=private)
        Figure
        UpdatedFovState struct
        TargetCellId string
        TraceResult struct
    end
    properties (Access=private)
        Protocol struct
        ExperimentDirectory string
        DecisionAppliedFcn
        ObisPowerW double = NaN
        VoltageField
        StatusDropdown
        NotesArea
    end

    methods
        function app=RampReviewApp(experimentDirectory,protocol,fovState,options)
            arguments
                experimentDirectory (1,1) string
                protocol (1,1) struct
                fovState (1,1) struct
                options.Visible (1,1) string {mustBeMember(options.Visible,["on","off"])} = "on"
                options.TraceResult (1,1) struct = struct
                options.DecisionAppliedFcn = []
            end
            app.ExperimentDirectory=experimentDirectory;
            app.Protocol=adaptive_optopatch.normalize_protocol(protocol);
            app.UpdatedFovState=fovState;
            app.DecisionAppliedFcn=options.DecisionAppliedFcn;
            app.ObisPowerW=archived_obis_power(experimentDirectory);
            ids=unique(app.Protocol.events.target_cell_id(~app.Protocol.events.is_null));
            if numel(ids)~=1
                error("adaptive_optopatch:RampTargetMismatch", ...
                    "A single-cell ramp review requires exactly one target cell.");
            end
            app.TargetCellId=ids;
            if isempty(fieldnames(options.TraceResult))
                app.TraceResult=adaptive_optopatch.extract_roi_traces( ...
                    experimentDirectory,fovState.reference);
            else
                app.TraceResult=options.TraceResult;
            end
            app.buildUi(options.Visible);
        end

        function fovState=applyDecision(app,voltage,status,notes)
            arguments
                app
                voltage (1,1) double
                status (1,1) string {mustBeMember(status, ...
                    ["good","unreliable","multispike","off_target","excluded"])}
                notes (1,1) string = ""
            end
            durations=1000*app.Protocol.events.duration_s(~app.Protocol.events.is_null);
            stimulationEnabled=status~="excluded";
            app.UpdatedFovState=adaptive_optopatch.update_cell_calibration( ...
                app.UpdatedFovState,app.TargetCellId,"CommandVoltageV",voltage, ...
                "Status",status,"StimulationEnabled",stimulationEnabled, ...
                "Notes",notes,"Acquisition",app.ExperimentDirectory, ...
                "PulseDurationMs",durations(1),"ObisPowerW",app.ObisPowerW);
            if ~isempty(app.DecisionAppliedFcn)
                app.DecisionAppliedFcn(app.UpdatedFovState);
            end
            fovState=app.UpdatedFovState;
        end

        function delete(app)
            if ~isempty(app.Figure) && isvalid(app.Figure), delete(app.Figure); end
        end
    end

    methods (Access=private)
        function buildUi(app,visible)
            app.Figure=uifigure("Name","Blue ramp review — "+app.TargetCellId, ...
                "Position",[120 100 1180 760],"Visible",visible);
            root=uigridlayout(app.Figure,[3 2]);
            root.RowHeight={"1x","1x",110}; root.ColumnWidth={"1x","1x"};
            targetAxes=uiaxes(root); targetAxes.Layout.Row=1; targetAxes.Layout.Column=1;
            averageAxes=uiaxes(root); averageAxes.Layout.Row=1; averageAxes.Layout.Column=2;
            neighborAxes=uiaxes(root); neighborAxes.Layout.Row=2; neighborAxes.Layout.Column=1;
            [relativeMs,aligned,targetIndex]=app.alignedTraces();
            levels=unique(app.Protocol.events.command_voltage_v,"stable");
            colors=lines(numel(levels)); hold(targetAxes,"on"); hold(averageAxes,"on");
            for k=1:numel(levels)
                selected=app.Protocol.events.command_voltage_v==levels(k);
                plot(targetAxes,relativeMs,aligned(:,selected,targetIndex), ...
                    "Color",0.65+0.35*colors(k,:));
                plot(averageAxes,relativeMs,mean(aligned(:,selected,targetIndex),2,"omitnan"), ...
                    "Color",colors(k,:),"LineWidth",1.5,"DisplayName",sprintf('%.4g V',levels(k)));
            end
            xline(targetAxes,0,"k--"); xline(averageAxes,0,"k--");
            title(targetAxes,"Target-cell event-aligned traces");
            title(averageAxes,"Mean response by command voltage"); legend(averageAxes,"Location","best");
            xlabel(targetAxes,"Time from pulse (ms)"); xlabel(averageAxes,"Time from pulse (ms)");
            ylabel(targetAxes,"Corrected fluorescence"); ylabel(averageAxes,"Corrected fluorescence");
            neighbors=setdiff(1:size(aligned,3),targetIndex);
            if isempty(neighbors)
                text(neighborAxes,0.5,0.5,"No neighboring recording cells", ...
                    "Units","normalized","HorizontalAlignment","center");
            else
                neighborMean=squeeze(mean(aligned(:,:,neighbors),2,"omitnan"));
                plot(neighborAxes,relativeMs,neighborMean);
                xline(neighborAxes,0,"k--");
            end
            title(neighborAxes,"Neighbor-cell mean event-aligned traces");
            xlabel(neighborAxes,"Time from pulse (ms)"); ylabel(neighborAxes,"Corrected fluorescence");
            if all(isfield(app.TraceResult,["spike_count","neighbor_spike_count"]))
                latency=nan(height(app.Protocol.events),1);
                if isfield(app.TraceResult,"first_spike_latency_ms")
                    latency=app.TraceResult.first_spike_latency_ms;
                end
                statistics=adaptive_optopatch.summarize_ramp_response(app.Protocol, ...
                    app.TraceResult.spike_count,app.TraceResult.neighbor_spike_count,latency);
                statisticsTable=uitable(root,"Data",statistics);
                statisticsTable.Layout.Row=2; statisticsTable.Layout.Column=2;
            else
                note=uitextarea(root,"Value", ...
                    "No pulse-level spike detections were supplied. "+ ...
                    "Manual calibration remains available.","Editable","off");
                note.Layout.Row=2; note.Layout.Column=2;
            end

            controls=uigridlayout(root,[2 6]); controls.Layout.Row=3; controls.Layout.Column=[1 2];
            controls.RowHeight={28,"1x"}; controls.ColumnWidth={120,100,70,140,90,"1x"};
            uilabel(controls,"Text","Chosen voltage (V)");
            app.VoltageField=uieditfield(controls,"numeric","Value",levels(1), ...
                "Limits",[eps 5]);
            uilabel(controls,"Text","Status");
            app.StatusDropdown=uidropdown(controls,"Items", ...
                ["good","unreliable","multispike","off_target","excluded"],"Value","good");
            uibutton(controls,"Text","Save decision", ...
                "ButtonPushedFcn",@(~,~)app.saveFromControls());
            uilabel(controls,"Text","The operator's decision is authoritative; plots are review aids.");
            notesLabel=uilabel(controls,"Text","Notes"); notesLabel.Layout.Row=2;
            app.NotesArea=uitextarea(controls); app.NotesArea.Layout.Row=2; app.NotesArea.Layout.Column=[2 6];
        end

        function [relativeMs,aligned,targetIndex]=alignedTraces(app)
            ids=string({app.UpdatedFovState.cells.cell_id});
            targetIndex=find(ids==app.TargetCellId,1);
            if isempty(targetIndex), error("adaptive_optopatch:UnknownCellId","Unknown cell ID: %s",app.TargetCellId); end
            t=double(app.TraceResult.tvec(:)); traces=double(app.TraceResult.corrected_traces);
            frameRate=double(app.TraceResult.frame_rate_hz);
            if ~isfinite(frameRate), frameRate=1/median(diff(t)); end
            pulseMs=1000*max(app.Protocol.events.duration_s);
            relativeMs=(-20:1000/frameRate:max(50,pulseMs+40))';
            onsets=app.Protocol.events.onset_s;
            aligned=nan(numel(relativeMs),numel(onsets),size(traces,2));
            for k=1:numel(onsets)
                query=onsets(k)+relativeMs/1000;
                aligned(:,k,:)=reshape(interp1(t,traces,query,"linear",NaN), ...
                    numel(relativeMs),1,size(traces,2));
            end
        end

        function saveFromControls(app)
            notes=strjoin(string(app.NotesArea.Value),newline);
            app.applyDecision(app.VoltageField.Value,string(app.StatusDropdown.Value),notes);
            app.Figure.Name="Blue ramp review — saved "+app.TargetCellId;
        end
    end
end

function value=archived_obis_power(experimentDirectory)
value=NaN;
path=fullfile(experimentDirectory,"output_data.mat");
if ~isfile(path), return; end
try
    saved=load(path,"adaptive_optopatch_record");
    if isfield(saved,"adaptive_optopatch_record") && ...
            isfield(saved.adaptive_optopatch_record,"obis_power_w")
        value=double(saved.adaptive_optopatch_record.obis_power_w);
    end
catch
end
end
