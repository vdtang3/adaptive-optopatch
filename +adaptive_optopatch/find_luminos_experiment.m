function experiment = find_luminos_experiment(selectedFolder)
%FIND_LUMINOS_EXPERIMENT Locate output_data.mat below a selected folder.
arguments
    selectedFolder (1,1) string
end
if ~isfolder(selectedFolder)
    error("adaptive_optopatch:MissingExperimentFolder", ...
        "Folder not found: %s",selectedFolder);
end
direct=fullfile(selectedFolder,"output_data.mat");
if isfile(direct)
    outputDataPath=direct;
else
    matches=dir(fullfile(selectedFolder,"**","output_data.mat"));
    matches=matches(~[matches.isdir]);
    if isempty(matches)
        error("adaptive_optopatch:OutputDataNotFound", ...
            "No output_data.mat was found under %s.",selectedFolder);
    end
    depths=zeros(numel(matches),1);
    for k=1:numel(matches)
        relative=erase(string(matches(k).folder),selectedFolder);
        depths(k)=count(relative,filesep);
    end
    minimumDepth=min(depths);
    candidates=find(depths==minimumDepth);
    if numel(candidates)>1
        [~,newest]=max([matches(candidates).datenum]);
        selected=candidates(newest);
    else
        selected=candidates;
    end
    outputDataPath=fullfile(matches(selected).folder,matches(selected).name);
end
experiment=struct("selected_folder",selectedFolder, ...
    "experiment_directory",string(fileparts(outputDataPath)), ...
    "output_data_path",string(outputDataPath));
end
