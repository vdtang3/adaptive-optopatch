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
        acquisition_active logical = false
        exp_complete logical = false
        round_complete logical = false
        expfolder string = ""
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
            if ~isfolder(outputRoot), mkdir(outputRoot); end
            app.AcquisitionCount=app.AcquisitionCount+1;
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
