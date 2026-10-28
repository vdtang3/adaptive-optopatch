function hardware = resolve_luminos_1p_hardware(app,profile,options)
%RESOLVE_LUMINOS_1P_HARDWARE Find and validate the live VU blue-light path.
arguments
    app
    profile (1,1) struct = adaptive_optopatch.virtual_upright_1p_profile()
    options.RequireCalibratedDmd (1,1) logical = true
end
if isempty(app)
    error("adaptive_optopatch:MissingLuminosApp", ...
        "A live Luminos app object is required.");
end
if isprop(app,"acquisition_active") && logical(app.acquisition_active)
    error("adaptive_optopatch:LuminosAcquisitionActive", ...
        "Luminos already reports an active acquisition.");
end

hardware=struct;
hardware.daq=require_device(app,"DAQ",profile.daq.name);
hardware.dmd=require_device(app,"DMD",profile.dmd.name);
hardware.laser=[];
if string(profile.laser.device_type)~="none"
    hardware.laser=require_device(app,"Laser_Device",profile.laser.name);
end
hardware.modulator=require_device(app,"NI_DAQ_Modulator",profile.modulator.name);
hardware.shutter=require_device(app,"NI_DAQ_Shutter",profile.shutter.name);
hardware.dmd_trigger=require_device(app,"NI_DAQ_Shutter",profile.dmd.trigger_alias);
% The orange recording path, resolved here because AO now drives it for the
% length of an acquisition: a constant on mod594 from the buffer, and
% shutter594 opened and closed imperatively around the armed window. A rig
% profile that declares neither keeps inheriting the operator's own orange
% configuration, which is what every rig did before this.
hardware.orange_modulator=[];
hardware.orange_shutter=[];
hardware.owns_orange_illumination=isfield(profile,"orange_modulator");
if hardware.owns_orange_illumination
    hardware.orange_modulator=require_device(app,"NI_DAQ_Modulator", ...
        profile.orange_modulator.name);
    if string(hardware.orange_modulator.port)~=string(profile.orange_modulator.port)
        error("adaptive_optopatch:UnexpectedOrangeModulatorPort", ...
            "%s is on %s; the profile requires %s.", ...
            profile.orange_modulator.name, ...
            string(hardware.orange_modulator.port), ...
            string(profile.orange_modulator.port));
    end
end
if isfield(profile,"orange_shutter")
    hardware.orange_shutter=require_device(app,"NI_DAQ_Shutter", ...
        profile.orange_shutter.name);
    if string(hardware.orange_shutter.port)~=string(profile.orange_shutter.port)
        error("adaptive_optopatch:UnexpectedOrangeShutterPort", ...
            "%s is on %s; the profile requires %s.", ...
            profile.orange_shutter.name, ...
            string(hardware.orange_shutter.port), ...
            string(profile.orange_shutter.port));
    end
end
% The recording DMD is resolved here only so its Luminos-owned calibration
% can be archived with the run. prepare_luminos_orange_mask remains the
% place that requires it and validates it before programming a mask, so a
% missing or uncalibrated DMD_Orange still fails there, with its message.
hardware.orange_dmd=optional_device(app,"DMD",profile.orange_dmd.name);
hardware.cameras=app.getDevice("Camera");

if string(hardware.modulator.port)~=string(profile.modulator.port)
    error("adaptive_optopatch:UnexpectedModulatorPort", ...
        "mod488 is on %s; the profile requires %s.", ...
        string(hardware.modulator.port),string(profile.modulator.port));
end
if string(hardware.shutter.port)~=string(profile.shutter.port)
    error("adaptive_optopatch:UnexpectedShutterPort", ...
        "shutter488 is on %s; the profile requires %s.", ...
        string(hardware.shutter.port),string(profile.shutter.port));
end
if string(hardware.dmd_trigger.port)~=string(profile.dmd.trigger_port)
    error("adaptive_optopatch:UnexpectedDmdTriggerPort", ...
        "DMD Trigger is on %s; the profile requires %s.", ...
        string(hardware.dmd_trigger.port),string(profile.dmd.trigger_port));
