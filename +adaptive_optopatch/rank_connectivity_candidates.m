function ranking = rank_connectivity_candidates(connectivity, reference)
%RANK_CONNECTIVITY_CANDIDATES Rank directed non-self pairs for manual review.
arguments
    connectivity (1,1) struct
    reference (1,1) struct
end
n=numel(reference.cells);
source_index=zeros(n*(n-1),1); observed_index=source_index;
source_cell_id=strings(n*(n-1),1); observed_cell_id=source_cell_id;
zscore=zeros(n*(n-1),1); effect=zscore; consistency=zscore;
target_activation_z=zscore; suggested=false(n*(n-1),1);
row=0;
for source=1:n
    for observed=1:n
        if source==observed, continue; end
        row=row+1;
        source_index(row)=source; observed_index(row)=observed;
        source_cell_id(row)=string(reference.cells(source).cell_id);
        observed_cell_id(row)=string(reference.cells(observed).cell_id);
        zscore(row)=connectivity.zscore(source,observed);
        effect(row)=connectivity.effect(source,observed);
        consistency(row)=connectivity.consistency(source,observed);
        target_activation_z(row)=connectivity.target_activation_z(source);
        suggested(row)=connectivity.candidate_edge(source,observed);
    end
end
score=zscore.*max(consistency,0).*max(target_activation_z,0);
ranking=table(false(row,1),suggested(1:row),source_index(1:row), ...
    observed_index(1:row),source_cell_id(1:row),observed_cell_id(1:row), ...
    score(1:row),zscore(1:row),effect(1:row),consistency(1:row), ...
    target_activation_z(1:row), ...
    'VariableNames',{'accepted','suggested','source_index','observed_index', ...
    'source_cell_id','observed_cell_id','score','zscore','effect', ...
    'consistency','target_activation_z'});
ranking=sortrows(ranking,{'suggested','score'},{'descend','descend'});
end
