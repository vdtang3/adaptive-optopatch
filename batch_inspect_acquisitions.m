function summary=batch_inspect_acquisitions(sessionDirectories,options)
%BATCH_INSPECT_ACQUISITIONS Precompute inspection caches for many acquisitions.
%   summary=batch_inspect_acquisitions(sessionDirectories) runs
%   inspect_acquisition on each exact Luminos experiment folder, in order,
%   so that later interactive inspect_acquisition calls open from
%   inspection_analysis.mat instead of re-reading the movie.
%
%   Options:
%     Force            re-analyze even when a valid cache exists (false)
%     GenerateFigures  also write inspection.png for each session (false)
%     ContinueOnError  record a failure and move on, or rethrow (true)
%
%   summary has one row per session: session, status ("processed",
%   "cached" or "failed"), cache_hit, elapsed_s, error_identifier and
%   error_message.
%
%   Folders are not searched recursively; pass the exact directories that
%   contain output_data.mat.
arguments
    sessionDirectories {mustBeText}
    options.Force (1,1) logical = false
    options.GenerateFigures (1,1) logical = false
    options.ContinueOnError (1,1) logical = true
end
sessions=reshape(string(sessionDirectories),[],1);
nSessions=numel(sessions);
status=strings(nSessions,1);
cacheHit=false(nSessions,1);
elapsed=zeros(nSessions,1);
errorIdentifier=strings(nSessions,1);
errorMessage=strings(nSessions,1);

for k=1:nSessions
    started=tic;
    try
        viewer=inspect_acquisition(sessions(k), ...
            "Force",options.Force, ...
            "GenerateFigure",options.GenerateFigures, ...
            "Visible","off");
        % The PNG is already written; a batch should not leave windows behind.
        delete(viewer.figure);
        cacheHit(k)=viewer.cache_hit;
        if cacheHit(k), status(k)="cached"; else, status(k)="processed"; end
    catch exception
        if ~options.ContinueOnError
            rethrow(exception);
        end
        status(k)="failed";
        errorIdentifier(k)=string(exception.identifier);
        errorMessage(k)=string(exception.message);
    end
    elapsed(k)=toc(started);
    fprintf("[%d/%d] %-9s %6.1f s  %s\n",k,nSessions,status(k), ...
        elapsed(k),sessions(k));
    if status(k)=="failed"
        fprintf("        %s\n",errorMessage(k));
    end
end

summary=table(sessions,status,cacheHit,elapsed,errorIdentifier,errorMessage, ...
    'VariableNames',{'session','status','cache_hit','elapsed_s', ...
    'error_identifier','error_message'});
end
