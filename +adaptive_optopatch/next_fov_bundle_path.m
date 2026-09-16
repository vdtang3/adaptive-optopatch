function [path,number]=next_fov_bundle_path(folder,snapshotStem)
%NEXT_FOV_BUNDLE_PATH The next unused <snapshot>_FOV### bundle in a folder.
%   Saving a FOV ALLOCATES A NEW NUMBER. It never replaces an existing
%   bundle and it never touches the camera snapshot, whose file is the one
%   piece of the session that cannot be regenerated. An operator who saves
%   twice gets two bundles and can go back to the first; an operator who
%   wanted to replace one deletes it deliberately, outside this function.
%
%   The number is one past the highest already present rather than the first
%   gap, so numbering follows the order the FOVs were saved in even after one
%   is deleted. The result is checked against the filesystem and advanced
%   until it names a file that does not exist, which also covers a bundle
%   written by another session between the listing and the save.
arguments
    folder (1,1) string
    snapshotStem (1,1) string
end
if strlength(folder)==0
    error("adaptive_optopatch:NoFovSaveFolder", ...
        "There is no folder to save a FOV into. The reference was not " + ...
        "loaded from a file on this session's filesystem.");
end
if strlength(snapshotStem)==0
    error("adaptive_optopatch:NoFovSaveName", ...
        "There is no snapshot name to derive a FOV bundle name from.");
end
if ~isfolder(folder), mkdir(folder); end

highest=0;
listing=dir(fullfile(folder,snapshotStem+"_FOV*.mat"));
for entry=reshape(listing,1,[])
    if entry.isdir, continue; end
    [~,name]=fileparts(entry.name);
    [isBundle,stem,value]=adaptive_optopatch.parse_fov_bundle_name(string(name));
    % Same-stem only: "snap_FOV001" and "snap_other_FOV001" are different
    % references and must not share a numbering sequence.
    if isBundle && stem==snapshotStem && isfinite(value)
        highest=max(highest,value);
    end
end

number=highest+1;
path=bundle_path(folder,snapshotStem,number);
while isfile(path)
    number=number+1;
    path=bundle_path(folder,snapshotStem,number);
end
end

function path=bundle_path(folder,snapshotStem,number)
% Three digits, so a directory listing sorts the bundles in the order they
% were saved. A session that somehow reaches 1000 keeps counting rather than
% wrapping or colliding; sprintf widens the field on its own.
path=string(fullfile(folder,sprintf("%s_FOV%03d.mat",snapshotStem,number)));
end
