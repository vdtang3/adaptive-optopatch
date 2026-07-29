function report = verify_vu_environment(luminosApp,bundleFolder)
%VERIFY_VU_ENVIRONMENT Read-only compatibility and live API checks.
arguments
    luminosApp = []
    bundleFolder (1,1) string = ""
end
check=strings(0,1); status=strings(0,1); detail=strings(0,1);
add("MATLAB release",release_status(),"Detected "+string(version("-release")));
if ispc
    add("Operating system","PASS","Windows detected: "+string(system_dependent("getos")));
else
    add("Operating system","WARN","This diagnostic is not running on Windows.");
end

if isempty(ver("images"))
    add("Image Processing Toolbox","FAIL", ...
        "Required for ROI masks, morphology, and DMD-boundary operations.");
else
    imageVersion=ver("images");
    add("Image Processing Toolbox","PASS",string(imageVersion(1).Version));
end

installedProducts=ver;
installed=string({installedProducts.Name});
luminosToolboxes=["Instrument Control Toolbox", ...
    "Optimization Toolbox", ...
    "Image Processing Toolbox", ...
    "Statistics and Machine Learning Toolbox", ...
    "Data Acquisition Toolbox", ...
    "Computer Vision Toolbox"];
missingToolboxes=luminosToolboxes(~ismember(luminosToolboxes,installed));
if isempty(missingToolboxes)
    add("Luminos toolboxes","PASS","All toolboxes listed by Luminos are installed.");
else
    add("Luminos toolboxes","FAIL","Missing: "+strjoin(missingToolboxes,", "));
end

packageFunctions=["adaptive_optopatch.ReferencePreparationApp", ...
    "adaptive_optopatch.read_reference_snapshot", ...
    "adaptive_optopatch.OnePhotonRunnerApp", ...
    "adaptive_optopatch.GalvoCalibrationApp", ...
    "adaptive_optopatch.TwoPhotonTestRunnerApp", ...
    "adaptive_optopatch.run_1p_manifest", ...
    "adaptive_optopatch.run_2p_manifest", ...
    "adaptive_optopatch.luminos_event_waveform"];
missingPackage=packageFunctions(arrayfun(@(name)isempty(which(name)),packageFunctions));
if isempty(missingPackage)
    add("Adaptive Optopatch path","PASS", ...
        "Package classes and runner functions are visible to MATLAB.");
else
    add("Adaptive Optopatch path","FAIL", ...
        "Missing: "+strjoin(missingPackage,", "));
end

imageFunctions=["drawpolygon","poly2mask","bwboundaries", ...
    "imerode","imdilate","strel"];
missingImage=imageFunctions(arrayfun(@(name)exist(name,"file")==0,imageFunctions));
if isempty(missingImage)
    add("Image APIs","PASS","All required R2023b-compatible image APIs found.");
else
    add("Image APIs","FAIL","Missing: "+strjoin(missingImage,", "));
end

luminosFunctions=["Waveform_Camera_Sync_Acquisition","Rig_Control_App"];
missingLuminos=luminosFunctions(arrayfun(@(name)exist(name,"file")==0,luminosFunctions));
if isempty(missingLuminos)
    add("Luminos path","PASS","Camera-synchronized acquisition APIs found.");
else
    add("Luminos path","FAIL","Missing: "+strjoin(missingLuminos,", "));
end

if isempty(luminosApp)
    add("Live Luminos app","WARN", ...
        "No app supplied; live device and active-protocol checks were skipped.");
