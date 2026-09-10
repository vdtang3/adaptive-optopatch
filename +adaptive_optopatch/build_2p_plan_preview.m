function preview=build_2p_plan_preview(protocol,target,hardware,options)
%BUILD_2P_PLAN_PREVIEW Shared guarded 2P preview used by both runner GUIs.
arguments
    protocol (1,1) struct
    target (1,1) struct
    hardware (1,1) struct
    options.ReleaseLevel (1,1) string = "blocked_test"
    options.MaximumVelocityVPerS (1,1) double {mustBePositive} = 1000
    options.MaximumAccelerationVPerS2 (1,1) double {mustBePositive} = 6e6
    options.AllowCalibrationExtrapolation (1,1) logical = false
    % A frozen run executes the targeting transform archived with it. Preview
    % must draw the same trajectory, so callers that will execute a frozen
    % plan pass that transform here instead of letting the preview fall back
    % to whatever calibration is active now.
    options.TargetingTransform = []
end
motion=adaptive_optopatch.validate_provisional_2p_motion_limits( ...
    options.MaximumVelocityVPerS,options.MaximumAccelerationVPerS2);
if ~motion.passed
    error("adaptive_optopatch:UnvalidatedGalvoMotionLimits", ...
        "%s",strjoin(motion.issues,newline));
end
coverage=adaptive_optopatch.validate_2p_calibration_coverage( ...
    target,hardware.calibration);
if ~coverage.passed && ~options.AllowCalibrationExtrapolation
    error("adaptive_optopatch:TargetOutsideGalvoCalibration", ...
        "The target lies outside the accepted calibration hull. " + ...
        "Enable calibration extrapolation to proceed. Details: %s", ...
        strjoin(coverage.issues," "));
end
minimumRadiusFraction=0.95;
if options.ReleaseLevel=="blocked_test", minimumRadiusFraction=eps; end
if ~isempty(options.TargetingTransform)
    tform=options.TargetingTransform;
    targetingSource="frozen_plan";
else
    tform=hardware.scanner.tform;
    targetingSource="live_scanner";
    if isfield(hardware,"calibration") && isfield(hardware.calibration,"calibration") && ...
            isfield(hardware.calibration.calibration,"tform")
        tform=hardware.calibration.calibration.tform;
        targetingSource="active_calibration";
    end
end
% 2P timing is frozen in samples: build_2p_trial_waveforms emits literal
% sample vectors that Luminos replays at its active rate, so the two must be
% one number rather than two independent constants.
waveforms=adaptive_optopatch.build_2p_trial_waveforms( ...
    protocol,target,tform, ...
    "SampleRateHz",active_sample_rate(hardware), ...
    "MaximumVelocityVPerS",options.MaximumVelocityVPerS, ...
    "MaximumAccelerationVPerS2",options.MaximumAccelerationVPerS2, ...
    "MinimumIlluminatedRadiusFraction",minimumRadiusFraction);
preview=struct("schema_version","0.2.0","waveforms",waveforms, ...
    "calibration_coverage",coverage,"motion_validation",motion, ...
    "targeting_tform",tform,"targeting_transform_source",targetingSource);
end

function rate=active_sample_rate(hardware)
rate=adaptive_optopatch.virtual_upright_2p_profile().scanner.sample_rate_hz;
if ~isfield(hardware,"daq") || isempty(hardware.daq), return; end
try
    live=double(hardware.daq.global_props.rate);
catch
    return
end
if isscalar(live) && isfinite(live) && live>0, rate=live; end
end
