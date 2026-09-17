function report=account_stimulation_outputs(globalProps,wfmData,options)
%ACCOUNT_STIMULATION_OUTPUTS Measure what a candidate waveform would output.
%   report=ACCOUNT_STIMULATION_OUTPUTS(globalProps,wfmData) compiles the
%   waveform configuration AO is about to install, terminal by physical
%   terminal, and says of each one what it is: a stimulation output AO is
%   commanding, a stimulation output holding its declared neutral, imaging
%   infrastructure AO deliberately inherits, infrastructure Luminos will
%   add itself, or something nothing has accounted for.
%
%   The neutral check is measured, not asserted. Every AO-owned terminal is
%   evaluated over the acquisition's own time vector and every sample is
%   compared against the value the rig manifest declares safe. A record
%   that merely looks like a zero constant is not evidence; the samples
%   that would reach the wire are.
%
%   What the code can prove unsafe, it reports as a violation whatever the
%   policy:
%     - two records resolving to one AO-owned physical terminal
%     - a record on an AO-owned terminal in a camera-triggered subsystem
%     - and, once a Modality has been given: an AO-owned stimulation
%       terminal driven by a record AO does not own, or a buffered record
%       on a line the manifest says that modality drives imperatively or
%       suppresses from the run entirely
%   The last two need a modality because who SHOULD own a line is a
%   question about the run that is about to happen. Modality "unknown" is
%   an ambient survey of the operator's own configuration, where a live
%   mod488 record is what AO is about to replace rather than a fault;
%   those findings become report.observations instead.
%
%   What it merely does not recognise, it reports as unaccounted, and
%   whether that blocks is the policy's decision:
%     report_only  unaccounted terminals warn. Pass 3A's real-rig default,
%                  because the VU's ambient configuration has not been
%                  surveyed yet and guessing a classification to make this
%                  pass would be the opposite of safe.
%     fail_closed  unaccounted terminals block too. Correct once the
%                  manifest is complete, and not before.
%
%   Nothing here is ever silently dropped: a terminal that fits no
%   declaration still appears in report.terminals with its records named.
arguments
    globalProps (1,1) struct
    wfmData (1,1) struct
    options.Manifest (1,1) struct = ...
        adaptive_optopatch.virtual_upright_stimulation_manifest()
    options.Policy (1,1) string {mustBeMember(options.Policy, ...
        ["report_only","fail_closed"])} = "report_only"
    options.Modality (1,1) string {mustBeMember(options.Modality, ...
        ["1p_dmd","2p_spiral","mixed","unknown"])} = "unknown"
    options.Context (1,1) string = ""
    options.NeutralToleranceV (1,1) double {mustBeNonnegative} = 1e-9
end
manifest=options.Manifest;
aliasList=manifest.alias_list;
owner=adaptive_optopatch.script_owner_tag();

rows=empty_rows();
violations=strings(0,1);
observations=strings(0,1);

for subsystem=["ao","do"]
    if ~isfield(wfmData,subsystem), continue; end
    records=wfmData.(subsystem);
    if isempty(records), continue; end
    terminals=adaptive_optopatch.compile_output_samples( ...
        globalProps,records,aliasList);
    for t=1:numel(terminals)
        [row,rowViolations,rowObservations]=classify_terminal( ...
            terminals(t),records,subsystem,manifest,options,owner,terminals);
        rows(end+1)=row; %#ok<AGROW>
        violations=[violations;rowViolations]; %#ok<AGROW>
        observations=[observations;rowObservations]; %#ok<AGROW>
    end
end

% The camera-triggered subsystems are Luminos's, driven from camera
% feedback rather than the acquisition clock. AO never writes to them, so a
% record there on a terminal AO owns is not something AO can reason about -
% only something it must refuse to run past.
for subsystem=["ao_camera_triggered","do_camera_triggered"]
    if ~isfield(wfmData,subsystem), continue; end
    records=wfmData.(subsystem);
    for k=1:numel(records)
        entry=match_declaration(record_terminals(records(k)),manifest,aliasList);
        if entry.classification~="ao_owned_stimulation", continue; end
        violations(end+1)=sprintf( ...
            ['%s drives the AO-owned stimulation terminal %s (%s) from the ' ...
             '%s subsystem, which adaptive_optopatch does not control and ' ...
             'cannot make neutral.'],record_label(records(k)), ...
            entry.terminal,entry.role,subsystem); %#ok<AGROW>
    end
end

declared=declared_coverage(manifest,rows,options.Modality,aliasList);
unaccounted=rows(strcmp_class(rows,"unaccounted"));

