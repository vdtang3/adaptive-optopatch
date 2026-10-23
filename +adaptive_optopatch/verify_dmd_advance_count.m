function report=verify_dmd_advance_count(armed,final,expectedAdvances,playlistLength)
%VERIFY_DMD_ADVANCE_COUNT Did the DMD advance once per trigger, no more, no less?
%   report=VERIFY_DMD_ADVANCE_COUNT(armed,final,expected,playlistLength)
%   compares two READ_DMD_PROJECTION_PROGRESS readings - taken after the
%   playlist was armed and after the acquisition finished - with the number
%   of DMD triggers the state table emitted.
%
%   WHY. A blanket playlist wraps one round. If one edge is lost or doubled
%   the DMD stays shifted against mod488 for every later state, which can put
%   a target's Vstim on the blanket union mask. A wrong count makes the
%   acquisition invalid; status says which way.
%
%   COUNTER MODEL ("alp_frames_left_v1"). ALP reports frames LEFT in the
%   current iteration and iterations LEFT, both counting down:
%
%       advances = iterationsElapsed x framesPerIteration
%                  + (armed.frame_counter - final.frame_counter)
%       iterationsElapsed = armed.sequence_counter - final.sequence_counter
%                           (mod 2^32: it underflows for AlpProjStartCont)
%
%   The model is self-consistent whether the ALP reports the end of an
%   iteration as "0 frames left" or as "a full iteration left, one fewer
%   iteration". What it cannot know is whether arming already counts as a
%   displayed frame; counter_model_commissioned stays false until a
%   fluorescent-slide run with a known trigger count confirms the model on
%   the VU controller. Raw readings are archived either way.
%
%   status: "matched", "mismatched", or "unavailable" (no readback; the
%   acquisition is then UNVERIFIED, not valid).
arguments
    armed (1,1) struct
    final (1,1) struct
    expectedAdvances (1,1) double {mustBeNonnegative,mustBeInteger}
    playlistLength (1,1) double {mustBePositive,mustBeInteger}
end
report=struct("schema_version","1.0.0", ...
    "counter_model","alp_frames_left_v1", ...
    "counter_model_commissioned",false, ...
    "expected_advance_count",expectedAdvances, ...
    "playlist_length",playlistLength, ...
    "reported_advance_count",NaN, ...
    "reported_frames_per_iteration",NaN, ...
    "matched",false,"status","unavailable","detail","", ...
    "armed",armed,"final",final);
if ~armed.available || ~final.available
    parts=strings(0,1);
    if ~armed.available, parts(end+1)="armed: "+string(armed.detail); end
    if ~final.available, parts(end+1)="final: "+string(final.detail); end
    report.detail=strjoin(parts,"; ");
    return
end
framesPerIteration=final.frames_per_sub_sequence;
report.reported_frames_per_iteration=framesPerIteration;
iterations=mod(armed.sequence_counter-final.sequence_counter,2^32);
report.reported_advance_count=iterations*framesPerIteration+ ...
    (armed.frame_counter-final.frame_counter);
report.matched=framesPerIteration==playlistLength && ...
    report.reported_advance_count==expectedAdvances;
if report.matched
    report.status="matched";
    return
end
report.status="mismatched";
if framesPerIteration~=playlistLength
    report.detail=sprintf("The ALP iterates %d frames, but the programmed " + ...
        "playlist has %d.",framesPerIteration,playlistLength);
else
    report.detail=sprintf("The DAQ emitted %d DMD triggers, but the ALP " + ...
        "counters account for %d advances (%+d).",expectedAdvances, ...
        report.reported_advance_count, ...
        report.reported_advance_count-expectedAdvances);
end
end
