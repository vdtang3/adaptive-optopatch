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
switch string(rig.rigname)
    case "Virtual_Upright"
        profile=adaptive_optopatch.virtual_upright_1p_profile();
    case "Spinning_Upright"
        profile=adaptive_optopatch.spinning_upright_1p_profile();
    otherwise
        error("adaptive_optopatch:UnsupportedRig", ...
            "Adaptive Optopatch has no 1P hardware profile for rig '%s'.", ...
            string(rig.rigname));
end
end
