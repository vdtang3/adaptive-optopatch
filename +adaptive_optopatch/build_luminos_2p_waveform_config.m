function [globalProps,wfmData,summary]=build_luminos_2p_waveform_config( ...
        activeGlobalProps,activeWfmData,waveforms,options)
%BUILD_LUMINOS_2P_WAVEFORM_CONFIG Inject validated X/Y/Pockels sample vectors.
arguments
    activeGlobalProps (1,1) struct
    activeWfmData (1,1) struct
    waveforms (1,1) struct
    options.Profile (1,1) struct = adaptive_optopatch.virtual_upright_2p_profile()
end
profile=options.Profile;
required=["rate","clock_source","trigger_source","daq_master"];
if ~all(isfield(activeGlobalProps,required))
    error("adaptive_optopatch:IncompleteActiveWaveformSettings", ...
        "The active Luminos waveform lacks rate, clock, trigger, or DAQ-master settings.");
end
if abs(double(activeGlobalProps.rate)-waveforms.sample_rate_hz)>1e-9
    error("adaptive_optopatch:TwoPhotonSampleRateMismatch", ...
        "Planned 2P waveforms are at %.0f Hz but Luminos is configured for %.0f Hz.", ...
        waveforms.sample_rate_hz,double(activeGlobalProps.rate));
end
n=numel(waveforms.x_v);
if numel(waveforms.y_v)~=n || numel(waveforms.pockels_v)~=n
    error("adaptive_optopatch:TwoPhotonWaveformSizeMismatch", ...
        "Galvo X, galvo Y, and Pockels vectors must have equal lengths.");
end
globalProps=activeGlobalProps;
globalProps.total_time=n/waveforms.sample_rate_hz;
wfmData=ensure_fields(activeWfmData);
wfmData.ao=remove_outputs(wfmData.ao, ...
    [profile.scanner.x_port profile.scanner.y_port ...
     profile.modulator.name profile.modulator.port]);
wfmData.ao=append_record(wfmData.ao,make_record( ...
    "Adaptive2P_X",profile.scanner.x_port,waveforms.sample_rate_hz, ...
    waveforms.x_v,waveforms.x_v(end)));
wfmData.ao=append_record(wfmData.ao,make_record( ...
    "Adaptive2P_Y",profile.scanner.y_port,waveforms.sample_rate_hz, ...
    waveforms.y_v,waveforms.y_v(end)));
wfmData.ao=append_record(wfmData.ao,make_record( ...
    profile.modulator.name,profile.modulator.name,waveforms.sample_rate_hz, ...
    waveforms.pockels_v,profile.modulator.dark_v));
summary=struct("schema_version","0.1.0", ...
    "sample_rate_hz",waveforms.sample_rate_hz,"sample_count",n, ...
    "duration_s",globalProps.total_time, ...
    "clock_source",reshape(string(globalProps.clock_source),1,[]), ...
    "trigger_source",reshape(string(globalProps.trigger_source),1,[]), ...
    "x_port",profile.scanner.x_port,"y_port",profile.scanner.y_port, ...
    "pockels_port",profile.modulator.port, ...
    "preflight",waveforms.preflight,"per_pulse",waveforms.per_pulse);
end

function record=make_record(name,port,sampleRate,values,finalValue)
record=struct("name",char(name),"port",char(port), ...
    "wavefile","adaptive_optopatch.luminos_sampled_waveform", ...
    "params",{{sampleRate,values(:),finalValue}}, ...
    "operation","Multiplication","concatTime",[]);
end

function data=ensure_fields(data)
for name=["ao","do","ai","di","ctri","ao_camera_triggered","do_camera_triggered"]
    if ~isfield(data,name), data.(name)=[]; end
end
end

function values=remove_outputs(values,identifiers)
if isempty(values), return; end
keep=true(size(values));
identifiers=strip(string(identifiers));
for k=1:numel(values)
    name=""; port="";
    if isfield(values,"name"), name=strip(string(values(k).name)); end
    if isfield(values,"port"), port=strip(string(values(k).port)); end
    keep(k)=~any(name==identifiers | port==identifiers);
end
values=values(keep);
end

function values=append_record(values,record)
if isempty(values), values=record; return; end
fields=union(fieldnames(values),fieldnames(record),'stable');
for k=1:numel(fields)
    if ~isfield(values,fields{k}), [values.(fields{k})]=deal([]); end
    if ~isfield(record,fields{k}), record.(fields{k})=[]; end
end
values(end+1)=orderfields(record,values);
end
