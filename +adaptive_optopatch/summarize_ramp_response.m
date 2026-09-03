function summary=summarize_ramp_response(protocol,spikeCount,neighborSpikeCount,firstSpikeLatencyMs)
%SUMMARIZE_RAMP_RESPONSE Aggregate operator-reviewed ramp pulse outcomes.
arguments
    protocol (1,1) struct
    spikeCount (:,1) double {mustBeNonnegative,mustBeInteger}
    neighborSpikeCount (:,1) double {mustBeNonnegative,mustBeInteger}
    firstSpikeLatencyMs (:,1) double = nan(size(spikeCount))
end
pulses=adaptive_optopatch.flatten_pulse_schedule(protocol);
n=height(pulses);
if numel(spikeCount)~=n || numel(neighborSpikeCount)~=n || numel(firstSpikeLatencyMs)~=n
    error("adaptive_optopatch:RampReviewSizeMismatch", ...
        "Ramp review vectors must have one value per physical pulse.");
end
levels=unique(pulses.command_voltage_v,"stable"); summary=table;
for k=1:numel(levels)
    selected=pulses.command_voltage_v==levels(k);
    voltage=levels(k); trialCount=sum(selected);
    zeroSpikeFraction=mean(spikeCount(selected)==0);
    oneSpikeFraction=mean(spikeCount(selected)==1);
    multiSpikeFraction=mean(spikeCount(selected)>1);
    neighborSpikeFraction=mean(neighborSpikeCount(selected)>0);
    latencies=firstSpikeLatencyMs(selected & spikeCount>0);
    medianFirstSpikeLatencyMs=median(latencies,"omitnan");
    row=table(voltage,trialCount,zeroSpikeFraction,oneSpikeFraction, ...
        multiSpikeFraction,neighborSpikeFraction,medianFirstSpikeLatencyMs, ...
        'VariableNames',{'command_voltage_v','trial_count','zero_spike_fraction', ...
        'exactly_one_spike_fraction','multi_spike_fraction', ...
        'neighbor_spike_fraction','median_first_spike_latency_ms'});
    summary=[summary;row]; %#ok<AGROW>
end
end
