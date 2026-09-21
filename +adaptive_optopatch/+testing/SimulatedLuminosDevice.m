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
        % Luminos's generic "send my stack before every acquisition" toggle,
        % and the ownership claim that suspends it. Modelled because the bug
        % they exist for is an interaction between the two: neither a static
        % write nor the FLUT slot path clears pattern_stack, so an AO target
        % was replaced by a stale generic stack at acquisition startup.
        auto_write_stack logical = false
        pattern_owner string = ""
        pattern_owner_fingerprint string = ""
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
        % Per-camera calibration store, as Patterning_Device keeps it: one
        % field per camera, each holding at least a tform. Modelled so a test
        % can put the device into the state the calibration checks exist for -
        % a nonidentity, correctly shaped transform belonging to a different
        % camera than the one the plan was made on.
        calibrations struct = struct()
        calibration_camera string = ""
    end

    properties (Access=private)
        saved_auto_write_stack logical = false
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
            % The RETURN CONTRACT is Patterning_Device's, and it is not the
            % obvious one: the warped mask comes back only when the caller
            % asked for no write. Once it has written, the real method has
            % already moved the mask into Target and returns the scalar 1.
            %
            % Reproduced here because the difference is invisible until it
            % is archived. This simulator used to return the mask either
            % way, so a caller that recorded the return value as "what the
            % device was programmed with" recorded a mask in test and a
            % scalar true on the rig, and every test agreed with itself.
            % The programmed pattern is Target; ask for that.
            device.Target=logical(mask);
            writeNow=false;
            for k=1:2:numel(varargin)
                if strcmpi(string(varargin{k}),"write_when_complete")
                    writeNow=logical(varargin{k+1});
                end
            end
            if writeNow
                device.Write_Static();
                transformed=1;
            else
                transformed=logical(mask);
            end
        end

        % ---- Per-camera calibration, mirroring Patterning_Device ---------

        function key=calibration_key(~,cameraName)
            name=string(cameraName);
            if strlength(name)==0, key=""; return; end
            key=string(matlab.lang.makeValidName(char(name)));
        end

        function set_calibration_entry(device,cameraName,transform,metadata)
            arguments
                device
                cameraName
                transform
                metadata struct = struct()
            end
            key=device.calibration_key(cameraName);
            if strlength(key)==0, return; end
            entry=metadata;
            entry.camera=char(string(cameraName));
            entry.tform=transform;
            entry.session='SIMULATION';
            entry.utc=posixtime(datetime('now','TimeZone','UTC'));
            device.calibrations.(key)=entry;
            device.tform=transform;
        end

        function entry=get_calibration_entry(device,cameraName)
            entry=[];
            key=device.calibration_key(cameraName);
            if strlength(key)>0 && isfield(device.calibrations,key)
                entry=device.calibrations.(key);
            end
        end

        function tf=has_any_calibration_entry(device)
            tf=~isempty(fieldnames(device.calibrations));
        end

        function status=calibration_status(device,cameraName)
            entry=device.get_calibration_entry(cameraName);
            if isempty(entry) || ~isfield(entry,'tform') || isempty(entry.tform)
                status="none";
            else
                status="session";
            end
        end

        function status=use_calibration_camera(device,cameraName)
            % Reproduces the behaviour the calibration checks exist for: the
            % selected camera changes, and when the newly selected pair has
            % no entry the PREVIOUS camera's transform stays active.
            device.calibration_camera=string(cameraName);
            entry=device.get_calibration_entry(cameraName);
            if ~isempty(entry) && isfield(entry,'tform') && ~isempty(entry.tform)
                device.tform=entry.tform;
            end
            status=device.calibration_status(cameraName);
        end

        function identity=calibration_identity(device,cameraName)
            arguments
                device
                cameraName string = device.calibration_camera
            end
            identity=struct("schema_version","1.0.0", ...
                "device",device.name,"device_class",string(class(device)), ...
                "camera",string(cameraName), ...
                "selected_camera",device.calibration_camera, ...
                "status",device.calibration_status(cameraName), ...
                "has_pair_calibration",false, ...
                "active_transform_is_pair_transform",false, ...
                "has_any_pair_calibration",device.has_any_calibration_entry(), ...
                "pair_transform",[],"active_transform",device.tform, ...
                "measured_utc",NaN,"bin",NaN,"roi",[],"mode","");
            entry=device.get_calibration_entry(cameraName);
            if isempty(entry) || ~isfield(entry,'tform') || isempty(entry.tform)
                return
            end
            identity.has_pair_calibration=true;
            identity.pair_transform=entry.tform;
            if isfield(entry,'utc'), identity.measured_utc=entry.utc; end
            if isfield(entry,'bin'), identity.bin=entry.bin; end
            if isfield(entry,'roi'), identity.roi=entry.roi; end
            if isfield(entry,'mode'), identity.mode=string(entry.mode); end
            identity.active_transform_is_pair_transform= ...
                same_transform(device.tform,entry.tform);
        end

        % ---- Exclusive pattern ownership ---------------------------------

        function previous=Claim_Pattern_Ownership(device,owner)
            owner=string(owner);
            held=strlength(device.pattern_owner)>0;
            if held && device.pattern_owner~=owner
                error("DMD:PatternOwnershipHeld", ...
                    "%s is currently programmed by '%s'.", ...
                    device.name,device.pattern_owner);
            end
            previous=struct("device",device.name,"owner",owner, ...
                "auto_write_stack",device.auto_write_stack, ...
                "already_owned",held);
            if held
                previous.auto_write_stack=device.saved_auto_write_stack;
                return
            end
            device.saved_auto_write_stack=device.auto_write_stack;
            device.pattern_owner=owner;
            device.pattern_owner_fingerprint="";
            device.auto_write_stack=false;
        end

        function Release_Pattern_Ownership(device,owner)
            arguments
                device
                owner string = ""
            end
            if strlength(device.pattern_owner)==0, return; end
            if strlength(owner)>0 && device.pattern_owner~=owner, return; end
            device.auto_write_stack=device.saved_auto_write_stack;
            device.pattern_owner="";
            device.pattern_owner_fingerprint="";
        end

        function fingerprint=Pattern_Fingerprint(device)
            % Same contract as DMD.Pattern_Fingerprint: MATLAB-side state
            % only, changing whenever what the device would project changes -
            % the static pattern, the loaded bank, the playlist order, the
            % playback mode - and not otherwise. No hardware inquiry, for the
            % reason given there: an ALP inquiry may answer -1 at any time,
            % and an intermittently unavailable answer must not read as "the
            % pattern changed".
            parts=strings(0,1);
            parts(end+1,1)=summarize_mask(device.Target);
            for k=1:numel(device.slot_patterns)
                parts(end+1,1)=summarize_mask(device.slot_patterns{k}); %#ok<AGROW>
            end
            parts(end+1,1)=string(mat2str(double(device.playlist(:))'));
            parts(end+1,1)=string(device.playlist_mode);
            parts(end+1,1)=string(double(device.invert_output));
            fingerprint=string(keyHash(strjoin(parts,"|")));
        end

        function fingerprint=Record_Owned_Pattern(device,owner)
            owner=string(owner);
            if device.pattern_owner~=owner
                error("DMD:PatternOwnershipNotHeld", ...
                    "'%s' does not own %s.",owner,device.name);
            end
            fingerprint=device.Pattern_Fingerprint();
            device.pattern_owner_fingerprint=fingerprint;
        end

        function report=Verify_Owned_Pattern(device)
            report=struct("device",string(device.name), ...
                "owner",device.pattern_owner,"checked",false, ...
                "matches",false,"expected",device.pattern_owner_fingerprint, ...
                "actual","");
            if strlength(device.pattern_owner)==0 || ...
                    strlength(device.pattern_owner_fingerprint)==0
                return
            end
            report.actual=device.Pattern_Fingerprint();
            report.checked=true;
            report.matches=report.actual==report.expected;
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

function text=summarize_mask(mask)
% Size, population count and a position-weighted sum: enough to notice a
% different pattern and a rearranged one, cheaply.
mask=double(logical(mask));
v=mask(:);
text=string(sprintf('%s#%d#%.17g',mat2str(size(mask)),nnz(v), ...
    sum(v.*(1:numel(v))')));
end

function tf=same_transform(a,b)
A=matrix_of(a); B=matrix_of(b);
tf=false;
if isempty(A) || isempty(B) || ~isequal(size(A),size(B)), return; end
A=A/A(end,end); B=B/B(end,end);
tf=max(abs(A-B),[],"all")<=1e-9;
end

function A=matrix_of(transform)
A=[];
if isempty(transform), return; end
if isa(transform,"affinetform2d") || isa(transform,"projtform2d")
    A=double(transform.A);
elseif isa(transform,"affine2d") || isa(transform,"projective2d")
    A=double(transform.T)';
elseif isnumeric(transform) && isequal(size(transform),[3 3])
    A=double(transform);
end
end

function value=unavailable_as_minus_one(value)
% A real controller answers -1 for an inquiry it does not implement, and
% ALP_DMD_State passes that through; NaN is the simulator's stand-in.
if ~isfinite(value), value=-1; end
end
