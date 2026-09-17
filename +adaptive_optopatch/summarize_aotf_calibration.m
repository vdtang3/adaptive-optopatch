function summary=summarize_aotf_calibration(aotf_voltage_V,power_mW,area_mm2)
%SUMMARIZE_AOTF_CALIBRATION Group power readings into an AOTF irradiance curve.
%   Every reading is converted to an irradiance individually and kept, then
%   grouped by commanded voltage. Averaging the power first and discarding the
%   readings would throw away the only estimate of measurement spread there is.
%
%   No functional form is assumed. An AOTF's optical response is usually
%   strongly nonlinear, so the curve is interpolated (shape-preserving PCHIP)
%   rather than fitted, and never extrapolated: a query outside the measured
%   voltage range returns NaN instead of a plausible-looking guess.
%
%   The inverse lookup exists only when the mean irradiance is STRICTLY
%   increasing with voltage. A non-monotonic curve has no unique inverse, and
%   sorting by irradiance to manufacture one would hide exactly the thing worth
%   looking at - noise, AOTF behaviour, or a calibration problem.
%
%   SD is the sample standard deviation, and is NaN where N is 1: one reading
%   carries no information about reproducibility, and reporting 0 would claim
%   that it does.
%
%   Called with two empty vectors it returns an empty summary, so the caller can
%   run the footprint half of the workflow on its own.
arguments
    aotf_voltage_V double
    power_mW double
    area_mm2 (1,1) double {mustBePositive,mustBeFinite}
end

summary=empty_summary();

haveVoltage=~isempty(aotf_voltage_V);
havePower=~isempty(power_mW);
if ~haveVoltage && ~havePower
    return
end
if haveVoltage~=havePower
    error("adaptive_optopatch:IncompleteAotfMeasurements", ...
        "AOTF_V and Power_mW must be supplied together; got %d voltages and " + ...
        "%d power readings.",numel(aotf_voltage_V),numel(power_mW));
end

voltage=double(aotf_voltage_V(:));
power=double(power_mW(:));

if numel(voltage)~=numel(power)
    error("adaptive_optopatch:AotfMeasurementLengthMismatch", ...
        "AOTF_V has %d elements but Power_mW has %d. Each element is one " + ...
        "power-meter reading at one commanded voltage.", ...
        numel(voltage),numel(power));
end
if ~all(isfinite(voltage))
    error("adaptive_optopatch:NonFiniteAotfVoltage", ...
        "AOTF_V contains NaN or Inf.");
end
if ~all(isfinite(power))
    error("adaptive_optopatch:NonFiniteAotfPower", ...
        "Power_mW contains NaN or Inf.");
end
if any(power<0)
    error("adaptive_optopatch:NegativeAotfPower", ...
        "Power_mW contains negative values; a power-meter reading cannot be " + ...
        "negative.");
end

% Every reading, converted on its own and kept.
irradiance=power/area_mm2;

% unique() matches exactly rather than within a tolerance: a commanded setpoint
% is a number the operator typed, and merging nearby ones would silently
% combine two distinct points. Sorted ascending by voltage.
uniqueVoltage=unique(voltage,"sorted");
n=numel(uniqueVoltage);
counts=zeros(n,1);
meanPower=zeros(n,1);
sdPower=nan(n,1);
meanIrradiance=zeros(n,1);
sdIrradiance=nan(n,1);

for k=1:n
    atThisVoltage=voltage==uniqueVoltage(k);
    counts(k)=nnz(atThisVoltage);
    meanPower(k)=mean(power(atThisVoltage));
    meanIrradiance(k)=mean(irradiance(atThisVoltage));
    if counts(k)>1
        sdPower(k)=std(power(atThisVoltage));
        sdIrradiance(k)=std(irradiance(atThisVoltage));
    end
end

summary.available=true;
summary.aotf_voltage_V=voltage;
summary.power_mW=power;
summary.irradiance_mW_mm2=irradiance;
summary.voltage_V=uniqueVoltage;
summary.n_per_voltage=counts;
summary.mean_power_mW=meanPower;
summary.std_power_mW=sdPower;
summary.mean_irradiance_mW_mm2=meanIrradiance;
summary.std_irradiance_mW_mm2=sdIrradiance;

summary.calibration_table=table(uniqueVoltage,counts,meanPower,sdPower, ...
    meanIrradiance,sdIrradiance, ...
    'VariableNames',{'AOTF_V','N','MeanPower_mW','SDPower_mW', ...
    'MeanIrradiance_mW_mm2','SDIrradiance_mW_mm2'});

% One point is a measurement, not a curve.
if n<2
    summary.monotonic=false;
    summary.monotonicity_note="Only one commanded voltage was measured, so " + ...
        "there is no curve to interpolate.";
    return
end

summary.irradiance_at_voltage=@(v) ...
    interp1(uniqueVoltage,meanIrradiance,v,"pchip",NaN);

summary.monotonic=all(diff(meanIrradiance)>0);
if summary.monotonic
    summary.voltage_for_irradiance=@(I) ...
        interp1(meanIrradiance,uniqueVoltage,I,"pchip",NaN);
    summary.monotonicity_note="";
else
    summary.monotonicity_note="Mean irradiance is not strictly increasing " + ...
        "with AOTF voltage, so it has no unique inverse.";
    warning("adaptive_optopatch:NonMonotonicAotfCalibration", ...
        "%s The irradiance -> voltage lookup is therefore unavailable. The " + ...
        "raw readings are preserved in the result; inspect them for noise, " + ...
        "AOTF behaviour, or a calibration problem.",summary.monotonicity_note);
end
end


function summary=empty_summary()
summary=struct( ...
    "available",false, ...
    "aotf_voltage_V",[], ...
    "power_mW",[], ...
    "irradiance_mW_mm2",[], ...
    "voltage_V",[], ...
    "n_per_voltage",[], ...
    "mean_power_mW",[], ...
    "std_power_mW",[], ...
    "mean_irradiance_mW_mm2",[], ...
    "std_irradiance_mW_mm2",[], ...
    "calibration_table",table(), ...
    "monotonic",false, ...
    "monotonicity_note","", ...
    "irradiance_at_voltage",[], ...
    "voltage_for_irradiance",[]);
end
