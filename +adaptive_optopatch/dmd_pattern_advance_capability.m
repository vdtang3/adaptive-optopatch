function capability=dmd_pattern_advance_capability(dmd)
%DMD_PATTERN_ADVANCE_CAPABILITY Read the DMD's own minimum picture time.
%   In ALP_SLAVE_VD mode the loaded sequence advances one picture per external
%   trigger, and the ALP's ALP_MIN_PICTURE_TIME is defined as the minimum time
%   between the start of consecutive pictures. Luminos programs exactly that
%   value into the sequence in Write_Stack, so it is the authoritative lower
%   bound on the externally triggered pattern-advance interval for the stack
%   that is loaded. Triggers arriving faster are not honored, which would
%   illuminate a cell through the previous pulse's mask.
%
%   The value is a property of the allocated sequence (it depends on the
%   picture count and data format), so query it after the stack is written.
%   No constant is invented: when the device does not report the capability,
%   minimum_picture_time_s is NaN and the caller records that the interval
%   could not be validated.
arguments
    dmd
end
capability=struct("schema_version","1.0.0", ...
    "minimum_picture_time_s",NaN,"source","unavailable","detail","");

% An explicitly declared capability wins, so a rig profile or test backend can
% state the number its hardware documentation gives.
declared=read_member(dmd,"minimum_picture_time_us");
if is_positive_scalar(declared)
    capability.minimum_picture_time_s=double(declared)*1e-6;
    capability.source="declared_minimum_picture_time_us";
    return
end

api=read_member(dmd,"api");
sequence=read_member(dmd,"seq");
if isempty(api) || isempty(sequence)
    capability.detail="The DMD does not expose an ALP sequence to inquire.";
    return
end
try
    [~,pictureTimeUs]=sequence.inquire(api.MIN_PICTURE_TIME);
catch exception
    capability.detail="ALP_MIN_PICTURE_TIME inquiry failed: "+string(exception.message);
    return
end
if ~is_positive_scalar(pictureTimeUs)
    capability.detail="The ALP reported no usable ALP_MIN_PICTURE_TIME.";
    return
end
capability.minimum_picture_time_s=double(pictureTimeUs)*1e-6;
capability.source="alp_sequence_min_picture_time";
end

function value=read_member(object,name)
value=[];
try
    if isstruct(object) && isfield(object,name)
        value=object.(name);
    elseif isobject(object) && isprop(object,name)
        value=object.(name);
    end
catch
end
end

function tf=is_positive_scalar(value)
tf=isnumeric(value) && isscalar(value) && isfinite(double(value)) && double(value)>0;
end
