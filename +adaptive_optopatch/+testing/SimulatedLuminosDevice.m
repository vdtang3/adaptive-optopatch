classdef SimulatedLuminosDevice < handle
    %SIMULATEDLUMINOSDEVICE Small duck-typed device used by the test backend.
    properties
        DeviceType string = ""
        name string = ""
        port string = ""
        global_props struct = struct
        wfm_data struct = struct
        waveforms_built logical = false
        default_trigger string = strings(1,0)
        clock_bridge string = strings(1,0)
        clock_master_device string = ""
        master_clock_task_index = []
        buffered_tasks = struct([])
        cam_id string = ""
        bin double = 1
        frames_requested double = 1
        frametrigger_source string = "DAQ"
        daqtrig_period_ms double = 1
        maximum_frame_rate_hz double = 1200
        Dimensions double = [1080 1920]
        Target logical = false(1080,1920)
        tform = []
        refimage = []
        Mode string = "ANALOG"
        SetPower double = 0.01
        InterlockEnabled logical = true
        EmissionOn logical = false
        level double = 0
        State logical = false
        galvox_physport string = ""
        galvoy_physport string = ""
        fixed_rep_rate_flag logical = false
        Points_Per_Volt double = 20
        sample_rate double = 200000
        vbounds double = [-5 -5 5 5]
        galvox_wfm double = []
        galvoy_wfm double = []
        roi_meta struct = struct("trans_center",[0 0])
        ResetCount double = 0
        StaticWriteCount double = 0
    end

    methods
        function device=SimulatedLuminosDevice(type,name)
            if nargin>0, device.DeviceType=string(type); end
            if nargin>1, device.name=string(name); end
        end

        function archive=Build_Archive(device)
            archive=struct("simulation",true,"device_type",device.DeviceType, ...
                "name",device.name,"port",device.port);
        end

        function rate=calculate_framerate(device)
            rate=device.maximum_frame_rate_hz;
        end

        function AutoN(device,durationS)
            device.frames_requested=ceil(double(durationS)*device.calculate_framerate());
        end

        function Stop(device)
            device.EmissionOn=false;
        end

        function Start(device)
            device.EmissionOn=true;
        end

        function state=Get_state(device)
            state=device.EmissionOn;
        end

        function state=Get_interlockStatus(device)
            state=device.InterlockEnabled;
        end

        function Write_Static(device)
            device.StaticWriteCount=device.StaticWriteCount+1;
        end

        function setPatterningROI(device,mask,varargin)
            device.Target=logical(mask);
            writeNow=false;
            for k=1:2:numel(varargin)
                if strcmpi(string(varargin{k}),"write_when_complete")
                    writeNow=logical(varargin{k+1});
                end
            end
            if writeNow, device.Write_Static(); end
        end

        function sync=Resolve_Buffered_Sync(device,varargin) %#ok<INUSD>
            sync=struct("passed",true,"simulation",true);
        end

        function Route_Clock_Bridge(device,varargin) %#ok<INUSD>
        end

        function Disconnect_Clock_Bridge(device,varargin) %#ok<INUSD>
        end

        function reset(device)
            device.ResetCount=device.ResetCount+1;
            device.waveforms_built=false;
            device.buffered_tasks=struct([]);
        end

        function value=remove_al(~,value)
            value=string(value);
        end

        function Gen_Spiral_JS(device,spiral)
            center=device.cameraToGalvo([spiral.centerx spiral.centery]);
            edge=device.cameraToGalvo([spiral.centerx+spiral.radius spiral.centery]);
            radius=norm(edge-center);
            points=max(20,ceil(2*pi*radius*device.Points_Per_Volt));
            theta=linspace(0,2*pi,points)';
            device.galvox_wfm=center(1)+radius.*cos(theta);
            device.galvoy_wfm=center(2)+radius.*sin(theta);
            device.roi_meta=struct("trans_center",center);
        end

        function Update_Galvos_Explicit(device,x,y)
            device.galvox_wfm=double(x(:));
            device.galvoy_wfm=double(y(:));
        end
    end

    methods (Access=private)
        function volts=cameraToGalvo(device,pixels)
            [x,y]=transformPointsInverse(device.tform,pixels(1),pixels(2));
            volts=[x y];
        end
    end
end
