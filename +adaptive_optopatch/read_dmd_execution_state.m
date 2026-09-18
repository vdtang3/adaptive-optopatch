function state=read_dmd_execution_state(dmd)
%READ_DMD_EXECUTION_STATE Compact readback of what a DMD is actually playing.
%   A correct MATLAB Target does not by itself mean the mirrors showed it.
%   This captures the few fields that distinguish "the intended pattern was
%   really displayed as a single static picture" from "the intended pattern
%   was written while the device kept playing something else", so an
%   archived acquisition can be told apart after the fact.
%
%   The fields and their constants are ALP's, reached through
%   ALP_DMD.Get_State. Every inquiry there is allowed to fail and reports -1
%   when the controller will not answer, so -1 and an absent field both mean
%   "unavailable" and never "zero"; both arrive here as NaN. A device with
%   no readback at all is recorded as unproven rather than treated as bad.
arguments
    dmd
end

state=struct;
state.schema_version="1.0.0";
state.captured_at=string(datetime("now","TimeZone","local"));

% The device boundary, before any hardware inquiry. invert_output is applied
% only in DMD.Device_Pattern, on the last step out to the mirrors: Target,
% pattern_stack, the previews the UI draws and everything calibration
% touches all stay as written. A wrong value here is therefore invisible in
% every other artifact AO archives, which is exactly why it is archived here.
state.invert_output=read_flag(dmd,"invert_output");
state.canvas_size=[NaN NaN];
try
    state.canvas_size=adaptive_optopatch.dmd_pattern_canvas_size(dmd);
catch
end

state.readback_available=false;
state.readback_error="";
raw=struct;
if ~ismethod(dmd,"Get_State")
    state.readback_error="The DMD does not expose Get_State.";
else
    try
        raw=dmd.Get_State();
    catch exception
        state.readback_error=string(exception.message);
    end
end
if ~isstruct(raw), raw=struct; end
state.readback_available=~isempty(fieldnames(raw));

inquiries=["device_state","available_pictures","projection_state", ...
    "projection_mode","projection_step","trigger_edge","flut_max_entries", ...
    "sequence_pictures","bit_planes","picture_time","illuminate_time"];
for name=inquiries
    state.(name)=read_inquiry(raw,name);
end

% alp.h: ALP_PROJ_ACTIVE/ALP_PROJ_IDLE and ALP_MASTER/ALP_SLAVE.
projActive=1200; projIdle=1201; master=2301; slave=2302;
state.projection_state_name=decode(state.projection_state, ...
    [projActive projIdle],["active","idle"]);
state.projection_mode_name=decode(state.projection_mode, ...
    [master slave],["master","slave"]);

% A static write leaves a freshly allocated one-picture master sequence:
% ALP_DMD::Project halts the device, frees the previous sequence, allocates
% SeqAlloc(1,1), restores master mode with stepping disabled, and starts
% continuous projection. Frame look-up addressing is a property of the
% sequence and is dropped when it is freed, and flut_enabled itself is a
% private C++ member that Get_State does not expose - so master mode plus a
% one-picture sequence is what this API can actually prove, and it is enough:
% a single-picture master sequence cannot be a multi-entry FLUT playlist.
state.static_single_pattern_confirmed= ...
    state.projection_mode==master && state.sequence_pictures==1;
state.contradicts_static_mode=state.projection_mode==slave || ...
    (isfinite(state.sequence_pictures) && state.sequence_pictures>1);
if state.static_single_pattern_confirmed
    state.verdict="confirmed_static";
elseif state.contradicts_static_mode
    state.verdict="contradicts_static";
else
    state.verdict="unproven";
end
end

function value=read_inquiry(raw,name)
% -1 is ALP_DMD_State::kUnavailable, not a measurement.
value=NaN;
if ~isfield(raw,name), return; end
candidate=double(raw.(name));
if ~isscalar(candidate) || ~isfinite(candidate) || candidate<0, return; end
value=candidate;
end

function name=decode(value,codes,names)
name="unavailable";
if ~isfinite(value), return; end
match=find(codes==value,1);
if isempty(match), name="unrecognized_"+string(value); return; end
name=names(match);
end

function flag=read_flag(object,name)
flag=NaN;
try
    if isobject(object) && isprop(object,name)
        flag=double(logical(object.(name)));
    elseif isstruct(object) && isfield(object,name)
        flag=double(logical(object.(name)));
    end
catch
end
end
