classdef SimulatedLuminosApp < handle
    %SIMULATEDLUMINOSAPP Minimal Luminos-compatible backend with no I/O.
    properties (SetAccess=private)
        IsSimulation logical = true
        Devices adaptive_optopatch.testing.SimulatedLuminosDevice
        GalvoCalibration struct
        SimulationOutputRoot string
        AcquisitionHistory struct = struct([])
    end
    properties
        % Every getDevice request, as "type|name". A suppressed output is
        % supposed to cost no device lookup at all, and the only way to
        % show the difference between "not touched" and "resolved, then
        % skipped" is to record what was asked for. Tests clear it before
        % the call they are measuring.
        DeviceLookupLog string = strings(0,1)
        acquisition_active logical = false
        exp_complete logical = false
        round_complete logical = false
        expfolder string = ""
        FailOnAcquisitionNumber double = NaN
        % What Luminos's generic stack autoload did, per DMD, on the last
        % simulated acquisition. Kept so a test can assert that an AO-owned
        % device was skipped rather than merely that its pattern survived.
        DmdStartupReport struct = struct([])
    end
    properties (Access=private)
        AcquisitionCount double = 0
    end

    methods
        function app=SimulatedLuminosApp(devices,calibration,outputRoot)
            app.Devices=devices;
            app.GalvoCalibration=calibration;
            app.SimulationOutputRoot=string(outputRoot);
        end

        function applyGalvoCalibration(app,calibration)
            %APPLYGALVOCALIBRATION Simulate an operator recalibrating the rig.
            %   Updates the simulator's active-calibration pointer and pushes
            %   the new transform onto the live scanner device, mirroring
            %   what a real recalibration workflow leaves behind.
            app.GalvoCalibration=calibration;
            scanner=app.getDevice("Scanning_Device","name",calibration.scanner_name);
            scanner.tform=calibration.calibration.tform;
        end

        function matchReferenceCameraGeometry(app,referenceCamera)
            %MATCHREFERENCECAMERAGEOMETRY Represent a loaded reference in simulation.
            arguments
                app
                referenceCamera (1,1) struct
            end
            if ~isfield(referenceCamera,"ROI") || ...
                    ~isfield(referenceCamera,"bin")
                error("adaptive_optopatch:ReferenceCameraGeometryUnavailable", ...
                    "The loaded reference does not contain camera ROI and binning metadata.");
            end
            roi=double(referenceCamera.ROI);
            bin=double(referenceCamera.bin);
            if numel(roi)~=4 || any(~isfinite(roi)) || ...
                    ~isscalar(bin) || ~isfinite(bin) || bin<=0
                error("adaptive_optopatch:ReferenceCameraGeometryUnavailable", ...
                    "The loaded reference contains invalid camera ROI or binning metadata.");
            end
            cameras=app.getDevice("Camera");
            if isempty(cameras)
                error("adaptive_optopatch:RequiredDeviceMissing", ...
                    "The simulated Luminos backend has no Camera device.");
            end
            cameras(1).ROI=reshape(roi,1,4);
            cameras(1).bin=bin;
        end

        function devices=getDevice(app,type,varargin)
            requestedType=string(type);
            if requestedType=="DAQ"
                match=arrayfun(@(d)d.DeviceType=="DAQ",app.Devices);
            elseif requestedType=="Camera"
                match=arrayfun(@(d)d.DeviceType=="Camera",app.Devices);
            else
                match=arrayfun(@(d)d.DeviceType==requestedType,app.Devices);
            end
            requestedName="";
            for k=1:2:numel(varargin)
                if strcmpi(string(varargin{k}),"name")
                    requestedName=string(varargin{k+1});
                end
            end
            if strlength(requestedName)>0
                match=match & arrayfun(@(d)d.name==requestedName,app.Devices);
            end
            app.DeviceLookupLog(end+1,1)=requestedType+"|"+requestedName;
            devices=app.Devices(match);
        end

        function archive=buildAppArchive(app)
            archive=struct("simulation",true,"backend","SimulatedLuminosApp", ...
                "output_root",app.SimulationOutputRoot, ...
                "device_names",string({app.Devices.name}));
        end

        function simulateAcquisition(app,bins,varargin)
            app.exp_complete=false;
            app.round_complete=false;
            app.acquisition_active=true;
            % The two points in Luminos acquisition startup that can change
            % what a DMD projects, run here in the same order and at the same
            % two moments the real script runs them: the generic stack
            % autoload early, and the owned-pattern check at the last moment
            % before the trigger. Luminos's own functions, not copies - a
            % copy would keep agreeing with itself while the real startup
            % overwrote the target, which is the failure being simulated
            % against.
            app.DmdStartupReport=app.runDmdAcquisitionStartup();
            tag="simulated";
            outputRoot=app.SimulationOutputRoot;
            for k=1:2:numel(varargin)
                name=lower(string(varargin{k}));
                if name=="tag", tag=string(varargin{k+1}); end
                if name=="fullpath", outputRoot=string(varargin{k+1}); end
            end
            if strlength(outputRoot)==0
                outputRoot=fullfile(tempdir,"adaptive_optopatch_simulation");
            end
            Verify_Owned_Dmd_Patterns(app.getDevice("DMD"));
            if ~isfolder(outputRoot), mkdir(outputRoot); end
            app.AcquisitionCount=app.AcquisitionCount+1;
            if app.AcquisitionCount==app.FailOnAcquisitionNumber
                app.acquisition_active=false;
                error("adaptive_optopatch:SimulatedAcquisitionFailure", ...
                    "Requested simulated acquisition failure.");
            end
            safeTag=regexprep(char(tag),'[^A-Za-z0-9_-]','_');
            stamp=char(datetime("now","Format","yyyyMMdd_HHmmss_SSS"));
            folder=fullfile(outputRoot,sprintf('SIMULATION_%s_%03d_%s', ...
                stamp,app.AcquisitionCount,safeTag));
            mkdir(folder);
            daq=app.getDevice("DAQ");
            app.populateGalvoFeedback(daq);
            simulated_acquisition=struct( ...
                "simulation",true,"backend","SimulatedLuminosApp", ...
                "created_at",string(datetime("now","TimeZone","local")), ...
                "tag",tag,"bins",double(bins), ...
                "global_props",daq.global_props,"wfm_data",daq.wfm_data, ...
                "devices",app.buildAppArchive());
            simulation=true;
            save(fullfile(folder,"output_data.mat"), ...
                "simulation","simulated_acquisition","-v7.3");
            app.expfolder=string(folder);
            entry=simulated_acquisition;
            entry.experiment_directory=string(folder);
            if isempty(app.AcquisitionHistory), app.AcquisitionHistory=entry;
            else, app.AcquisitionHistory(end+1)=entry; end
            app.exp_complete=true;
            app.round_complete=true;
            app.acquisition_active=false;
        end
    end

    methods (Access=private)
        function report=runDmdAcquisitionStartup(app)
            adaptive_optopatch.require_luminos_acquisition_helpers();
            dmds=app.getDevice("DMD");
            if isempty(dmds), report=struct([]); return; end
            report=Write_Pending_Dmd_Stacks(dmds);
        end

        function populateGalvoFeedback(~,daq)
            if isempty(daq) || ~isstruct(daq.wfm_data) || ...
                    ~isfield(daq.wfm_data,"ao"), return; end
            records=daq.wfm_data.ao;
            x=[]; y=[];
            for k=1:numel(records)
                name=string(records(k).name);
                if ~isfield(records,"params") || numel(records(k).params)<2, continue; end
                if name=="Adaptive2P_X", x=double(records(k).params{2}(:)); end
                if name=="Adaptive2P_Y", y=double(records(k).params{2}(:)); end
            end
            if isempty(x) || isempty(y), return; end
            channels=struct("phys_channel",{"Dev2/ai1","Dev2/ai2"}, ...
                "data",{x,y});
            daq.buffered_tasks=struct("task_type","aif", ...
                "clock_source",string(daq.global_props.clock_source), ...
                "trigger_source",string(daq.global_props.trigger_source), ...
                "rate",double(daq.global_props.rate),"channels",channels, ...
                "simulation",true);
        end
    end
end
