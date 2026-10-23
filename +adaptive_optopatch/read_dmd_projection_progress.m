function progress=read_dmd_projection_progress(dmd)
%READ_DMD_PROJECTION_PROGRESS The ALP's own frame and iteration counters.
%   progress=READ_DMD_PROJECTION_PROGRESS(dmd) reads AlpProjInquireEx(
%   ALP_PROJ_PROGRESS) through Luminos's Get_Projection_Progress, when the
%   device has it. It is how a blanket acquisition checks, after the fact,
%   that the DMD advanced exactly once per DAQ trigger: a lost or doubled
%   edge shifts the wrapped playlist against mod488 for the rest of the run.
%
%   The counters are the ALP's (tAlpProjProgress in alp.h):
%     sequence_counter            iterations left; counts down and underflows
%                                 for an AlpProjStartCont sequence
%     frame_counter               frames left inside the current iteration
%     frames_per_sub_sequence     frames in one iteration (the playlist)
%   available=false (with detail) when the device or MEX build has no such
%   readback, or the controller refused it. Nothing is guessed in its place.
%
%   See also VERIFY_DMD_ADVANCE_COUNT.
arguments
    dmd
end
progress=struct("schema_version","1.0.0","available",false,"detail","", ...
    "captured_at",string(datetime("now","TimeZone","local")), ...
    "status",NaN,"current_queue_id",NaN,"sequence_id",NaN, ...
    "waiting_sequences",NaN,"sequence_counter",NaN, ...
    "sequence_counter_underflow",NaN,"frame_counter",NaN, ...
    "picture_time_us",NaN,"frames_per_sub_sequence",NaN,"flags",NaN);
if ~ismethod(dmd,"Get_Projection_Progress")
    progress.detail="This DMD (or its Luminos MEX build) has no " + ...
        "Get_Projection_Progress readback.";
    return
end
try
    raw=dmd.Get_Projection_Progress();
catch exception
    progress.detail="Get_Projection_Progress failed: "+string(exception.message);
    return
end
if ~isstruct(raw) || isempty(fieldnames(raw))
    progress.detail="Get_Projection_Progress returned nothing.";
    return
end
names=["status","current_queue_id","sequence_id","waiting_sequences", ...
    "sequence_counter","sequence_counter_underflow","frame_counter", ...
    "picture_time_us","frames_per_sub_sequence","flags"];
for name=names
    if isfield(raw,name) && isnumeric(raw.(name)) && isscalar(raw.(name))
        progress.(name)=double(raw.(name));
    end
end
required=["sequence_counter","frame_counter","frames_per_sub_sequence"];
missing=required(arrayfun(@(name)~isfinite(progress.(name)),required));
if ~isempty(missing)
    progress.detail="ALP_PROJ_PROGRESS did not report "+strjoin(missing,", ")+".";
    return
end
if isfinite(progress.status) && progress.status~=0
    progress.detail="ALP_PROJ_PROGRESS inquiry returned ALP status "+ ...
        string(progress.status)+".";
    return
end
progress.available=true;
end
