function value=representative_pulse_duration_ms(protocol,fallbackMs)
%REPRESENTATIVE_PULSE_DURATION_MS The one pulse duration previews and plans size by.
%   value=REPRESENTATIVE_PULSE_DURATION_MS(protocol,fallbackMs) returns the
%   duration, in milliseconds, that a target bundle should be built for when
%   a protocol contains events of more than one length.
%
%   THE SHORTEST LIGHT EVENT, and that is the whole rule.
%
%   It has to be the shortest because the number it sizes is a 2P spiral
%   cycle count: a spiral built for a 20 ms pulse cannot complete inside a
%   10 ms one, so sizing by anything longer produces geometry the shortest
%   pulse in the protocol cannot execute. The shortest is feasible for every
%   pulse.
%
%   ONE IMPLEMENTATION, because there were two and they disagreed. buildPlan
%   already used the minimum - so the PLAN, the thing that actually runs, was
%   correct - while currentPulseDurationMs used `durations(1)`, the first
%   event in the first acquisition. Every preview goes through the second
%   one. With a non-uniform protocol the operator therefore aimed with
%   spiral geometry built at one duration and ran geometry built at another,
%   with nothing on screen to say so.
%
%   `fallbackMs` is returned when the protocol schedules no light at all -
%   an all-null protocol, or a scheduler-backed definition whose template
%   event carries no finite duration. The caller owns that default because
%   the sensible one differs: the planner has no editable value to fall back
%   to, and the preview has the GUI's pulse_duration_ms.
%
%   Orientation-independent: acquisitions may be 1xN or Nx1.
%
%   See also BUILD_TARGET_PREVIEW, which applies the same minimum rule to a
%   RESOLVED acquisition's events, where the durations are already literal.
arguments
    protocol
    fallbackMs (1,1) double
end
value=fallbackMs;
if isempty(protocol), return; end
if isfield(protocol,"acquisitions")
    durations=light_durations(protocol.acquisitions);
elseif isfield(protocol,"events")
    durations=light_durations(protocol);
else
    return
end
if isempty(durations), return; end
value=1000*min(durations);
end

function durations=light_durations(acquisitions)
durations=[];
for index=1:numel(acquisitions)
    events=acquisitions(index).events;
    selected=~events.is_null & isfinite(events.duration_s);
    durations=[durations;events.duration_s(selected)]; %#ok<AGROW>
end
end
