classdef TestGuiPanelPresentation < matlab.unittest.TestCase
    %TESTGUIPANELPRESENTATION Layout of the unified GUI's two operator panels.
    %   These are presentation assertions only. Nothing here may depend on
    %   protocol resolution, calibration semantics, or hardware execution;
    %   the point is that the panels show the right things in the right
    %   order and that every control an experimenter needs is reachable.

    methods (Test)
        function cellTableLeadsWithThePerCellDecisions(testCase)
            [app,root]=open_gui(testCase);
            app.setReferenceData(ones(70,90),panel_info(root),panel_polygon());
            qc=qc_table(testCase,app);

            % The first four columns are the identity and the three per-cell
            % decisions, in the order the experimenter makes them.
            testCase.verifyEqual(string(qc.ColumnName(1:4))', ...
                ["Cell ID","Record","Stim","Blue V (1P)"]);

            % The geometry and QC columns follow, unchanged and in their
            % previous relative order.
            testCase.verifyEqual(string(qc.ColumnName(5:end))', ...
                ["Area px","X","Y","Edge px","QC"]);
        end

        function blueVoltageColumnIsExplicitlyOnePhoton(testCase)
            % "Blue V" alone could be read as a generic stimulation voltage.
            % It is the 488 nm per-cell calibration and nothing else, and no
            % 2P column may join it: the Pockels command is protocol-owned.
            [app,root]=open_gui(testCase);
            app.setReferenceData(ones(70,90),panel_info(root),panel_polygon());
            names=string(qc_table(testCase,app).ColumnName)';
            testCase.verifyTrue(ismember("Blue V (1P)",names));
            testCase.verifyFalse(any(contains(names,"2P","IgnoreCase",true)));
            testCase.verifyFalse(any(contains(names,"Pockels","IgnoreCase",true)));
        end

        function reorderedTableEditsTheSameUnderlyingState(testCase)
            % Record and Stim still drive setCellEligibility, while Blue V
            % edits the same canonical per-cell value displayed by the table.
            [app,root]=open_gui(testCase);
            app.setReferenceData(ones(70,90),panel_info(root),panel_polygon());
            app.setCellCalibration("cell_001",0.8);
            qc=qc_table(testCase,app);

            testCase.verifyEqual(logical(qc.ColumnEditable), ...
                [false true true true false false false false false]);
            testCase.verifyEqual(string(qc.Data{1,1}),"cell_001");
            testCase.verifyEqual(qc.Data{1,4},0.8);

            callback=qc.CellEditCallback;
            callback(qc,struct("Indices",[1 2],"NewData",false));
            state=app.saveCurrentFov(fullfile(root,"record_off.mat"));
            testCase.verifyFalse(state.cells(1).recording_enabled);
            testCase.verifyTrue(state.cells(1).stimulation_enabled);

            callback(qc,struct("Indices",[1 3],"NewData",false));
            state=app.saveCurrentFov(fullfile(root,"stim_off.mat"));
            testCase.verifyFalse(state.cells(1).recording_enabled);
            testCase.verifyFalse(state.cells(1).stimulation_enabled);

            callback(qc,struct("Indices",[1 4],"NewData",1.2));
            state=app.saveCurrentFov(fullfile(root,"blue_v.mat"));
            testCase.verifyEqual(state.cells(1).selected_blue_voltage_v,1.2);

            % An invalid Blue V edit is refused and the table is redrawn
            % from canonical state rather than from the typed value.
            qc.Data{1,4}=99;
            callback(qc,struct("Indices",[1 4],"NewData",99));
            testCase.verifyEqual(qc.Data{1,4},1.2);
        end

        function protocolPanelFitsTheHeightItIsGiven(testCase)
            % The panel used to request more height than the root grid gives
            % it, which silently clipped its bottom row of buttons. Position
            % is not laid out for an invisible figure, so the fit is checked
            % from the grid's own declared geometry.
            app=open_gui(testCase);
            grid=protocol_grid(testCase,app);
            required=sum([grid.RowHeight{:}]) ...
                +grid.RowSpacing*(numel(grid.RowHeight)-1) ...
                +grid.Padding(2)+grid.Padding(4);

            runtime=grid.Parent; root=runtime.Parent;
            allotted=root.RowHeight{runtime.Layout.Row} ...
                -runtime.Padding(2)-runtime.Padding(4);
            testCase.verifyLessThanOrEqual(required,allotted, ...
                "The protocol panel must fit the height the root grid gives it.");
        end

        function everyProtocolButtonIsPresentAndOnAnAllocatedRow(testCase)
            app=open_gui(testCase);
            grid=protocol_grid(testCase,app);
            rows=numel(grid.RowHeight);
            buttons=["Load protocol…","Preview","Check","Run next","Run all", ...
                "Stop after current","Resume run…", ...
                "Review completed Blue ramp…","Freeze new run","Start new batch", ...
                "Return to editing"];
            for name=buttons
                control=findall(app.Figure,"Text",name);
                testCase.verifyNumElements(control,1, ...
                    sprintf("Expected exactly one %s button.",name));
                testCase.verifySameHandle(control.Parent,grid, ...
                    sprintf("%s must live in the protocol panel.",name));
                testCase.verifyLessThanOrEqual(control.Layout.Row,rows, ...
                    sprintf("%s sits on a row the panel does not allocate.",name));
            end
        end

        function mod488FieldIsActuallyLaidOutInThePanel(testCase)
            % The field is reparented out of the planning grid into the
            % protocol panel, and reparenting carries its old grid
            % coordinates with it. That grew its one-cell wrapper to the
            % planning grid's shape and left the control with zero height:
            % present and editable, but invisible to the experimenter.
            app=open_gui(testCase);
            app.setPlanParameter("mode","1p_dmd");
            [field,wrapper]=command_voltage_field(testCase,app);
            testCase.verifyEqual(field.Layout.Row,1);
            testCase.verifyEqual(field.Layout.Column,1);
            testCase.verifyNumElements(wrapper.RowHeight,1, ...
                "The mod488 wrapper must stay one cell.");
            testCase.verifyNumElements(wrapper.ColumnWidth,1, ...
                "The mod488 wrapper must stay one cell.");
            testCase.verifyEqual(string(field.Visible),"on");
        end

        function panelCarriesNoOwnershipCaptionsAndNoPockelsInput(testCase)
            app=open_gui(testCase);

            % The ownership explanations no longer occupy permanent space.
            for text=["OBIS power is owned by Luminos/React", ...
                    "Pockels: from protocol","mod488 / Pockels (V)"]
                testCase.verifyEmpty(findall(app.Figure,"Text",text), ...
                    sprintf("%s must not occupy permanent panel space.",text));
            end

            % No permanent caption anywhere names Pockels, so no control
            % reads as a Pockels input. A tooltip is not permanent space.
            labels=findall(app.Figure,"Type","uilabel");
            captions=arrayfun(@(label)string(label.Text),labels);
            testCase.verifyFalse(any(contains(captions,"Pockels")), ...
                "No GUI label may present itself as a Pockels control.");

            % The one command-voltage field is the 1P mod488 default, and it
            % is inert in 2P because that command is protocol-only.
            testCase.verifyNotEmpty(findall(app.Figure,"Text","mod488 (V)"));
            app.setPlanParameter("mode","1p_dmd");
            testCase.verifyEqual(string(app.commandVoltageEnabled()),"on");
            app.setPlanParameter("mode","2p_spiral");
            testCase.verifyEqual(string(app.commandVoltageEnabled()),"off");
        end
    end
