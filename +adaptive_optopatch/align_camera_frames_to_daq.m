function [frameTime,report]=align_camera_frames_to_daq(outputDataPath,camera,nominalTime)
%ALIGN_CAMERA_FRAMES_TO_DAQ Use archived VSYNC counts when every frame matches.
frameTime=nominalTime;
report=struct("source","nominal_frame_rate","counter_port","", ...
    "detected_edges",0,"movie_frames",numel(nominalTime), ...
    "first_frame_offset_s",NaN,"first_detected_edge_s",NaN, ...
    "status","counter_unavailable");
saved=load(outputDataPath,"Device_Data");
if ~isfield(saved,"Device_Data"), return; end
devices=saved.Device_Data;
cameraIndex=double(camera.archive_index);
if cameraIndex<1 || cameraIndex>numel(devices) || ...
        ~isfield(devices{cameraIndex},"vsync")
    return
end
counterPort=string(devices{cameraIndex}.vsync);
report.counter_port=counterPort;
for deviceIndex=1:numel(devices)
    device=devices{deviceIndex};
    if ~isstruct(device) || ~isfield(device,"Counter_Inputs") || ...
            ~isfield(device,"global_props") || ...
            ~isfield(device.global_props,"rate")
        continue
    end
    rate=double(device.global_props.rate);
    if ~isscalar(rate) || ~isfinite(rate) || rate<=0, continue; end
    counters=device.Counter_Inputs;
    for counterIndex=1:numel(counters)
        counter=counters(counterIndex);
        if ~strcmpi(string(counter.counter),counterPort), continue; end
        values=double(counter.data(:));
        edges=find(diff(values)>0)+1;
        report.detected_edges=numel(edges);
        if ~isempty(edges)
            report.first_detected_edge_s=(double(edges(1))-1)/rate;
        end
        if isempty(edges)
            report.status="no_counter_edges";
        elseif numel(edges)~=numel(nominalTime)
            % An incomplete counter trace cannot identify which movie frames
            % lack edges. Applying its first edge would imply a false mapping.
            report.status="frame_count_mismatch";
        else
            frameTime=(double(edges)-1)/rate;
            report.source="archived_camera_vsync_counter";
            report.first_frame_offset_s=frameTime(1)-double(nominalTime(1));
            report.status="aligned";
        end
        return
    end
end
end
