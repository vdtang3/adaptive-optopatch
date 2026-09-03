function paths = save_bundle(outputDirectory, reference, targets, manifest, options)
%SAVE_BUNDLE Save versioned planning artifacts.
arguments
    outputDirectory (1,1) string
    reference (1,1) struct
    targets (1,1) struct
    manifest (1,1) struct
    options.CreateSubfolder (1,1) logical = false
    options.SubfolderPrefix (1,1) string = "adaptive_optopatch"
    options.SessionState = []
    options.FovState = []
end

if options.CreateSubfolder
    fovId = "fov";
    if isfield(reference,"fov_id") && strlength(string(reference.fov_id)) > 0
        fovId = string(reference.fov_id);
    end
    safeFovId = string(matlab.lang.makeValidName(char(fovId)));
    timestamp = string(datetime("now","Format","yyyyMMdd_HHmmss"));
    baseName = options.SubfolderPrefix + "_" + safeFovId + "_" + timestamp;
    candidate = fullfile(outputDirectory,baseName);
    suffix = 1;
    while isfolder(candidate)
        candidate = fullfile(outputDirectory,baseName + compose("_%02d",suffix));
        suffix = suffix + 1;
    end
    outputDirectory = candidate;
end

if ~isfolder(outputDirectory), mkdir(outputDirectory); end
paths = struct( ...
    "output_directory", outputDirectory, ...
    "reference", fullfile(outputDirectory,"reference_model.mat"), ...
    "targets", fullfile(outputDirectory,"pattern_bundle.mat"), ...
    "manifest", fullfile(outputDirectory,"trial_manifest.mat"), ...
    "session", fullfile(outputDirectory,"planning_session.mat"), ...
    "fov_state",fullfile(outputDirectory,"fov_state.mat"));
save(paths.reference,"reference","-v7.3");
save(paths.targets,"targets","-v7.3");
save(paths.manifest,"manifest");
if ~isempty(options.SessionState)
    planning_session=options.SessionState;
    save(paths.session,"planning_session","-v7.3");
else
    paths.session="";
end
if ~isempty(options.FovState)
    fov_state=options.FovState;
    save(paths.fov_state,"fov_state","-v7.3");
else
    paths.fov_state="";
end
end
