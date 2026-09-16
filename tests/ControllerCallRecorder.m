classdef ControllerCallRecorder < adaptive_optopatch.AdaptiveOptopatchController
    %CONTROLLERCALLRECORDER Records which controller operations were invoked.
    %   The point of the action endpoint is that it DELEGATES: every action
    %   maps to one controller operation and reproduces none of it. That is
    %   hard to assert on the result of an operation - a plan parameter looks
    %   the same whether the controller set it or the dispatcher did - so
    %   these tests assert on the call itself.
    %
    %   runNext, runAll and runPreparedPlan are recorded and NOT executed.
    %   Executing them would drive a runner, which is not what an endpoint test
    %   is about and is the one thing these tests must never do by accident.
    %   runPreparedPlan still applies its real gate first, because whether a
    %   plan may run at all is precisely what is under test.
    %   Every other override records and then calls the real implementation,
    %   so the state a test reads afterwards is genuinely the controller's.
    %
    %   A test double, not production code: nothing under +adaptive_optopatch
    %   knows it exists.

    properties
        %CALLS Operation names in the order they were invoked.
        Calls string = strings(0,1)
    end

    methods
        function recorder=ControllerCallRecorder(varargin)
            % Passes the real controller's options straight through, so a
            % test builds one exactly the way it builds a controller.
            recorder@adaptive_optopatch.AdaptiveOptopatchController(varargin{:});
        end

        function run=runNext(recorder)
            recorder.record("runNext");
            run=struct("stubbed",true);
        end

        function run=runAll(recorder)
            recorder.record("runAll");
            run=struct("stubbed",true);
        end

        function paths=updatePlan(recorder)
            % Recorded and then really performed: preparing a plan resolves
            % the protocol and writes a bundle, which is CPU and disk and
            % touches no hardware. A test that read the state afterwards
            % would learn nothing from a stub.
            recorder.record("updatePlan");
            paths=updatePlan@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder);
        end

        function run=runPreparedPlan(recorder)
            % The REAL gate, and then no acquisition. An endpoint test has
            % to find out that an absent or stale plan is refused - that is
            % most of what these tests are about - and must never drive a
            % runner. Recording AFTER the gate is what lets a test assert
            % that a refused run reached nothing.
            recorder.assertRunnable();
            recorder.record("runPreparedPlan");
            run=struct("stubbed",true);
        end

        function stopAfterCurrent(recorder)
            recorder.record("stopAfterCurrent");
            stopAfterCurrent@adaptive_optopatch.AdaptiveOptopatchController(recorder);
        end

        function fovState=setCellEligibility(recorder,cellId,options)
            arguments
                recorder
                cellId (1,1) string
                options.RecordingEnabled = []
                options.StimulationEnabled = []
            end
            recorder.record("setCellEligibility");
            fovState=setCellEligibility@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,cellId,"RecordingEnabled",options.RecordingEnabled, ...
                "StimulationEnabled",options.StimulationEnabled);
        end

        function cellId=addSomaPolygon(recorder,verticesXy)
            recorder.record("addSomaPolygon");
            cellId=addSomaPolygon@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,verticesXy);
        end

        function updateSomaPolygon(recorder,cellId,verticesXy)
            recorder.record("updateSomaPolygon");
            updateSomaPolygon@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,cellId,verticesXy);
        end

        function deleteCell(recorder,cellId)
            recorder.record("deleteCell");
            deleteCell@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,cellId);
        end

        function setPlanParameter(recorder,name,value)
            recorder.record("setPlanParameter");
            setPlanParameter@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,name,value);
        end

        function protocol=loadProtocolChoice(recorder,choiceId)
            recorder.record("loadProtocolChoice");
            protocol=loadProtocolChoice@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,choiceId);
        end

        function paths=freezeRun(recorder,outputRoot)
            arguments
                recorder
                outputRoot (1,1) string = ""
            end
            recorder.record("freezeRun");
            paths=freezeRun@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,outputRoot);
        end

        function paths=startNewRun(recorder,outputRoot)
            arguments
                recorder
                outputRoot (1,1) string = ""
            end
            recorder.record("startNewRun");
            paths=startNewRun@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,outputRoot);
        end

        function returnToEditing(recorder)
            recorder.record("returnToEditing");
            returnToEditing@adaptive_optopatch.AdaptiveOptopatchController(recorder);
        end

        function paths=startNewBatch(recorder,outputRoot,options)
            arguments
                recorder
                outputRoot (1,1) string = ""
                options.Automatic (1,1) logical = false
            end
            recorder.record("startNewBatch");
            paths=startNewBatch@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder,outputRoot,"Automatic",options.Automatic);
        end

        function display=referenceDisplayImage(recorder)
            recorder.record("referenceDisplayImage");
            display=referenceDisplayImage@adaptive_optopatch.AdaptiveOptopatchController( ...
                recorder);
        end
    end

    methods (Access=private)
        function record(recorder,name)
            recorder.Calls(end+1,1)=string(name);
        end
    end
end