end
serials=strings(numel(hardware.cameras),1);
for k=1:numel(hardware.cameras)
    serials(k)=strip(erase(string(hardware.cameras(k).cam_id),"S/N: "));
end
cameraIndex=find(serials==string(profile.camera.serial),1);
if isempty(cameraIndex)
    error("adaptive_optopatch:VoltageCameraNotFound", ...
        "Voltage camera serial %s is not present in the live rig.",profile.camera.serial);
end
hardware.voltage_camera_index=cameraIndex;
hardware.voltage_camera=hardware.cameras(cameraIndex);

if isempty(hardware.dmd.trigger_channel)
    hardware.dmd.trigger_channel=profile.dmd.trigger_port;
elseif ~same_terminal(hardware.daq,hardware.dmd.trigger_channel,profile.dmd.trigger_port)
    error("adaptive_optopatch:UnexpectedDmdTriggerPort", ...
        "DMD_Blue trigger is %s; the profile requires %s.", ...
        string(hardware.dmd.trigger_channel),profile.dmd.trigger_port);
end

if options.RequireCalibratedDmd
    if isempty(hardware.dmd.tform) || is_identity_transform(hardware.dmd.tform)
        error("adaptive_optopatch:UncalibratedDmd", ...
            "DMD_Blue has no nonidentity camera-to-DMD transform.");
    end
    if isempty(hardware.dmd.refimage)
        error("adaptive_optopatch:MissingDmdReference", ...
            "DMD_Blue has no calibration reference image.");
    end
end

hardware.laser_mode="not_managed";
hardware.laser_was_on=false;
hardware.laser_power_w=NaN;
hardware.laser_interlock_ok=NaN;
if ~isempty(hardware.laser)
    hardware.laser_mode=string(hardware.laser.Mode);
    hardware.laser_was_on=logical(hardware.laser.Get_state());
    hardware.laser_power_w=double(hardware.laser.SetPower);
    hardware.laser_interlock_ok=logical(hardware.laser.Get_interlockStatus());
    if ~hardware.laser_interlock_ok
        error("adaptive_optopatch:LaserInterlockOpen", ...
            "The 488 OBIS reports that its key or interlock is not enabled.");
    end
    if hardware.laser_power_w<0 || hardware.laser_power_w>profile.laser.max_power_w
        error("adaptive_optopatch:ActiveLaserPowerOutOfRange", ...
            "The active OBIS setpoint %.4g W is outside the profile range 0-%.4g W.", ...
            hardware.laser_power_w,profile.laser.max_power_w);
    end
end
% THE ACQUISITION'S TIMING IS AO'S, not the Waveforms tab's.
%
% This used to refuse to go on unless DAQ.global_props already carried a
% struct, which on a fresh Luminos it never does - the property is unset
% until load_waveform_from_json runs - so Adaptive Optopatch could not start
% until somebody had opened Waveforms and loaded a protocol. Worse, what
% that protocol happened to contain then decided the run: the sample rate is
% what every 1P pulse boundary, the blanket state table and the 2P galvo
% waveforms are quantised to, so a tab left at a different rate silently
% changed the experiment and nothing said so.
%
% AO builds the whole struct from the rig profile instead. Built with a
% nominal one-second duration here, which exists only to validate the
% profile and to describe the topology below; the runner rebuilds it per
% trial with that trial's real duration.
%
% OPT-IN PER RIG, through daq.sample_rate_hz. The Virtual Upright declares
% one and AO owns its timing. The Spinning Upright does not, and must not:
% its DAQ is genuinely clocked from the Orange camera's line sync, so the
% real sample rate is a property of that camera rather than a number a
% profile can state, and nothing has been checked on that rig. There it
% keeps inheriting the Waveforms tab, which is what every rig did before
% this - including the gate below, which is the thing a VU operator no
% longer meets.
hardware.owns_daq_timing=isfield(profile.daq,"sample_rate_hz");
hardware.ao_global_props=struct([]);
hardware.daq_timing=struct([]);
if hardware.owns_daq_timing
    hardware.ao_global_props=adaptive_optopatch.build_luminos_global_props( ...
        profile,1);
    [~,hardware.daq_timing]=adaptive_optopatch.build_luminos_global_props( ...
        profile,1,"PreviousGlobalProps",live_global_props(hardware.daq));
