function [isBundle,snapshotStem,number]=parse_fov_bundle_name(name)
%PARSE_FOV_BUNDLE_NAME Split a saved-FOV file stem into snapshot and number.
%   A saved Adaptive Optopatch FOV lives beside the camera snapshot it was
%   drawn on, named for it:
%
%       Snaps/120000ao_full_cam-OrcaFusion.mat          the snapshot
%       Snaps/120000ao_full_cam-OrcaFusion_FOV001.mat   a FOV saved from it
%       Snaps/120000ao_full_cam-OrcaFusion_FOV002.mat   the next one
%
%   The name is the only place that link is written down in a form a human
%   reading a directory listing can follow, so one function owns the
%   convention and both the listing and the save path parse it here rather
%   than each spelling the pattern out again.
%
%   isBundle is false for an ordinary snapshot stem, and the other two
%   outputs are then empty and NaN. A stem that merely contains "_FOV"
%   without a trailing number - "cell_FOVs_backup" - is not a bundle.
arguments
    name (1,1) string
end
isBundle=false;
snapshotStem="";
number=NaN;
token=regexp(char(name),'^(?<stem>.+)_FOV(?<number>\d+)$','names','once');
if isempty(token) || strlength(string(token.stem))==0, return; end
isBundle=true;
snapshotStem=string(token.stem);
number=str2double(token.number);
end
