function generate_ao_fixtures()
%GENERATE_AO_FIXTURES Write development AO state fixtures from the real controller.
%   The fixtures are exactly what JS_Server would put on the wire as the
%   `data` field of a reply: jsonencode(controller.getState()). They exist so
%   fake_matlab_server.js can serve real controller state to the Luminos React
%   frontend on a machine with no rig. They are DEVELOPMENT ARTIFACTS of this
%   repository - nothing in Luminos reads them.
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
write_fixture(fullfile(fixture_dir,"fake_ao_state_loaded.json"), ...
    loaded_controller().getState());
end

function controller=empty_controller()
%EMPTY_CONTROLLER A controller as the operator first sees it: no FOV, no protocol.
controller=adaptive_optopatch.AdaptiveOptopatchController();
end

function controller=loaded_controller()
%LOADED_CONTROLLER A realistic mid-session controller, built the way the
%   controller tests build one: simulated Luminos backend, a reference FOV with
%   two somata, per-cell decisions, a real screen protocol, and a frozen run.
root=string(tempname);
mkdir(root);
cleanup=onCleanup(@()remove_if_present(root)); %#ok<NASGU>

controller=adaptive_optopatch.AdaptiveOptopatchController( ...
    "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
    "RunRoot",root);
controller.setReferenceData(ones(80,100),reference_info(root), ...
    {[25 25;40 25;40 40;25 40],[60 40;75 40;75 55;60 55]});
controller.setCellCalibration("cell_001",1.4,"development fixture");
controller.setCellEligibility("cell_002","StimulationEnabled",false);
controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",1,"ModulatorVoltage",1));
controller.setPlanParameter("mode","1p_dmd");
controller.freezeRun();
end

function info=reference_info(root)
camera=struct("ROI",[0 0 100 80],"bin",1, ...
    "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
info=struct("snapshot_name","dev_fixture_fov", ...
    "snapshot_directory",root, ...
    "snapshot_path",fullfile(root,"snapshot.mat"), ...
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

fid=fopen(target,"w");
if fid<0
    error("adaptive_optopatch:dev:FixtureNotWritable", ...
        "Could not write %s",target);
end
closer=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,"%s\n",jsonencode(state,"PrettyPrint",true));
fprintf("wrote %s\n",target);
end

function value=redact_temporary(value)
value=replace(string(value),string(tempdir),"<dev fixture>"+filesep);
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
