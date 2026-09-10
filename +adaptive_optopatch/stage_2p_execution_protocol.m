function protocol=stage_2p_execution_protocol(frozenProtocol,staging,isNull)
%STAGE_2P_EXECUTION_PROTOCOL Derive the schedule a staged 2P call executes.
%   The frozen resolved acquisition is never modified. This returns the working
%   copy that the current release level actually executes, so preview and
%   execution derive the physical schedule from one implementation.
arguments
    frozenProtocol (1,1) struct
    staging (1,1) struct
    isNull (1,1) logical = false
end
protocol=adaptive_optopatch.normalize_protocol(frozenProtocol);
if isfinite(staging.executed_event_count)
    count=double(staging.executed_event_count);
    postDelay=max(0,protocol.acquisition_duration_s-protocol.events.offset_s(end));
    protocol.events=protocol.events(1:count,:);
    protocol.acquisition_duration_s=protocol.events.offset_s(end)+postDelay;
    protocol.protocol_id=protocol.protocol_id+"_"+staging.release_level;
    protocol.staged_from_protocol_id=string(frozenProtocol.protocol_id);
    protocol=adaptive_optopatch.normalize_protocol(protocol);
end
voltage=double(staging.command_voltage_v);
if string(staging.command_voltage_policy)=="explicit_test_command" && ...
        (~isfinite(voltage) || voltage<=0)
    error("adaptive_optopatch:MissingTestCommandVoltage", ...
        "%s executes at an explicitly confirmed Pockels voltage. " + ...
        "Enter a positive command before previewing or running.", ...
        staging.release_level);
end
if isNull, voltage=0; end
if ~isfinite(voltage), return; end
if voltage==0
    protocol.events.is_null(:)=true;
    protocol.events.target_cell_id(:)="";
    protocol.events.target_index(:)=0;
    protocol.events.dmd_pattern_index(:)=0;
    protocol.events.command_voltage_v(:)=0;
    protocol.events.command_voltage_source(:)="release_"+staging.release_level;
else
    selected=~protocol.events.is_null;
    protocol.events.command_voltage_v(selected)=voltage;
    protocol.events.command_voltage_v(~selected)=0;
    protocol.events.command_voltage_source(selected)= ...
        "release_"+staging.release_level;
end
end
