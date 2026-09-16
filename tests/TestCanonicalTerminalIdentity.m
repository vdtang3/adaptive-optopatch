classdef TestCanonicalTerminalIdentity < matlab.unittest.TestCase
    %TESTCANONICALTERMINALIDENTITY One rule for what "the same terminal" means.
    %   The hazard these cover is not that AO builds a wrong waveform. It is
    %   that AO builds a right one and leaves a stale record beside it that
    %   Luminos then resolves onto the same wire.

    methods (Test)
        function aliasSlashAndCaseNameOneTerminal(testCase)
            groups={ ...
                ["DMD Trigger","Dev1/port0/line4","/DEV1/PORT0/LINE4", ...
                 "  dmd trigger  "], ...
                ["Dev2/ao0","/Dev2/AO0","dev2/ao0","/dev2/AO0"], ...
                ["mod488","Dev1/ao2","/Dev1/AO2"], ...
                ["2P mod","Dev1/ao3","/DEV1/ao3"], ...
                ["shutter488","Dev1/port0/line0"]};
            for k=1:numel(groups)
                canonical=adaptive_optopatch.canonical_terminal(groups{k});
                testCase.verifyNumElements(unique(canonical),1, ...
                    sprintf("Spellings %s should name one terminal.", ...
                    strjoin(groups{k},", ")));
            end
        end

        function distinctTerminalsStayDistinct(testCase)
            % The rule has to separate as well as join. Dropping every slash
            % is what makes "Dev1/ao2" and "Dev1/ao3" close together, so the
            % cheap check that they are still different is worth having.
            terminals=["Dev1/ao2","Dev1/ao3","Dev2/ao0","Dev2/ao1", ...
                "Dev1/port0/line0","Dev1/port0/line4","Dev1/port0/line5"];
            canonical=adaptive_optopatch.canonical_terminal(terminals);
            testCase.verifyNumElements(unique(canonical),numel(terminals));
        end

        function agreesWithLuminosSameTerminal(testCase)
            % The rule is DAQ.Same_Terminal's. Assert that against the
            % simulated DAQ, which now carries the rig's alias list and
            % implements Same_Terminal the way the real one does.
            app=adaptive_optopatch.testing.make_simulated_luminos();
            daq=app.getDevice("DAQ");
            pairs={"DMD Trigger","Dev1/port0/line4";
                   "/Dev2/AO0","Dev2/ao0";
                   "mod488","Dev1/ao2";
                   "2P mod","/DEV1/AO3"};
            for k=1:size(pairs,1)
                testCase.verifyTrue(daq.Same_Terminal(pairs{k,1},pairs{k,2}));
                testCase.verifyEqual( ...
                    adaptive_optopatch.canonical_terminal(pairs{k,1}), ...
                    adaptive_optopatch.canonical_terminal(pairs{k,2}));
            end
            testCase.verifyFalse(daq.Same_Terminal("Dev1/ao2","Dev1/ao3"));
        end

        function removalMatchesEveryEquivalentSpelling(testCase)
            records=[constant("stale a","DMD Trigger",1), ...
                constant("stale b","/DEV1/PORT0/LINE4",1), ...
                constant("keep","Dev1/port0/line6",1)];
            kept=adaptive_optopatch.remove_output_records(records, ...
                "Dev1/port0/line4");
            testCase.verifyNumElements(kept,1);
            testCase.verifyEqual(string(kept.name),"keep");
        end

        function removalMatchesARecordNamedForTheTerminal(testCase)
            % Luminos resolves by port, so a record whose PORT is somebody's
            % label and whose NAME is the terminal still reaches the line.
            records=[constant("Dev1/ao2","some label",1), ...
                constant("keep","Dev1/ao7",1)];
            kept=adaptive_optopatch.remove_output_records(records,"mod488");
            testCase.verifyNumElements(kept,1);
            testCase.verifyEqual(string(kept.name),"keep");
        end

        function manifestDeclaresEveryAoOwnedStimulationTerminal(testCase)
            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            roles=string({manifest.outputs.role});
            testCase.verifyEqual(sort(roles),sort([ ...
                "blue_modulator","blue_shutter","blue_dmd_advance_trigger", ...
                "two_photon_modulator","galvo_x","galvo_y"]));
            % Neutral values are rig declarations, so every one has to say
            % where it came from. "Probably zero" is the thing this forbids.
            for k=1:numel(manifest.outputs)
                testCase.verifyGreaterThan( ...
                    strlength(manifest.outputs(k).neutral_source),0);
                testCase.verifyTrue( ...
                    isscalar(manifest.outputs(k).neutral_value));
            end
        end

        function manifestNeutralsTrackTheRigProfiles(testCase)
            % The manifest consolidates the profiles rather than restating
            % them: if a profile's declared safe value changes, this moves
            % with it or the consolidation was a copy after all.
            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            oneP=adaptive_optopatch.virtual_upright_1p_profile();
            twoP=adaptive_optopatch.virtual_upright_2p_profile();
            testCase.verifyEqual(neutral(manifest,"blue_modulator"), ...
                double(oneP.modulator.dark_v));
            testCase.verifyEqual(neutral(manifest,"two_photon_modulator"), ...
                double(twoP.modulator.dark_v));
            testCase.verifyEqual(neutral(manifest,"galvo_x"), ...
                double(oneP.inactive_two_photon.scanner.stationary_v(1)));
            testCase.verifyEqual(neutral(manifest,"galvo_y"), ...
                double(oneP.inactive_two_photon.scanner.stationary_v(2)));
            testCase.verifyEqual(neutral(manifest,"blue_shutter"), ...
                double(oneP.shutter.closed_state));
        end

        function ambiguousRigOutputsAreDeclaredUnresolvedNotGuessed(testCase)
            % Dev1/port0/line5 is the one the audit asked about: the rig file
            % calls it "General Shutter" and AO's own fixtures have called it
            % an Orange DMD trigger. Until the VU says which, it is neither.
            manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
            roles=string({manifest.unresolved.role});
            testCase.verifyTrue(all(ismember( ...
                ["pmt_shutter","general_shutter","sensory_shutter"],roles)));
            line5=manifest.unresolved(roles=="general_shutter");
            testCase.verifyEqual(line5.terminal,"Dev1/port0/line5");
            testCase.verifyTrue(ismissing(line5.stimulation_capable));
            testCase.verifySubstring(char(line5.reason),"Orange DMD");
            % An unresolved entry is not quietly promoted to AO-owned.
            owned=string({manifest.outputs.terminal});
            testCase.verifyFalse(any(owned=="Dev1/port0/line5"));
        end
    end
end

function value=neutral(manifest,role)
value=double(manifest.outputs( ...
    string({manifest.outputs.role})==string(role)).neutral_value);
end

function record=constant(name,port,value)
record=struct("name",char(name),"port",char(port), ...
    "wavefile","awfm_constant","params",{{double(value)}}, ...
    "operation","Multiplication","concatTime",[]);
end
