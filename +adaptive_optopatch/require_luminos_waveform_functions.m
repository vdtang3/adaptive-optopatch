function require_luminos_waveform_functions()
%REQUIRE_LUMINOS_WAVEFORM_FUNCTIONS Ensure Luminos's wavefiles are callable.
%   Compiling a waveform configuration to samples means calling the
%   functions the records name - awfm_constant, dwfm_pulse and the rest -
%   and those are Luminos's, not AO's. On the rig they are already on the
%   path because Luminos is running. Away from the rig they are not, and a
%   bare feval failure reads as "Unrecognized function 'awfm_constant'",
%   which says nothing about what to do next.
%
%   Same sibling lookup read_reference_snapshot uses for CL_RefImage.
if exist("awfm_constant","file")==2 && exist("defcheck","file")==2
    return
end
packageDirectory=fileparts(mfilename("fullpath"));
projectDirectory=fileparts(packageDirectory);
softwareDirectory=fileparts(projectDirectory);
devices=fullfile(softwareDirectory,"luminos-private","src","Devices");
waveformFunctions=fullfile(devices,"DAQ","Waveform_Functions");
if ~isfile(fullfile(waveformFunctions,"awfm_constant.m"))
    error("adaptive_optopatch:MissingLuminosWaveformFunctions", ...
        "Measuring what a waveform configuration would output requires " + ...
        "Luminos's own waveform functions, and %s was not found. Add " + ...
        "Luminos's src/Devices/DAQ/Waveform_Functions and src/Devices " + ...
        "directories to the MATLAB path, or check out luminos-private " + ...
        "beside adaptive-optopatch.", ...
        fullfile(waveformFunctions,"awfm_constant.m"));
end
addpath(waveformFunctions,devices);
rehash;
end