end

function [app,root]=open_gui(testCase)
root=tempname; mkdir(root);
testCase.addTeardown(@()remove_if_present(root));
[app,~]=open_simulated_test_gui("Visible","off","RunRoot",root);
testCase.addTeardown(@()delete(app));
end

function qc=qc_table(testCase,app)
tables=findall(app.Figure,"Type","uitable");
qc=tables(arrayfun( ...
    @(value)any(string(value.ColumnName)=="Cell ID"),tables));
testCase.verifyNumElements(qc,1);
end

function [field,wrapper]=command_voltage_field(testCase,app)
% The panel holds exactly one nested grid, and it wraps the mod488 field.
grid=protocol_grid(testCase,app);
wrapper=findobj(grid.Children,"-isa","matlab.ui.container.GridLayout");
testCase.verifyNumElements(wrapper,1);
field=wrapper.Children;
testCase.verifyNumElements(field,1);
end

function grid=protocol_grid(testCase,app)
% The panel is whatever grid holds the run buttons.
button=findall(app.Figure,"Text","Run all");
testCase.verifyNumElements(button,1);
grid=button.Parent;
end

function positions=panel_polygon()
positions={[30 25;50 25;50 45;30 45]};
end

function info=panel_info(root)
camera=struct("ROI",[0 0 90 70],"bin",1, ...
    "x_world_limits",[979 1069],"y_world_limits",[989 1059]);
metadata=struct("rig_name","Virtual_Upright","voltage_camera",camera);
info=struct("snapshot_name","panel_presentation_test", ...
    "snapshot_directory",string(root), ...
    "snapshot_path",string(fullfile(root,"snapshot.mat")),"metadata",metadata);
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
