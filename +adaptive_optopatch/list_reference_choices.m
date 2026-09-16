function choices=list_reference_choices(options)
%LIST_REFERENCE_CHOICES One typed listing of everything a session can start from.
%   A session's reference comes from one of two things, and they are NOT the
%   same thing:
%
%     kind = "snapshot"   a Luminos camera snapshot. Loading it starts a
%                         FRESH FOV: the picture, the camera identity, the
%                         crop and the DMD transforms recorded with the
%                         snap, and no cells. Canonical path: loadSnapshot.
%
%     kind = "ao_fov"     a saved Adaptive Optopatch FOV, written beside the
%                         snapshot it was drawn on as <snapshot>_FOV###.mat.
%                         Loading it RESTORES: soma geometry, stable cell
%                         identities, per-cell recording/stimulation
%                         decisions and Blue calibration, the spatial plan
%                         values, and the reference provenance. Canonical
%                         path: loadFov.
%
%   They are offered in ONE listing because to an operator they are one
%   question - which field am I working on - and answering it in two places
%   invites loading a snapshot on top of a FOV that already had the cells.
%   They are TYPED rather than blended because an Adaptive Optopatch FOV
%   must never pretend to be a camera snapshot: the two carry different
%   things and take different paths into the controller.
%
%   choice_id is the FILE STEM, which is unique across both kinds because a
%   bundle's stem always ends in _FOV###. A frontend sends that id and
%   nothing else; resolving it to a file, and deciding which of the two
%   paths it takes, both happen on this side.
arguments
    options.Roots string = strings(0,1)
    options.Limit (1,1) double {mustBePositive,mustBeInteger} = 40
    options.ExpectedCameraName (1,1) string = "Orca Fusion"
end

snapshots=adaptive_optopatch.list_snapshot_choices( ...
    "Roots",options.Roots,"Limit",options.Limit, ...
    "ExpectedCameraName",options.ExpectedCameraName);
bundles=adaptive_optopatch.list_fov_choices( ...
    "Roots",options.Roots,"Limit",options.Limit);

choices=empty_choice_array();
for k=1:numel(snapshots)
    choices(end+1,1)=from_snapshot(snapshots(k)); %#ok<AGROW>
end
for k=1:numel(bundles)
    choices(end+1,1)=from_bundle(bundles(k)); %#ok<AGROW>
end
if isempty(choices), return; end

% Grouped by the reference they describe, newest reference first, and within
% a group the snapshot ahead of the FOVs saved from it. That is the order the
% list is read in: "which field", then "which set of decisions about it".
[choices,groupOrder]=sort_by_reference(choices);
for k=1:numel(choices)
    choices(k).group_index=groupOrder(k);
end
end

function choice=from_snapshot(entry)
choice=empty_choice();
choice.choice_id=entry.choice_id;
choice.kind="snapshot";
choice.name=entry.name;
choice.label=entry.name;
choice.folder=entry.folder;
choice.path=entry.path;
choice.loadable=entry.loadable;
choice.issue=entry.issue;
% A snapshot IS its own reference identity; the bundles saved from it carry
% the same value, which is what groups them together in the listing.
choice.reference_id=entry.name;
choice.camera_name=entry.camera_name;
choice.camera_bin=entry.camera_bin;
choice.image_size=entry.image_size;
choice.roi_origin_xy=entry.roi_origin_xy;
choice.roi_size_xy=entry.roi_size_xy;
choice.timestamp=entry.timestamp;
end

function choice=from_bundle(entry)
choice=empty_choice();
choice.choice_id=entry.choice_id;
choice.kind="ao_fov";
choice.name=entry.name;
choice.label=sprintf("%s — FOV %03d",entry.reference_id,entry.fov_number);
choice.folder=entry.folder;
choice.path=entry.path;
choice.loadable=entry.loadable;
choice.issue=entry.issue;
choice.reference_id=entry.reference_id;
choice.fov_number=entry.fov_number;
choice.fov_id=entry.fov_id;
choice.cell_count=entry.cell_count;
choice.recording_enabled_count=entry.recording_enabled_count;
choice.stimulation_enabled_count=entry.stimulation_enabled_count;
choice.calibrated_cell_count=entry.calibrated_cell_count;
choice.camera_name=entry.camera_name;
choice.camera_bin=entry.camera_bin;
choice.image_size=entry.image_size;
choice.roi_origin_xy=entry.roi_origin_xy;
choice.roi_size_xy=entry.roi_size_xy;
choice.source_snapshot=entry.source_snapshot;
choice.timestamp=entry.timestamp;
end

function [choices,groupOrder]=sort_by_reference(choices)
references=reshape([choices.reference_id],[],1);
kinds=reshape([choices.kind],[],1);
% Both listings arrive newest first, so a reference's rank is the position
% of its earliest entry: the most recently touched reference leads.
uniqueReferences=unique(references,"stable");
rank=zeros(numel(choices),1);
for k=1:numel(uniqueReferences)
    rank(references==uniqueReferences(k))=k;
end
% Within a group: the snapshot, then the FOVs saved from it, newest first -
% which is the order they already arrived in, preserved by the third key.
withinGroup=double(kinds=="ao_fov");
% Column keys throughout: [choices.field] is a row, and sortrows needs the
% three keys to be columns of one matrix.
[~,order]=sortrows([rank withinGroup (1:numel(choices))']);
choices=choices(order);
groupOrder=rank(order);
end

function choice=empty_choice()
choice=struct("choice_id","","kind","","label","","name","", ...
    "folder","","path","","loadable",false,"issue","", ...
    "reference_id","","fov_number",NaN,"fov_id","", ...
    "cell_count",NaN,"recording_enabled_count",NaN, ...
    "stimulation_enabled_count",NaN,"calibrated_cell_count",NaN, ...
    "camera_name","","camera_bin",NaN,"image_size",[0 0], ...
    "roi_origin_xy",[NaN NaN],"roi_size_xy",[NaN NaN], ...
    "source_snapshot","","timestamp","","group_index",NaN, ...
    "is_current",false);
end

function choices=empty_choice_array()
choices=repmat(empty_choice(),0,1);
end
