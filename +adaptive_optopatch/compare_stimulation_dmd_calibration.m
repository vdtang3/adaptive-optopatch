function report=compare_stimulation_dmd_calibration(dmd,targets)
%COMPARE_STIMULATION_DMD_CALIBRATION Frozen vs live Blue camera-to-DMD map.
%   A 1P run projects frozen camera-space masks through whatever transform
%   the DMD currently holds, because that transform lives on the device and
%   is applied inside Luminos's setPatterningROI. Recalibrating DMD_Blue
%   between planning and execution therefore moves where a frozen mask
%   lands. Consistent with the 2P policy, an active-vs-frozen calibration
%   difference is recorded rather than treated as an execution gate: it is
%   often a legitimate recalibration, and the archived comparison is what
%   makes the run reproducible after the fact.
arguments
    dmd
    targets (1,1) struct
end
report=struct("schema_version","1.0.0","comparable",false,"matched",false, ...
    "maximum_element_difference",NaN,"detail","");
planned=[];
if isfield(targets,"stimulation_dmd_transform")
    planned=targets.stimulation_dmd_transform;
end
if isempty(planned)
    report.detail="The planning bundle archived no Blue camera-to-DMD transform.";
    return
end
live=[];
try
    live=dmd.tform;
catch
end
if isempty(live)
    report.detail="The live DMD reports no camera-to-DMD transform.";
    return
end
plannedMatrix=transform_matrix(planned);
liveMatrix=transform_matrix(live);
if isempty(plannedMatrix) || isempty(liveMatrix) || ...
        ~isequal(size(plannedMatrix),size(liveMatrix))
    report.detail="The archived and live transforms are not directly comparable.";
    return
end
report.comparable=true;
report.maximum_element_difference=max(abs(plannedMatrix-liveMatrix),[],"all");
report.matched=report.maximum_element_difference<=1e-9;
if ~report.matched
    report.detail=sprintf(['DMD_Blue has been recalibrated since this plan ' ...
        'was built (maximum transform difference %.6g). The frozen masks ' ...
        'are projected through the current calibration.'], ...
        report.maximum_element_difference);
end
end

function matrix=transform_matrix(tform)
matrix=[];
if isa(tform,"affinetform2d") || isa(tform,"projtform2d")
    matrix=double(tform.A);
elseif isa(tform,"affine2d") || isa(tform,"projective2d")
    matrix=double(tform.T)';
elseif isnumeric(tform)
    matrix=double(tform);
end
end
