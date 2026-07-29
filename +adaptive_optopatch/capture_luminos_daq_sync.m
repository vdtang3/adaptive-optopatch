function sync = capture_luminos_daq_sync(daq)
%CAPTURE_LUMINOS_DAQ_SYNC Read the active multi-DAQ timing state without writes.
arguments
    daq
end

sync=struct;
sync.schema_version="0.1.0";
sync.captured_at=string(datetime("now","TimeZone","local"));
sync.selected_clock_source="";
sync.selected_master_device="";
sync.selected_trigger_source=strings(1,0);
sync.daq_master=false;
sync.sample_rate_hz=NaN;
sync.clock_master_device="";
sync.master_clock_task_index=[];
sync.default_trigger=strings(1,0);
sync.clock_bridge=strings(1,0);
sync.active_waveform_devices=strings(1,0);
sync.buffered_tasks=struct([]);
sync.issues=strings(0,1);

globalProps=safe_get(daq,"global_props",struct());
if isstruct(globalProps)
    if isfield(globalProps,"clock_source")
        sync.selected_clock_source=string(globalProps.clock_source);
    end
    if isfield(globalProps,"trigger_source")
        sync.selected_trigger_source=as_string_row(globalProps.trigger_source);
    end
    if isfield(globalProps,"daq_master") && ~isempty(globalProps.daq_master)
        sync.daq_master=logical(globalProps.daq_master);
    end
    if isfield(globalProps,"rate") && isscalar(globalProps.rate)
        sync.sample_rate_hz=double(globalProps.rate);
    end
end
sync.default_trigger=as_string_row(safe_get(daq,"default_trigger",strings(1,0)));
sync.clock_bridge=as_string_row(safe_get(daq,"clock_bridge",strings(1,0)));
sync.clock_master_device=string(safe_get(daq,"clock_master_device",""));
sync.master_clock_task_index=safe_get(daq,"master_clock_task_index",[]);

wfmData=safe_get(daq,"wfm_data",struct());
for field=["ao","do","ai","di","ctri"]
    if ~isstruct(wfmData) || ~isfield(wfmData,field), continue; end
    records=wfmData.(field);
    for k=1:numel(records)
        if ~isfield(records,"port") || isempty(records(k).port), continue; end
        port=resolve_alias(daq,records(k).port);
        device=device_from_terminal(port);
        if strlength(device)>0
            sync.active_waveform_devices(end+1)=device; %#ok<AGROW>
        end
    end
end
sync.active_waveform_devices=unique(sync.active_waveform_devices,"stable");

tasks=safe_get(daq,"buffered_tasks",[]);
taskRecords=struct([]);
for k=1:numel(tasks)
    record=struct("index",k,"class",string(class(tasks(k))), ...
        "task_type",string(safe_get(tasks(k),"task_type","")), ...
        "clock_source",string(safe_get(tasks(k),"clock_source","")), ...
        "trigger_source",string(safe_get(tasks(k),"trigger_source","")), ...
        "channels",strings(1,0),"device","");
    channels=safe_get(tasks(k),"channels",[]);
    for c=1:numel(channels)
        terminal=string(safe_get(channels(c),"phys_channel",""));
        record.channels(end+1)=terminal;
    end
    if ~isempty(record.channels), record.device=device_from_terminal(record.channels(1)); end
    if isempty(taskRecords), taskRecords=record; else, taskRecords(end+1)=record; end %#ok<AGROW>
end
sync.buffered_tasks=taskRecords;

if strlength(sync.selected_clock_source)==0
    sync.issues(end+1)="No active clock source is recorded in DAQ global_props.";
else
    sync.selected_master_device=master_from_clock(sync.selected_clock_source);
end
if isempty(sync.default_trigger)
    sync.issues(end+1)="No device-local start-trigger terminals are configured.";
end
if numel(sync.active_waveform_devices)>1
    for device=sync.active_waveform_devices
        if ~has_device_terminal(sync.clock_bridge,device)
            sync.issues(end+1)="No clock-bridge terminal is configured for "+device+".";
        end
        if ~has_device_terminal(sync.default_trigger,device)
            sync.issues(end+1)="No start-trigger terminal is configured for "+device+".";
        end
    end
    if strlength(sync.selected_master_device)>0 && ...
            ~ismember(sync.selected_master_device,sync.active_waveform_devices)
        sync.issues(end+1)="Selected clock master "+sync.selected_master_device+ ...
            " has no active buffered waveform channel.";
    end
end
sync.passed=isempty(sync.issues);
end

function value=safe_get(object,name,fallback)
value=fallback;
try
    if isstruct(object)
        if isfield(object,name), value=object.(name); end
    elseif isprop(object,name)
        value=object.(name);
    end
catch
end
end

function value=resolve_alias(daq,value)
try
    if ismethod(daq,"remove_al"), value=daq.remove_al(value); end
catch
end
value=string(value);
end

function values=as_string_row(value)
if isempty(value), values=strings(1,0); return; end
if iscell(value), values=string(value); else, values=string(value); end
values=reshape(values,1,[]);
values=values(strlength(values)>0);
end

function device=device_from_terminal(terminal)
terminal=strip(string(terminal),"left","/");
parts=split(terminal,"/");
if isempty(parts), device=""; else, device=parts(1); end
if ~startsWith(device,"Dev","IgnoreCase",true), device=""; end
end

function device=master_from_clock(clockSource)
clockSource=strip(string(clockSource));
tokens=regexp(char(clockSource),'^Internal\s+(Dev[^\s]+)$','tokens','once');
if ~isempty(tokens)
    device=string(tokens{1});
else
    device=device_from_terminal(clockSource);
end
end

function tf=has_device_terminal(terminals,device)
tf=false;
for terminal=reshape(string(terminals),1,[])
    if device_from_terminal(terminal)==device, tf=true; return; end
end
end
