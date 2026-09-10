function results = run_tests()
root = fileparts(mfilename("fullpath"));
testHelpers=fullfile(root,"tests");
originalPath=path;
cleanup=onCleanup(@()path(originalPath)); %#ok<NASGU>
addpath(root,testHelpers);
suite = testsuite(fullfile(root,"tests"));
results = run(suite);
assertSuccess(results);
end
