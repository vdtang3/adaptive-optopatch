function report=validate_protocol_for_mode(protocol,mode)
%VALIDATE_PROTOCOL_FOR_MODE Check that a canonical schedule can be realized.
arguments
    protocol (1,1) struct
    mode (1,1) string {mustBeMember(mode,["1p_dmd","2p_spiral"])}
end
report=adaptive_optopatch.validate_protocol(protocol);
report.mode=mode;
if report.passed
    try
        adaptive_optopatch.flatten_pulse_schedule(report.protocol, ...
            "ConfiguredVoltage",1);
    catch exception
        report.passed=false;
        report.issues(end+1)=string(exception.message);
    end
end
end
