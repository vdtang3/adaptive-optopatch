function protocol=resolve_protocol_commands(protocol,configuredVoltage)
%RESOLVE_PROTOCOL_COMMANDS Freeze relative amplitudes as physical commands.
arguments
    protocol (1,1) struct
    configuredVoltage (1,1) double
end
protocol=adaptive_optopatch.normalize_protocol(protocol);
events=protocol.events;
for k=1:height(events)
    if events.is_null(k)
        events.command_voltage_v(k)=0;
    elseif ~isfinite(events.command_voltage_v(k))
        if ~isfinite(configuredVoltage) || configuredVoltage<0 || ...
                ~isfinite(events.amplitude_fraction(k))
            error("adaptive_optopatch:HardwareAmplitudeRequired", ...
                "Pulse %s has no resolvable physical command voltage.", ...
                string(events.pulse_id(k)));
        end
        events.command_voltage_v(k)=configuredVoltage*events.amplitude_fraction(k);
    end
end
protocol.events=events;
protocol.configured_voltage_used_v=configuredVoltage;
protocol.commands_resolved=true;
protocol=adaptive_optopatch.normalize_protocol(protocol);
end
