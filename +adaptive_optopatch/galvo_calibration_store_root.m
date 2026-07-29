function root=galvo_calibration_store_root(options)
%GALVO_CALIBRATION_STORE_ROOT Resolve local or administrator-selected store.
arguments
    options.Root (1,1) string = ""
end
root=options.Root;
if strlength(root)==0
    configured=string(getenv("ADAPTIVE_OPTOPATCH_CONFIG_ROOT"));
    if strlength(configured)>0
        root=fullfile(configured,"Virtual_Upright");
    else
        root=fullfile(string(prefdir),"AdaptiveOptopatch","Virtual_Upright");
    end
end
end
