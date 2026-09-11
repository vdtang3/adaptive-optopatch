function referencePath=resolve_reference_path(record,acquisitionPath)
%RESOLVE_REFERENCE_PATH Resolve portable and legacy acquisition links.
arguments
    record (1,1) struct
    acquisitionPath (1,1) string
end
savedLinks=strings(0,1);
if isfield(record,"reference_model_path") && ...
        strlength(string(record.reference_model_path))>0
    savedLinks(end+1,1)=string(record.reference_model_path);
end
if isfield(record,"run_directory") && ...
        strlength(string(record.run_directory))>0
    savedLinks(end+1,1)=append_reference_filename(record.run_directory);
end
if isempty(savedLinks)
    error("adaptive_optopatch:AcquisitionReferenceLinkMissing", ...
        "The acquisition record does not identify its Adaptive Optopatch "+ ...
        "run/reference. Re-run with a current runner or add an explicit linkage.");
end

recordingRoot=adaptive_optopatch.resolve_recording_root(acquisitionPath);
resolved=strings(0,1);
reconstructed=strings(numel(savedLinks),1);
for k=1:numel(savedLinks)
    [candidate,reconstructed(k)]=resolve_one(savedLinks(k),recordingRoot);
    if strlength(candidate)==0, continue; end
    [~,attributes]=fileattrib(candidate);
    resolved(end+1,1)=string(attributes.Name); %#ok<AGROW>
end
resolved=unique(resolved,"stable");
if isempty(resolved)
    attempted=reconstructed(strlength(reconstructed)>0);
    if isempty(attempted), attempted="(none)"; end
    if strlength(recordingRoot)==0, rootText="(not found)"; else, rootText=recordingRoot; end
    message="The acquisition links to a missing reference model."+newline+newline+ ...
        "Saved reference:"+newline+savedLinks(1)+newline+newline+ ...
        "Recording root:"+newline+rootText+newline+newline+ ...
        "Resolved candidate:"+newline+strjoin(attempted,newline);
    error("adaptive_optopatch:AcquisitionReferenceLinkBroken","%s",message);
end
if numel(resolved)~=1
    error("adaptive_optopatch:AmbiguousAcquisitionReference", ...
        "The acquisition record contains conflicting reference-model links: %s", ...
        strjoin(resolved,", "));
end
referencePath=resolved(1);
end

function value=append_reference_filename(runDirectory)
normalized=replace(string(runDirectory),"\","/");
if endsWith(normalized,"/"), normalized=extractBefore(normalized,strlength(normalized)); end
value=normalized+"/reference_model.mat";
end

function [resolved,reconstructed]=resolve_one(savedPath,recordingRoot)
resolved=""; reconstructed="";
[suffix,snapsIndex]=snaps_suffix(savedPath);
isPortable=~isempty(snapsIndex) && snapsIndex==1;
if ~isPortable && isfile(savedPath)
    resolved=savedPath;
    return
end
if ~isempty(suffix) && strlength(recordingRoot)>0
    parts=cellstr(suffix);
    reconstructed=string(fullfile(recordingRoot,parts{:}));
    if isfile(reconstructed), resolved=reconstructed; return; end
end
if isPortable && strlength(recordingRoot)>0, return; end
if isfile(savedPath), resolved=savedPath; end
end

function [suffix,index]=snaps_suffix(path)
normalized=replace(string(path),"\","/");
parts=split(normalized,"/");
parts=parts(strlength(parts)>0);
index=find(strcmpi(parts,"Snaps"),1);
if isempty(index), suffix=strings(0,1); else, suffix=parts(index:end); end
end
