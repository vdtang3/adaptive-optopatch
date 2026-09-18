classdef TestEventWaveformPerformance < matlab.unittest.TestCase
    methods (Test)
        function optimizedWaveformIsSampleExactAcrossBoundaryCases(testCase)
            t=[0 0.1 0.2 0.3 0.4 0.5 0.6];
            cases={ ...
                [0.1 0.3],[0.2 0.5],[1 2],0; ...
                [0.1000000001 0.299],[0.4 0.6001],[3 4],-0.7; ...
                [0.2 0.25],[0.5 0.3],[1.5 9],2; ...
                [0.11 0.12],[0.19 0.12001],[5 6],0; ...
                [0.1 0.2],[0.5 0.4],[1 7],-2};
            for k=1:size(cases,1)
                onset=cases{k,1}; offset=cases{k,2};
                amplitude=cases{k,3}; baseline=cases{k,4};
                expected=reference_waveform(t,onset,offset,amplitude,baseline);
                actual=adaptive_optopatch.luminos_event_waveform( ...
                    t,onset,offset,amplitude,baseline);
                testCase.verifyEqual(actual,expected);
            end
        end

        function thousandsOfEventsProduceTheExpectedSparseTrain(testCase)
            rate=20000;
            eventCount=3500;
            onset=0.1+(0:eventCount-1)'*0.02;
            offset=onset+0.010;
            amplitude=0.5+mod((1:eventCount)',7)/10;
            t=(0:round((offset(end)+0.1)*rate)-1)/rate;
            y=adaptive_optopatch.luminos_event_waveform( ...
                t,onset,offset,amplitude,-0.25);
            testCase.verifyEqual(y(end),-0.25);
            for k=[1 2 173 1749 3500]
                active=t>=onset(k) & t<offset(k);
                testCase.verifyEqual(y(active),amplitude(k)*ones(1,sum(active)));
            end
        end

        function nonmonotonicCompatibilityPathRetainsReferenceSemantics(testCase)
            t=[0.2 0 0.3 0.1];
            onset=[0.05 0.2]; offset=[0.25 0.31]; amplitude=[1 2];
            testCase.verifyEqual( ...
                adaptive_optopatch.luminos_event_waveform(t,onset,offset,amplitude,3), ...
                reference_waveform(t,onset,offset,amplitude,3));
        end
    end
end

function y=reference_waveform(t,onset,offset,amplitude,baseline)
y=baseline*ones(size(t));
for k=1:numel(onset)
    y(t>=onset(k) & t<offset(k))=amplitude(k);
end
if ~isempty(y), y(end)=baseline; end
end