else
    if ismethod(luminosApp,"getDevice") && ismethod(luminosApp,"buildAppArchive")
        add("Luminos app API","PASS","getDevice and buildAppArchive are available.");
    else
        add("Luminos app API","FAIL","The supplied object lacks required Luminos methods.");
    end
    try
        hardware=adaptive_optopatch.resolve_luminos_1p_hardware(luminosApp);
        add("Live 1P hardware","PASS",sprintf( ...
            "DMD_Blue, 488, mod488, shutter488, and Camera 1 found; OBIS %s at %.3g mW.", ...
            hardware.laser_mode,1000*hardware.laser_power_w));
        add("Active timing","PASS",sprintf( ...
            "Master %s via %s at %.0f Hz; bridge [%s], triggers [%s].", ...
            hardware.daq_sync.selected_master_device, ...
            hardware.daq_sync.selected_clock_source, ...
            hardware.daq_sync.sample_rate_hz, ...
            strjoin(hardware.daq_sync.clock_bridge,", "), ...
            strjoin(hardware.daq_sync.default_trigger,", ")));
    catch exception
        add("Live 1P hardware","WARN", ...
            "Optional for the 2P workflow: "+string(exception.message));
    end
    try
        profile=adaptive_optopatch.virtual_upright_2p_profile();
        daq=luminosApp.getDevice("DAQ");
        scanner=luminosApp.getDevice("Scanning_Device","name",profile.scanner.name);
        modulator=luminosApp.getDevice("NI_DAQ_Modulator","name",profile.modulator.name);
        cameras=luminosApp.getDevice("Camera");
        serials=arrayfun(@(camera)strip(erase(string(camera.cam_id),"S/N: ")),cameras);
        if numel(daq)~=1 || numel(scanner)~=1 || numel(modulator)~=1 || ...
                ~any(serials=="001125")
            error("adaptive_optopatch:TwoPhotonHardwareMissing", ...
                "Combined DAQ, Chameleon scanner, 2P mod, or Camera 1 is missing.");
        end
        if string(scanner.galvox_physport)~=profile.scanner.x_port || ...
                string(scanner.galvoy_physport)~=profile.scanner.y_port || ...
                string(modulator.port)~=profile.modulator.port
            error("adaptive_optopatch:UnexpectedTwoPhotonPorts", ...
                "Expected Dev2/ao0, Dev2/ao1, and Dev1/ao3.");
        end
        sync=adaptive_optopatch.capture_luminos_daq_sync(daq);
        if ~sync.daq_master || ...
                ~ismember(sync.selected_master_device,["Dev1","Dev2"])
            error("adaptive_optopatch:MultiDaqSyncNotReady", ...
                "Select Internal Dev1 or Internal Dev2 and self-trigger.");
        end
        add("Live 2P hardware","PASS",sprintf( ...
            "Camera 1, Chameleon X/Y, and 2P mod found; master %s at %.0f Hz.", ...
            sync.selected_master_device,sync.sample_rate_hz));
    catch exception
        add("Live 2P hardware","FAIL",string(exception.message));
    end
    try
        [artifact,active]=adaptive_optopatch.get_active_galvo_calibration();
        if ~active.found
            add("Active galvo calibration","WARN", ...
                "No active calibration yet; expected before the calibration workflow.");
        else
            validation=adaptive_optopatch.validate_galvo_calibration_artifact( ...
                artifact,luminosApp);
            if validation.passed
                add("Active galvo calibration","PASS", ...
                    "Validated calibration "+artifact.calibration_id+".");
            else
                add("Active galvo calibration","FAIL",strjoin(validation.issues," "));
            end
        end
    catch exception
        add("Active galvo calibration","FAIL",string(exception.message));
    end
end

if strlength(bundleFolder)==0
    add("Planning bundle","WARN","No bundle folder supplied; bundle checks were skipped.");
else
    targetPath=fullfile(bundleFolder,"pattern_bundle.mat");
    manifestPath=fullfile(bundleFolder,"trial_manifest.mat");
    if isfile(targetPath) && isfile(manifestPath)
        try
            saved=load(manifestPath,"manifest");
            if isfield(saved,"manifest") && ...
                    all(ismember(string(saved.manifest.trials.stimulation_mode), ...
                    ["1p_dmd","2p_spiral"]))
                modes=unique(string(saved.manifest.trials.stimulation_mode));
                add("Planning bundle","PASS", ...
                    "A "+strjoin(modes,", ")+" manifest and target bundle were found.");
            else
                add("Planning bundle","FAIL", ...
                    "The manifest is missing or has an unsupported stimulation mode.");
            end
        catch exception
            add("Planning bundle","FAIL",string(exception.message));
        end
        folderFile=java.io.File(char(bundleFolder));
        if folderFile.canWrite()
            add("Bundle checkpoint access","PASS", ...
                "MATLAB reports write access for run_checkpoint.mat.");
        else
            add("Bundle checkpoint access","FAIL", ...
                "The runner needs write access to the planning-bundle folder.");
        end
    else
        add("Planning bundle","FAIL", ...
            "pattern_bundle.mat or trial_manifest.mat is missing.");
    end
end

report=table(check,status,detail);
disp(report);

    function add(name,state,message)
        check(end+1,1)=string(name);
        status(end+1,1)=string(state);
        detail(end+1,1)=string(message);
    end
end

function state=release_status()
release=string(version("-release"));
if release=="2023b"
    state="PASS";
else
    state="WARN";
end
end
