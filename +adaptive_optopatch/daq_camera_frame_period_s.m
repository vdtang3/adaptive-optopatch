function periodS=daq_camera_frame_period_s(camera)
%DAQ_CAMERA_FRAME_PERIOD_S Frame period of a DAQ-triggered camera, else NaN.
%   A DAQ-triggered camera's daqtrig_period_ms is the authoritative frame
%   cadence (see set_camera_frames_for_duration). A free-running or
%   camera-clocked camera has no DAQ frame period, and NaN says so.
arguments
    camera
end
periodS=NaN;
try
    source=string(camera.frametrigger_source);
    if ~isscalar(source) || ~contains(upper(source),"DAQ"), return; end
    periodMs=double(camera.daqtrig_period_ms);
catch
    return
end
if isscalar(periodMs) && isfinite(periodMs) && periodMs>0
    periodS=periodMs/1000;
end
end
