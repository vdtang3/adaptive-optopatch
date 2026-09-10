function configuration=prepare_luminos_dmd_sequence(dmd,plan,options)
%PREPARE_LUMINOS_DMD_SEQUENCE Transform and preload an ALP slave stack.
arguments
    dmd
    plan (1,1) struct
    options.DryRun (1,1) logical = true
end
n=plan.pattern_count;
configuration=rmfield(plan,"camera_pattern_stack");
configuration.mode="slave";
configuration.loaded=false;
if options.DryRun, return; end
stack=[];
for k=1:n
    transformed=dmd.setPatterningROI(plan.camera_pattern_stack(:,:,k), ...
        "write_when_complete",false);
    if k==1, stack=false([size(transformed),n]); end
    stack(:,:,k)=logical(transformed);
end
dmd.pattern_stack=stack;
dmd.Write_Stack('slave');
configuration.dmd_stack_size=size(stack);
configuration.loaded=true;
% The stack is armed but the DAQ waveform is not built and the shutter is
% still closed, so this is the last point at which the frozen advance
% schedule can be checked against what this DMD can physically display.
configuration.pattern_advance=validate_pattern_advance(dmd,plan);
end

function report=validate_pattern_advance(dmd,plan)
capability=adaptive_optopatch.dmd_pattern_advance_capability(dmd);
triggers=double(plan.dmd_trigger_s(:));
intervals=diff(triggers);
report=struct("schema_version","1.0.0", ...
    "minimum_picture_time_s",capability.minimum_picture_time_s, ...
    "capability_source",string(capability.source), ...
    "capability_detail",string(capability.detail), ...
    "requested_minimum_interval_s",min([intervals;Inf]), ...
    "validated",false);
if ~isfinite(capability.minimum_picture_time_s)
    % No authoritative limit is available from this device, so none is
    % invented. The unvalidated state is archived with the configuration.
    return
end
report.validated=true;
if isempty(intervals), return; end
[shortest,index]=min(intervals);
if shortest<capability.minimum_picture_time_s-1e-12
    error("adaptive_optopatch:DmdPatternAdvanceTooFast", ...
        ['Pattern %d must advance %.4f ms after pattern %d (pulse %s to ' ...
         'pulse %s), but %s reports a minimum picture time of %.4f ms. ' ...
         'Lengthen that dark interval in the protocol and freeze a new run; ' ...
         'the frozen schedule is not stretched automatically.'], ...
        index+1,1000*shortest,index, ...
        string(plan.trigger_associated_pulse_id(index)), ...
        string(plan.trigger_associated_pulse_id(index+1)), ...
        string(capability.source), ...
        1000*capability.minimum_picture_time_s);
end
end
