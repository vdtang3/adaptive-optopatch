function root=luminos_snapshot_root(luminosApp)
%LUMINOS_SNAPSHOT_ROOT Where the attached Luminos session writes camera snaps.
%   Camera_Snap writes every snapshot into <app.datafolder>/Snaps, three files
%   sharing one stem: the .tiff pixels, the .mat CL_RefImage that carries the
%   camera ROI, binning and DMD transforms, and a .png copy for the browser.
%   The .mat is the one Adaptive Optopatch reads, and this is the folder it
%   lives in.
%
%   Duck-typed on the property rather than on the class, for the same reason
%   Luminos duck-types its side of the controller handshake: the simulated
%   backend and the test stubs are not Rig_Control_App and must simply fall
%   through to "no snapshot folder" rather than error.
%
%   Returns "" when there is no attached session, no datafolder, or the
%   folder does not exist. A caller treats that as "nothing to offer", which
%   is what a session that has not written a snap yet genuinely means.
arguments
    luminosApp = []
end
root="";
if isempty(luminosApp) || ~isprop(luminosApp,"datafolder"), return; end
try
    dataFolder=string(luminosApp.datafolder);
catch
    return
end
if ~isscalar(dataFolder) || strlength(dataFolder)==0, return; end
candidate=fullfile(dataFolder,"Snaps");
if isfolder(candidate), root=string(candidate); end
end
