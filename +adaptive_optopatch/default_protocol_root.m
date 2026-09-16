function root=default_protocol_root()
%DEFAULT_PROTOCOL_ROOT Where the protocol generators write by default.
%   pulse-protocols/generated is what every script under pulse-protocols/
%   writes into, so it is where a session looks for protocols unless a
%   controller has been given an explicit ProtocolRoot. Resolved from this
%   file's own location rather than from pwd, so it does not depend on
%   where MATLAB happens to be started.
root=string(fullfile(fileparts(fileparts(mfilename("fullpath"))), ...
    "pulse-protocols","generated"));
end
