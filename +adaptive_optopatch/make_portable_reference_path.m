function storedPath=make_portable_reference_path(referencePath)
%MAKE_PORTABLE_REFERENCE_PATH Store a reference link from its Snaps folder.
arguments
    referencePath (1,1) string
end
[suffix,~]=snaps_suffix(referencePath);
if isempty(suffix)
    % Nonstandard development layouts may not have a Snaps directory. Keep
    % their existing behavior rather than inventing an unrelated root.
    storedPath=referencePath;
else
    storedPath=strjoin(suffix,"/");
end
end

function [suffix,index]=snaps_suffix(path)
normalized=replace(string(path),"\","/");
parts=split(normalized,"/");
parts=parts(strlength(parts)>0);
index=find(strcmpi(parts,"Snaps"),1);
if isempty(index), suffix=strings(0,1); else, suffix=parts(index:end); end
end
