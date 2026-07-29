function settings = summarize_luminos_settings(snapshot)
%SUMMARIZE_LUMINOS_SETTINGS Flatten archived settings for review/overrides.
arguments
    snapshot (1,1) struct
end
path=strings(0,1); current_value=strings(0,1);
source=strings(0,1);
for k=1:numel(snapshot.devices)
    device=snapshot.devices{k};
    prefix="device."+device.name;
    [p,v]=flatten_struct(device.archive,prefix,0);
    path=[path;p]; current_value=[current_value;v]; %#ok<AGROW>
    source=[source;repmat(device.class,numel(p),1)]; %#ok<AGROW>
end
override_value=repmat("",numel(path),1);
apply_override=false(numel(path),1);
settings=table(apply_override,path,current_value,override_value,source);
end

function [paths,values]=flatten_struct(value,prefix,depth)
paths=strings(0,1); values=strings(0,1);
if depth>3, return; end
if isstruct(value) && isscalar(value)
    names=fieldnames(value);
    for k=1:numel(names)
        field=value.(names{k});
        [p,v]=flatten_struct(field,prefix+"."+names{k},depth+1);
        paths=[paths;p]; values=[values;v]; %#ok<AGROW>
    end
elseif isnumeric(value) || islogical(value)
    if numel(value)<=16
        paths=prefix; values=string(mat2str(value));
    end
elseif ischar(value) || (isstring(value) && isscalar(value))
    paths=prefix; values=string(value);
end
end
