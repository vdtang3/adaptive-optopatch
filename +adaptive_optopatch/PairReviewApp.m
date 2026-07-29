classdef PairReviewApp < handle
    %PAIRREVIEWAPP Manual acceptance of ranked directed connectivity pairs.
    properties (SetAccess=private)
        Figure
    end
    properties (Access=private)
        Axes
        Table
        Status
        Reference
        Ranking
    end
    methods
        function app=PairReviewApp(analysis,reference,options)
            arguments
                analysis (1,1) struct
                reference (1,1) struct
                options.Visible (1,1) string = "on"
            end
            app.Reference=reference;
            if isfield(analysis,"ranking")
                app.Ranking=analysis.ranking;
            elseif isfield(analysis,"connectivity")
                app.Ranking=adaptive_optopatch.rank_connectivity_candidates( ...
                    analysis.connectivity,reference);
            else
                app.Ranking=adaptive_optopatch.rank_connectivity_candidates(analysis,reference);
            end
            app.buildUI(options.Visible); app.refreshTable(); app.showRow(1);
        end
        function delete(app)
            if ~isempty(app.Figure) && isvalid(app.Figure), delete(app.Figure); end
        end
    end
    methods (Access=private)
        function buildUI(app,visible)
            app.Figure=uifigure("Name","Adaptive Optopatch — Pair Review", ...
                "Position",[100 100 1250 720],"Visible",visible);
            grid=uigridlayout(app.Figure,[2 2]);
            grid.RowHeight={"1x",90}; grid.ColumnWidth={480,"1x"};
            app.Axes=uiaxes(grid); app.Axes.Layout.Row=1; app.Axes.Layout.Column=1;
            app.Table=uitable(grid,"ColumnEditable",[true false false false false false false false], ...
                "CellSelectionCallback",@(src,event)app.selectCell(src,event), ...
                "CellEditCallback",@(src,event)app.editCell(src,event));
            app.Table.Layout.Row=1; app.Table.Layout.Column=2;
            panel=uigridlayout(grid,[1 2]); panel.Layout.Row=2; panel.Layout.Column=1;
            app.Status=uitextarea(panel,"Editable","off","Value","Ready.");
            uibutton(panel,"Text","Save accepted pairs…","FontWeight","bold", ...
                "ButtonPushedFcn",@(~,~)app.saveAccepted());
            note=uitextarea(grid,"Editable","off","Value", ...
                "Check Accept for directed pairs to carry into STF design.");
            note.Layout.Row=2; note.Layout.Column=2;
        end
        function refreshTable(app)
            n=height(app.Ranking); data=cell(n,8);
            for k=1:n
                data(k,:)={app.Ranking.accepted(k),char(app.Ranking.source_cell_id(k)), ...
                    char(app.Ranking.observed_cell_id(k)),app.Ranking.score(k), ...
                    app.Ranking.zscore(k),app.Ranking.effect(k), ...
                    app.Ranking.consistency(k),app.Ranking.target_activation_z(k)};
            end
            app.Table.ColumnName={'Accept','Stimulated','Observed','Score','Z', ...
                'Effect','Consistency','Target Z'};
            app.Table.Data=data;
        end
        function selectCell(app,~,event)
            if ~isempty(event.Indices), app.showRow(event.Indices(1)); end
        end
        function editCell(app,~,event)
            if event.Indices(2)==1
                app.Ranking.accepted(event.Indices(1))=logical(event.NewData);
            end
        end
        function showRow(app,row)
            if row<1 || row>height(app.Ranking), return; end
            imagesc(app.Axes,app.Reference.reference_image); axis(app.Axes,"image");
            app.Axes.YDir="reverse"; colormap(app.Axes,"gray"); hold(app.Axes,"on");
            s=app.Ranking.source_index(row); o=app.Ranking.observed_index(row);
            plot_boundaries(app.Axes,app.Reference.roi_masks(:,:,s),"r",2);
            plot_boundaries(app.Axes,app.Reference.roi_masks(:,:,o),"c",2);
            hold(app.Axes,"off");
            title(app.Axes,sprintf('%s -> %s', ...
                char(app.Ranking.source_cell_id(row)), ...
                char(app.Ranking.observed_cell_id(row))),"Interpreter","none");
            app.Status.Value=sprintf(['Red = stimulated; cyan = observed\n' ...
                'Z %.3g, consistency %.3g, target activation Z %.3g'], ...
                app.Ranking.zscore(row),app.Ranking.consistency(row), ...
                app.Ranking.target_activation_z(row));
        end
        function saveAccepted(app)
            folder=uigetdir(pwd,"Choose output folder for accepted pairs");
            if isequal(folder,0), return; end
            accepted_pairs=app.Ranking(app.Ranking.accepted,:);
            save(fullfile(folder,"accepted_pairs.mat"),"accepted_pairs");
            writetable(accepted_pairs,fullfile(folder,"accepted_pairs.csv"));
            app.Status.Value=sprintf('Saved %d accepted directed pairs to:\n%s', ...
                height(accepted_pairs),folder);
        end
    end
end

function plot_boundaries(ax,mask,color,width)
b=bwboundaries(mask);
for k=1:numel(b)
    p=b{k}; plot(ax,p(:,2),p(:,1),"-","Color",color,"LineWidth",width);
end
end
