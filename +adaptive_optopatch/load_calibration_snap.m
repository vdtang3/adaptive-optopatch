function snap=load_calibration_snap(snapPath)
%LOAD_CALIBRATION_SNAP Load a Luminos snap that carries a physical camera scale.
%   Only snaps taken after Luminos gained the empirical XY spatial calibration
%   carry snap.pixel_to_sample_um, and only those can be turned into a physical
%   area. Anything older fails here rather than downstream, because the
%   alternative - substituting a pixel pitch, a nominal magnification, an
%   identity, or Adaptive Optopatch's own typed 0.35 um/pixel - would turn a
%   missing measurement into a confident wrong irradiance.
arguments
    snapPath (1,1) string
end

if ~isfile(snapPath)
    error("adaptive_optopatch:MissingCalibrationSnap", ...
        "Snap file not found: %s",snapPath);
end
[~,~,extension]=fileparts(snapPath);
if ~strcmpi(extension,".mat")
    error("adaptive_optopatch:CalibrationSnapMatRequired", ...
        "Select the .mat written by the Luminos Snap button, not %s. " + ...
        "The TIFF carries no calibration.",extension);
end

loaded=load(snapPath,"snap");
if ~isfield(loaded,"snap") || ~isscalar(loaded.snap) || ...
        ~(isstruct(loaded.snap) || isobject(loaded.snap))
    error("adaptive_optopatch:InvalidCalibrationSnap", ...
        "%s does not contain a scalar Luminos 'snap'.",snapPath);
end
snap=loaded.snap;

if ~has_member(snap,"img") || isempty(snap.img) || ~isnumeric(snap.img)
    error("adaptive_optopatch:InvalidCalibrationSnapImage", ...
        "snap.img must be a nonempty numeric image.");
end

% Absent and empty are the same answer: a snap written before the field existed
% and a snap taken from an uncalibrated camera are equally unusable here.
if ~has_member(snap,"pixel_to_sample_um") || isempty(snap.pixel_to_sample_um)
    error("adaptive_optopatch:SnapHasNoPhysicalCalibration", ...
        "This snap does not contain a physical camera calibration.\n" + ...
        "Re-run the Luminos XY spatial calibration and take a new snap.");
end

J=double(snap.pixel_to_sample_um);
if ~isequal(size(J),[2 2]) || ~all(isfinite(J(:)))
    error("adaptive_optopatch:BadSnapPhysicalCalibration", ...
        "snap.pixel_to_sample_um must be a finite 2x2 matrix.");
end
if abs(det(J))<=0
    error("adaptive_optopatch:SingularSnapPhysicalCalibration", ...
        "snap.pixel_to_sample_um is singular, so every footprint would have " + ...
        "zero area. The snap needs a recalibrated camera.");
end
end


% isprop for a CL_RefImage, isfield for the struct a snap .mat degrades into
% when that class is not on the MATLAB path.
function tf=has_member(value,name)
tf=(isobject(value) && isprop(value,name)) || ...
    (isstruct(value) && isfield(value,name));
end
