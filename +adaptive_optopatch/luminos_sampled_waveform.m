function output=luminos_sampled_waveform(t,sampleRate,values,finalValue)
%LUMINOS_SAMPLED_WAVEFORM Return a precomputed vector on Luminos's timebase.
arguments
    t double
    sampleRate (1,1) double {mustBePositive}
    values (:,1) double
    finalValue (1,1) double = 0
end
indices=floor(double(t)*sampleRate)+1;
output=repmat(finalValue,size(indices));
valid=indices>=1 & indices<=numel(values);
output(valid)=values(indices(valid));
end