elseif ~isstruct(hardware.daq.global_props) || ...
        isempty(fieldnames(hardware.daq.global_props))
    error("adaptive_optopatch:NoActiveLuminosWaveform", ...
        "This rig profile declares no acquisition sample rate, so " + ...
        "Adaptive Optopatch takes its timing from Luminos. Load an " + ...
        "active Luminos waveform protocol before starting the runner.");
end
% wfm_data is still read from the device, because AO edits the operator's
% record set rather than replacing it wholesale - it removes every ambient
% spelling of the terminals it owns and leaves everything else alone. An
% unset wfm_data simply means there is nothing ambient to remove.
% Scalar as well as a struct: an unset wfm_data reaches this as [] on a
% live DAQ and as an EMPTY STRUCT ARRAY on any object whose property is
% declared `struct`, and the second passes isstruct while failing every
% (1,1) struct argument downstream.
if ~isstruct(hardware.daq.wfm_data) || ~isscalar(hardware.daq.wfm_data)
    hardware.daq.wfm_data=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[]);
end
% Described against the configuration AO will install. The multi-device
% checks inside are about the rig's physical bridges and the tasks the run
% will build, which is a real question; "has the operator selected a clock"
% is no longer one.
hardware.daq_sync=adaptive_optopatch.capture_luminos_daq_sync(hardware.daq, ...
    "GlobalProps",hardware.ao_global_props);
if ~hardware.owns_daq_timing
    % An inheriting rig still has to be checked the old way: what it is
    % about to run on is the operator's selection, not AO's.
    if ~isfield(hardware.daq.global_props,"rate") || ...
            ~isscalar(hardware.daq.global_props.rate) || ...
            ~isfinite(hardware.daq.global_props.rate) || ...
            hardware.daq.global_props.rate<=0
        error("adaptive_optopatch:InvalidWaveformRate", ...
            "The active Luminos waveform sample rate must be positive.");
    end
end
if ~same_terminals(hardware.daq_sync.default_trigger,profile.daq.default_trigger)
    error("adaptive_optopatch:UnexpectedMultiDaqTriggers", ...
        "The live DAQ trigger terminals are [%s]; expected [%s].", ...
        strjoin(hardware.daq_sync.default_trigger,", "), ...
        strjoin(profile.daq.default_trigger,", "));
end
if ~same_terminals(hardware.daq_sync.clock_bridge,profile.daq.clock_bridge)
    error("adaptive_optopatch:UnexpectedClockBridge", ...
        "The live DAQ clock bridge is [%s]; expected [%s].", ...
        strjoin(hardware.daq_sync.clock_bridge,", "), ...
        strjoin(profile.daq.clock_bridge,", "));
end
% The self-trigger and clock-master checks that used to live here read
% global_props, so they now describe values AO itself has just written and
% could only ever pass. They are kept as an assertion on the PROFILE, which
% is the thing a person edits and can get wrong, rather than deleted - a
% profile naming a clock master the rig cannot be is still worth refusing,
% and refusing it here means refusing it before any device is driven.
% On a rig AO owns the timing of, these read values AO itself has just
% written, so they are assertions on the PROFILE - the thing a person edits
% and can get wrong - rather than on the operator. On an inheriting rig they
% are what they always were: a check that the Waveforms tab is set up the
% way this rig needs. Either way, failing here costs nothing.
if ~hardware.daq_sync.daq_master && profile.daq.requires_self_trigger
    if hardware.owns_daq_timing
        error("adaptive_optopatch:SelfTriggerRequired", ...
            "The rig profile requires self-trigger but builds global_props " + ...
            "with daq_master false. Fix %s.daq.requires_self_trigger.", ...
            profile.profile_id);
    end
    error("adaptive_optopatch:SelfTriggerRequired", ...
        "Select self-trigger/DAQ master in Luminos before running the automated protocol.");
