function pulses=flatten_pulse_schedule(protocol,options)
%FLATTEN_PULSE_SCHEDULE Resolve the already-flat physical pulse table.
arguments
    protocol (1,1) struct
    options.ConfiguredVoltage (1,1) double = NaN
end
report=adaptive_optopatch.validate_protocol(protocol);
if ~report.passed
    error("adaptive_optopatch:InvalidProtocol","%s",strjoin(report.issues,newline));
end
protocol=report.protocol; events=protocol.events;
if isempty(events)
    error("adaptive_optopatch:EmptyPulseSchedule","The protocol contains no pulses.");
end
configured=options.ConfiguredVoltage;
if ~isfinite(configured) && isfield(protocol,"hardware_command_voltage")
    configured=double(protocol.hardware_command_voltage);
end
command=zeros(height(events),1);
for k=1:height(events)
    if events.is_null(k)
        command(k)=0;
    elseif isfinite(events.command_voltage_v(k))
        command(k)=events.command_voltage_v(k);
    elseif isfinite(configured) && isfinite(events.amplitude_fraction(k))
        command(k)=configured*events.amplitude_fraction(k);
    else
        error("adaptive_optopatch:HardwareAmplitudeRequired", ...
            "Pulse %s has no resolvable physical command voltage.",string(events.pulse_id(k)));
    end
end
[~,order]=sort(events.onset_s);
pulses=events(order,:);
pulses.command_voltage_v=command(order);
pulses.modulator_voltage=pulses.command_voltage_v;
pulses.pulse_index=(1:height(pulses))';
if any(pulses.onset_s<0) || ...
        any(pulses.offset_s>double(protocol.acquisition_duration_s)+1e-9)
    error("adaptive_optopatch:PulseOutsideAcquisition", ...
        "A pulse lies outside the planned acquisition duration.");
end
end
