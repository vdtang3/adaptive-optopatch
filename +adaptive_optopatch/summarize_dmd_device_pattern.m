function summary=summarize_dmd_device_pattern(dmd)
%SUMMARIZE_DMD_DEVICE_PATTERN Compact description of the pattern last written.
%   Records both the pattern as written (Target) and the pattern the mirrors
%   were actually set to. Those differ on a rig that images the DMD's "off"
%   light: DMD.Device_Pattern complements the mask there, and nothing
%   upstream of it - Target, the previews, the calibration artifacts - shows
%   the difference. mirrors_on_fraction is therefore the one number that
%   distinguishes a localized stimulus from a field-wide one.
%
%   Full masks are deliberately not returned. Target is already a
%   non-transient DMD property and reaches output_data.mat through
%   Device.Build_Archive; what is missing from an archived run is the
%   scalar summary, not the pixels.
arguments
    dmd
end

summary=struct;
summary.schema_version="1.0.0";
summary.available=false;
summary.error="";
summary.size=[NaN NaN];
summary.target_on_pixels=NaN;
summary.target_on_fraction=NaN;
summary.mirrors_on_pixels=NaN;
summary.mirrors_on_fraction=NaN;
summary.bounding_box_rows=[NaN NaN];
summary.bounding_box_columns=[NaN NaN];
summary.device_pattern_source="";

try
    target=dmd.Target>.5;
catch exception
    summary.error=string(exception.message);
    return
end
if isempty(target)
    summary.error="The DMD Target is empty.";
    return
end

summary.size=size(target,1,2);
summary.target_on_pixels=nnz(target);
summary.target_on_fraction=summary.target_on_pixels/numel(target);
rows=find(any(target,2));
columns=find(any(target,1));
if ~isempty(rows)
    summary.bounding_box_rows=[rows(1) rows(end)];
    summary.bounding_box_columns=[columns(1) columns(end)];
end

% Ask the device rather than reimplementing the inversion: Device_Pattern is
% the single place it lives, and duplicating it here would be one more copy
% to fall out of step with the rig file.
mirrors=target;
summary.device_pattern_source="target_only";
try
    if ismethod(dmd,"Device_Pattern")
        mirrors=logical(dmd.Device_Pattern(target));
        summary.device_pattern_source="Device_Pattern";
    end
catch exception
    summary.error=string(exception.message);
end
summary.mirrors_on_pixels=nnz(mirrors);
summary.mirrors_on_fraction=summary.mirrors_on_pixels/numel(mirrors);
summary.available=true;
end
