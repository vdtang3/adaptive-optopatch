classdef TestBlueDmdAdvisoryPolicy < matlab.unittest.TestCase
    methods (Test)
        function overlapIsAdvisoryAndRunProvenance(testCase)
            [reference,targets]=blue_case(true,false);
            protocol=resolved_protocol("cell_001",1);
            manifest=adaptive_optopatch.build_manifest(reference,targets,protocol, ...
                "Mode","1p_dmd");
            testCase.verifyFalse(targets.targets(1).blue_qc_pass);
            testCase.verifyGreaterThan(targets.targets(1).dmd_overlap_pixels,0);
            testCase.verifyTrue(has_code(manifest.advisories,"blue_mask_overlap"));
            preflight=adaptive_optopatch.preflight_trial(targets,manifest.trials(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
            testCase.verifyTrue(any(contains(preflight.warnings,"overlaps another canonical ROI")));

            outputRoot=tempname;
            cleanup=onCleanup(@()remove_if_present(outputRoot)); %#ok<NASGU>
            simulator=adaptive_optopatch.testing.make_simulated_luminos( ...
                "SimulationOutputRoot",outputRoot);
            run=adaptive_optopatch.run_1p_manifest(manifest,targets,simulator, ...
                "ConfirmLiveOutput",true,"ShutterSettleTimeS",0);
            testCase.verifyEqual(run.trials.acquisition_status,"completed");
            saved=load(fullfile(run.trials.experiment_directory,"output_data.mat"), ...
                "adaptive_optopatch_record");
            testCase.verifyTrue(has_code( ...
                saved.adaptive_optopatch_record.advisories,"blue_mask_overlap"));
        end

        function edgeProximityIsAdvisory(testCase)
            [reference,targets]=blue_case(false,true);
            manifest=adaptive_optopatch.build_manifest(reference,targets, ...
                resolved_protocol("cell_001",1),"Mode","1p_dmd");
            testCase.verifyTrue(targets.targets(1).edge_flag);
            testCase.verifyFalse(targets.targets(1).blue_qc_pass);
            testCase.verifyTrue(has_code(manifest.advisories,"blue_mask_near_edge"));
            preflight=adaptive_optopatch.preflight_trial(targets,manifest.trials(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
            testCase.verifyTrue(any(contains(preflight.warnings,"near the camera ROI edge")));
        end

        function overlapAndEdgeRemainRunnable(testCase)
            [reference,targets]=blue_case(true,true);
            manifest=adaptive_optopatch.build_manifest(reference,targets, ...
                resolved_protocol("cell_001",1),"Mode","1p_dmd");
            codes=string({manifest.advisories.code});
            testCase.verifyTrue(all(ismember( ...
                ["blue_mask_overlap","blue_mask_near_edge"],codes)));
            preflight=adaptive_optopatch.preflight_trial(targets,manifest.trials(1,:), ...
                "RequireConfirmedLiveProtocol",false);
            testCase.verifyTrue(preflight.passed);
        end

        function unresolvedProtocolIncludesWarningTargets(testCase)
            [reference,targets]=blue_case(true,false);
            protocol=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            manifest=adaptive_optopatch.build_manifest(reference,targets,protocol, ...
                "Mode","1p_dmd","RandomSeed",4);
            assigned=string(cellfun(@(p)p.events.target_cell_id(1), ...
                manifest.trials.pulse_schedule));
            testCase.verifyTrue(any(assigned=="cell_001"));
            testCase.verifyTrue(has_code(manifest.advisories,"blue_mask_overlap"));
        end

        function trueOnePhotonFailuresRemainHard(testCase)
            [reference,targets]=blue_case(true,false);
            protocol=resolved_protocol("cell_001",1);

            disabledReference=reference;
            disabledReference.cells(1).stimulation_enabled=false;
            disabledTargets=adaptive_optopatch.build_target_bundle(disabledReference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
                "BlueMaskAdjustmentPixels",4);
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                disabledReference,disabledTargets,protocol,"Mode","1p_dmd"), ...
                "adaptive_optopatch:StimulationDisabledCell");

            unusable=targets; unusable.dmd_camera_masks(:,:,1)=false;
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,unusable,protocol,"Mode","1p_dmd"), ...
                "adaptive_optopatch:UnusableBlueTarget");

            unsafe=protocol; unsafe.events.command_voltage_v(:)=5.1;
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,targets,unsafe,"Mode","1p_dmd"), ...
                "adaptive_optopatch:ModulatorVoltageOutOfRange");

            unknown=protocol; unknown.events.target_cell_id(:)="cell_999";
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,targets,unknown,"Mode","1p_dmd"), ...
                "adaptive_optopatch:UnknownTargetCell");
        end

        function twoPhotonExecutionQcRemainsStrict(testCase)
            [reference,targets]=blue_case(false,true);
            testCase.verifyFalse(targets.targets(1).spiral_qc_pass);
            testCase.verifyError(@()adaptive_optopatch.build_manifest( ...
                reference,targets,resolved_protocol("cell_001",1), ...
                "Mode","2p_spiral"),"adaptive_optopatch:TargetQcFailed");
        end
    end
end

function [reference,targets]=blue_case(overlap,nearEdge)
image=zeros(40,50); masks=false(40,50,2);
if nearEdge, rows=1:6; else, rows=12:17; end
masks(rows,10:15,1)=true;
if overlap, columns=19:24; adjustment=4; else, columns=35:40; adjustment=0; end
masks(rows,columns,2)=true;
metadata=struct("rig_name","Virtual_Upright", ...
    "voltage_camera",struct("name","Orca Fusion","bin",1));
reference=adaptive_optopatch.create_reference_model(image,masks,metadata, ...
    "FovId","blue_advisory_test");
targets=adaptive_optopatch.build_target_bundle(reference, ...
    "SpiralRadiusUm",2,"ParkingClearancePixels",1, ...
    "BlueMaskAdjustmentPixels",adjustment);
end

function protocol=resolved_protocol(cellId,voltage)
protocol=adaptive_optopatch.generate_screen_protocol( ...
    "PulseCount",1,"ModulatorVoltage",voltage);
protocol.events.target_cell_id(:)=cellId;
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function tf=has_code(advisories,code)
tf=~isempty(advisories) && any(string({advisories.code})==string(code));
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
