function hardware=resolve_luminos_2p_hardware(app,options)
%RESOLVE_LUMINOS_2P_HARDWARE Validate live VU devices and active calibration.
arguments
    app
    options.Profile (1,1) struct = adaptive_optopatch.virtual_upright_2p_profile()
end
profile=options.Profile;
if isempty(app), error("adaptive_optopatch:MissingLuminosApp","A live Luminos app is required."); end
if isprop(app,"acquisition_active") && logical(app.acquisition_active)
    error("adaptive_optopatch:LuminosAcquisitionActive","Luminos is already acquiring.");
end
hardware=struct;
hardware.daq=app.getDevice("DAQ");
hardware.scanner=app.getDevice("Scanning_Device","name",profile.scanner.name);
hardware.modulator=app.getDevice("NI_DAQ_Modulator","name",profile.modulator.name);
hardware.cameras=app.getDevice("Camera");
if numel(hardware.daq)~=1 || numel(hardware.scanner)~=1 || ...
        numel(hardware.modulator)~=1
    error("adaptive_optopatch:TwoPhotonHardwareMissing", ...
        "The combined DAQ, Chameleon scanner, or 2P modulator was not found uniquely.");
end
requiredMethods=["Resolve_Buffered_Sync","Route_Clock_Bridge", ...
    "Disconnect_Clock_Bridge"];
if ~all(arrayfun(@(name)ismethod(hardware.daq,name),requiredMethods))
    error("adaptive_optopatch:IncompatibleLuminosMultiDaqApi", ...
        ["The active Luminos checkout lacks the synchronized multi-DAQ API. " ...
         "A branch containing VU_MultiDAQ_Synchronization is required for " ...
         "Dev1 Pockels plus Dev2 galvos."]);
end
if string(hardware.scanner.galvox_physport)~=profile.scanner.x_port || ...
        string(hardware.scanner.galvoy_physport)~=profile.scanner.y_port || ...
        string(hardware.modulator.port)~=profile.modulator.port
    error("adaptive_optopatch:UnexpectedTwoPhotonPorts", ...
        "Expected X=Dev2/ao0, Y=Dev2/ao1, and 2P mod=Dev1/ao3.");
end
serials=strings(numel(hardware.cameras),1);
for k=1:numel(hardware.cameras)
    serials(k)=strip(erase(string(hardware.cameras(k).cam_id),"S/N: "));
end
hardware.voltage_camera_index=find(serials=="001125",1);
if isempty(hardware.voltage_camera_index)
    error("adaptive_optopatch:VoltageCameraNotFound","Camera 1 serial 001125 was not found.");
end
hardware.voltage_camera=hardware.cameras(hardware.voltage_camera_index);
hardware.calibration_status=adaptive_optopatch.load_active_galvo_calibration(app);
if ~hardware.calibration_status.found || ~hardware.calibration_status.applied
    error("adaptive_optopatch:ActiveGalvoCalibrationRequired", ...
        "A validated active Camera 1/galvo calibration is required.");
end
hardware.calibration=hardware.calibration_status.artifact;
hardware.daq_sync=adaptive_optopatch.capture_luminos_daq_sync(hardware.daq);
if ~hardware.daq_sync.daq_master || ...
        ~ismember(hardware.daq_sync.selected_master_device,["Dev1","Dev2"])
    error("adaptive_optopatch:MultiDaqSyncNotReady", ...
        "Select Internal Dev1 or Internal Dev2 and self-trigger.");
end
if ~isstruct(hardware.daq.global_props) || ...
        ~isfield(hardware.daq.global_props,"rate") || ...
        double(hardware.daq.global_props.rate)~=profile.scanner.sample_rate_hz
    error("adaptive_optopatch:TwoPhotonSampleRateMismatch", ...
        "The active Luminos waveform must use the 200 kHz scanner rate.");
end
if ~isstruct(hardware.daq.wfm_data)
    error("adaptive_optopatch:NoActiveLuminosWaveform", ...
        "Load an active Luminos waveform protocol first.");
end
end