report=struct;
report.schema_version="1.0.0";
report.created_at=string(datetime("now","TimeZone","local"));
report.context=options.Context;
report.modality=options.Modality;
report.policy=options.Policy;
report.manifest_schema_version=manifest.schema_version;
report.rig_name=manifest.rig_name;
report.script_owner=owner;
report.sample_rate_hz=double(globalProps.rate);
report.duration_s=double(globalProps.total_time);
report.sample_count=round(double(globalProps.total_time)*double(globalProps.rate));
report.terminals=struct2table_safe(rows);
report.declared=declared;
report.violations=unique(violations,"stable");
report.unaccounted_terminals=reshape( ...
    string([unaccounted.canonical_terminal]),[],1);
report.unaccounted_detail=struct2table_safe(unaccounted);
report.warnings=unaccounted_warnings(unaccounted,manifest);
report.observations=unique(observations,"stable");
report.blocking=report.violations;
if options.Policy=="fail_closed"
    report.blocking=[report.violations;report.warnings];
end
report.passed=isempty(report.blocking);
end

% -------------------------------------------------------------------------

function [row,violations,observations]=classify_terminal(terminal,records, ...
        subsystem,manifest,options,owner,allTerminals)
violations=strings(0,1);
observations=strings(0,1);
% Who SHOULD own a line is a question about the run that is about to
% happen. An ambient survey has no modality, so it can still say what every
% terminal would output but cannot call the operator's own waveform a
% violation: before AO builds anything, a live mod488 record is simply the
% configuration AO is going to replace. Those findings become observations.
%   Duplicates and collisions are not affected: two records on one physical
% terminal produce a waveform neither of them describes whoever wrote them.
ownershipIsDecidable=options.Modality~="unknown";
aliasList=manifest.alias_list;
members=records(terminal.record_indices);
entry=match_declaration(terminal.canonical_terminal,manifest,aliasList);

owners=strings(1,numel(members));
for k=1:numel(members)
    owners(k)=record_owner(members(k));
end
aoOwned=all(owners==owner) && ~isempty(owners);

row=empty_rows();
row(1).subsystem=string(subsystem);
row(1).port=terminal.port;
row(1).canonical_terminal=terminal.canonical_terminal;
row(1).role=entry.role;
row(1).classification=entry.classification;
row(1).record_names=join_field(members,"name");
row(1).wavefiles=join_field(members,"wavefile");
row(1).record_count=terminal.record_count;
row(1).ownership_tags=strjoin(owners(strlength(owners)>0),", ");
row(1).ao_owned_records=aoOwned;
row(1).declared_neutral=NaN;
row(1).neutral_source="";
row(1).measured_minimum=empty_to_nan(min(terminal.samples));
row(1).measured_maximum=empty_to_nan(max(terminal.samples));
row(1).all_samples_neutral=false;
row(1).neutral_verified=false;
row(1).runtime_owner=modality_owner(entry,options.Modality);
row(1).duplicate_records=terminal.record_count>1;
row(1).collides_with=collisions(terminal,allTerminals);
row(1).reason=entry.reason;

if entry.classification~="ao_owned_stimulation"
    % AO does not declare a neutral for a line it does not own, so there is
    % nothing here to verify. What the samples are is still recorded above.
    row(1).classification=entry.classification;
    return
end

neutral=double(entry.neutral_value);
row(1).declared_neutral=neutral;
row(1).neutral_source=entry.neutral_source;
% Every sample, not a summary of them: a single stray sample on a Pockels
% line is a photon burst, and a min/max pair that happened to bracket the
% neutral would hide it.
row(1).all_samples_neutral= ...
    ~isempty(terminal.samples) && ...
    all(abs(terminal.samples-neutral)<=options.NeutralToleranceV);
row(1).neutral_verified=row(1).all_samples_neutral;
if row(1).all_samples_neutral
    row(1).classification="neutral";
else
    row(1).classification="commanded";
end

if ~aoOwned && row(1).classification=="commanded"
    finding=sprintf( ...
        ['%s is commanding the AO-owned stimulation terminal %s (%s) and is ' ...
         'not tagged script_owner=%s. Samples span %.6g to %.6g; the rig ' ...
         'declares %.6g as neutral (%s).'],row(1).record_names, ...
        entry.terminal,entry.role,owner,row(1).measured_minimum, ...
        row(1).measured_maximum,neutral,entry.neutral_source);
    if ownershipIsDecidable
        violations(end+1)=finding;
    else
        observations(end+1)=finding+" This is an ambient survey, so that " + ...
            "is what AO would replace rather than a fault.";
    end
