function y = luminos_event_waveform(t,onset_s,offset_s,amplitude_v,baseline_v)
%LUMINOS_EVENT_WAVEFORM Sample an explicitly timed pulse list for Luminos.
if nargin<5 || isempty(baseline_v), baseline_v=0; end
t=double(t(:)');
onset_s=double(onset_s(:)); offset_s=double(offset_s(:));
amplitude_v=double(amplitude_v(:));
if numel(onset_s)~=numel(offset_s) || numel(onset_s)~=numel(amplitude_v)
    error("adaptive_optopatch:PulseVectorSizeMismatch", ...
        "Onset, offset, and amplitude vectors must have the same length.");
end
y=baseline_v*ones(size(t));
if isempty(t), return; end
% Luminos supplies an increasing, uniformly sampled time vector. Locate the
% two half-open boundaries with comparisons against that actual vector, not
% rounded seconds-to-sample arithmetic: this is sample-exact with
% t>=onset & t<offset even for sub-sample and floating-point boundaries.
% Each event then touches only the samples it writes.
if any(diff(t)<0)
    % Preserve the historical semantics for an unexpected nonmonotonic
    % caller; the acquisition path never takes this compatibility branch.
    for k=1:numel(onset_s)
        y(t>=onset_s(k) & t<offset_s(k))=amplitude_v(k);
    end
    y(end)=baseline_v;
    return
end
for k=1:numel(onset_s)
    if isnan(onset_s(k)) || isnan(offset_s(k)) || onset_s(k)>=offset_s(k)
        continue
    end
    first=lower_bound(t,onset_s(k));
    after=lower_bound(t,offset_s(k));
    if first<after
        y(first:after-1)=amplitude_v(k);
    end
end
y(end)=baseline_v;
end

function index=lower_bound(values,boundary)
% First index whose value is >= boundary, or numel(values)+1.
low=1;
high=numel(values)+1;
while low<high
    middle=floor((low+high)/2);
    if middle<=numel(values) && values(middle)<boundary
        low=middle+1;
    else
        high=middle;
    end
end
index=low;
end
