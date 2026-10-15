function [records,report]=ensure_auxiliary_input(records,profile)
%ENSURE_AUXILIARY_INPUT Add a rig-declared AI channel once per acquisition.
report=struct("enabled",false,"name","","port","","identity","", ...
    "source","");
if ~isfield(profile,"auxiliary_input") || isempty(profile.auxiliary_input)
    return
end
input=profile.auxiliary_input;
report.enabled=true;
report.name=string(input.name);
report.port=string(input.port);
report.identity=string(input.identity);
ports=strings(numel(records),1);
for k=1:numel(records)
    ports(k)=string(records(k).port);
end
matches=strcmpi(erase(ports,"/"),erase(report.port,"/"));
if sum(matches)>1
    error("adaptive_optopatch:DuplicateAuxiliaryInput", ...
        "The active waveform has more than one input on %s.",report.port);
end
if any(matches)
    report.source="operator_waveform";
    index=find(matches,1);
    existingName=string(records(index).name);
    if strlength(strtrim(existingName))==0
        records(index).name=char(report.name);
        report.source="operator_waveform_unnamed";
    else
        report.name=existingName;
    end
    return
end
record=struct("name",char(report.name),"port",char(report.port));
if isempty(records)
    records=record;
else
    fields=union(fieldnames(records),fieldnames(record),'stable');
    for k=1:numel(fields)
        if ~isfield(records,fields{k}), [records.(fields{k})]=deal([]); end
        if ~isfield(record,fields{k}), record.(fields{k})=[]; end
    end
    records(end+1)=orderfields(record,records);
end
report.source="adaptive_optopatch";
end
