function snapshot = snapshot_luminos_settings(app)
%SNAPSHOT_LUMINOS_SETTINGS Archive active nontransient Luminos settings.
arguments
    app
end
snapshot=struct;
snapshot.schema_version="0.3.0";
snapshot.captured_at=string(datetime("now","TimeZone","local"));
snapshot.app_class=string(class(app));
snapshot.app_archive=struct;
snapshot.devices={};
snapshot.errors=strings(0,1);
snapshot.daq_synchronization=struct([]);
snapshot.active_galvo_calibration=struct([]);

try
    snapshot.app_archive=app.buildAppArchive();
catch exception
    snapshot.errors(end+1)="App archive: "+string(exception.message);
end
try
    devices=app.Devices;
catch exception
    snapshot.errors(end+1)="Device enumeration: "+string(exception.message);
    devices=[];
end

rows=cell(numel(devices),5);
snapshot.devices=cell(numel(devices),1);
for k=1:numel(devices)
    record=struct("index",k,"class",string(class(devices(k))), ...
        "name","","archive",struct,"error","");
    try
        record.name=string(devices(k).name);
    catch
    end
    try
        record.archive=devices(k).Build_Archive;
    catch exception
        record.error=string(exception.message);
        snapshot.errors(end+1)="Device "+k+": "+record.error;
    end
    snapshot.devices{k}=record;
    rows(k,:)={k,char(record.class),char(record.name), ...
        isempty(record.error),char(record.error)};
end
snapshot.summary=cell2table(rows,'VariableNames', ...
    {'device_index','device_class','device_name','archive_ok','error'});
try
    daq=app.getDevice("DAQ");
    if ~isempty(daq)
        snapshot.daq_synchronization= ...
            adaptive_optopatch.capture_luminos_daq_sync(daq(1));
    end
catch exception
    snapshot.errors(end+1)="DAQ synchronization: "+string(exception.message);
end
try
    [artifact,status]=adaptive_optopatch.get_active_galvo_calibration();
    snapshot.active_galvo_calibration=struct("status",status,"artifact",artifact);
catch exception
    snapshot.errors(end+1)="Active galvo calibration: "+string(exception.message);
end
end
