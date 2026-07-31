function [referenceImage, info] = read_reference_snapshot(snapshotPath, options)
%READ_REFERENCE_SNAPSHOT Load a reference made by Luminos's React Snap button.
arguments
    snapshotPath (1,1) string
    options.ExpectedCameraName (1,1) string = "Orca Fusion"
    options.StimulationDmdName (1,1) string = "DMD_Blue"
    options.RigName (1,1) string = "Virtual_Upright"
end

if ~isfile(snapshotPath)
    error("adaptive_optopatch:MissingSnapshot", ...
        "Snapshot file not found: %s",snapshotPath);
end
[snapshotDirectory,baseName,extension]=fileparts(snapshotPath);
if ~strcmpi(extension,".mat")
    error("adaptive_optopatch:SnapshotMatRequired", ...
        "Select the .mat file written by the Luminos Snap button. "+ ...
        "The TIFF does not contain the camera and DMD coordinate metadata.");
end

loaded=load(snapshotPath,"snap");
if ~isfield(loaded,"snap") || ~isscalar(loaded.snap) || ...
        ~(isstruct(loaded.snap) || isobject(loaded.snap))
    error("adaptive_optopatch:InvalidSnapshot", ...
        "The selected MAT file does not contain a scalar Luminos 'snap' object.");
end
snap=loaded.snap;
required=["img","name","bin","ref2d","timestamp"];
present=false(size(required));
for k=1:numel(required), present(k)=has_member(snap,required(k)); end
missing=required(~present);
if ~isempty(missing)
    error("adaptive_optopatch:InvalidSnapshot", ...
        "Luminos snapshot is missing: %s.",strjoin(missing,", "));
end
if ~isnumeric(snap.img) || ndims(snap.img)~=2 || isempty(snap.img)
    error("adaptive_optopatch:InvalidSnapshotImage", ...
        "snap.img must be a nonempty two-dimensional numeric image.");
end
cameraName=string(snap.name);
if strlength(options.ExpectedCameraName)>0 && cameraName~=options.ExpectedCameraName
    error("adaptive_optopatch:WrongReferenceCamera", ...
        "Selected snapshot is from '%s'; choose the voltage-camera snapshot from '%s'.", ...
        cameraName,options.ExpectedCameraName);
end

referenceImage=single(snap.img);
imageSize=size(referenceImage);
[cameraRoi,xWorldLimits,yWorldLimits]=camera_coordinates(snap,imageSize);
bitDepth=8*bytes_per_element(snap.img);
camera=struct( ...
    "archive_index",NaN, ...
    "camera_index",1, ...
    "frames_file","", ...
    "name",cameraName, ...
    "serial","", ...
    "ROI",cameraRoi, ...
    "bin",double(snap.bin), ...
    "bit_depth",bitDepth, ...
    "frames_requested",1, ...
    "exposuretime",[], ...
    "frame_rate",[], ...
    "x_world_limits",xWorldLimits, ...
    "y_world_limits",yWorldLimits, ...
    "raw_archive",snap);

metadata=struct;
metadata.schema_version="0.2.0";
metadata.rig_name=options.RigName;
metadata.source_type="luminos_camera_snapshot";
metadata.snapshot_path=snapshotPath;
metadata.voltage_camera=camera;
metadata.cameras=camera;
metadata.stimulation_dmd=extract_dmd(snap,options.StimulationDmdName);
metadata.scanner=struct([]);

info=struct( ...
    "metadata",metadata, ...
    "snapshot_path",snapshotPath, ...
    "snapshot_directory",string(snapshotDirectory), ...
    "snapshot_name",string(baseName), ...
    "image_size",imageSize, ...
    "camera_name",cameraName, ...
    "camera_bin",double(snap.bin), ...
    "timestamp",snap.timestamp);
end

function [roi,xLimits,yLimits]=camera_coordinates(snap,imageSize)
xLimits=[0 imageSize(2)];
yLimits=[0 imageSize(1)];
if isprop_or_field(snap.ref2d,"XWorldLimits")
    xLimits=double(snap.ref2d.XWorldLimits);
end
if isprop_or_field(snap.ref2d,"YWorldLimits")
    yLimits=double(snap.ref2d.YWorldLimits);
end
roi=[xLimits(1),diff(xLimits),yLimits(1),diff(yLimits)];
end

function tf=isprop_or_field(value,name)
tf=has_member(value,name);
end

function tf=has_member(value,name)
tf=(isobject(value) && isprop(value,name)) || ...
    (isstruct(value) && isfield(value,name));
end

function dmd=extract_dmd(snap,dmdName)
dmd=struct([]);
if ~has_member(snap,"tform") || isempty(snap.tform), return; end
names=strings(numel(snap.tform),1);
for k=1:numel(snap.tform)
    if isfield(snap.tform(k),"name"), names(k)=string(snap.tform(k).name); end
end
idx=find(names==dmdName,1);
if isempty(idx), return; end
dmd=struct( ...
    "archive_index",NaN, ...
    "name",dmdName, ...
    "device_type","DMD", ...
    "tform",snap.tform(idx).tform, ...
    "raw_archive",snap.tform(idx));
end

function bytes=bytes_per_element(value)
switch class(value)
    case {"uint8","int8","logical"}
        bytes=1;
    case {"uint16","int16"}
        bytes=2;
    case {"uint32","int32","single"}
        bytes=4;
    otherwise
        bytes=8;
end
end
