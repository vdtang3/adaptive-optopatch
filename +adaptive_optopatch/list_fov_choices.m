function choices=list_fov_choices(options)
%LIST_FOV_CHOICES Saved Adaptive Optopatch FOVs a frontend may ask to load.
%   The saved-FOV half of the unified Reference/FOV chooser. It reads the
%   same folders list_snapshot_choices reads, because a bundle is written
%   beside the snapshot it was drawn on, and it recognises one by name:
%   <snapshot>_FOV###.mat (see parse_fov_bundle_name).
%
%   Every candidate is opened through load_fov_state - the same function
%   loadFov uses - so `loadable` means "loadFov would succeed" rather than
%   "this file has the right name". A bundle written by an older package
%   version fails its schema check here and is listed with that reason,
%   which is the answer an operator needs; hiding it would leave them
%   looking for a FOV they know they saved.
%
%   That costs one MAT load per candidate, so the listing is capped and
%   ordered newest first, and it is read on demand, never on a poll.
arguments
    options.Roots string = strings(0,1)
    %LIMIT How many of the most recent bundles to describe.
    options.Limit (1,1) double {mustBePositive,mustBeInteger} = 40
end

files=struct("path",{},"modified",{});
seen=strings(0,1);
for root=reshape(unique(reshape(options.Roots,[],1),"stable"),1,[])
    if strlength(root)==0 || ~isfolder(root), continue; end
    for entry=reshape(dir(fullfile(root,"*_FOV*.mat")),1,[])
        if entry.isdir, continue; end
        [~,name]=fileparts(entry.name);
        if ~adaptive_optopatch.parse_fov_bundle_name(string(name)), continue; end
        path=string(fullfile(entry.folder,entry.name));
        if any(seen==path), continue; end
        seen(end+1,1)=path; %#ok<AGROW>
        files(end+1)=struct("path",path,"modified",entry.datenum); %#ok<AGROW>
    end
end

choices=empty_choice_array();
if isempty(files), return; end

[~,order]=sort([files.modified],"descend");
files=files(order);
files=files(1:min(numel(files),options.Limit));

for entry=files
    choices(end+1,1)=describe_choice(entry.path,choices); %#ok<AGROW>
end
end

function choice=describe_choice(path,existing)
[folder,name]=fileparts(path);
[~,snapshotStem,number]=adaptive_optopatch.parse_fov_bundle_name(string(name));
choice=empty_choice();
choice.choice_id=unique_choice_id(name,existing);
choice.name=string(name);
choice.folder=string(folder);
choice.path=string(path);
choice.reference_id=snapshotStem;
choice.fov_number=number;
try
    fovState=adaptive_optopatch.load_fov_state(path);
    reference=fovState.reference;
    choice.loadable=true;
    choice.fov_id=string(fovState.fov_id);
    choice.cell_count=numel(fovState.cells);
    choice.stimulation_enabled_count= ...
        count_flag(fovState.cells,"stimulation_enabled");
    choice.recording_enabled_count= ...
        count_flag(fovState.cells,"recording_enabled");
    choice.calibrated_cell_count= ...
        sum(isfinite(double([fovState.cells.selected_blue_voltage_v])));
    choice.image_size=double(reference.image_size(1:2));
    choice.source_snapshot=source_snapshot(reference);
    if isfield(reference,"voltage_camera")
        camera=reference.voltage_camera;
        if isfield(camera,"name"), choice.camera_name=string(camera.name); end
        if isfield(camera,"bin"), choice.camera_bin=double(camera.bin); end
        if isfield(camera,"ROI") && numel(camera.ROI)>=4
            roi=double(camera.ROI);
            choice.roi_origin_xy=[roi(1) roi(3)];
            choice.roi_size_xy=[roi(2) roi(4)];
        end
    end
    choice.timestamp=timestamp_text(fovState);
catch exception
    % Listed, and listed as unloadable, for the same reason an unreadable
    % snapshot is: one stale bundle must not hide the ones beside it.
    choice.issue=string(exception.message);
end
end

function value=source_snapshot(reference)
value="";
if isfield(reference,"source_snapshot")
    value=string(reference.source_snapshot);
end
end

function value=count_flag(cells,name)
value=NaN;
if ~isfield(cells,name), return; end
value=sum(logical([cells.(name)]));
end

function value=timestamp_text(fovState)
value="";
for field=["updated_at","created_at"]
    if ~isfield(fovState,field), continue; end
    try
        value=string(datetime(string(fovState.(field))),"yyyy-MM-dd HH:mm:ss");
        return
    catch
        % A bundle written before timestamps, or with an unparseable one.
    end
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
% Flat and small, for the same reason the snapshot listing is: a saved FOV
% carries the reference image, the ROI mask stack and every cell's
% calibration history, and none of that belongs on a wire a browser reads
% once per button press.
choice=struct("choice_id","","name","","folder","","path","", ...
    "loadable",false,"issue","","reference_id","","fov_number",NaN, ...
    "fov_id","","cell_count",NaN,"recording_enabled_count",NaN, ...
    "stimulation_enabled_count",NaN,"calibrated_cell_count",NaN, ...
    "camera_name","","camera_bin",NaN,"image_size",[0 0], ...
    "roi_origin_xy",[NaN NaN],"roi_size_xy",[NaN NaN], ...
    "source_snapshot","","timestamp","");
end

function choices=empty_choice_array()
choices=repmat(empty_choice(),0,1);
end
