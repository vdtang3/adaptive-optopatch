function metadata = load_luminos_metadata(outputDataPath, options)
%LOAD_LUMINOS_METADATA Read archived Luminos metadata without loading movies.
arguments
    outputDataPath (1,1) string
    options.VoltageCameraSerial (1,1) string = "001125"
    options.StimulationDmdName (1,1) string = "DMD_Blue"
    options.ScannerName (1,1) string = "Chameleon (To friends: Ben)"
end

if ~isfile(outputDataPath)
    error("adaptive_optopatch:MissingOutputData", ...
        "File not found: %s", outputDataPath);
end

s = load(outputDataPath, "Device_Data");
if ~isfield(s, "Device_Data") || isempty(s.Device_Data)
    error("adaptive_optopatch:InvalidOutputData", ...
        "Device_Data is missing from %s", outputDataPath);
end
dd = s.Device_Data;
appArchive = dd{1};
if isfield(appArchive, "rigName")
    rigName = string(appArchive.rigName);
elseif isfield(appArchive, "Rig")
    rigName = string(appArchive.Rig);
else
    rigName = "";
end

metadata = struct;
metadata.schema_version = "0.1.0";
metadata.output_data_path = outputDataPath;
metadata.rig_name = rigName;
metadata.device_data = dd;
metadata.voltage_camera = struct([]);
metadata.stimulation_dmd = struct([]);
metadata.scanner = struct([]);

cameraCounter = 0;
for k = 2:numel(dd)
    d = dd{k};
    if ~isstruct(d), continue; end
    deviceType = get_field_string(d, ["deviceType", "Device_Type"]);
    deviceName = get_field_string(d, ["name", "Device_Name"]);

    if deviceType == "Camera"
        cameraCounter = cameraCounter + 1;
        serial = erase(get_field_string(d, "cam_id"), "S/N: ");
        camera = struct( ...
            "archive_index", k, ...
            "camera_index", cameraCounter, ...
            "frames_file", "frames" + cameraCounter + ".bin", ...
            "name", deviceName, ...
            "serial", strip(serial), ...
            "ROI", get_field(d, "ROI", []), ...
            "bin", get_field(d, "bin", []), ...
            "bit_depth", get_field(d, "bit_depth", []), ...
            "frames_requested", get_field(d, "frames_requested", []), ...
            "exposuretime", get_field(d, "exposuretime", []), ...
            "frame_rate", get_field(d, ["frame_rate","framerate"], []), ...
            "raw_archive", d);
        metadata.cameras(cameraCounter) = camera;
        if strip(serial) == options.VoltageCameraSerial
            metadata.voltage_camera = camera;
        end
    elseif deviceName == options.StimulationDmdName
        metadata.stimulation_dmd = device_summary(d, k);
    elseif deviceType == "Scanning_Device" && deviceName == options.ScannerName
        metadata.scanner = device_summary(d, k);
    end
end

if metadata.rig_name ~= "Virtual_Upright"
    warning("adaptive_optopatch:UnexpectedRig", ...
        "Expected Virtual_Upright but found '%s'.", metadata.rig_name);
end
if isempty(metadata.voltage_camera)
    error("adaptive_optopatch:VoltageCameraNotFound", ...
        "Voltage camera serial %s was not found.", options.VoltageCameraSerial);
end
if isempty(metadata.stimulation_dmd)
    error("adaptive_optopatch:DmdNotFound", ...
        "Stimulation DMD '%s' was not found.", options.StimulationDmdName);
end
end

function out = device_summary(d, archiveIndex)
out = struct( ...
    "archive_index", archiveIndex, ...
    "name", get_field_string(d, ["name", "Device_Name"]), ...
    "device_type", get_field_string(d, ["deviceType", "Device_Type"]), ...
    "tform", get_field(d, "tform", []), ...
    "raw_archive", d);
end

function value = get_field(s, names, fallback)
names = string(names);
for name = names
    if isfield(s, name)
        value = s.(name);
        return
    end
end
value = fallback;
end

function value = get_field_string(s, names)
value = string(get_field(s, names, ""));
end
