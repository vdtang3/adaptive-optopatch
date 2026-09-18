function require_luminos_acquisition_helpers()
%REQUIRE_LUMINOS_ACQUISITION_HELPERS Ensure Luminos's DMD startup hooks are callable.
%   Write_Pending_Dmd_Stacks and Verify_Owned_Dmd_Patterns are the two points
%   in Luminos acquisition startup that can touch a DMD after AO has finished
%   programming it. They are Luminos's, not AO's, and they are the code that
%   actually has to be right: an AO-only reimplementation of the same
%   sequence would keep passing while the real one overwrote the target,
%   which is precisely the failure being tested for. So the simulated backend
%   calls the real functions.
%
%   Same sibling lookup require_luminos_waveform_functions uses.
if exist("Write_Pending_Dmd_Stacks","file")==2 && ...
        exist("Verify_Owned_Dmd_Patterns","file")==2
    return
end
packageDirectory=fileparts(mfilename("fullpath"));
projectDirectory=fileparts(packageDirectory);
softwareDirectory=fileparts(projectDirectory);
helpers=fullfile(softwareDirectory,"luminos-private","src", ...
    "Experimental_Scripts","js","helpers");
if ~isfile(fullfile(helpers,"Write_Pending_Dmd_Stacks.m"))
    error("adaptive_optopatch:MissingLuminosAcquisitionHelpers", ...
        "Simulating an acquisition runs Luminos's own DMD startup hooks, " + ...
        "and %s was not found. Add Luminos's " + ...
        "src/Experimental_Scripts/js/helpers directory to the MATLAB " + ...
        "path, or check out luminos-private beside adaptive-optopatch.", ...
        fullfile(helpers,"Write_Pending_Dmd_Stacks.m"));
end
addpath(helpers);
rehash;
end
