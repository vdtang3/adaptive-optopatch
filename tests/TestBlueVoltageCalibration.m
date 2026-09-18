classdef TestBlueVoltageCalibration < matlab.unittest.TestCase
    %TESTBLUEVOLTAGECALIBRATION Blue V is a calibration, not a command source.
    %   selected_blue_voltage_v is what 488 nm power a cell was measured to
    %   need. It is edited from a cell table, through the allowlisted
    %   set_cell_blue_voltage action, and it lands in the same canonical FOV
    %   field the MATLAB table writes.
    %
    %   What makes it worth its own suite is the second half: a stored
    %   calibration must never become a COMMAND. The resolver's order is
    %   event > acquisition > protocol > fov_cell, so a protocol that names
    %   a voltage wins; and for 2p_spiral the fov_cell tier is not reachable
    %   at all, because a Chameleon driven from a Blue number is the one
    %   mistake this value could cause.
    %
    %   TestTwoPhotonPockelsVoltage owns that narrowing from the 2P side;
    %   TestProtocolResolution owns the precedence order in general. This
    %   suite owns the editable per-cell value itself.

    methods (Test)
        function blueVoltageIsEditableThroughTheAllowlistedAction(testCase)
            controller=testCase.loadedController();

            response=testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_002","voltage_v",2.25));

            testCase.verifyTrue(response.ok,response.message);
            testCase.verifyEqual(response.status,"applied");
            testCase.verifyEqual( ...
                response.state.cells(2).selected_blue_voltage_v,2.25);
        end

        function theActionWritesTheFieldTheMatlabTableWrites(testCase)
            % The MATLAB cell table's edit callback calls
            % setCellBlueVoltage, which updates selected_blue_voltage_v in
            % the canonical FOV cell record. The action must land in the
            % same place, not in a parallel one.
            controller=testCase.loadedController();

            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",1.75));

            fovState=controller.currentFovState();
            testCase.verifyEqual( ...
                double(fovState.cells(1).selected_blue_voltage_v),1.75);
        end

        function anOutOfRangeVoltageIsRefusedAndChangesNothing(testCase)
            controller=testCase.loadedController();
            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",1.5));
            before=controller.getState();

            for voltage={0,-1,5.5,Inf,NaN,"high"}
                response=testCase.act(controller,"set_cell_blue_voltage", ...
                    struct("cell_id","cell_001","voltage_v",voltage{1}));
                testCase.verifyEqual(response.status,"validation_error");
                testCase.verifyEqual(response.identifier, ...
                    "adaptive_optopatch:InvalidCellCalibration");
                testCase.verifyTrue(isequaln(controller.getState(),before), ...
                    "A refused edit leaves the stored calibration alone.");
            end
        end

        function anUnknownCellIsRefused(testCase)
            controller=testCase.loadedController();

            response=testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_999","voltage_v",1.5));

            testCase.verifyFalse(response.ok);
            testCase.verifyEqual(response.identifier, ...
                "adaptive_optopatch:UnknownCellId");
        end

        function theControllerMethodNameIsStillNotAnAction(testCase)
            % The action is set_cell_blue_voltage. The METHOD name must
            % remain unreachable, because a dispatcher that accepted it
            % would be reaching controller.(action) rather than reading an
            % allowlist.
            controller=testCase.loadedController();

            response=testCase.act(controller,"setCellBlueVoltage", ...
                struct("cell_id","cell_001","voltage_v",1.5));

            testCase.verifyEqual(response.status,"unknown_action");
        end

        function aStoredBlueVoltageNeverOverridesAnExplicitProtocolVoltage(testCase)
            % The claim the editable cell table makes. A protocol whose
            % events carry command_voltage_v must execute that voltage no
            % matter what is stored per cell, because the resolver's order
            % is event > acquisition > protocol > fov_cell.
            controller=testCase.loadedController();
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"ModulatorVoltage",1.2));
            controller.setPlanParameter("mode","1p_dmd");

            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",4.5));

            resolved=controller.buildPlan().resolved_protocols{1};
            events=resolved.events(~resolved.events.is_null,:);
            testCase.verifyNotEmpty(events);
            testCase.verifyEqual(unique(events.command_voltage_v),1.2, ...
                "The protocol's explicit voltage is what executes.");
            testCase.verifyTrue(all(events.command_voltage_source=="event"), ...
                "and it is resolved from the event tier, not from fov_cell.");
        end

        function theStoredCalibrationIsUsedOnlyWhenNothingElseDefinesOne(testCase)
            % The other half of the same claim: the fov_cell tier is real,
            % and it is reached only when the event, the acquisition and the
            % protocol all leave the voltage unset. Without this the first
            % test would pass for a stored value that never resolves at all.
            controller=testCase.loadedController();
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2));
            controller.setPlanParameter("mode","1p_dmd");

            % Every stimulated cell needs one: an uncalibrated cell in a
            % protocol that names no voltage is an unresolved event, which
            % the resolver refuses rather than guesses at.
            for cellId=["cell_001","cell_002"]
                testCase.act(controller,"set_cell_blue_voltage", ...
                    struct("cell_id",cellId,"voltage_v",3.25));
            end

            resolved=controller.buildPlan().resolved_protocols{1};
            events=resolved.events(~resolved.events.is_null,:);
            testCase.verifyEqual(unique(events.command_voltage_v),3.25);
            testCase.verifyTrue(all(events.command_voltage_source=="fov_cell"));
        end

        function aStoredBlueVoltageCannotBecomeAPockelsCommand(testCase)
            % selected_blue_voltage_v is a 488 nm calibration. For
            % 2p_spiral the allowed tiers are narrowed to event,
            % acquisition and protocol, so a 2P protocol with no explicit
            % voltage must FAIL rather than quietly command a Chameleon
            % with a Blue number.
            controller=testCase.loadedController();
            controller.setProtocol(adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",2,"StimulationSource","2p_spiral"));
            controller.setPlanParameter("mode","2p_spiral");
            testCase.act(controller,"set_cell_blue_voltage", ...
                struct("cell_id","cell_001","voltage_v",3.25));

            identifier="<no error was raised>";
            try
                controller.buildPlan();
            catch exception
                identifier=string(exception.identifier);
            end
            testCase.verifyTrue(ismember(identifier, [ ...
                "adaptive_optopatch:MissingTwoPhotonPockelsVoltage"
                "adaptive_optopatch:ProtocolModeIncompatible"]), ...
                "A 2P plan with no explicit Pockels voltage must be " + ...
                "refused, not resolved from a Blue calibration. Got: " + ...
                identifier);
        end
    end

    methods (Access=private)
        function response=act(~,controller,action,payload)
            arguments
                ~
                controller
                action (1,1) string
                payload = struct()
            end
            response=AoFixtures.act(controller,action,payload);
        end

        function controller=loadedController(testCase)
            controller=AoFixtures.previewController(testCase);
        end
    end
end
