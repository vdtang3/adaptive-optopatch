function y=luminos_round_waveform(t,sampleRate,roundStartSample, ...
        segmentSamples,segmentValues,roundCount,baselineValue)
%LUMINOS_ROUND_WAVEFORM One round of piecewise-constant samples, repeated.
%   y=LUMINOS_ROUND_WAVEFORM(t,rate,start,samples,values,rounds,baseline)
%   is the Luminos wavefile for blanket-depolarization outputs. One round is
%   described compactly as consecutive segments (samples(k) DAQ samples at
%   values(k)); it starts at DAQ sample `start` and repeats `rounds` times
%   back to back. Outside those rounds the output is `baseline`.
%
%   Indexing is by SAMPLE, not by comparing seconds: t is Luminos's uniform
%   time vector, so round(t*rate) is the exact 0-based sample index and a
%   boundary can never move by a sample through floating-point error. Both
%   blanket outputs - mod488 and the DMD trigger - are built from the same
%   state table and evaluated here, so they share every boundary.
arguments
    t double
    sampleRate (1,1) double {mustBePositive}
    roundStartSample (1,1) double {mustBeNonnegative,mustBeInteger}
    segmentSamples (:,1) double {mustBePositive,mustBeInteger}
    segmentValues (:,1) double
    roundCount (1,1) double {mustBePositive,mustBeInteger}
    baselineValue (1,1) double = 0
end
if numel(segmentSamples)~=numel(segmentValues)
    error("adaptive_optopatch:RoundWaveformSizeMismatch", ...
        "Every round segment needs exactly one value.");
end
roundValues=repelem(segmentValues,segmentSamples);
roundSamples=numel(roundValues);
sample=round(double(t)*sampleRate);
y=repmat(baselineValue,size(sample));
relative=sample-roundStartSample;
inside=relative>=0 & relative<roundCount*roundSamples;
y(inside)=roundValues(mod(relative(inside),roundSamples)+1);
end
