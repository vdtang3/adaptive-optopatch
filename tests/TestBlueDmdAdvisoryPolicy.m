classdef TestBlueDmdAdvisoryPolicy < matlab.unittest.TestCase
    methods (Test)
        function edgeProximityIsAdvisory(testCase)
            [reference,targets,fovState]=blue_case(true,false);
            manifest=adaptive_optopatch.build_manifest(reference,targets, ...
                adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1),"Mode","1p_dmd", ...
                "FovState",fovState,"GuiDefaults",gui_defaults());
            testCase.verifyTrue(targets.targets(1).edge_flag);
            testCase.verifyTrue(has_code(manifest.advisories,"blue_mask_near_edge"));
            preflight=adaptive_optopatch.preflight_trial(targets,manifest.trials(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
            testCase.verifyTrue(any(contains(preflight.warnings,"near the camera ROI edge")));
        end

        function trueOnePhotonFailuresRemainHard(testCase)
            [reference,targets,fovState]=blue_case(false,false);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);

            disabledReference=reference;
            disabledReference.cells(1).stimulation_enabled=false;
            disabledTargets=adaptive_optopatch.build_target_bundle(disabledReference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",0);
            disabledFov=fovState; disabledFov.cells(1).stimulation_enabled=false;
            [manifest,~]=adaptive_optopatch.build_manifest( ...
                disabledReference,disabledTargets,protocol,"Mode","1p_dmd", ...
                "FovState",disabledFov,"GuiDefaults",gui_defaults());
            testCase.verifyFalse(any(manifest.trials.target_cell_id=="cell_001"));

            % A resolved event whose Blue-mask adjustment truly empties
            % the canonical ROI must fail explicitly at resolution time
            % rather than silently excluding the target from the
            % manifest, so acquisition count is never silently reduced.
            unusableFov=fovState; unusableFov.cells(2).stimulation_enabled=false;
            emptyingDefaults=gui_defaults();
            emptyingDefaults.blue_mask_adjustment_pixels=-5;
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,targets,protocol,"Mode","1p_dmd", ...
                "FovState",unusableFov,"GuiDefaults",emptyingDefaults), ...
                "adaptive_optopatch:EmptyBlueMaskAdjustment");

            testCase.verifyError(@()adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",5.1), ...
                "adaptive_optopatch:InvalidCommandVoltage");
        end

        function twoPhotonExecutionQcRemainsStrict(testCase)
            [reference,targets,fovState]=blue_case(true,true);
            fovState.cells(2).stimulation_enabled=false;
            testCase.verifyFalse(targets.targets(1).spiral_qc_pass);
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,targets,adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1),"Mode","2p_spiral", ...
                "FovState",fovState,"GuiDefaults",gui_defaults()), ...
                "adaptive_optopatch:NoAcceptedTargets");
        end
    end
end

function [reference,targets,fovState]=blue_case(nearEdge,~)
% Two non-overlapping canonical ROIs; overlap is no longer a spatial QC
% concept, so cases here vary only edge proximity.
image=zeros(40,50); masks=false(40,50,2);
if nearEdge, rows=1:6; else, rows=12:17; end
masks(rows,10:15,1)=true; masks(rows,35:40,2)=true;
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","blue_advisory_test");
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",0);
polygons=cell(numel(reference.cells),1);
for k=1:numel(reference.cells)
    boundaries=bwboundaries(reference.roi_masks(:,:,k));
    p=boundaries{1}; polygons{k}=[p(:,2) p(:,1)];
end
fovState=adaptive_optopatch.create_fov_state(reference,polygons, ...
    "StimulationMode","1p_dmd");
end

function value=gui_defaults()
value=struct("command_voltage_v",1,"pulse_duration_s",0.005, ...
    "blue_mask_adjustment_pixels",0,"orange_expansion_pixels",2, ...
    "spiral_radius_um",2,"spiral_density_points_per_volt",10);
end

function tf=has_code(advisories,code)
tf=~isempty(advisories) && any(string({advisories.code})==string(code));
end
