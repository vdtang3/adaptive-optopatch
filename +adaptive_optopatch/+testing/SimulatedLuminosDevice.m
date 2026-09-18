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
        % [left width top height] on the sensor, as Luminos reports it.
        ROI double = [0 2048 0 2048]
        bin double = 1
        frames_requested double = 1
        frametrigger_source string = "DAQ"
        daqtrig_period_ms double = 1
        maximum_frame_rate_hz double = 1200
        % Luminos device order is [width height]; Target is [rows columns].
        Dimensions double = [1920 1080]
        Target logical = false(1080,1920)
        tform = []
        refimage = []
        Mode string = "ANALOG"
        InterlockEnabled logical = true
        EmissionOn logical = false
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
        pattern_stack logical = false(0,0,0)
        % Declared ALP_MIN_PICTURE_TIME equivalent. NaN means the simulated
        % DMD declares no capability, so no advance-interval limit is
        % invented; tests set it to exercise the real check.
        minimum_picture_time_us double = NaN
        StackWriteCount double = 0
        StackMode string = ""
        supports_flut logical = true
        flut_max_entries double = 4096
        reserved_slot_count double = 0
        slot_write_count double = 0
        written_slots double = zeros(0,1)
        slot_patterns cell = cell(0,1)
        playlist double = zeros(0,1)
        playlist_mode string = ""
        % Modelled ALP playback state, in the units Get_State reports: the
        % codes are alp.h's (ALP_MASTER 2301, ALP_SLAVE 2302,
        % ALP_PROJ_ACTIVE 1200, ALP_PROJ_IDLE 1201) and NaN stands for the
        % -1 a controller returns for an inquiry it will not answer. A fresh
        % device has nothing loaded, so no mode is claimed until something
        % is written.
        projection_mode_code double = NaN
        projection_step_code double = NaN
        projection_state_code double = NaN
        sequence_pictures double = 0
        % A rig that images the mirrors' "off" light needs the complement of
        % the wanted pattern, and DMD.Device_Pattern is the only place that
        % inversion is applied. Modelled so a test can show that Target and
        % the illuminated field are not the same thing.
        invert_output logical = false
        % Models a hypothetical device whose static write does NOT restore
        % master mode, so the static-state invariant can be shown to fire.
        % The real ALP_DMD::Project always restores it.
        StaticWriteSkipsModeReset logical = false
        trigger_channel string = ""
        % DAQ.alias_list, so a simulated rig resolves a terminal written
        % under a rig alias the way the real one does. It was empty, and
        % remove_al below returned its input unchanged, which is why a
        % stale waveform stored as "DMD Trigger" looked like a waveform on
        % some unrelated line in every test that had ever been written.
        alias_list cell = cell(0,2)
        % Raising a simulated OBIS can be made to fail, so the pre-arm
        % failure path - which happens before any acquisition is armed, and
        % so before the flag most cleanup keys off is ever set - is
        % reachable from a test.
        FailOnStart logical = false
        FailOnStaticWrite logical = false
        FailOnStaticWriteNumber double = NaN
        StaticWriteAttemptCount double = 0
        % How many times Update_Galvos_Explicit has been called. A test
        % asserting that a pure 1P run never commands the galvos has to be
        % able to see the CALL, not the end state: parking them at the
        % stationary value they were already sitting at leaves no trace in
        % galvox_wfm. Counted separately from Gen_Spiral_JS, which also
        % writes those properties but is a trajectory rather than a
        % neutralization command.
        ExplicitGalvoUpdateCount double = 0
    end

    properties (SetObservable)
        % Observable because the ORDER these are written in is itself a
        % safety property: a test has to be able to see that mod488 was
        % dark at the moment the laser's power was raised, which an end
        % state cannot show.
        SetPower double = 0.01
        level double = 0
        State logical = false
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
            if device.FailOnStart
                error("adaptive_optopatch:SimulatedLaserStartFailure", ...
                    "The simulated 488 OBIS was configured to fail on Start.");
            end
            device.EmissionOn=true;
        end

        function state=Get_state(device)
            state=device.EmissionOn;
        end

        function state=Get_State(device)
            state=struct("flut_max_entries",device.flut_max_entries, ...
                "min_picture_time",round(device.minimum_picture_time_us), ...
                "projection_mode",unavailable_as_minus_one(device.projection_mode_code), ...
                "projection_step",unavailable_as_minus_one(device.projection_step_code), ...
                "projection_state",unavailable_as_minus_one(device.projection_state_code), ...
                "sequence_pictures",device.sequence_pictures);
        end

        function mask=Device_Pattern(device,mask)
            mask=mask>.5;
            if device.invert_output, mask=~mask; end
        end

        function state=Get_interlockStatus(device)
            state=device.InterlockEnabled;
        end

        function Write_Static(device)
            device.StaticWriteAttemptCount=device.StaticWriteAttemptCount+1;
            if device.FailOnStaticWrite || ...
                    device.StaticWriteAttemptCount==device.FailOnStaticWriteNumber
                % ALP_DMD.Write_Static clears its MATLAB bookkeeping and
                % then throws in Pattern_Bytes, before Project_Image is
                % reached, so a failed static write leaves the device
                % playing whatever it was already playing. The modelled
                % playback state is deliberately left untouched here.
                error("adaptive_optopatch:SimulatedDmdStaticWriteFailure", ...
                    "Requested simulated DMD static-write failure.");
            end
            device.StaticWriteCount=device.StaticWriteCount+1;
            % ALP_DMD::Project: DevHalt, free the previous sequence,
            % SeqAlloc(1,1), master mode with stepping disabled,
            % ProjStartCont.
            device.sequence_pictures=1;
            device.projection_state_code=1200;
            if ~device.StaticWriteSkipsModeReset
                device.projection_mode_code=2301;
                device.projection_step_code=0;
            end
        end

        function canvasSize=Pattern_Canvas_Size(device)
            canvasSize=device.Dimensions([2 1]);
        end

        function transformed=setPatterningROI(device,mask,varargin)
            device.Target=logical(mask);
            transformed=logical(mask);
            writeNow=false;
            for k=1:2:numel(varargin)
                if strcmpi(string(varargin{k}),"write_when_complete")
                    writeNow=logical(varargin{k+1});
                end
            end
            if writeNow, device.Write_Static(); end
        end

        function Write_Stack(device,mode)
            device.StackWriteCount=device.StackWriteCount+1;
            device.StackMode=string(mode);
            if ~isempty(device.pattern_stack)
                device.Target=device.pattern_stack(:,:,1);
            end
            % Project_Stack loads every picture as one sequence and leaves
            % the device in the requested projection mode.
            device.sequence_pictures=size(device.pattern_stack,3);
            device.projection_mode_code=mode_code(mode);
            device.projection_step_code=0;
            device.projection_state_code=1200;
        end

        function tf=Supports_FLUT(device)
            tf=device.supports_flut;
        end

        function Reserve_Slots(device,count)
            device.reserved_slot_count=double(count);
            device.slot_write_count=0;
            device.written_slots=zeros(0,1);
            device.slot_patterns=cell(count,1);
            device.playlist=zeros(0,1);
        end

        function Write_Pattern_To_Slot(device,slot,mask)
            if slot<1 || slot>device.reserved_slot_count
                error("DMD:SlotOutOfRange","Simulated slot is outside the reserved bank.");
            end
            device.slot_write_count=device.slot_write_count+1;
            device.written_slots(end+1,1)=slot;
            device.slot_patterns{slot}=logical(mask);
        end

        function Set_Playlist(device,slots,mode)
            device.playlist=double(slots(:));
            device.playlist_mode=string(mode);
            if ~isempty(device.playlist)
                device.Target=device.slot_patterns{device.playlist(1)};
            end
            % A FLUT playlist addresses the reserved picture pool, so the
            % loaded sequence still holds one picture per unique mask; the
            % playlist length is the look-up table, not the sequence.
            device.sequence_pictures=device.reserved_slot_count;
            device.projection_mode_code=mode_code(mode);
            device.projection_step_code=0;
            device.projection_state_code=1200;
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

        function value=remove_al(device,value)
            value=adaptive_optopatch.resolve_terminal_alias(value, ...
                device.alias_list);
        end

        function tf=Same_Terminal(device,terminalA,terminalB)
            canonical=@(t)adaptive_optopatch.canonical_terminal(t, ...
                device.alias_list);
            tf=canonical(terminalA)==canonical(terminalB);
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
            device.ExplicitGalvoUpdateCount=device.ExplicitGalvoUpdateCount+1;
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

function code=mode_code(mode)
% alp.h: ALP_MASTER 2301, ALP_SLAVE 2302.
if strcmpi(string(mode),"slave"), code=2302; else, code=2301; end
end

function value=unavailable_as_minus_one(value)
% A real controller answers -1 for an inquiry it does not implement, and
% ALP_DMD_State passes that through; NaN is the simulator's stand-in.
if ~isfinite(value), value=-1; end
end
