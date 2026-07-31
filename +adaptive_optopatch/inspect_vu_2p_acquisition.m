function report=inspect_vu_2p_acquisition(experimentFolder)
%INSPECT_VU_2P_ACQUISITION Extract 2P wiring/timing evidence without writes.
arguments
    experimentFolder (1,1) string
end
located=adaptive_optopatch.find_luminos_experiment(experimentFolder);
s=load(located.output_data_path,"Device_Data");
dd=s.Device_Data;
daq=[]; scanner=[];
for k=1:numel(dd)
    if ~isstruct(dd{k}), continue; end
    type=field_string(dd{k},"deviceType");
    name=field_string(dd{k},"name");
    if type=="DAQ", daq=dd{k}; end
    if type=="Scanning_Device" && name=="Chameleon (To friends: Ben)"
        scanner=dd{k};
    end
end
if isempty(daq) || isempty(scanner)
    error("adaptive_optopatch:MissingTwoPhotonArchive", ...
        "The acquisition lacks the combined DAQ or Chameleon scanner archive.");
end
profile=adaptive_optopatch.virtual_upright_2p_profile();
channels=struct([]);
for k=1:numel(daq.buffered_tasks)
    task=daq.buffered_tasks(k);
    for c=1:numel(task.channels)
        item=struct("task_index",k,"task_type",string(task.task_type), ...
            "clock_source",string(task.clock_source), ...
            "trigger_source",string(task.trigger_source), ...
            "name",strip(string(task.channels(c).name)), ...
            "physical_channel",string(task.channels(c).phys_channel), ...
            "sample_count",numel(task.channels(c).data));
        if isempty(channels), channels=item; else, channels(end+1)=item; end %#ok<AGROW>
    end
end
physical=string({channels.physical_channel});
required=[profile.modulator.port profile.scanner.x_port profile.scanner.y_port];
issues=strings(0,1); warnings=strings(0,1);
for port=required
    if ~any(physical==port), issues(end+1)="Missing archived output "+port+"."; end
end
hasFeedback=any(physical==profile.scanner.feedback_x_port) && ...
    any(physical==profile.scanner.feedback_y_port);
if ~hasFeedback
    warnings(end+1)="Galvo feedback Dev2/ai1 and Dev2/ai2 was not recorded.";
end
calibrationUsable=false;
try
    camera=[];
    for k=1:numel(dd)
        if isstruct(dd{k}) && field_string(dd{k},"deviceType")=="Camera" && ...
                strip(erase(field_string(dd{k},"cam_id"),"S/N: "))=="001125"
            camera=dd{k}; break
        end
    end
    roi=double(camera.ROI);
    % Hamamatsu archive order is horizontal start/size, vertical start/size.
    cameraCenter=[roi(1)+roi(2)/2 roi(3)+roi(4)/2];
    probe=cameraCenter+[0 0;10 0;0 10];
    probeV=adaptive_optopatch.camera_to_galvo_volts(scanner.tform,probe);
    calibrationUsable=all(probeV>=profile.scanner.command_bounds_v(1) & ...
        probeV<=profile.scanner.command_bounds_v(2),"all");
catch
end
if ~calibrationUsable
    warnings(end+1)=["The archived scanner transform does not map the recorded " + ...
        "camera ROI into the ±5 V scanner domain; camera targeting requires recalibration."];