end
if row(1).duplicate_records
    violations(end+1)=sprintf( ...
        ['%d records resolve to the AO-owned stimulation terminal %s (%s): ' ...
         '%s. Luminos combines them, so what reaches the wire is not what ' ...
         'any one of them says.'],terminal.record_count,entry.terminal, ...
        entry.role,row(1).record_names);
end
if ~isempty(row(1).collides_with)
    violations(end+1)=sprintf( ...
        ['Port %s and %s name the same physical terminal %s (%s) but are ' ...
         'spelled differently, so Luminos resolves two channels onto one ' ...
         'line.'],terminal.port,strjoin(row(1).collides_with,", "), ...
        entry.terminal,entry.role);
end
if row(1).runtime_owner=="imperative"
    violations(end+1)=sprintf( ...
        ['%s installs a buffered waveform on %s (%s), which this modality ' ...
         'drives imperatively. One line cannot have two runtime owners ' ...
         'while a task holds it.'],row(1).record_names,entry.terminal, ...
        entry.role);
end
% The same invariant read the other way. A suppressed output is one this
% modality commands not at all, so the only correct configuration is the
% one with no record on it: a buffered record here is an output nothing
% asked for, and on the galvo card it is also what makes Luminos build a
% second-card AO task that then has to be clocked and triggered across
% cards. Neutral or not, the record should not exist, so this does not
% depend on what the samples measured.
if row(1).runtime_owner=="suppressed"
    violations(end+1)=sprintf( ...
        ['%s installs a buffered waveform on %s (%s), which this modality ' ...
         'suppresses from the run. Nothing commands this output, so it ' ...
         'must carry no record at all; the rig declares %.6g as its ' ...
         'neutral (%s) and the modality that drives this output is the ' ...
         'one that asserts it.'],row(1).record_names, ...
        entry.terminal,entry.role,neutral,entry.neutral_source);
end
end

function entry=match_declaration(canonical,manifest,aliasList)
%MATCH_DECLARATION Find the manifest entry naming this physical terminal.
%   canonical may be more than one spelling - a record contributes both its
%   name and its port - and a match on any of them is a match.
canonical=reshape(string(canonical),1,[]);
canonical=canonical(strlength(canonical)>0);
groups=["outputs","inherited","luminos_infrastructure","unresolved"];
fallback=["ao_owned_stimulation","inherited_non_stimulation", ...
    "expected_luminos_infrastructure","unaccounted"];
for g=1:numel(groups)
    declarations=manifest.(groups(g));
    for k=1:numel(declarations)
        spellings=[declarations(k).terminal declarations(k).aliases ...
            declarations(k).device_name];
        spellings=spellings(strlength(spellings)>0);
        if isempty(spellings), continue; end
        if any(ismember( ...
                adaptive_optopatch.canonical_terminal(spellings,aliasList), ...
                canonical))
            entry=declarations(k);
            entry.classification=fallback(g);
            if ~isfield(entry,"neutral_value"), entry.neutral_value=[]; end
            if ~isfield(entry,"neutral_source"), entry.neutral_source=""; end
            return
        end
    end
end
entry=struct("role","","device_name","","terminal",first_or_empty(canonical), ...
    "aliases",{strings(1,0)},"kind","","reason", ...
    "No declaration in the rig stimulation manifest names this terminal.", ...
    "classification","unaccounted","stimulation_capable",missing, ...
    "neutral_value",[],"neutral_source","", ...
    "owner",struct("one_photon","unknown","two_photon","unknown", ...
        "mixed","unknown"));
end

function value=first_or_empty(values)
if isempty(values), value=""; else, value=values(1); end
end

function value=modality_owner(entry,modality)
% Through the shared helper, so the check that polices runtime ownership
% and NEUTRALIZE_ALL_STIMULATION, which acts on it, cannot come to
% different conclusions about the same output.
value=adaptive_optopatch.manifest_runtime_owner(entry.owner,modality);
end

function declared=declared_coverage(manifest,rows,modality,aliasList)
%DECLARED_COVERAGE One row per AO-owned output, present in the build or not.
%   A terminal that is missing from the configuration produces no compiled
%   row at all, so without this an output AO forgot to neutralise would
%   simply not appear in the report.
%
%   present=false is read together with runtime_owner. For an output this
%   modality declares "suppressed" or "imperative" it is the intended
%   result and what the report is here to show; for one it declares
%   "buffered" it is an output that should have been driven and was not.
declared=struct("role",{},"terminal",{},"kind",{},"runtime_owner",{}, ...
    "declared_neutral",{},"neutral_source",{},"present",{}, ...
    "classification",{},"neutral_verified",{});
