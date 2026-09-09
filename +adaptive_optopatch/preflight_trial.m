function report = preflight_trial(targets, trialRow, options)
%PREFLIGHT_TRIAL Validate a planned acquisition without touching hardware.
arguments
    targets (1,1) struct
    trialRow (1,:) table
    options.RequireConfirmedLiveProtocol (1,1) logical = true
    options.LiveProtocolConfirmed (1,1) logical = false
    options.Advisories = struct([])
end
if height(trialRow)~=1
    error("adaptive_optopatch:SingleTrialRequired","Provide exactly one trial row.");
end
issues=strings(0,1);
warnings=strings(0,1);
if ~isempty(options.Advisories) && isfield(options.Advisories,"message")
    warnings=[warnings;reshape(string({options.Advisories.message}),[],1)];
end
required=["stimulation_mode","is_null","target_index","pulse_schedule"];
if ~all(ismember(required,string(trialRow.Properties.VariableNames)))
    issues(end+1)="Trial row is missing required fields.";
else
    protocol=trialRow.pulse_schedule{1};
    validation=adaptive_optopatch.validate_protocol(protocol);
    if ~validation.passed
        issues=[issues;validation.issues(:)];
    else
        try
            adaptive_optopatch.flatten_pulse_schedule( ...
                validation.protocol,"ConfiguredVoltage",1);
        catch exception
            issues(end+1)=string(exception.message);
        end
    end
    if ~trialRow.is_null && validation.passed
        events=validation.protocol.events;
        ids=string({targets.targets.cell_id});
        pulseIds=events.target_cell_id(~events.is_null);
        mode=string(trialRow.stimulation_mode);
        for id=unique(pulseIds(:))'
            idx=find(ids==id,1);
            if isempty(idx)
                issues(end+1)="Unknown target cell ID: "+id; %#ok<AGROW>
            elseif isfield(targets.targets,"stimulation_enabled") && ...
                    ~targets.targets(idx).stimulation_enabled
                issues(end+1)="Target is disabled for stimulation: "+id; %#ok<AGROW>
            elseif mode=="1p_dmd"
                maskIssue=blue_mask_issue(targets,idx,id,events);
                if maskIssue~="", issues(end+1)=maskIssue; end %#ok<AGROW>
            end
            % 2P edge-proximity and parking-point QC (spiral_qc_pass) are
            % nonblocking advisories, not execution gates: they do not
            % reflect a genuine physical/hardware impossibility. Real
            % scanner/calibration limits are enforced elsewhere (e.g.
            % validate_2p_calibration_coverage, build_2p_trial_waveforms).
        end
        if mode=="1p_dmd"
            spatial=adaptive_optopatch.collect_blue_spatial_advisories(targets,pulseIds);
            if ~isempty(spatial)
                warnings=[warnings;reshape(string({spatial.message}),[],1)]; %#ok<AGROW>
            end
        end
        defaultAdjustment=double(targets.parameters.blue_mask_adjustment_pixels);
        if mode=="1p_dmd" && (numel(unique(pulseIds))>1 || ...
                any(events.blue_mask_adjustment_pixels~=defaultAdjustment))
            try
                adaptive_optopatch.build_dmd_sequence_plan(validation.protocol,targets);
            catch exception
                issues(end+1)=string(exception.message);
            end
        end
    end
end
if options.RequireConfirmedLiveProtocol && ~options.LiveProtocolConfirmed
    warnings(end+1)="Live Luminos protocol is unconfirmed; dry-run only.";
end
if string(trialRow.stimulation_mode)=="2p_spiral"
    warnings(end+1)="Exact galvo voltage, repetition rate, and tracking checks "+ ...
        "remain pending live scanner calibration and feedback.";
end
report=struct("schema_version","0.2.0","passed",isempty(issues), ...
    "issues",issues,"warnings",unique(warnings,"stable"));
end

function issue=blue_mask_issue(targets,idx,id,events)
% Evaluate physical Blue-mask executability from the resolved per-event
% adjustment against the canonical ROI, using the same primitive applied
% at DMD execution time, rather than any bundle-level default mask.
issue="";
if ~isfield(targets,"canonical_roi_masks") || size(targets.canonical_roi_masks,3)<idx
    issue="Blue mask geometry is unavailable for target: "+id; return
end
canonicalMask=targets.canonical_roi_masks(:,:,idx);
selected=reshape(find(~events.is_null & events.target_cell_id==id),1,[]);
seenAdjustments=[];
for k=selected
    adjustment=double(events.blue_mask_adjustment_pixels(k));
    if any(seenAdjustments==adjustment), continue; end
    seenAdjustments(end+1)=adjustment; %#ok<AGROW>
    try
        adaptive_optopatch.apply_blue_mask_adjustment(canonicalMask,adjustment, ...
            "Context",sprintf("target %s, pulse %s",id,string(events.pulse_id(k))));
    catch exception
        issue=string(exception.message); return
    end
end
end
