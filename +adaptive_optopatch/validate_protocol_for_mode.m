function report=validate_protocol_for_mode(protocol,mode)
%VALIDATE_PROTOCOL_FOR_MODE Check schema-3 structural mode compatibility.
arguments
    protocol (1,1) struct
    mode (1,1) string {mustBeMember(mode,["1p_dmd","2p_spiral"])}
end
report=adaptive_optopatch.validate_protocol(protocol); report.mode=mode;
if ~report.passed, return; end
if string(report.protocol.artifact_type)=="experiment_definition" && ...
        mode=="2p_spiral"
    if string(report.protocol.target_policy)=="multi_target_continuous"
        report.issues(end+1)= ...
            "multi_target_continuous is not supported by the 2P spiral runner.";
    end
    report.issues=[report.issues;pockels_voltage_issues(report.protocol)];
end
report.passed=isempty(report.issues);
end

function issues=pockels_voltage_issues(protocol)
%POCKELS_VOLTAGE_ISSUES Require an explicit protocol-owned 2P command.
%   The 2P Pockels command comes only from the protocol artifact, so a
%   definition that leaves it to be filled in is incompatible with 2P mode.
%   Reporting it here means the operator finds out when the protocol is
%   loaded or the mode is switched, not only when the plan is resolved.
issues=strings(0,1);
if scalar_number(protocol.parameters,"command_voltage_v"), return; end
for k=1:numel(protocol.acquisitions)
    acquisition=protocol.acquisitions(k);
    if scalar_number(acquisition.parameters,"command_voltage_v"), continue; end
    events=acquisition.events;
    light=~events.is_null;
    if ~any(light) || all(isfinite(events.command_voltage_v(light))), continue; end
    issues(end+1)="Acquisition "+string(acquisition.acquisition_id)+ ...
        " does not define a Pockels stimulation voltage. A 2p_spiral "+ ...
        "protocol must set command_voltage_v explicitly on its events, "+ ...
        "acquisition parameters, or protocol parameters; there is no GUI "+ ...
        "or per-cell Blue-calibration fallback."; %#ok<AGROW>
end
end

function tf=scalar_number(parameters,name)
tf=isstruct(parameters) && isfield(parameters,name) && ...
    isnumeric(parameters.(name)) && isscalar(parameters.(name)) && ...
    isfinite(double(parameters.(name)));
end
