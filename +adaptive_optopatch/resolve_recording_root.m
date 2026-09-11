function recordingRoot=resolve_recording_root(acquisitionPath)
%RESOLVE_RECORDING_ROOT Find the current directory immediately above Snaps.
arguments
    acquisitionPath (1,1) string
end
current=acquisitionPath;
if isfile(current), current=string(fileparts(current)); end
recordingRoot="";
while isfolder(current)
    [parent,name]=fileparts(current);
    parent=string(parent); name=string(name);
    if strcmpi(name,"Snaps")
        recordingRoot=parent;
        return
    end
    listing=dir(current);
    names=string({listing([listing.isdir]).name});
    if any(strcmpi(names,"Snaps"))
        recordingRoot=current;
        return
    end
    if parent==current || strlength(parent)==0, return; end
    current=parent;
end
end
