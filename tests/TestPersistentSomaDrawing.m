classdef TestPersistentSomaDrawing < matlab.unittest.TestCase
    methods (Test)
        function oneActivationCommitsMultiplePolygonsUntilEmpty(testCase)
            first=[1 1;5 1;5 5;1 5];
            second=[10 10;14 10;14 14;10 14];
            pending={first,second,zeros(0,2)};
            committed={};

            count=adaptive_optopatch.draw_soma_rois_until_empty( ...
                @draw_next,@commit);

            testCase.verifyEqual(count,2);
            testCase.verifyEqual(committed,{first,second});

            function position=draw_next()
                position=pending{1};
                pending(1)=[];
            end
            function commit(position)
                committed{end+1}=position;
            end
        end

        function emptyFirstPolygonExitsWithoutCommit(testCase)
            commits=0;
            count=adaptive_optopatch.draw_soma_rois_until_empty( ...
                @()zeros(0,2),@commit);

            testCase.verifyEqual(count,0);
            testCase.verifyEqual(commits,0);

            function commit(~)
                commits=commits+1;
            end
        end

        function degeneratePolygonExitsWithoutCommit(testCase)
            commits=0;
            position=[1 1;2 2;3 3];
            count=adaptive_optopatch.draw_soma_rois_until_empty( ...
                @()position,@commit);

            testCase.verifyEqual(count,0);
            testCase.verifyEqual(commits,0);

            function commit(~)
                commits=commits+1;
            end
        end

        function committedIdsIncrementAndSurviveCancellation(testCase)
            pending={[1 1;5 1;5 5],[10 10;14 10;14 14],zeros(0,2)};
            ids="cell_004";
            next_index=5;

            adaptive_optopatch.draw_soma_rois_until_empty(@draw_next,@commit);

            testCase.verifyEqual(ids,["cell_004";"cell_005";"cell_006"]);
            testCase.verifyEqual(next_index,7);

            function position=draw_next()
                position=pending{1};
                pending(1)=[];
            end
            function commit(~)
                ids(end+1,1)=compose("cell_%03d",next_index);
                next_index=next_index+1;
            end
        end

        function externalStopPreservesCommittedPolygons(testCase)
            pending={[1 1;5 1;5 5],[10 10;14 10;14 14]};
            committed={};
            keep_drawing=true;

            count=adaptive_optopatch.draw_soma_rois_until_empty( ...
                @draw_next,@commit,@should_continue);

            testCase.verifyEqual(count,1);
            testCase.verifyNumElements(committed,1);

            function position=draw_next()
                position=pending{1};
                pending(1)=[];
            end
            function commit(position)
                committed{end+1}=position;
                keep_drawing=false;
            end
            function value=should_continue()
                value=keep_drawing;
            end
        end
    end
end
