function generate_ao_fixtures()
%GENERATE_AO_FIXTURES Write development AO fixtures from the real controller.
%   The fixtures are exactly what JS_Server would put on the wire as the
%   `data` field of a reply: jsonencode of what the real endpoints return.
%   They exist so fake_matlab_server.js can serve real controller state,
%   real canonical geometry and a real reference image to the Luminos React
%   frontend on a machine with no rig. They are DEVELOPMENT ARTIFACTS of
%   this repository - nothing in Luminos reads them.
%
%   Written here:
%       fake_ao_state_empty.json        a fresh session
%       fake_ao_state_loaded.json       a mid-session controller
%       fake_ao_reference_image.json    that session's reference FOV
%       fake_ao_protocol_choices.json   protocols it could load
%
%   Run headlessly from this folder:
%       matlab -batch "generate_ao_fixtures"

repository_root=string(fileparts(fileparts(fileparts(mfilename("fullpath")))));
if ~isfolder(fullfile(repository_root,"+adaptive_optopatch"))
    error("adaptive_optopatch:dev:PackageNotFound", ...
        ["No +adaptive_optopatch package under %s. This script expects to " ...
         "live at <repository root>/dev/luminos-react/."],repository_root);
end

% Only the repository root, not a recursive addpath: that is the one folder
% the +adaptive_optopatch package and simulatedLuminosApp are reached through,
% and it is what run_tests.m adds too.
original_path=path;
cleanup=onCleanup(@()path(original_path)); %#ok<NASGU>
addpath(repository_root);

fixture_dir=fullfile(fileparts(mfilename("fullpath")),"fixtures");
if ~isfolder(fixture_dir), mkdir(fixture_dir); end

write_fixture(fullfile(fixture_dir,"fake_ao_state_empty.json"), ...
    empty_controller().getState());

[controller,protocol_root]=loaded_controller();
write_fixture(fullfile(fixture_dir,"fake_ao_state_loaded.json"), ...
    controller.getState());

% The reference image travels on its own endpoint, never on the state poll,
% so it is its own fixture. Stored with its dimensions because the stub has
% to reproduce JS_Server's framing decision - small arrays go as JSON, large
% ones as raw bytes - and needs to know how many elements there are.
image=controller.referenceDisplayImage();
write_json(fullfile(fixture_dir,"fake_ao_reference_image.json"), ...
    struct("rows",size(image,1),"columns",size(image,2), ...
        "note","uint8, column-major, exactly what the endpoint returns", ...
        "pixels",reshape(double(image),1,[])),"Pretty",false);

controller.ProtocolRoot=protocol_root;
write_json(fullfile(fixture_dir,"fake_ao_protocol_choices.json"), ...
    redact_choice_paths(controller.protocolChoices()));
end

function controller=empty_controller()
%EMPTY_CONTROLLER A controller as the operator first sees it: no FOV, no protocol.
controller=adaptive_optopatch.AdaptiveOptopatchController();
end

function [controller,protocol_root]=loaded_controller()
%LOADED_CONTROLLER A realistic mid-session controller.
%   Built the way the controller tests build one: simulated Luminos backend,
%   a reference FOV, canonical somata drawn round the cells actually visible
%   in it, per-cell decisions, a real screen protocol, and a frozen run.
root=string(tempname);
mkdir(root);
cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>

[image,polygons]=synthetic_reference();
controller=adaptive_optopatch.AdaptiveOptopatchController( ...
    "LuminosApp",simulatedLuminosApp("CameraRoi", ...
        [974 size(image,2) 984 size(image,1)]), ...
    "RunRoot",root);
controller.setReferenceData(image,reference_info(root,image),polygons);
controller.setCellCalibration("cell_001",1.4,"development fixture");
controller.setCellEligibility("cell_002","StimulationEnabled",false);
controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",1,"ModulatorVoltage",1));
controller.setPlanParameter("mode","1p_dmd");
controller.freezeRun();

protocol_root=adaptive_optopatch.default_protocol_root();
end

function [image,polygons]=synthetic_reference()
%SYNTHETIC_REFERENCE A small deterministic FOV with three cells in it.
%   Not real imaging data: a fixture that is committed has to be small, and
%   a real snapshot is neither. What matters for frontend work is that the
%   picture has structure the operator can aim at, that the canonical
%   polygons sit on that structure, and that both are identical on every
%   machine - so the background is seeded rather than random.
rows=128; columns=160;
[x,y]=meshgrid(1:columns,1:rows);
stream=RandStream("mt19937ar","Seed",20260916);
image=120+8*randn(stream,rows,columns);

% Gentle illumination falloff, so the display stretch has something to do.
image=image+40*exp(-((x-columns/2).^2+(y-rows/2).^2)/(2*(0.8*columns)^2));

centres=[38 40; 104 56; 72 98];
radii=[9 8 10];
polygons=cell(size(centres,1),1);
for k=1:size(centres,1)
    centre=centres(k,:); radius=radii(k);
    image=image+900*exp(-((x-centre(1)).^2+(y-centre(2)).^2)/(2*(radius/2)^2));
    % A polygon an operator would plausibly have drawn: an octagon a little
    % outside the visible soma.
    angles=(0:7)'*pi/4;
    polygons{k}=[centre(1)+(radius+2)*cos(angles), ...
        centre(2)+(radius+2)*sin(angles)];
end
image=single(image);
end

function info=reference_info(root,image)
camera=struct("ROI",[0 0 size(image,2) size(image,1)],"bin",1, ...
    "x_world_limits",[974 974+size(image,2)], ...
    "y_world_limits",[984 984+size(image,1)]);
info=struct("snapshot_name","dev_fixture_fov", ...
    "snapshot_directory",root, ...
    "snapshot_path",fullfile(root,"snapshot.mat"), ...
    "camera_name","Orca Fusion","camera_bin",1, ...
    "metadata",struct("rig_name","Virtual_Upright","voltage_camera",camera));
end

function write_fixture(target,state)
% The frozen run folder is a temporary directory that will not exist when the
% fixture is served, so it is rewritten to something that reads as what it is.
if isfield(state,"active_run") && isfield(state.active_run,"folder")
    state.active_run.folder=redact_temporary(state.active_run.folder);
end
if isfield(state,"fov")
    state.fov.snapshot_directory=redact_temporary(state.fov.snapshot_directory);
    state.fov.snapshot_path=redact_temporary(state.fov.snapshot_path);
end
state.status=redact_temporary(state.status);
write_json(target,state);
end

function choices=redact_choice_paths(choices)
% The generating machine's protocol folder is not the serving machine's.
for k=1:numel(choices)
    choices(k).folder="<dev fixture protocols>";
    choices(k).path="<dev fixture protocols>"+string(filesep)+ ...
        choices(k).name+".mat";
end
end

function write_json(target,value,options)
% Pretty by default, because a fixture that is read and hand-edited should
% be readable. One pixel per line is not readable, so the image is not.
arguments
    target (1,1) string
    value
    options.Pretty (1,1) logical = true
end
fid=fopen(target,"w");
if fid<0
    error("adaptive_optopatch:dev:FixtureNotWritable", ...
        "Could not write %s",target);
end
closer=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,"%s\n",jsonencode(value,"PrettyPrint",options.Pretty));
fprintf("wrote %s\n",target);
end

function value=redact_temporary(value)
value=replace(string(value),string(tempdir),"<dev fixture>"+filesep);
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
