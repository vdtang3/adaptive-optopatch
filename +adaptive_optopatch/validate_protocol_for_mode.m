function report=validate_protocol_for_mode(protocol,mode,options)
%VALIDATE_PROTOCOL_FOR_MODE Check pulse resolution requirements for a mode.
arguments
    protocol (1,1) struct
    mode (1,1) string {mustBeMember(mode,["1p_dmd","2p_spiral"])}
    options.RequireResolvedTargets (1,1) logical = false
    options.AvailableCellIds string = strings(0,1)
end
report=adaptive_optopatch.validate_protocol(protocol);
report.mode=mode;
if ~report.passed, return; end
events=report.protocol.events;
nonNull=~events.is_null;
if options.RequireResolvedTargets && any(strlength(events.target_cell_id(nonNull))==0)
    report.issues(end+1)="Every non-null pulse must have a resolved target cell before freezing.";
end
if ~isempty(options.AvailableCellIds)
    unknown=nonNull & strlength(events.target_cell_id)>0 & ...
        ~ismember(events.target_cell_id,options.AvailableCellIds);
    if any(unknown)
        report.issues(end+1)="Protocol contains unknown target cell IDs: "+ ...
            strjoin(unique(events.target_cell_id(unknown)),", ");
    end
end
report.passed=isempty(report.issues);
end
