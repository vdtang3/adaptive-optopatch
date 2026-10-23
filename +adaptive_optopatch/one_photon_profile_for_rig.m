function profile=one_photon_profile_for_rig(app)
%ONE_PHOTON_PROFILE_FOR_RIG Select only explicitly supported rig wiring.
if isempty(app) || ~isprop(app,"Rig_Init") || isempty(app.Rig_Init)
    profile=adaptive_optopatch.virtual_upright_1p_profile();
    return
end
rig=app.Rig_Init;
if (isstruct(rig) && ~isfield(rig,"rigname")) || ...
        (~isstruct(rig) && ~isprop(rig,"rigname"))
    error("adaptive_optopatch:UnknownRig", ...
        "Luminos rig initializer has no rigname.");
end
% Rig_Initializer.rigname is [] when the rig's JSON does not declare it, and
% error() refuses a non-scalar %s argument, which used to hide the real cause.
rigname=rig.rigname;
if ~(ischar(rigname) || isstring(rigname) || iscellstr(rigname)) || ...
        ~isscalar(string(rigname)) || ismissing(string(rigname)) || ...
        strlength(string(rigname))==0
    error("adaptive_optopatch:UnknownRig", ...
        "Luminos rig initializer rigname must be one rig name, but it is a %s %s. " + ...
        "Declare ""rigname"" in the rig's JSON file, e.g. ""Virtual_Upright"".", ...
        strjoin(string(size(rigname)),"x"),class(rigname));
end
switch string(rigname)
    case "Virtual_Upright"
        profile=adaptive_optopatch.virtual_upright_1p_profile();
    case "Spinning_Upright"
        profile=adaptive_optopatch.spinning_upright_1p_profile();
    otherwise
        error("adaptive_optopatch:UnsupportedRig", ...
            "Adaptive Optopatch has no 1P hardware profile for rig '%s'.", ...
            string(rigname));
end
end
