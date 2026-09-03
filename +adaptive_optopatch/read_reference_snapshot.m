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

ensure_snapshot_class_available(snapshotPath);
loaded=load(snapshotPath,"snap");
if ~isfield(loaded,"snap") || ~isscalar(loaded.snap) || ...
        ~(isstruct(loaded.snap) || isobject(loaded.snap))
    error("adaptive_optopatch:InvalidSnapshot", ...
        "The selected MAT file does not contain a scalar Luminos 'snap' object.");
end
snap=loaded.snap;
% bin and timestamp were added to CL_RefImage after older Luminos sessions
% had already written snapshots, so they must remain optional here.
required=["img","name","ref2d"];
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
if strlength(options.ExpectedCameraName)>0 && ...
        ~strcmpi(strtrim(cameraName),strtrim(options.ExpectedCameraName))
    error("adaptive_optopatch:WrongReferenceCamera", ...
        "Selected snapshot is from '%s'; choose the voltage-camera snapshot from '%s'.", ...
        cameraName,options.ExpectedCameraName);
end

referenceImage=single(snap.img);
imageSize=size(referenceImage);
[cameraRoi,xWorldLimits,yWorldLimits]=camera_coordinates(snap,imageSize);
cameraBin=read_camera_bin(snap,imageSize,xWorldLimits,yWorldLimits);
timestamp=read_timestamp(snap,snapshotPath);
bitDepth=8*bytes_per_element(snap.img);
camera=struct( ...
    "archive_index",NaN, ...
    "camera_index",1, ...
    "frames_file","", ...
    "name",cameraName, ...
    "serial","", ...
    "ROI",cameraRoi, ...
    "bin",cameraBin, ...
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
    "camera_bin",cameraBin, ...
    "timestamp",timestamp);
end

function ensure_snapshot_class_available(snapshotPath)
variables=whos("-file",snapshotPath);
index=find(strcmp({variables.name},"snap"),1);
if isempty(index) || ~strcmp(variables(index).class,"CL_RefImage") || ...
        exist("CL_RefImage","class")~=0
    return
end

packageDirectory=fileparts(mfilename("fullpath"));
projectDirectory=fileparts(packageDirectory);
softwareDirectory=fileparts(projectDirectory);
classDirectory=fullfile(softwareDirectory,"luminos-private","src", ...
    "utils","Data_Structures");
classFile=fullfile(classDirectory,"CL_RefImage.m");
if ~isfile(classFile)
    error("adaptive_optopatch:MissingLuminosSnapshotClass", ...
        ["This MAT file stores snap as a CL_RefImage object, but MATLAB " ...
         "cannot find CL_RefImage.m. Add Luminos's " ...
         "src/utils/Data_Structures directory to the MATLAB path, then " ...
         "load the snapshot again."]);
end
addpath(classDirectory);
rehash;
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
transforms=snap.tform;
% Before multi-DMD support, Luminos stored the transform object directly.
if is_transform(transforms)
    dmd=make_dmd_record(dmdName,transforms,transforms);
    return
end
names=strings(numel(transforms),1);
for k=1:numel(transforms)
    if has_member(transforms(k),"name")
        names(k)=string(transforms(k).name);
    end
end
idx=find(strcmpi(strtrim(names),strtrim(dmdName)),1);
if isempty(idx), return; end
dmd=make_dmd_record(dmdName,transforms(idx).tform,transforms(idx));
end

function dmd=make_dmd_record(name,tform,rawArchive)
dmd=struct( ...
    "archive_index",NaN, ...
    "name",name, ...
    "device_type","DMD", ...
    "tform",tform, ...
    "raw_archive",rawArchive);
end

function tf=is_transform(value)
tf=isscalar(value) && (isa(value,"affine2d") || ...
    isa(value,"projective2d") || isa(value,"affinetform2d") || ...
    isa(value,"projtform2d"));
end

function bin=read_camera_bin(snap,imageSize,xLimits,yLimits)
if has_member(snap,"bin") && isnumeric(snap.bin) && ...
        isscalar(snap.bin) && isfinite(snap.bin) && snap.bin>0
    bin=double(snap.bin);
    return
end
ratios=[diff(xLimits)/imageSize(2),diff(yLimits)/imageSize(1)];
if all(isfinite(ratios)) && all(ratios>0) && ...
        abs(ratios(1)-ratios(2))<=1e-6*max(ratios)
    bin=mean(ratios);
else
    bin=1;
end
end

function timestamp=read_timestamp(snap,snapshotPath)
if has_member(snap,"timestamp") && ~isempty(snap.timestamp)
    timestamp=snap.timestamp;
    if isnumeric(timestamp) && isscalar(timestamp)
        timestamp=datetime(timestamp,"ConvertFrom","datenum");
    end
    return
end
fileInfo=dir(snapshotPath);
timestamp=datetime(fileInfo.datenum,"ConvertFrom","datenum");
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
