classdef SettingsReviewApp < handle
    %SETTINGSREVIEWAPP Review inherited Luminos settings and record overrides.
    properties (SetAccess=private)
        Figure
    end
    properties (Access=private)
        Table
        Status
        Snapshot
        Settings
    end
    methods
        function app=SettingsReviewApp(snapshot,options)
            arguments
                snapshot (1,1) struct
                options.Visible (1,1) string = "on"
            end
            app.Snapshot=snapshot;
            app.Settings=adaptive_optopatch.summarize_luminos_settings(snapshot);
            app.buildUI(options.Visible); app.refresh();
        end
        function delete(app)
            if ~isempty(app.Figure) && isvalid(app.Figure), delete(app.Figure); end
        end
    end
    methods (Access=private)
        function buildUI(app,visible)
            app.Figure=uifigure("Name","Adaptive Optopatch — Active Luminos Settings", ...
                "Position",[150 100 1050 700],"Visible",visible);
            grid=uigridlayout(app.Figure,[2 1]); grid.RowHeight={"1x",80};
            app.Table=uitable(grid,"ColumnEditable",[true false false true false], ...
                "CellEditCallback",@(src,event)app.editCell(src,event));
            bottom=uigridlayout(grid,[1 2]);
            app.Status=uitextarea(bottom,"Editable","off", ...
                "Value","Overrides are recorded only; live application remains locked.");
            uibutton(bottom,"Text","Save settings snapshot…","FontWeight","bold", ...
                "ButtonPushedFcn",@(~,~)app.saveSettings());
        end
        function refresh(app)
            n=height(app.Settings); data=cell(n,5);
            for k=1:n
                data(k,:)={app.Settings.apply_override(k),char(app.Settings.path(k)), ...
                    char(app.Settings.current_value(k)), ...
                    char(app.Settings.override_value(k)),char(app.Settings.source(k))};
            end
            app.Table.ColumnName={'Override','Setting','Active value','Requested value','Source'};
            app.Table.Data=data;
        end
        function editCell(app,~,event)
            row=event.Indices(1); column=event.Indices(2);
            if column==1
                app.Settings.apply_override(row)=logical(event.NewData);
            elseif column==4
                app.Settings.override_value(row)=string(event.NewData);
            end
        end
        function saveSettings(app)
            folder=uigetdir(pwd,"Choose settings output folder");
            if isequal(folder,0), return; end
            settings_snapshot=app.Snapshot;
            settings_overrides=app.Settings(app.Settings.apply_override,:);
            save(fullfile(folder,"luminos_settings.mat"), ...
                "settings_snapshot","settings_overrides","-v7.3");
            writetable(app.Settings,fullfile(folder,"luminos_settings.csv"));
            app.Status.Value=sprintf('Saved settings and %d requested overrides to:\n%s', ...
                height(settings_overrides),folder);
        end
    end
end
