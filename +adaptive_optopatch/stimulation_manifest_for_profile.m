function manifest=stimulation_manifest_for_profile(profile)
%STIMULATION_MANIFEST_FOR_PROFILE Keep waveform accounting rig specific.
switch string(profile.rig_name)
    case "Virtual_Upright"
        manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
    case "Spinning_Upright"
        manifest=adaptive_optopatch.spinning_upright_stimulation_manifest();
    otherwise
        error("adaptive_optopatch:UnsupportedRig", ...
            "No stimulation output declaration for rig '%s'.",profile.rig_name);
end
end
