function bundle = find_latest_planning_bundle(searchFolder, options)
%FIND_LATEST_PLANNING_BUNDLE Find the newest compatible saved plan.
arguments
    searchFolder (1,1) string
    options.ExperimentDirectory (1,1) string = ""
    options.SourceSnapshot (1,1) string = ""
end
bundle=struct([]);
if ~isfolder(searchFolder), return; end
sessionFiles=dir(fullfile(searchFolder,"**","planning_session.mat"));
sessionFiles=sessionFiles(~[sessionFiles.isdir]);
if isempty(sessionFiles), return; end
folders=unique(string({sessionFiles.folder}));
records=struct([]);
for k=1:numel(folders)
    folder=folders(k);
    referencePath=fullfile(folder,"reference_model.mat");
    sessionPath=fullfile(folder,"planning_session.mat");
    if ~isfile(referencePath) || ~isfile(sessionPath), continue; end
    compatible=true;
    sourceExperiment="";
    sourceSnapshot="";
    try
        loaded=load(referencePath,"reference");
        if isfield(loaded,"reference") && isfield(loaded.reference,"source_experiment")
            sourceExperiment=string(loaded.reference.source_experiment);
        end
        if isfield(loaded,"reference") && isfield(loaded.reference,"source_snapshot")
            sourceSnapshot=string(loaded.reference.source_snapshot);
        end
        if strlength(options.SourceSnapshot)>0
            compatible=strlength(sourceSnapshot)>0 && ...
                normalize_path(sourceSnapshot)==normalize_path(options.SourceSnapshot);
        end
        if strlength(options.ExperimentDirectory)>0 && strlength(sourceExperiment)>0
            compatible=compatible && normalize_path(sourceExperiment)== ...
                normalize_path(options.ExperimentDirectory);
        end
    catch
        compatible=false;
    end
    if ~compatible, continue; end
    listing=dir(referencePath);
    sessionListing=dir(sessionPath);
    modified=max(listing.datenum,sessionListing.datenum);
    record=struct("folder",folder,"reference_path",string(referencePath), ...
        "session_path",string(sessionPath),"modified_datenum",modified, ...
        "source_experiment",sourceExperiment,"source_snapshot",sourceSnapshot);
    if isempty(records), records=record; else, records(end+1)=record; end %#ok<AGROW>
end
if isempty(records), return; end
[~,idx]=max([records.modified_datenum]);
bundle=records(idx);
end

function value=normalize_path(value)
value=replace(string(value),"\","/");
value=strip(value,"right","/");
end
