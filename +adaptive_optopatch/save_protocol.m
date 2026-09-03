function save_protocol(path,protocol)
%SAVE_PROTOCOL Normalize, validate, and save canonical variable protocol.
arguments
    path (1,1) string
    protocol (1,1) struct
end
report=adaptive_optopatch.validate_protocol(protocol);
if ~report.passed
    error("adaptive_optopatch:InvalidProtocol","%s",strjoin(report.issues,newline));
end
protocol=report.protocol;
folder=fileparts(path);
if strlength(folder)>0 && ~isfolder(folder), mkdir(folder); end
save(path,"protocol");
end
