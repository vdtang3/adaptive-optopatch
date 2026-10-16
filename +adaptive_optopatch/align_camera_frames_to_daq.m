function [frameTime,report]=align_camera_frames_to_daq(outputDataPath,camera,nominalTime)
%ALIGN_CAMERA_FRAMES_TO_DAQ Use VSYNC edges for frame times or measured cadence.
%   When the DAQ sample clock is the camera's own line clock (Spinning
%   Upright: camera clock = DAQ clock_source), one DAQ sample is one camera
%   line, not 1/global_props.rate seconds. Frames are then placed on the
%   VSYNC grid extended back to the first frame period of the DAQ record
%   (the counter misses its first edges; the camera starts with the DAQ),
%   and seconds come from the camera exposure time. report.daq_time_scale
%   converts nominal DAQ/protocol seconds to the same physical seconds.
frameTime=nominalTime;
report=struct("source","nominal_frame_rate","counter_port","", ...
    "detected_edges",0,"movie_frames",numel(nominalTime), ...
    "first_frame_offset_s",NaN,"first_detected_edge_s",NaN, ...
    "measured_frame_rate_hz",NaN,"absolute_offset_known",false, ...
    "daq_time_scale",1,"physical_daq_rate_hz",NaN, ...
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
        if is_camera_clocked(device,camera) && numel(edges)>=20
            [frameTime,report]=camera_clocked_times(values,edges,rate, ...
                double(camera.exposuretime),numel(nominalTime),report);
            return
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

function tf=is_camera_clocked(device,camera)
normalize=@(x) regexprep(lower(string(x)),"[^a-z0-9]","");
tf=isfield(device.global_props,"clock_source") && isfield(camera,"raw_archive") && ...
    isfield(camera.raw_archive,"clock") && ...
    strlength(normalize(camera.raw_archive.clock))>0 && ...
    normalize(camera.raw_archive.clock)==normalize(device.global_props.clock_source) && ...
    isfield(camera,"exposuretime") && isscalar(camera.exposuretime) && ...
    isfinite(double(camera.exposuretime)) && double(camera.exposuretime)>0;
end

function [frameTime,report]=camera_clocked_times(values,edges,nominalRate,framePeriod,nFrames,report)
samplesPerFrame=(double(edges(end))-double(edges(1)))/(numel(edges)-1);
gridError=double(edges)-(double(edges(1))+(0:numel(edges)-1)'*samplesPerFrame);
if any(diff(values([1;edges]))~=1) || max(abs(gridError))>2
    error("adaptive_optopatch:IrregularVsyncCounter", ...
        "VSYNC edges on the camera-clocked DAQ are not one regular frame grid.");
end
physicalRate=samplesPerFrame/framePeriod;
firstStart=double(edges(1))-floor((double(edges(1))-1)/samplesPerFrame)*samplesPerFrame;
frameTime=(firstStart-1+(0:nFrames-1)'*samplesPerFrame)/physicalRate;
report.source="camera_clocked_vsync_grid";
report.measured_frame_rate_hz=1/framePeriod;
report.physical_daq_rate_hz=physicalRate;
report.daq_time_scale=nominalRate/physicalRate;
report.first_frame_offset_s=frameTime(1);
report.absolute_offset_known=true;
report.status="camera_clocked_aligned";
end