observed=strings(1,0);
if ~isempty(rows), observed=[rows.canonical_terminal]; end
for k=1:numel(manifest.outputs)
    entry=manifest.outputs(k);
    canonical=adaptive_optopatch.canonical_terminal(entry.terminal,aliasList);
    index=find(observed==canonical,1);
    declared(end+1)=struct("role",entry.role,"terminal",entry.terminal, ...
        "kind",entry.kind,"runtime_owner",modality_owner(entry,modality), ...
        "declared_neutral",double(entry.neutral_value), ...
        "neutral_source",entry.neutral_source, ...
        "present",~isempty(index), ...
        "classification",classification_at(rows,index), ...
        "neutral_verified",verified_at(rows,index)); %#ok<AGROW>
end
declared=struct2table_safe(declared);
end

function value=classification_at(rows,index)
if isempty(index), value="absent"; else, value=rows(index).classification; end
end

function value=verified_at(rows,index)
if isempty(index), value=false; else, value=rows(index).neutral_verified; end
end

function warnings=unaccounted_warnings(unaccounted,manifest)
warnings=strings(0,1);
for k=1:numel(unaccounted)
    note=rig_note(unaccounted(k).canonical_terminal,manifest);
    warnings(end+1)=sprintf( ...
        ['Unaccounted %s terminal %s carries %s (%s). Nothing in the %s ' ...
         'stimulation manifest says what this output does, so AO cannot ' ...
         'say whether it can stimulate the preparation.%s'], ...
        unaccounted(k).subsystem,unaccounted(k).port, ...
        unaccounted(k).record_names,unaccounted(k).wavefiles, ...
        manifest.rig_name,note); %#ok<AGROW>
end
end

function note=rig_note(canonical,manifest)
% An unresolved terminal the rig file DOES describe is still unaccounted,
% but the report should hand over what the rig says rather than make the
% reader go and look it up during a commissioning session.
note="";
for k=1:numel(manifest.unresolved)
    entry=manifest.unresolved(k);
    spellings=[entry.terminal entry.aliases entry.device_name];
    spellings=spellings(strlength(spellings)>0);
    if isempty(spellings), continue; end
    if any(adaptive_optopatch.canonical_terminal( ...
            spellings,manifest.alias_list)==canonical)
        note=" Rig context: "+entry.reason;
        return
    end
end
end

function value=empty_to_nan(value)
if isempty(value), value=NaN; end
end

function value=collisions(terminal,allTerminals)
value=strings(1,0);
for k=1:numel(allTerminals)
    if allTerminals(k).port==terminal.port, continue; end
    if allTerminals(k).canonical_terminal==terminal.canonical_terminal
        value(end+1)=allTerminals(k).port; %#ok<AGROW>
    end
end
end

function value=record_owner(record)
value="";
if isfield(record,"script_owner") && ~isempty(record.script_owner)
    value=string(record.script_owner);
end
end

function value=record_terminals(record)
spellings=strings(1,0);
if isfield(record,"name"), spellings(end+1)=string(record.name); end
if isfield(record,"port"), spellings(end+1)=string(record.port); end
value=adaptive_optopatch.canonical_terminal(spellings);
end

function value=record_label(record)
value=sprintf("%s (port %s)",string(record.name),string(record.port));
end

function value=join_field(records,field)
if isempty(records) || ~isfield(records,field), value=""; return; end
value=strjoin(arrayfun(@(r)string(r.(field)),records),", ");
end

function mask=strcmp_class(rows,value)
mask=false(size(rows));
for k=1:numel(rows), mask(k)=rows(k).classification==value; end
end

function rows=empty_rows()
% Also the row template: assigning into element 1 of this fills every field
% below, so a row can never be built with a field this list does not have.
rows=struct("subsystem",{},"port",{},"canonical_terminal",{},"role",{}, ...
    "classification",{},"record_names",{},"wavefiles",{},"record_count",{}, ...
    "ownership_tags",{},"ao_owned_records",{},"declared_neutral",{}, ...
    "neutral_source",{},"measured_minimum",{},"measured_maximum",{}, ...
    "all_samples_neutral",{},"neutral_verified",{},"runtime_owner",{}, ...
    "duplicate_records",{},"collides_with",{},"reason",{});
end

function value=struct2table_safe(rows)
% A table is what an operator reads during a commissioning session and what
% an archive is inspected through. An empty one still has to carry its
% column names, or a report with nothing to flag reads like a report that
% looked at nothing.
value=struct2table(rows,"AsArray",true);
end
