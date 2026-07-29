function result=run_galvo_calibration(app,plan,options)
%RUN_GALVO_CALIBRATION Acquire a Camera 1 calibration grid through Luminos.
arguments
    app
    plan (1,1) struct
    options.CameraRoi (1,4) double = [768 768 768 768]
    options.OutputRoot (1,1) string = ""
    options.ConfirmTrajectoryTest (1,1) logical = false
    options.ConfirmLiveOutput (1,1) logical = false
    options.TimeoutMarginS (1,1) double {mustBePositive} = 30
end
if ~options.ConfirmTrajectoryTest
    error("adaptive_optopatch:CalibrationTrajectoryNotConfirmed", ...
        "Run and inspect the blocked-light trajectory before live calibration.");
end
if plan.pockels_voltage>0 && ~options.ConfirmLiveOutput
    error("adaptive_optopatch:CalibrationLightNotConfirmed", ...
        "Positive Pockels output requires explicit live-light confirmation.");
end
profile=adaptive_optopatch.virtual_upright_2p_profile();
% The VU archive exposes one combined DAQ object; use an unfiltered lookup.
daq=app.getDevice("DAQ");
if numel(daq)~=1
    error("adaptive_optopatch:CombinedDaqRequired", ...
        "Expected one combined Luminos DAQ object, found %d.",numel(daq));
end
scanner=app.getDevice("Scanning_Device","name",profile.scanner.name);
modulator=app.getDevice("NI_DAQ_Modulator","name",profile.modulator.name);
cameras=app.getDevice("Camera");
serials=strings(numel(cameras),1);
for k=1:numel(cameras)
    serials(k)=strip(erase(string(cameras(k).cam_id),"S/N: "));
end
cameraIndex=find(serials=="001125",1);
if isempty(cameraIndex)
    error("adaptive_optopatch:VoltageCameraNotFound", ...
        "Camera 1 serial 001125 was not found.");
end
camera=cameras(cameraIndex);
if isempty(scanner) || string(scanner.galvox_physport)~=profile.scanner.x_port || ...
        string(scanner.galvoy_physport)~=profile.scanner.y_port
    error("adaptive_optopatch:UnexpectedScannerPorts", ...
        "The live Chameleon scanner does not match Dev2/ao0 and Dev2/ao1.");
end
if isempty(modulator) || string(modulator.port)~=profile.modulator.port
    error("adaptive_optopatch:UnexpectedPockelsPort", ...
        "The live 2P modulator is not on Dev1/ao3.");
end
sync=adaptive_optopatch.capture_luminos_daq_sync(daq);
if ~sync.daq_master || sync.selected_master_device~="Dev1"
    error("adaptive_optopatch:CalibrationRequiresDev1Master", ...
        "Select Internal Dev1 and self-trigger in Luminos for Camera 1 calibration.");
end
original=capture_state(daq,cameras);
cleanup=onCleanup(@()restore_state(app,daq,cameras,original,modulator,profile)); %#ok<NASGU>
modulator.level=profile.modulator.dark_v;
configure_camera(camera,options.CameraRoi,plan.camera_frame_rate_hz);
for k=1:numel(cameras)
    if k==cameraIndex
        cameras(k).AutoN(plan.duration_s);
    else
        try, cameras(k).frametrigger_source="Off"; catch, end
    end
end
[globalProps,wfmData,waveformSummary]= ...
    adaptive_optopatch.build_luminos_2p_waveform_config( ...
    original.global_props,original.wfm_data,plan);
daq.global_props=globalProps; daq.wfm_data=wfmData; daq.waveforms_built=false;
app.acquisition_active=true;
bins=arrayfun(@(c)c.bin,cameras);
if strlength(options.OutputRoot)>0
    Waveform_Camera_Sync_Acquisition(app,bins,"tag","galvo_calibration", ...
        "fullpath",char(options.OutputRoot));
else
    Waveform_Camera_Sync_Acquisition(app,bins,"tag","galvo_calibration");
end
started=tic;
while ~logical(app.exp_complete)
    pause(0.05); drawnow;
    if toc(started)>plan.duration_s+options.TimeoutMarginS
        error("adaptive_optopatch:CalibrationAcquisitionTimeout", ...
            "Calibration acquisition did not complete.");
    end
end
folder=string(app.expfolder);
if ~isfile(fullfile(folder,"output_data.mat"))
    error("adaptive_optopatch:MissingLuminosOutput", ...
        "Luminos did not create output_data.mat in %s.",folder);
end
calibration_plan=plan; %#ok<NASGU>
calibration_run_record=struct("schema_version","0.1.0", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "camera_serial","001125","camera_roi",options.CameraRoi, ...
    "daq_synchronization",sync,"waveform_summary",waveformSummary); %#ok<NASGU>
save(fullfile(folder,"galvo_calibration_plan.mat"), ...
    "calibration_plan","calibration_run_record","-v7.3");
result=adaptive_optopatch.analyze_galvo_calibration_acquisition(folder,plan);
calibration_result=result; %#ok<NASGU>
save(fullfile(folder,"galvo_calibration_result.mat"), ...
    "calibration_result","-v7.3");
end

function original=capture_state(daq,cameras)
original=struct("global_props",daq.global_props,"wfm_data",daq.wfm_data, ...
    "camera",cell(numel(cameras),1));
for k=1:numel(cameras)
    names=["roiJS","ROI","bin","daqtrig_period_ms","frametrigger_source", ...
        "frames_requested"];
    state=struct;
    for name=names
        try, state.(name)=cameras(k).(name); catch, end
    end
    original.camera{k}=state;
end
end

function configure_camera(camera,roi,frameRate)
roi=round(roi);
roiJs=struct("left",roi(1),"width",roi(2),"top",roi(3), ...
    "height",roi(4),"type","arbitrary");
configured=false;
if ismethod(camera,"SetROI")
    try, camera.SetROI(roiJs); configured=true; catch, end
elseif ismethod(camera,"Set_ROI")
    try, camera.Set_ROI(roiJs); configured=true; catch, end
elseif ismethod(camera,"setROI")
    try, camera.setROI(roiJs); configured=true; catch, end
end
if ~configured
    try, camera.roiJS=roiJs; configured=true; catch, end
end
if ~configured
    error("adaptive_optopatch:CameraRoiApiUnavailable", ...
        "The live Camera 1 object does not expose a supported ROI setter.");
end
try, camera.bin=1; catch, end
camera.daqtrig_period_ms=1000/frameRate;
camera.frametrigger_source="DAQ";
end

function restore_state(app,daq,cameras,original,modulator,profile)
try, modulator.level=profile.modulator.dark_v; catch, end
try
    if isprop(app,"acquisition_active") && logical(app.acquisition_active)
        for k=1:numel(cameras), try, cameras(k).Stop(); catch, end, end
        try, daq.Disconnect_Clock_Bridge(); catch, end
        try, daq.reset(); catch, end
        app.acquisition_active=false;
    end
catch
end
try
    daq.global_props=original.global_props;
    daq.wfm_data=original.wfm_data;
    daq.waveforms_built=false;
catch
end
for k=1:numel(cameras)
    state=original.camera{k};
    for name=reshape(string(fieldnames(state)),1,[])
        try, cameras(k).(name)=state.(name); catch, end
    end
end
end
