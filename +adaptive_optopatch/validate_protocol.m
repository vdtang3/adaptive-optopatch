function report=validate_protocol(value)
%VALIDATE_PROTOCOL Validate a schema-3 definition or resolved acquisition.
arguments
    value (1,1) struct
end
issues=strings(0,1); protocol=struct([]);
try
    protocol=adaptive_optopatch.normalize_protocol(value);
    if string(protocol.artifact_type)=="experiment_definition"
        issues=[issues;validate_parameter_shapes(protocol.parameters,"protocol")];
        for k=1:numel(protocol.acquisitions)
            issues=[issues;validate_events(protocol.acquisitions(k).events,false)]; %#ok<AGROW>
            issues=[issues;validate_parameter_scopes(protocol.acquisitions(k))]; %#ok<AGROW>
            issues=[issues;validate_parameter_shapes( ...
                protocol.acquisitions(k).parameters,"acquisition")]; %#ok<AGROW>
        end
    else
        issues=validate_events(protocol.events,true);
        issues=[issues;validate_resolved_parameters(protocol.parameters)];
    end
catch exception
    issues=string(exception.message);
end

issues=unique(issues(strlength(issues)>0),"stable");
report=struct("schema_version","3.0.0","passed",isempty(issues), ...
    "issues",issues,"protocol",protocol);
end

function issues=validate_parameter_shapes(parameters,scope)
issues=strings(0,1);
metadata=adaptive_optopatch.protocol_parameter_metadata();
for k=1:numel(metadata)
    name=string(metadata(k).name);
    if isfield(parameters,name) && ...
            (~isnumeric(parameters.(name)) || ~isscalar(parameters.(name)))
        issues(end+1)=scope+"-level parameter "+name+ ...
            " must be a scalar. Vectors never create acquisition boundaries; "+ ...
            "define separate acquisition entries explicitly."; %#ok<AGROW>
    end
end
end

function issues=validate_events(events,resolved)
issues=strings(0,1); onset=events.onset_s; duration=events.duration_s;
if isempty(events), issues(end+1)="Every acquisition requires at least one event."; return; end
if numel(unique(events.pulse_id))~=height(events)
    issues(end+1)="Pulse IDs must be unique within an acquisition.";
end
if any(strlength(strip(events.condition_id))==0)
    issues(end+1)="Condition IDs must be nonempty.";
end
if resolved || all(isfinite(onset))
    if any(~isfinite(onset) | onset<0), issues(end+1)="Pulse onsets must be finite and nonnegative."; end
    [sorted,index]=sort(onset); finish=sorted+duration(index);
    if numel(sorted)>1 && any(sorted(2:end)<finish(1:end-1)-1e-12)
        issues(end+1)="Protocol pulses overlap in time.";
    end
end
if any(isfinite(duration) & duration<=0)
    issues(end+1)="Pulse durations must be positive when specified.";
end
if resolved
    nonNull=~events.is_null;
    if any(strlength(events.target_cell_id(nonNull))==0)
        issues(end+1)="Resolved pulses require literal target cell IDs.";
    end
    if any(~isfinite(events.command_voltage_v(nonNull)) | ...
            events.command_voltage_v(nonNull)<=0 | ...
            events.command_voltage_v(nonNull)>5)
        issues(end+1)="Resolved non-null command voltages must lie in (0,5] V.";
    end
    if any(~isfinite(duration) | duration<=0)
        issues(end+1)="Resolved pulse durations must be positive and finite.";
    end
    if any(~isfinite(events.target_index(nonNull)) | ...
            events.target_index(nonNull)<1 | ...
            fix(events.target_index(nonNull))~=events.target_index(nonNull))
        issues(end+1)="Resolved non-null target indices must be positive integers.";
    end
    if any(events.target_index(events.is_null)~=0)
        issues(end+1)="Resolved null events must use target index zero.";
    end
    adjustment=events.blue_mask_adjustment_pixels;
    if any(~isfinite(adjustment) | fix(adjustment)~=adjustment)
        issues(end+1)="Resolved Blue DMD-mask adjustments must be finite integers.";
    end
end
end

function issues=validate_resolved_parameters(parameters)
issues=strings(0,1);
if ~isfield(parameters,"orange_expansion_pixels") || ...
        ~isfinite(parameters.orange_expansion_pixels) || ...
        parameters.orange_expansion_pixels<0 || ...
        fix(parameters.orange_expansion_pixels)~=parameters.orange_expansion_pixels
    issues(end+1)="Resolved Orange DMD-mask expansion must be a nonnegative integer.";
end
for name=["spiral_radius_um","spiral_density_points_per_volt"]
    if ~isfield(parameters,name) || ~isfinite(parameters.(name)) || ...
            parameters.(name)<=0
        issues(end+1)="Resolved "+replace(name,"_"," ")+ ...
            " must be positive and finite."; %#ok<AGROW>
    end
end
end

function issues=validate_parameter_scopes(acquisition)
issues=strings(0,1);
names=string(acquisition.events.Properties.VariableNames);
for name=["orange_expansion_pixels","spiral_radius_um", ...
        "spiral_density_points_per_volt"]
    if ismember(name,names)
        values=double(acquisition.events.(name));
        if any(isfinite(values))
            issues(end+1)=scope_message(name); %#ok<AGROW>
        end
    end
end
end

function value=scope_message(name)
labels=struct("orange_expansion_pixels","Orange DMD mask expansion", ...
    "spiral_radius_um","2P spiral radius", ...
    "spiral_density_points_per_volt","2P spiral density");
value=labels.(name)+" cannot vary within one acquisition. "+ ...
    "Define separate acquisition entries explicitly.";
end
