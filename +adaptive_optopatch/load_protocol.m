function protocol=load_protocol(path)
%LOAD_PROTOCOL Load and validate canonical variable protocol from a MAT file.
arguments
    path (1,1) string
end
if ~isfile(path)
    error("adaptive_optopatch:ProtocolFileNotFound", ...
        "Pulse protocol file was not found: %s",path);
end
saved=load(path,"protocol");
if ~isfield(saved,"protocol")
    error("adaptive_optopatch:ProtocolVariableMissing", ...
        "Pulse protocol MAT file must contain a variable named protocol.");
end
report=adaptive_optopatch.validate_protocol(saved.protocol);
if ~report.passed
    error("adaptive_optopatch:InvalidProtocol","%s",strjoin(report.issues,newline));
end
protocol=report.protocol;
end
