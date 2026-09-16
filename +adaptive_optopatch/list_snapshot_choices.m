function choices=list_snapshot_choices(options)
%LIST_SNAPSHOT_CHOICES Camera snapshots a frontend may ask to have loaded.
%   MATLAB owns discovery, exactly as it does for pulse protocols. A frontend
%   picks a stable choice_id out of this list and asks for it by that name; it
%   never sends a filesystem path, and nothing outside this function decides
%   which files are offerable.
%
%   choice_id is the snapshot's STEM, which is the identifier Luminos already
%   uses for a snapshot everywhere else: Camera_Snap writes <stem>.tiff,
%   <stem>.mat and a browser-visible <stem>.png from one stem, and the
%   patterning image pickers pass that same stem to Load_Ref_Im_JS. Reusing it
%   means a snapshot is called the same thing in the Adaptive Optopatch tab as
%   in the DMD tab, and a frontend that wants the PNG thumbnail Luminos
%   already serves can find it by name.
%
%   Every candidate is opened through read_reference_snapshot - the same
%   function loadSnapshot uses - so `loadable` means "loadSnapshot would
%   succeed", not "this file looks plausible". A snap from the wrong camera,
%   a half-written file, or a MAT holding something else is listed with the
%   reason rather than hidden, because an operator who cannot see the file
%   they just took has no way to find out why.
%
%   Saved Adaptive Optopatch FOVs share this folder and this extension.
%   They are excluded here and listed by list_fov_choices instead, because a
%   restorable FOV is a different kind of thing from a camera snapshot; see
%   list_reference_choices for the one listing that offers both.
%
%   That costs one image load per candidate, so the listing is capped and
%   ordered newest first: the snapshot an operator wants is almost always the
%   one they just took. It is read on demand, never on a poll.
arguments
    options.Roots string = strings(0,1)
    %LIMIT How many of the most recent snapshots to describe.
    options.Limit (1,1) double {mustBePositive,mustBeInteger} = 40
    %EXPECTEDCAMERANAME Passed through to read_reference_snapshot, so the
    %   listing applies exactly the camera rule loading will apply.
    options.ExpectedCameraName (1,1) string = "Orca Fusion"
end

roots=unique(reshape(options.Roots,[],1),"stable");
files=struct("path",{},"modified",{});
seen=strings(0,1);
for root=reshape(roots,1,[])
    if strlength(root)==0 || ~isfolder(root), continue; end
    listing=dir(fullfile(root,"*.mat"));
    for entry=reshape(listing,1,[])
        if entry.isdir, continue; end
        % A saved Adaptive Optopatch FOV lives beside the snapshot it was
        % drawn on and is also a .mat. It is not a camera snapshot and must
        % not be offered as one: read_reference_snapshot cannot read it, so
        % without this it would appear here as an unloadable snapshot rather
        % than in list_fov_choices as the restorable FOV it is.
        [~,stem]=fileparts(entry.name);
        if adaptive_optopatch.parse_fov_bundle_name(string(stem)), continue; end
        path=string(fullfile(entry.folder,entry.name));
        if any(seen==path), continue; end
        seen(end+1,1)=path; %#ok<AGROW>
        files(end+1)=struct("path",path,"modified",entry.datenum); %#ok<AGROW>
    end
end

choices=empty_choice_array();
if isempty(files), return; end

% Newest first, and only as many as the cap allows. Ordered by file time
% rather than by name: a stem starts with HHMMSS and sorts by time within one
% day, but a Snaps folder reached across midnight, or a root that is not a
% dated folder at all, does not.
[~,order]=sort([files.modified],"descend");
files=files(order);
files=files(1:min(numel(files),options.Limit));

for entry=files
    choices(end+1,1)=describe_choice(entry.path, ...
        options.ExpectedCameraName,choices); %#ok<AGROW>
end
end

function choice=describe_choice(path,expectedCamera,existing)
[folder,name]=fileparts(path);
choice=empty_choice();
choice.choice_id=unique_choice_id(name,existing);
choice.name=string(name);
choice.folder=string(folder);
choice.path=string(path);
try
    [~,info]=adaptive_optopatch.read_reference_snapshot(path, ...
        "ExpectedCameraName",expectedCamera);
    camera=info.metadata.voltage_camera;
    choice.loadable=true;
    choice.camera_name=string(info.camera_name);
    choice.camera_bin=double(info.camera_bin);
    % [rows columns], the same order fov.image_size reports.
    choice.image_size=double(info.image_size(1:2));
    % Where this frame sits on the sensor. A cropped snapshot is the normal
    % case on the Virtual Upright, and seeing the origin before loading is
    % how an operator tells two crops of the same field apart.
    choice.roi_origin_xy=[camera.ROI(1) camera.ROI(3)];
    choice.roi_size_xy=[camera.ROI(2) camera.ROI(4)];
    choice.timestamp=timestamp_text(info);
catch exception
    % Listed, and listed as unloadable. One unreadable MAT in the Snaps
    % folder must not hide every snapshot beside it.
    choice.issue=string(exception.message);
end
end

function value=timestamp_text(info)
value="";
if ~isfield(info,"timestamp"), return; end
try
    value=string(datetime(info.timestamp),"yyyy-MM-dd HH:mm:ss");
catch
    % A snapshot written before timestamps, or with an unparseable one.
end
end

function id=unique_choice_id(name,existing)
id=string(name);
if isempty(existing), return; end
taken=[existing.choice_id];
suffix=2;
while any(taken==id)
    id=string(name)+"#"+string(suffix);
    suffix=suffix+1;
end
end

function choice=empty_choice()
% Deliberately flat and deliberately small. info.metadata.voltage_camera also
% carries raw_archive - the whole CL_RefImage, pixels included - and none of
% that belongs on a wire that a browser reads.
choice=struct("choice_id","","name","","folder","","path","", ...
    "loadable",false,"issue","","camera_name","","camera_bin",NaN, ...
    "image_size",[0 0],"roi_origin_xy",[NaN NaN],"roi_size_xy",[NaN NaN], ...
    "timestamp","");
end

function choices=empty_choice_array()
choices=repmat(empty_choice(),0,1);
end
