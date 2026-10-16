function [frameTime,report]=align_camera_frames_to_daq(outputDataPath,camera,nominalTime)
%ALIGN_CAMERA_FRAMES_TO_DAQ Use VSYNC edges for frame times or measured cadence.
frameTime=nominalTime;
report=struct("source","nominal_frame_rate","counter_port","", ...
    "detected_edges",0,"movie_frames",numel(nominalTime), ...
    "first_frame_offset_s",NaN,"first_detected_edge_s",NaN, ...
    "measured_frame_rate_hz",NaN,"absolute_offset_known",false, ...
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
            % Missing edges do not identify the matching movie frame. A
            % stable counter cadence still measures frame spacing without
            % claiming to know the movie's absolute DAQ start offset.
            report.status="frame_count_mismatch";
            if numel(edges)>=20 && numel(nominalTime)>1
                periods=diff(double(edges))/rate;
                framePeriod=median(periods);
                increments=diff(values([1;edges]));
                regular=all(increments==1) && ...
                    all(abs(periods-framePeriod)<=max(2/rate,0.05*framePeriod));
                if regular && isfinite(framePeriod) && framePeriod>0
                    frameTime=double(nominalTime(1))+ ...
                        (0:numel(nominalTime)-1)'*framePeriod;
                    report.source="archived_camera_vsync_cadence";
                    report.measured_frame_rate_hz=1/framePeriod;
                    report.status="cadence_aligned_offset_unknown";
                end
            end
        else
            frameTime=(double(edges)-1)/rate;
            report.source="archived_camera_vsync_counter";
            report.first_frame_offset_s=frameTime(1)-double(nominalTime(1));
            if numel(frameTime)>1
                report.measured_frame_rate_hz=1/median(diff(frameTime));
            end
            report.absolute_offset_known=true;
            report.status="aligned";
        end
        return
    end
end
end
