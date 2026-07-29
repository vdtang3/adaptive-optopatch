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
for k=1:numel(onset_s)
    y(t>=onset_s(k) & t<offset_s(k))=amplitude_v(k);
end
if ~isempty(y), y(end)=baseline_v; end
end
