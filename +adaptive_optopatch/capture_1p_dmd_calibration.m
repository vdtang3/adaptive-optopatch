function record=capture_1p_dmd_calibration(hardware,targets)
%CAPTURE_1P_DMD_CALIBRATION Archive the 1P camera-to-DMD calibration used.
%   Luminos owns the camera-to-DMD calibration for DMD_Blue and DMD_Orange.
%   Adaptive Optopatch keeps its biological masks in voltage-camera
%   coordinates and hands them to Luminos, which projects them through
%   whichever calibration is active at that moment. That active calibration
%   is authoritative: a recalibration after planning is Luminos's improved
%   estimate of how to realize the same camera-space intent, so it is used,
%   not overridden and not gated.
%
%   Everything here is provenance. A planning-time snapshot is recorded
%   where one exists purely so a completed run can say whether the
%   projection changed between planning and execution; it never replaces
%   the live transform.
arguments
    hardware (1,1) struct
    targets (1,1) struct
end
planningBlue=[];
if isfield(targets,"planning_blue_dmd_transform")
    planningBlue=targets.planning_blue_dmd_transform;
end
record=struct("schema_version","1.0.0", ...
    "authority","luminos_active_calibration", ...
    "captured_at",string(datetime("now","TimeZone","local")), ...
    "blue",describe_dmd(field_or_empty(hardware,"dmd"),planningBlue), ...
    "orange",describe_dmd(field_or_empty(hardware,"orange_dmd"),[]));
end

function entry=describe_dmd(dmd,planningTransform)
entry=struct("name","","present",false,"has_transform",false, ...
    "execution_dmd_transform",[],"execution_transform_matrix",[], ...
    "dmd_dimensions",[],"reference_image_size",[], ...
    "reference_world_limits",[], ...
    "planning_dmd_transform",planningTransform, ...
    "planning_transform_matrix",transform_matrix(planningTransform), ...
    "comparison","no_planning_snapshot", ...
    "calibration_changed_since_planning",false, ...
    "maximum_element_difference",NaN);
if isempty(dmd), entry.comparison="device_absent"; return; end
entry.present=true;
entry.name=string(read_member(dmd,"name",""));
live=read_member(dmd,"tform",[]);
entry.execution_dmd_transform=live;
entry.execution_transform_matrix=transform_matrix(live);
entry.has_transform=~isempty(entry.execution_transform_matrix);
entry.dmd_dimensions=double(read_member(dmd,"Dimensions",[]));
[entry.reference_image_size,entry.reference_world_limits]= ...
    reference_geometry(read_member(dmd,"refimage",[]));
if isempty(entry.planning_transform_matrix)
    return
end
if ~entry.has_transform || ...
        ~isequal(size(entry.planning_transform_matrix), ...
        size(entry.execution_transform_matrix))
    entry.comparison="not_comparable";
    return
end
entry.maximum_element_difference=max(abs( ...
    entry.planning_transform_matrix-entry.execution_transform_matrix),[],"all");
if entry.maximum_element_difference<=1e-9
    entry.comparison="unchanged";
else
    entry.comparison="changed";
    entry.calibration_changed_since_planning=true;
end
end

function [imageSize,worldLimits]=reference_geometry(refimage)
imageSize=[]; worldLimits=[];
if isempty(refimage), return; end
image=read_member(refimage,"img",[]);
if isempty(image) && isnumeric(refimage), image=refimage; end
if ~isempty(image), imageSize=double(size(image,1:2)); end
ref2d=read_member(refimage,"ref2d",[]);
x=read_member(ref2d,"XWorldLimits",[]);
y=read_member(ref2d,"YWorldLimits",[]);
if numel(x)==2 && numel(y)==2
    worldLimits=[double(x(:))' double(y(:))'];
end
end

function value=field_or_empty(record,name)
value=[];
if isfield(record,name), value=record.(name); end
end

function value=read_member(object,name,defaultValue)
value=defaultValue;
if isempty(object), return; end
try
    if isstruct(object) && isfield(object,name)
        value=object.(name);
    elseif isobject(object) && isprop(object,name)
        value=object.(name);
    end
catch
end
if isempty(value), value=defaultValue; end
end

function matrix=transform_matrix(tform)
matrix=[];
if isempty(tform), return; end
if isa(tform,"affinetform2d") || isa(tform,"projtform2d")
    matrix=double(tform.A);
elseif isa(tform,"affine2d") || isa(tform,"projective2d")
    matrix=double(tform.T)';
elseif isnumeric(tform)
    matrix=double(tform);
end
end
