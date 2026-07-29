function app = launch_pair_review_gui(analysisPath, referencePath)
%LAUNCH_PAIR_REVIEW_GUI Review and accept ranked directed cell pairs.
arguments
    analysisPath (1,1) string = ""
    referencePath (1,1) string = ""
end
root=fileparts(mfilename("fullpath")); addpath(root);
if strlength(analysisPath)==0
    [file,path]=uigetfile("*.mat","Select connectivity analysis MAT file");
    if isequal(file,0), app=[]; return; end
    analysisPath=fullfile(path,file);
end
if strlength(referencePath)==0
    [file,path]=uigetfile("*.mat","Select reference_model.mat");
    if isequal(file,0), app=[]; return; end
    referencePath=fullfile(path,file);
end
a=load(analysisPath); r=load(referencePath);
analysis=find_struct(a,["analysis","connectivity_analysis"]);
reference=find_struct(r,"reference");
app=adaptive_optopatch.PairReviewApp(analysis,reference);
end

function value=find_struct(s,names)
for name=string(names)
    if isfield(s,name), value=s.(name); return; end
end
fields=fieldnames(s);
if isscalar(fields), value=s.(fields{1}); return; end
error("adaptive_optopatch:AmbiguousMatFile","Could not identify the required variable.");
end