end
if strlength(hardware.daq_sync.selected_master_device)>0 && ...
        ~ismember(hardware.daq_sync.selected_master_device,profile.daq.supported_internal_masters)
    error("adaptive_optopatch:UnsupportedDaqMaster", ...
        "The clock master '%s' is not supported by this rig profile.", ...
        hardware.daq_sync.selected_master_device);
end
% The camera cadence is validated here, where the profile is first read, so
% a profile that asks for an exposure longer than its frame period fails
% before the OBIS is raised rather than when the camera is armed.
hardware.camera_cadence=adaptive_optopatch.camera_cadence_for_profile(profile);
hardware.owns_camera_timing=hardware.camera_cadence.declared;
if ~hardware.daq_sync.passed
    error("adaptive_optopatch:MultiDaqSyncNotReady","%s", ...
        strjoin(hardware.daq_sync.issues,newline));
end
end

function tf=same_terminal(daq,a,b)
if ismethod(daq,"Same_Terminal")
    tf=logical(daq.Same_Terminal(a,b));
else
    tf=strcmpi(strip(string(a)),strip(string(b)));
end
end

function device=optional_device(app,type,name)
device=[];
try
    found=app.getDevice(type,"name",name,"displayWarning",false);
catch
    return
end
if numel(found)==1, device=found; end
end

function device=require_device(app,type,name)
device=app.getDevice(type,"name",name,"displayWarning",false);
if ~isempty(device), return; end
% THE SOLE DAQ IS THE ONE MEANT, which is the rule these profiles were
% written against: Luminos's getDevice used to return the only device of a
% type whatever name was asked for. The Virtual Upright's one DAQ is named
% "DAQ Dev1 + Dev2" in the rig JSON, while the profile calls it Dev1 - the
% NI device it owns and every port is addressed through - so the named
% lookup never matched and never had to. Rig_Control_App.name_matches
% (2026-09-24) made a named device match exactly, and this lookup started
% failing on a rig nothing had changed about.
%
% THE DAQ AND NOTHING ELSE. This fallback was written for any type, which
% was wrong in a way a rig would have found before a reader did: the VU has
% TWO DMDs, so on a rig where DMD_Blue is absent or renamed the sole
% remaining DMD is DMD_Orange - and AO would have programmed stimulation
% patterns onto the recording DMD while reporting, in DMD_Blue's name, that
% it was uncalibrated. A rig has exactly one DAQ by Luminos's own rule
% (Waveform_Camera_Sync_Acquisition refuses more than one), so there is
% genuinely nothing to confuse it with; every other type has to match by
% name or be refused.
if type=="DAQ"
    candidates=app.getDevice(type,"displayWarning",false);
    if isscalar(candidates)
        device=candidates;
        return
    end
end
error("adaptive_optopatch:RequiredDeviceMissing", ...
    "Required Luminos device '%s' (%s) was not found.",name,type);
end

function value=live_global_props(daq)
%LIVE_GLOBAL_PROPS Whatever the Waveforms tab left, for provenance only.
%   Never a source of timing. It exists so the run can archive what AO's
%   own configuration displaced, including the ordinary case of displacing
%   nothing at all on a Luminos where Waveforms was never opened.
value=struct([]);
try
    candidate=daq.global_props;
    if isstruct(candidate) && ~isempty(fieldnames(candidate)), value=candidate; end
catch
end
end

function tf=is_identity_transform(tform)
if isa(tform,"affinetform2d") || isa(tform,"projtform2d")
    matrix=tform.A;
elseif isa(tform,"affine2d") || isa(tform,"projective2d")
    matrix=tform.T';
else
    tf=false;
    return
end
tf=norm(double(matrix)-eye(3),"fro")<1e-9;
end

function tf=same_terminals(actual,expected)
actual=strip(string(actual));
expected=strip(string(expected));
actual=sort(strip(actual,"left","/"));
expected=sort(strip(expected,"left","/"));
tf=isequal(reshape(actual,1,[]),reshape(expected,1,[]));
end
