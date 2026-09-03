function provenance=software_provenance()
%SOFTWARE_PROVENANCE Record the repository revision used to build a plan.
packageDirectory=fileparts(mfilename("fullpath"));
repositoryDirectory=fileparts(packageDirectory);
provenance=struct("repository","adaptive-optopatch", ...
    "commit","unknown","working_tree_dirty",NaN, ...
    "captured_at",string(datetime("now","TimeZone","local")));
[status,commit]=system(sprintf('git -C "%s" rev-parse HEAD',repositoryDirectory));
if status==0, provenance.commit=strip(string(commit)); end
[status,changes]=system(sprintf('git -C "%s" status --porcelain',repositoryDirectory));
if status==0, provenance.working_tree_dirty=strlength(strip(string(changes)))>0; end
end
