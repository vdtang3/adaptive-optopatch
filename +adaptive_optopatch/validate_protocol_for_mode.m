function report=validate_protocol_for_mode(protocol,mode)
%VALIDATE_PROTOCOL_FOR_MODE Check schema-3 structural mode compatibility.
arguments
    protocol (1,1) struct
    mode (1,1) string {mustBeMember(mode,["1p_dmd","2p_spiral"])}
end
report=adaptive_optopatch.validate_protocol(protocol); report.mode=mode;
if ~report.passed, return; end
if string(report.protocol.artifact_type)=="experiment_definition" && ...
        mode=="2p_spiral" && ...
        string(report.protocol.target_policy)=="multi_target_continuous"
    report.issues(end+1)= ...
        "multi_target_continuous is not supported by the 2P spiral runner.";
end
report.passed=isempty(report.issues);
end