end
testMetrics=struct([]);
terminalReset=struct([]);
feedbackMetrics=struct([]);
x=find_channel(channels,daq,profile.scanner.x_port);
y=find_channel(channels,daq,profile.scanner.y_port);
feedbackX=find_channel(channels,daq,profile.scanner.feedback_x_port);
feedbackY=find_channel(channels,daq,profile.scanner.feedback_y_port);
feedbackSignalsValid=false;
if hasFeedback && ~isempty(x) && ~isempty(y) && ...
        ~isempty(feedbackX) && ~isempty(feedbackY)
    commands=[x(:) y(:)];
    feedback=[feedbackX(:) feedbackY(:)];
    commandStd=std(commands,0,1);
    feedbackStd=std(feedback,0,1);
    correlation=zeros(2);
    for row=1:2
        for column=1:2
            correlation(row,column)=normalized_correlation( ...
                feedback(:,row),commands(:,column));
        end
    end
    signalThreshold=max(1e-4,0.01*min(commandStd));
    feedbackSignalsValid=all(feedbackStd>signalThreshold);
    feedbackMetrics=struct("command_std_v",commandStd, ...
        "feedback_std_v",feedbackStd, ...
        "feedback_range_v",max(feedback,[],1)-min(feedback,[],1), ...
        "zero_lag_correlation_feedback_by_command",correlation, ...
        "minimum_signal_std_v",signalThreshold, ...
        "both_axes_have_signal",feedbackSignalsValid);
    if ~feedbackSignalsValid
        warnings(end+1)=sprintf([ ...
            'Both feedback channels were archived, but their signals are ' ...
            'not both valid (Dev2/ai1 std %.4g V; Dev2/ai2 std %.4g V).'], ...
            feedbackStd(1),feedbackStd(2));
    end
end
if ~isempty(x) && ~isempty(y)
    testMetrics=adaptive_optopatch.evaluate_galvo_waveform( ...
        x(:),y(:),double(daq.global_props.rate), ...
        "CommandBoundsVolts",profile.scanner.command_bounds_v);
    step=hypot(diff(x(:)),diff(y(:)));
    [maximumStep,maximumIndex]=max(step);
    nInterior=max(1,numel(step)-1);
    interiorMaximum=max(step(1:nInterior));
    terminalReset=struct("maximum_step_v",maximumStep, ...
        "maximum_step_index",maximumIndex, ...
        "occurs_on_final_transition",maximumIndex==numel(x)-1, ...
        "interior_maximum_step_v",interiorMaximum, ...
        "interior_maximum_velocity_v_per_s", ...
        interiorMaximum*double(daq.global_props.rate));
    if terminalReset.occurs_on_final_transition && ...
            terminalReset.maximum_step_v>10*terminalReset.interior_maximum_step_v
        warnings(end+1)=sprintf([ ...
            "The archived galvo command jumps %.4g V to zero on its final " + ...
            "sample (interior maximum %.4g V); the new planner must replace " + ...
            "this abrupt reset with a bounded return."], ...
            terminalReset.maximum_step_v,terminalReset.interior_maximum_step_v);
    end
end
report=struct("schema_version","0.1.0", ...
    "experiment_directory",located.experiment_directory, ...
    "output_data_path",located.output_data_path, ...
    "profile",profile,"global_props",daq.global_props, ...
    "channels",channels,"scanner_transform",scanner.tform, ...
    "scanner_archive",scanner,"galvo_feedback_recorded",hasFeedback, ...
    "galvo_feedback_signals_valid",feedbackSignalsValid, ...
    "galvo_feedback_metrics",feedbackMetrics, ...
    "camera_targeting_calibration_usable",calibrationUsable, ...
    "command_test_metrics",testMetrics,"terminal_reset",terminalReset, ...
    "issues",issues,"warnings",warnings, ...
    "passed",isempty(issues));
end

function value=normalized_correlation(a,b)
a=double(a(:))-mean(a);
b=double(b(:))-mean(b);
value=sum(a.*b)/(sqrt(sum(a.^2)*sum(b.^2))+eps);
end

function data=find_channel(channels,daq,port)
data=[];
for k=1:numel(channels)
    if channels(k).physical_channel==port
        c=channels(k); task=daq.buffered_tasks(c.task_index);
        for j=1:numel(task.channels)
            if string(task.channels(j).phys_channel)==port
                data=double(task.channels(j).data); return
            end
        end
    end
end
end

function value=field_string(s,name)
if isfield(s,name), value=string(s.(name)); else, value=""; end
end
