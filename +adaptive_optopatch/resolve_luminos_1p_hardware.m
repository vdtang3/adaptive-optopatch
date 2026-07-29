function hardware = resolve_luminos_1p_hardware(app,profile,options)
%RESOLVE_LUMINOS_1P_HARDWARE Find and validate the live VU blue-light path.
arguments
    app
    profile (1,1) struct = adaptive_optopatch.virtual_upright_1p_profile()
    options.RequireCalibratedDmd (1,1) logical = true
    options.RequireExternalLaserMode (1,1) logical = true
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
hardware.laser=require_device(app,"Laser_Device",profile.laser.name);
hardware.modulator=require_device(app,"NI_DAQ_Modulator",profile.modulator.name);
hardware.shutter=require_device(app,"NI_DAQ_Shutter",profile.shutter.name);
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

hardware.laser_mode=string(hardware.laser.Mode);
hardware.laser_was_on=logical(hardware.laser.Get_state());
hardware.laser_power_w=double(hardware.laser.SetPower);
hardware.laser_interlock_ok=logical(hardware.laser.Get_interlockStatus());
if options.RequireExternalLaserMode && ...
        ~ismember(upper(hardware.laser_mode),upper(profile.laser.external_modulation_modes))
    error("adaptive_optopatch:LaserNotExternallyModulated", ...
        "The 488 OBIS is in %s mode. Select ANALOG or MIXED in Luminos " + ...
        "before using mod488 pulse waveforms.",hardware.laser_mode);
end
if ~hardware.laser_interlock_ok
    error("adaptive_optopatch:LaserInterlockOpen", ...
        "The 488 OBIS reports that its key or interlock is not enabled.");
end
if hardware.laser_power_w<0 || hardware.laser_power_w>profile.laser.max_power_w
    error("adaptive_optopatch:ActiveLaserPowerOutOfRange", ...
        "The active OBIS setpoint %.4g W is outside the profile range 0-%.4g W.", ...
        hardware.laser_power_w,profile.laser.max_power_w);
end
if ~isstruct(hardware.daq.global_props) || isempty(fieldnames(hardware.daq.global_props)) || ...
        ~isstruct(hardware.daq.wfm_data)
    error("adaptive_optopatch:NoActiveLuminosWaveform", ...
        "Load an active Luminos waveform protocol before starting the runner.");
end
hardware.daq_sync=adaptive_optopatch.capture_luminos_daq_sync(hardware.daq);
if ~isfield(hardware.daq.global_props,"rate") || ...
        ~isscalar(hardware.daq.global_props.rate) || ...
        ~isfinite(hardware.daq.global_props.rate) || hardware.daq.global_props.rate<=0
    error("adaptive_optopatch:InvalidWaveformRate", ...
        "The active Luminos waveform sample rate must be positive.");
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
if ~hardware.daq_sync.daq_master && profile.daq.requires_self_trigger
    error("adaptive_optopatch:SelfTriggerRequired", ...
        "Select self-trigger/DAQ master in Luminos before running the automated protocol.");
end
if strlength(hardware.daq_sync.selected_master_device)>0 && ...
        ~ismember(hardware.daq_sync.selected_master_device,profile.daq.supported_internal_masters)
    error("adaptive_optopatch:UnsupportedDaqMaster", ...
        "The selected clock master '%s' is not supported by this VU profile.", ...
        hardware.daq_sync.selected_master_device);
end
if ~hardware.daq_sync.passed
    error("adaptive_optopatch:MultiDaqSyncNotReady","%s", ...
        strjoin(hardware.daq_sync.issues,newline));
end
end

function device=require_device(app,type,name)
device=app.getDevice(type,"name",name,"displayWarning",false);
if isempty(device)
    error("adaptive_optopatch:RequiredDeviceMissing", ...
        "Required Luminos device '%s' (%s) was not found.",name,type);
end
if numel(device)~=1
    error("adaptive_optopatch:AmbiguousDevice", ...
        "Expected one Luminos device named '%s', found %d.",name,numel(device));
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
actual=sort(strip(string(actual),"left","/"));
expected=sort(strip(string(expected),"left","/"));
tf=isequal(reshape(actual,1,[]),reshape(expected,1,[]));
end
