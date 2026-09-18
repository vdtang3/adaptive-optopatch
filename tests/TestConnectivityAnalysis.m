classdef TestConnectivityAnalysis < matlab.unittest.TestCase
    %TESTCONNECTIVITYANALYSIS Calling an edge, and screening the cells it names.
    %   infer_connectivity decides whether stimulating one cell moved another,
    %   and rank_connectivity_candidates turns those calls into the ordered
    %   candidate list an STF screen is built from. Both are analysis: they
    %   read traces and produce hypotheses, and nothing here reaches hardware.

    methods (Test)
        function infersDirectedEdge(testCase)
            t = (0:0.01:12)';
            traces = 0.05*randn(numel(t),2);
            stimTimes = (1:2:11)';
            targetIndex = [1;1;1;0;0;0];
            isNull = targetIndex==0;
            for i = 1:3
                win = t >= stimTimes(i)+0.05 & t <= stimTimes(i)+0.2;
                traces(win,1) = traces(win,1)+1.5;
                traces(win,2) = traces(win,2)+0.8;
            end
            epochs = table(targetIndex,isNull,stimTimes, ...
                'VariableNames',{'target_index','is_null','stim_time'});
            out = adaptive_optopatch.infer_connectivity(traces,t,epochs, ...
                "ResponseWindow",[0.05 0.2],"BaselineWindow",[-0.4 -0.05], ...
                "EdgeThresholdZ",1,"MinimumTargetResponseZ",1);
            testCase.verifyTrue(out.candidate_edge(1,2));
            testCase.verifyFalse(out.candidate_edge(1,1));
        end

        function ranksAndBuildsStfManifest(testCase)
            reference=struct;
            reference.cells=struct("cell_id",{"cell_001","cell_002","cell_003"});
            connectivity=struct("zscore",[NaN 5 1;2 NaN 4;1 1 NaN], ...
                "effect",[NaN 2 0;1 NaN 2;0 0 NaN], ...
                "consistency",[NaN .9 .2;.3 NaN .8;.2 .2 NaN], ...
                "target_activation_z",[6;5;4], ...
                "candidate_edge",logical([0 1 0;0 0 1;0 0 0]));
            ranking=adaptive_optopatch.rank_connectivity_candidates(connectivity,reference);
            ranking.accepted(1:2)=true;
            [fov,~]=AoFixtures.fovState();
            targets=adaptive_optopatch.build_target_bundle(fov.reference, ...
                "SpiralRadiusUm",2,"ParkingClearancePixels",1);
            definition=adaptive_optopatch.generate_stf_protocol( ...
                adaptive_optopatch.default_stf_conditions( ...
                "RepeatsPerCondition",2,"CommandVoltageV",1));
            manifest=adaptive_optopatch.build_manifest(fov.reference,targets, ...
                definition,"Mode","2p_spiral","FovState",fov, ...
                "GuiDefaults",AoFixtures.guiDefaults());
            testCase.verifyGreaterThanOrEqual(height(manifest.trials),1);
            testCase.verifyEqual(manifest.source_protocol_id,definition.protocol_id);
        end
    end
end
