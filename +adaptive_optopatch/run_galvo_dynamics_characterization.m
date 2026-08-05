function characterization=run_galvo_dynamics_characterization(app,options)
%RUN_GALVO_DYNAMICS_CHARACTERIZATION Guarded blocked-beam X/Y sine sweep.
arguments
    app
    options.AmplitudesV (1,:) double {mustBePositive} = [0.05 0.10 0.16 0.22]
    options.FrequenciesHz (1,:) double {mustBePositive} = [25 50 100 200 400 600 800 1000]
    options.Cycles (1,1) double {mustBeInteger,mustBeGreaterThanOrEqual(options.Cycles,10)} = 20
    options.RampCycles (1,1) double {mustBeInteger,mustBePositive} = 2
    options.OutputDirectory (1,1) string = ""
    options.OutputRoot (1,1) string = ""
    options.ConfirmMechanicalBeamBlock (1,1) logical = false
    options.ConfirmFeedbackWiring (1,1) logical = false
    options.StopOnFailure (1,1) logical = true
    options.TimeoutMarginS (1,1) double {mustBePositive} = 30
end
if ~options.ConfirmMechanicalBeamBlock
    error("adaptive_optopatch:MechanicalBeamBlockRequired", ...
        "Mechanically block the laser before galvo dynamics characterization.");
end
if ~options.ConfirmFeedbackWiring
    error("adaptive_optopatch:GalvoFeedbackConfirmationRequired", ...
        "Confirm that both galvo position outputs are connected to finite AI channels.");
end
if any(options.AmplitudesV>0.25) || any(options.FrequenciesHz>1000)
    error("adaptive_optopatch:GalvoDynamicsSweepOutsideManufacturerRange", ...
        "The guarded sweep is limited to 0.25 V amplitude and 1000 Hz.");
end
hardware=adaptive_optopatch.resolve_luminos_2p_hardware(app);
profile=adaptive_optopatch.virtual_upright_2p_profile();
require_feedback_inputs(hardware.daq.wfm_data, ...
    [profile.scanner.feedback_x_port profile.scanner.feedback_y_port]);
original=capture_state(hardware);
cleanup=onCleanup(@()restore_state(app,hardware,original,profile)); %#ok<NASGU>
neutralWfm=original.wfm_data;
% The characterization owns all outputs. Preserve inputs and synchronization
% metadata, but do not carry lasers, shutters, or unrelated AO/DO waveforms.
neutralWfm.ao=[]; neutralWfm.do=[];
if strlength(options.OutputDirectory)==0
    options.OutputDirectory=fullfile(pwd,"galvo_dynamics_"+ ...
        string(datetime("now","Format","yyyyMMdd_HHmmss")));
end
if ~isfolder(options.OutputDirectory), mkdir(options.OutputDirectory); end
conditions=make_conditions(options.AmplitudesV,options.FrequenciesHz);
results=repmat(struct("condition_index",0,"axis","", ...
    "amplitude_v",0,"frequency_hz",0,"experiment_directory","", ...
    "waveform_summary",struct([]),"feedback_summary",struct([]), ...
    "analysis",struct([]),"status","pending","error_message",""), ...
    height(conditions),1);
characterization=struct("schema_version","0.1.0","created_at", ...
    string(datetime("now","TimeZone","local")),"rig_name","Virtual_Upright", ...
    "hardware_profile",profile,"calibration",hardware.calibration, ...
    "conditions",conditions,"results",results,"stopped_early",false, ...
    "stop_reason","","completed_at","");
save_progress();
for k=1:height(conditions)
    row=conditions(k,:);
    try
        waveform=adaptive_optopatch.generate_galvo_dynamics_waveform( ...
            row.axis,row.amplitude_v,row.frequency_hz, ...
            "Cycles",options.Cycles,"RampCycles",options.RampCycles);
        [globalProps,wfmData,summary]= ...
            adaptive_optopatch.build_luminos_2p_waveform_config( ...
            original.global_props,neutralWfm,waveform);
        hardware.daq.global_props=globalProps;
        hardware.daq.wfm_data=wfmData;
        hardware.daq.waveforms_built=false;
        [hardware.cameras,cameraPlan]= ...
            adaptive_optopatch.set_camera_frames_for_duration( ...
            hardware.cameras,globalProps.total_time);
        summary.camera_frame_plan=cameraPlan;
        hardware.modulator.level=profile.modulator.dark_v;
        app.acquisition_active=true;
        bins=arrayfun(@(camera)camera.bin,hardware.cameras);
        tag=sprintf("galvo_dynamics_%03d_%s_A%0.3f_F%04g", ...
            k,row.axis,row.amplitude_v,row.frequency_hz);
        if strlength(options.OutputRoot)>0
            Waveform_Camera_Sync_Acquisition(app,bins,"tag",tag, ...
                "fullpath",char(options.OutputRoot));
        else
            Waveform_Camera_Sync_Acquisition(app,bins,"tag",tag);
        end
        wait_for_completion(globalProps.total_time+options.TimeoutMarginS);
        folder=string(app.expfolder);
        feedback=adaptive_optopatch.capture_galvo_feedback(hardware.daq,waveform);
        analysis=adaptive_optopatch.analyze_galvo_dynamics_feedback( ...
            waveform,feedback);
        galvo_dynamics_record=struct("schema_version","0.1.0", ...
            "condition",row,"waveform",waveform,"waveform_summary",summary, ...
            "feedback",feedback,"analysis",analysis); %#ok<NASGU>
        save(fullfile(folder,"galvo_dynamics_record.mat"), ...
            "galvo_dynamics_record","-v7.3");
        if isfile(fullfile(folder,"output_data.mat"))
            save(fullfile(folder,"output_data.mat"), ...
                "galvo_dynamics_record","-append");
        end
        results(k)=make_result(k,row,folder,summary,feedback.summary,analysis, ...
            string(ternary(analysis.passed,"passed","failed")),"");
        characterization.results=results; save_progress();
        if ~analysis.passed && options.StopOnFailure
            characterization.stopped_early=true;
            characterization.stop_reason=strjoin(analysis.issues," ");
            break
        end
    catch exception
        results(k)=make_result(k,row,"",struct([]),struct([]),struct([]), ...
            "error",string(exception.message));
        characterization.results=results;
        characterization.stopped_early=true;
        characterization.stop_reason=string(exception.message);
        save_progress();
        rethrow(exception)
    end
