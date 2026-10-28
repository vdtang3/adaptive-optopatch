function cadence=camera_cadence_for_profile(profile)
%CAMERA_CADENCE_FOR_PROFILE The frame cadence a rig profile declares, if any.
%   cadence=CAMERA_CADENCE_FOR_PROFILE(profile) reads the three camera
%   properties adaptive_optopatch imposes during an acquisition. The
%   declared flag is what lets the Virtual Upright take ownership of its
%   camera timing while a rig whose profile predates this - the Spinning
%   Upright, whose camera is counter-triggered through a different path -
%   keeps inheriting the Camera tab's cadence until somebody has checked it
%   on that rig.
%
%   One reader for one question, so the runner, the controller's preflight
%   and the interface cannot disagree about whether a rig owns its camera.
arguments
    profile (1,1) struct
end
cadence=struct("declared",false, ...
    "frame_trigger_source","", ...
    "frame_period_ms",NaN, ...
    "frame_rate_hz",NaN, ...
    "acquisition_exposure_s",NaN);
if ~isfield(profile,"camera"), return; end
camera=profile.camera;
required=["frame_trigger_source","frame_period_ms","acquisition_exposure_s"];
if ~all(isfield(camera,required)), return; end

period=double(camera.frame_period_ms);
exposure=double(camera.acquisition_exposure_s);
if ~isscalar(period) || ~isfinite(period) || period<=0
    error("adaptive_optopatch:InvalidProfileFramePeriod", ...
        "The rig profile's camera.frame_period_ms must be a positive period.");
end
if ~isscalar(exposure) || ~isfinite(exposure) || exposure<=0
    error("adaptive_optopatch:InvalidProfileExposure", ...
        "The rig profile's camera.acquisition_exposure_s must be positive.");
end
% In synchronous readout the frame ends when the next trigger arrives, so an
% exposure longer than the period describes a frame the camera cannot
% deliver, and Camera.calculate_framerate would archive a rate the recording
% does not have. Caught here, where the profile is written, rather than on
% the rig.
if exposure>period/1000+1e-12
    error("adaptive_optopatch:ExposureExceedsFramePeriod", ...
        "The rig profile asks for a %.6g ms exposure inside a %.6g ms " + ...
        "frame period.",1000*exposure,period);
end
cadence.declared=true;
cadence.frame_trigger_source=string(camera.frame_trigger_source);
cadence.frame_period_ms=period;
cadence.frame_rate_hz=1000/period;
cadence.acquisition_exposure_s=exposure;
end
