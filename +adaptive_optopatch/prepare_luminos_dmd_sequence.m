function configuration=prepare_luminos_dmd_sequence(dmd,plan,options)
%PREPARE_LUMINOS_DMD_SEQUENCE Program unique masks and the resolved event order.
arguments
    dmd
    plan (1,1) struct
    options.DryRun (1,1) logical = true
end
n=plan.event_count;
playlistSlots=plan.event_slot_indices;
if isfield(plan,"programmed_playlist_slots")
    playlistSlots=plan.programmed_playlist_slots;
end
playlistCount=numel(playlistSlots);
configuration=rmfield(plan,"unique_camera_masks");
configuration.mode="slave";
configuration.loaded=false;
configuration.execution_mode="unprogrammed";
uniqueCount=plan.unique_mask_count;
useFlut=supports_flut(dmd);
configuration.supports_flut=useFlut;
if isfield(plan,"dmd_diagnostic") && ~useFlut
    error("adaptive_optopatch:DmdFlutDiagnosticRequiresFlut", ...
        "The dmd_flut_wrap diagnostic requires a DMD with FLUT support.");
end
flutMaxEntries=NaN; playlistCapacity=NaN;
if useFlut
    state=dmd.Get_State();
    if ~isstruct(state) || ~isfield(state,"flut_max_entries") || ...
            ~isscalar(state.flut_max_entries) || state.flut_max_entries<=0
        error("adaptive_optopatch:FlutCapacityUnavailable", ...
            "The DMD reports FLUT support but no usable FLUT entry capacity.");
    end
    flutMaxEntries=double(state.flut_max_entries);
    playlistCapacity=adaptive_optopatch.calculate_dmd_flut_playlist_capacity( ...
        flutMaxEntries,uniqueCount);
    if playlistCount>playlistCapacity
        error("adaptive_optopatch:FlutPlaylistTooLong", ...
            "The DMD playlist contains %d entries, but this DMD and "+ ...
            "Luminos can hold only %d FLUT playlist entries for a %d-mask "+ ...
            "bank. Split the protocol into smaller acquisitions or reduce "+ ...
            "pulses_per_cell_per_chunk.", ...
            playlistCount,playlistCapacity,uniqueCount);
    end
    configuration.flut_max_entries=flutMaxEntries;
    configuration.flut_playlist_capacity=playlistCapacity;
end
configuration.physical_upload_count=uniqueCount;
configuration.playlist_entry_count=playlistCount;
if options.DryRun, return; end

% The transform every mask below is warped through has to belong to this
% DMD and to the camera the plan's reference image came from. Checked once,
% before the first mask is transformed, rather than per mask: it is a
% property of the device, and a failure must happen before anything reaches
% the mirrors.
configuration.calibration_identity= ...
    adaptive_optopatch.validate_dmd_calibration_identity( ...
    dmd,plan.reference_camera,"DMD_Blue");

referenceMask=adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
    plan.unique_camera_masks(:,:,1),plan.reference_camera,dmd,"DMD_Blue");
transformed=dmd.setPatterningROI(referenceMask,"write_when_complete",false);
transformedMasks=false([size(transformed),uniqueCount]);
transformedMasks(:,:,1)=logical(transformed);
for k=2:uniqueCount
    referenceMask=adaptive_optopatch.remap_camera_mask_to_dmd_reference( ...
        plan.unique_camera_masks(:,:,k),plan.reference_camera,dmd,"DMD_Blue");
    transformed=dmd.setPatterningROI(referenceMask, ...
        "write_when_complete",false);
    transformedMasks(:,:,k)=logical(transformed);
end

if useFlut
    dmd.Reserve_Slots(uniqueCount);
    for slot=1:uniqueCount
        dmd.Write_Pattern_To_Slot(slot,transformedMasks(:,:,slot));
    end
    dmd.Set_Playlist(playlistSlots,'slave');
    configuration.execution_mode="flut_playlist";
else
    stack=transformedMasks(:,:,plan.event_slot_indices);
    dmd.pattern_stack=stack;
    dmd.Write_Stack('slave');
    configuration.execution_mode="physical_event_stack";
    configuration.dmd_stack_size=size(stack);
    configuration.physical_upload_count=n;
    configuration.playlist_entry_count=n;
end
configuration.loaded=true;
% What the device is playing now, so Luminos can confirm immediately before
% the trigger that nothing replaced it. For the FLUT path this covers the
% pattern bank and the playlist order, which is the whole stimulus; for the
% stack path it covers the loaded sequence.
configuration.owned_pattern_fingerprint= ...
    adaptive_optopatch.record_owned_dmd_pattern(dmd);
% The stack is armed but the DAQ waveform is not built and the shutter is
% still closed, so this is the last point at which the frozen advance
% schedule can be checked against what this DMD can physically display.
configuration.pattern_advance=validate_pattern_advance(dmd,plan);
end

function tf=supports_flut(dmd)
tf=false;
if ismethod(dmd,"Supports_FLUT")
    tf=logical(dmd.Supports_FLUT());
end
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