end
characterization.completed_at=string(datetime("now","TimeZone","local"));
characterization.highest_passing=highest_passing(characterization.results);
save_progress();

    function save_progress()
        save(fullfile(options.OutputDirectory,"galvo_dynamics_characterization.mat"), ...
            "characterization","-v7.3");
    end
    function wait_for_completion(timeout)
        started=tic;
        while ~logical(app.exp_complete)
            pause(0.05); drawnow;
            if toc(started)>timeout
                error("adaptive_optopatch:GalvoDynamicsTimeout", ...
                    "Luminos did not complete the galvo dynamics acquisition.");
            end
        end
    end
end

function conditions=make_conditions(amplitudes,frequencies)
[amplitude,frequency]=ndgrid(sort(amplitudes),sort(frequencies));
base=table(amplitude(:),frequency(:), ...
    'VariableNames',{'amplitude_v','frequency_hz'});
base.stress=(2*pi*base.frequency_hz).^2.*base.amplitude_v;
base=sortrows(base,["stress","amplitude_v","frequency_hz"]);
n=height(base); axis=repmat(["x";"y"],n,1);
amplitude_v=repelem(base.amplitude_v,2);
frequency_hz=repelem(base.frequency_hz,2);
stress=repelem(base.stress,2);
condition_index=(1:2*n)';
conditions=table(condition_index,axis,amplitude_v,frequency_hz,stress);
end

function require_feedback_inputs(wfmData,ports)
if ~isfield(wfmData,"ai") || isempty(wfmData.ai)
    error("adaptive_optopatch:GalvoFeedbackInputsMissing", ...
        "Add both galvo-feedback finite AI channels to the active Luminos waveform.");
end
active=strings(numel(wfmData.ai),1);
for k=1:numel(wfmData.ai), active(k)=string(wfmData.ai(k).port); end
missing=ports(~ismember(ports,active));
if ~isempty(missing)
    error("adaptive_optopatch:GalvoFeedbackInputsMissing", ...
        "Active Luminos waveform is missing: %s.",strjoin(missing,", "));
end
end

function state=capture_state(hardware)
state=struct("global_props",hardware.daq.global_props, ...
    "wfm_data",hardware.daq.wfm_data, ...
    "camera_frames",arrayfun(@(camera)camera.frames_requested,hardware.cameras));
end

function restore_state(app,hardware,state,profile)
try, hardware.modulator.level=profile.modulator.dark_v; catch, end
try
    if isprop(app,"acquisition_active") && logical(app.acquisition_active)
        for k=1:numel(hardware.cameras)
            try, hardware.cameras(k).Stop(); catch, end
        end
        try, hardware.daq.Disconnect_Clock_Bridge(); catch, end
        try, hardware.daq.reset(); catch, end
        app.acquisition_active=false;
    end
catch
end
try
    hardware.daq.global_props=state.global_props;
    hardware.daq.wfm_data=state.wfm_data;
    hardware.daq.waveforms_built=false;
catch
end
for k=1:numel(hardware.cameras)
    try, hardware.cameras(k).frames_requested=state.camera_frames(k); catch, end
end
end

function result=make_result(index,row,folder,summary,feedback,analysis,status,message)
result=struct("condition_index",index,"axis",row.axis, ...
    "amplitude_v",row.amplitude_v,"frequency_hz",row.frequency_hz, ...
    "experiment_directory",folder,"waveform_summary",summary, ...
    "feedback_summary",feedback,"analysis",analysis, ...
    "status",status,"error_message",message);
end

function value=highest_passing(results)
value=struct("x",struct([]),"y",struct([]));
for axisName=["x","y"]
    keep=arrayfun(@(r)r.axis==axisName && r.status=="passed",results);
    candidates=results(keep);
    if isempty(candidates), continue; end
    acceleration=arrayfun(@(r)r.analysis.maximum_acceleration_v_per_s2,candidates);
    [~,index]=max(acceleration); value.(axisName)=candidates(index);
end
end

function value=ternary(condition,a,b)
if condition, value=a; else, value=b; end
end
