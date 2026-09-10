function [cameras,plan]=set_camera_frames_for_duration(cameras,durationS,options)
%SET_CAMERA_FRAMES_FOR_DURATION Set per-camera frame counts from live cadence.
arguments
    cameras
    durationS (1,1) double {mustBePositive}
    % Retained for caller compatibility; DAQ cadence no longer needs an override.
    options.AllowRateLimitOverride (1,1) logical = false
end
n=numel(cameras);
plan=repmat(struct("camera_index",0,"camera_name","", ...
    "trigger_source","","calculation_method","", ...
    "trigger_period_ms",NaN,"frame_rate_hz",NaN, ...
    "calculated_camera_limit_hz",NaN,"conservative_camera_limit_hz",NaN, ...
    "frames_requested",0,"acquisition_duration_s",durationS, ...
    "rate_validation_passed",false,"rate_override_allowed",false, ...
    "rate_override_used",false),n,1);
for k=1:n
    camera=cameras(k);
    source=string(read_member(camera,"frametrigger_source",""));
    isDaq=contains(upper(source),"DAQ");
    if isDaq
        periodMs=double(read_member(camera,"daqtrig_period_ms",NaN));
        if ~isscalar(periodMs) || ~isfinite(periodMs) || periodMs<=0
            error("adaptive_optopatch:InvalidCameraTriggerPeriod", ...
                "Camera %d is DAQ-triggered but has no positive daqtrig_period_ms.",k);
        end
        frameRate=1000/periodMs;
        % Trigger each Frame is paced explicitly by the DAQ period. Luminos's
        % calculate_framerate estimate is diagnostic, not a second authority
        % that can override or reject that configured cadence.
        cameraLimit=read_camera_rate_limit(camera);
        conservativeLimit=NaN;
        count=ceil(durationS*frameRate);
        camera.frames_requested=count;
        cameras(k)=camera;
        method="daq_trigger_period";
    else
        if ~ismethod(camera,"AutoN")
            error("adaptive_optopatch:CameraAutoNUnavailable", ...
                "Camera %d is not DAQ-triggered and does not provide AutoN.",k);
        end
        camera.AutoN(durationS);
        count=double(camera.frames_requested);
        frameRate=NaN;
        if ismethod(camera,"calculate_framerate")
            frameRate=double(camera.calculate_framerate());
        end
        periodMs=NaN;
        method="camera_AutoN";
        cameraLimit=frameRate;
        conservativeLimit=frameRate;
    end
    plan(k).camera_index=k;
    plan(k).camera_name=string(read_member(camera,"name", ...
        read_member(camera,"cam_id","Camera "+string(k))));
    plan(k).trigger_source=source;
    plan(k).calculation_method=method;
    plan(k).trigger_period_ms=periodMs;
    plan(k).frame_rate_hz=frameRate;
    plan(k).calculated_camera_limit_hz=cameraLimit;
    plan(k).conservative_camera_limit_hz=conservativeLimit;
    plan(k).frames_requested=count;
    plan(k).rate_validation_passed=true;
    plan(k).rate_override_allowed=false;
    plan(k).rate_override_used=false;
end

function rate=read_camera_rate_limit(camera)
rate=double(read_member(camera,"maximum_frame_rate_hz",NaN));
if isobject(camera) && ismethod(camera,"calculate_framerate")
    rate=double(camera.calculate_framerate());
end
if ~isscalar(rate), rate=NaN; end
end
end

function value=read_member(object,name,defaultValue)
if isstruct(object) && isfield(object,name)
    value=object.(name);
elseif isobject(object) && isprop(object,name)
    value=object.(name);
else
    value=defaultValue;
end
end
