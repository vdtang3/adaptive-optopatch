function results = run_tests()
root = fileparts(mfilename("fullpath"));
addpath(root);
suite = testsuite(fullfile(root,"tests"));
results = run(suite);
assertSuccess(results);
end

