function report = verify_vu_setup(luminosApp,bundleFolder)
%VERIFY_VU_SETUP Run read-only Windows/R2023b and Luminos compatibility checks.
arguments
    luminosApp = []
    bundleFolder (1,1) string = ""
end
root=fileparts(mfilename("fullpath")); addpath(root);
report=adaptive_optopatch.verify_vu_environment(luminosApp,bundleFolder);
end
