function app=make_simulated_luminos(options)
%MAKE_SIMULATED_LUMINOS Construct the local, no-hardware Luminos test double.
arguments
    options.CameraFrameRateHz (1,1) double {mustBePositive} = 1000
    options.LaserPowerMw (1,1) double {mustBeNonnegative} = 10
    options.SimulationOutputRoot (1,1) string = ""
    options.GalvoCalibration (1,1) struct = struct
    options.MissingDevice (1,1) string = ""
    options.LaserInterlockEnabled (1,1) logical = true
    options.Modulator488Port (1,1) string = "Dev1/ao2"
    options.ValidDaqSync (1,1) logical = true
end
if options.LaserPowerMw>55
    error("adaptive_optopatch:SimulatedLaserPowerOutOfRange", ...
        "LaserPowerMw must be between 0 and 55 mW.");
end
if strlength(options.SimulationOutputRoot)==0
    options.SimulationOutputRoot=fullfile(tempdir,"adaptive_optopatch_simulation");
end

profile1p=adaptive_optopatch.virtual_upright_1p_profile();
profile2p=adaptive_optopatch.virtual_upright_2p_profile();
daq=device("DAQ","Dev1");
daq.global_props=struct("rate",200000,"total_time",1, ...
    "clock_source","Internal Dev1", ...
    "trigger_source",profile2p.daq.default_trigger, ...
    "completion_trigger","None","daq_master",true);
daq.wfm_data=struct("ao",base_outputs(),"do",[],"ai",[],"di",[], ...
    "ctri",[],"ao_camera_triggered",[],"do_camera_triggered",[]);
daq.default_trigger=profile2p.daq.default_trigger;
daq.clock_bridge=profile2p.daq.clock_bridge;
daq.clock_master_device="Dev1";
daq.master_clock_task_index=1;
if ~options.ValidDaqSync
    daq.clock_bridge=strings(1,0);
    daq.global_props.daq_master=false;
end

camera=device("Camera",profile1p.camera.name);
camera.cam_id="S/N: 001125";
camera.frametrigger_source="DAQ";
camera.daqtrig_period_ms=1000/options.CameraFrameRateHz;
camera.maximum_frame_rate_hz=max(options.CameraFrameRateHz/0.85, ...
    options.CameraFrameRateHz+1);

dmd=device("DMD",profile1p.dmd.name);
dmd.tform=affinetform2d([1.01 0 2;0 1.01 3;0 0 1]);
dmd.refimage=zeros(32,32,"uint16");
dmd.trigger_channel=profile1p.dmd.trigger_port;
orangeDmd=device("DMD",profile1p.orange_dmd.name);
orangeDmd.tform=affinetform2d([1.02 0 1;0 1.02 2;0 0 1]);
orangeDmd.refimage=zeros(32,32,"uint16");
laser=device("Laser_Device",profile1p.laser.name);
laser.Mode="ANALOG";
laser.SetPower=options.LaserPowerMw/1000;
laser.InterlockEnabled=options.LaserInterlockEnabled;
mod488=device("NI_DAQ_Modulator",profile1p.modulator.name);
mod488.port=options.Modulator488Port;
shutter=device("NI_DAQ_Shutter",profile1p.shutter.name);
shutter.port=profile1p.shutter.port;
dmdTrigger=device("NI_DAQ_Shutter",profile1p.dmd.trigger_alias);
dmdTrigger.port=profile1p.dmd.trigger_port;
scanner=device("Scanning_Device",profile2p.scanner.name);
scanner.galvox_physport=profile2p.scanner.x_port;
scanner.galvoy_physport=profile2p.scanner.y_port;
scanner.sample_rate=profile2p.scanner.sample_rate_hz;
mod2p=device("NI_DAQ_Modulator",profile2p.modulator.name);
mod2p.port=profile2p.modulator.port;

if isempty(fieldnames(options.GalvoCalibration))
    calibration=synthetic_calibration(profile2p);
else
    calibration=options.GalvoCalibration;
end
scanner.tform=calibration.calibration.tform;
devices=[daq camera dmd orangeDmd laser mod488 shutter dmdTrigger scanner mod2p];
if strlength(options.MissingDevice)>0
    keep=arrayfun(@(d)d.name~=options.MissingDevice && ...
        d.DeviceType~=options.MissingDevice,devices);
    devices=devices(keep);
end
app=adaptive_optopatch.testing.SimulatedLuminosApp( ...
    devices,calibration,options.SimulationOutputRoot);

    function value=device(type,name)
        value=adaptive_optopatch.testing.SimulatedLuminosDevice(type,name);
    end
end

function records=base_outputs()
template=struct("name","","port","","wavefile","awfm_constant", ...
    "params",{{0}},"operation","Multiplication","concatTime",[]);
records=repmat(template,1,3);
records(1).name="mod488"; records(1).port="mod488";
records(2).name="Adaptive2P_X"; records(2).port="Dev2/ao0";
records(3).name="2P mod"; records(3).port="2P mod";
end

function artifact=synthetic_calibration(profile)
[x,y]=meshgrid([-5 0 5],[-5 0 5]);
volts=[x(:) y(:)];
tform=affinetform2d([200 0 1024;0 200 1024;0 0 1]);
[pixelX,pixelY]=transformPointsForward(tform,volts(:,1),volts(:,2));
calibration=struct("schema_version","SIMULATED", ...
    "passed",true,"transform_direction","galvo_volts_to_camera_pixels", ...
    "tform",tform,"galvo_volts",volts, ...
    "camera_pixels",[pixelX pixelY],"rmse_pixels",0, ...
    "held_out_rmse_pixels",0,"simulation",true);
artifact=struct("schema_version","SIMULATED", ...
    "calibration_id","SIMULATED_VU_CALIBRATION", ...
    "created_at",string(datetime("now","TimeZone","local")), ...
    "rig_name","Virtual_Upright","camera_serial","001125", ...
    "camera_name","Orca Fusion","scanner_name",profile.scanner.name, ...
    "scanner_x_port",profile.scanner.x_port, ...
    "scanner_y_port",profile.scanner.y_port, ...
    "pockels_port",profile.modulator.port, ...
    "source_experiment_directory","SIMULATION", ...
    "simulation",true,"calibration",calibration);
end
