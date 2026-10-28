function output=luminos_sampled_waveform(t,sampleRate,values,finalValue)
%LUMINOS_SAMPLED_WAVEFORM Return a precomputed vector on Luminos's timebase.
%   values(k) is the command for DAQ sample k, which Luminos evaluates at
%   t = (k-1)/sampleRate.
%
%   ROUNDED, NOT FLOORED, and the difference is not cosmetic. Luminos builds
%   its time vector with
%
%       linspace(0, (n-1)/rate, n)
%
%   and linspace lands a good fraction of those values one ulp either side
%   of the exact grid point. floor(t*rate)+1 therefore returned k for one
%   sample and k+2 for the next - duplicating a sample and dropping its
%   neighbour - for 43,116 of the 1,040,000 samples of a 5.2 s acquisition
%   at 200 kHz, which is 4% of them. Nothing noticed, because the only
%   callers were the 2P galvo and Pockels paths, where one-sample jitter on
%   a smooth trajectory looks like nothing at all.
%
%   It is not nothing: it means the commanded waveform and the delivered one
%   differed, at one sample in twenty-five, for reasons entirely internal to
%   this function. Rounding maps every on-grid t to its own sample exactly
%   and is no worse off-grid, where the nearest sample is the right answer
%   anyway.
%
%   Samples outside the vector take finalValue, which is how a waveform
%   shorter than the acquisition holds its declared level afterwards.
arguments
    t double
    sampleRate (1,1) double {mustBePositive}
    values (:,1) double
    finalValue (1,1) double = 0
end
indices=round(double(t)*sampleRate)+1;
output=repmat(finalValue,size(indices));
valid=indices>=1 & indices<=numel(values);
output(valid)=values(indices(valid));
end
