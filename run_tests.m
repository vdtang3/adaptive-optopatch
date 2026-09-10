function results = run_tests()
root = fileparts(mfilename("fullpath"));
simulationTools=fullfile(root,"tools","simulation");
originalPath=path;
cleanup=onCleanup(@()path(originalPath)); %#ok<NASGU>
addpath(root,simulationTools);
suite = testsuite(fullfile(root,"tests"));
results = run(suite);
assertSuccess(results);
end
