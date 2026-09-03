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
end
