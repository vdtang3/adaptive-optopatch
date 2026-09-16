function report=report_vu_stimulation_outputs(app,options)
%REPORT_VU_STIMULATION_OUTPUTS Survey the rig's live stimulation outputs.
%   report=REPORT_VU_STIMULATION_OUTPUTS(app) reads the Luminos waveform
%   configuration that is loaded right now, compiles it, and prints what
%   every physical output would do: which stimulation-capable terminals
%   exist, which are commanded, which hold a declared neutral, which are
%   imaging infrastructure AO inherits, and which nothing has accounted for.
%
%   This is the Pass 3A commissioning step. It touches no hardware: it does
%   not arm a task, write a device, open a shutter or start an acquisition.
%   It reads app's DAQ, evaluates waveform functions in memory and prints.
%
%   Run it on the VU with the ambient Waveforms tab exactly as an
%   experimenter would leave it, and again with a prepared AO plan's
%   configuration, and read the unaccounted section. That is how
%   Dev1/port0/line5, PMT Shutter and Shutter sensory get classified, and
%   until they are, fail_closed is not a policy this rig can run under.
arguments
    app
    % Which builder's output to survey. "ambient" reports the operator's
    % own configuration untouched, which is the one that says what is
    % really on the rig's outputs before AO does anything to it.
    options.Modality (1,1) string {mustBeMember(options.Modality, ...
        ["ambient","1p_dmd","2p_spiral"])} = "ambient"
    options.Policy (1,1) string {mustBeMember(options.Policy, ...
        ["report_only","fail_closed"])} = "report_only"
    options.Manifest (1,1) struct = ...
        adaptive_optopatch.virtual_upright_stimulation_manifest()
    options.Print (1,1) logical = true
end
daq=app.getDevice("DAQ");
if numel(daq)~=1
    error("adaptive_optopatch:CombinedDaqRequired", ...
        "Expected one combined Luminos DAQ object, found %d.",numel(daq));
end
if ~isstruct(daq.global_props) || ~isfield(daq.global_props,"rate") || ...
        ~isstruct(daq.wfm_data)
    error("adaptive_optopatch:NoActiveLuminosWaveform", ...
        "Load a Luminos waveform protocol before surveying the outputs.");
end

modality=options.Modality;
if modality=="ambient"
    % Nothing is modelled and nothing is assumed: this is the operator's
    % own configuration, with whatever total_time it carries.
    accountingModality="unknown";
else
    accountingModality=modality;
end
report=adaptive_optopatch.account_stimulation_outputs( ...
    daq.global_props,daq.wfm_data,"Manifest",options.Manifest, ...
    "Modality",accountingModality,"Policy",options.Policy, ...
    "Context",sprintf("VU survey (%s)",modality));
report.surveyed_at=string(datetime("now","TimeZone","local"));
report.alias_list=live_alias_list(daq);
report.alias_list_matches_manifest= ...
    isequal(canonical_pairs(report.alias_list), ...
        canonical_pairs(options.Manifest.alias_list));

if options.Print, print_report(report,options.Manifest); end
end

function pairs=canonical_pairs(aliasList)
pairs=strings(size(aliasList,1),2);
for k=1:size(aliasList,1)
    pairs(k,1)=lower(strip(string(aliasList{k,1})));
    pairs(k,2)=lower(strip(string(aliasList{k,2})));
end
pairs=sortrows(pairs);
end

function aliasList=live_alias_list(daq)
% The manifest transcribes the rig file. If the rig file has moved on, the
% survey should be the thing that notices rather than a later run.
aliasList=cell(0,2);
try
    if isprop(daq,"alias_list"), aliasList=daq.alias_list; end
catch
end
end

function print_report(report,manifest)
line=@()fprintf("%s\n",repmat('-',1,78));
fprintf("\nAdaptive Optopatch stimulation output survey\n");
line();
fprintf("rig            : %s\n",report.rig_name);
fprintf("surveyed       : %s\n",report.surveyed_at);
fprintf("modality       : %s\n",report.modality);
fprintf("policy         : %s\n",report.policy);
fprintf("waveform       : %.0f Hz x %.4f s (%d samples)\n", ...
    report.sample_rate_hz,report.duration_s,report.sample_count);
if ~report.alias_list_matches_manifest
    fprintf(2,"WARNING: the live DAQ alias list differs from the one the " + ...
        "manifest transcribes.\n         Terminal identity may resolve " + ...
        "differently on this rig than AO assumes.\n");
end

line();
fprintf("AO-owned stimulation outputs\n");
line();
declared=report.declared;
fprintf("%-26s %-18s %-5s %-11s %-9s %-9s %s\n", ...
    "role","terminal","kind","owner","neutral","present","state");
for k=1:height(declared)
    fprintf("%-26s %-18s %-5s %-11s %-9.4g %-9s %s\n", ...
        declared.role(k),declared.terminal(k),declared.kind(k), ...
        declared.runtime_owner(k),declared.declared_neutral(k), ...
        yes_no(declared.present(k)),verdict(declared,k));
end

line();
fprintf("Every compiled terminal\n");
line();
terminals=report.terminals;
fprintf("%-18s %-32s %-30s %s\n","terminal","classification","records","measured");
for k=1:height(terminals)
    fprintf("%-18s %-32s %-30s [%.4g .. %.4g]\n", ...
        terminals.port(k),terminals.classification(k), ...
        truncate(terminals.record_names(k),30), ...
        terminals.measured_minimum(k),terminals.measured_maximum(k));
end

line();
fprintf("Violations (block under either policy): %d\n",numel(report.violations));
for v=reshape(report.violations,1,[])
    fprintf(2,"  ! %s\n",v);
end

if ~isempty(report.observations)
    line();
    fprintf("Observations (no modality chosen, so not faults): %d\n", ...
        numel(report.observations));
    for o=reshape(report.observations,1,[])
        fprintf("  . %s\n",o);
    end
end

line();
fprintf("UNACCOUNTED terminals: %d\n",numel(report.unaccounted_terminals));
for w=reshape(report.warnings,1,[])
    fprintf("  ? %s\n",w);
end
if isempty(report.warnings)
    fprintf("  none in this configuration.\n");
end

line();
fprintf("Still awaiting classification from this rig before fail_closed:\n");
for k=1:numel(manifest.unresolved)
    entry=manifest.unresolved(k);
    terminal=entry.terminal;
    if strlength(terminal)==0, terminal="(no terminal declared)"; end
    fprintf("  - %-22s %-18s %s\n",entry.role,terminal, ...
        truncate(entry.reason,52));
end
line();
fprintf("passed: %s\n\n",yes_no(report.passed));
end

function value=verdict(declared,k)
if ~declared.present(k)
    value="absent";
    return
end
value=declared.classification(k);
if value=="neutral" && declared.neutral_verified(k)
    value="neutral (verified in samples)";
end
end

function value=truncate(text,width)
value=string(text);
if strlength(value)>width, value=extractBefore(value,width-2)+".."; end
end

function value=yes_no(flag)
if flag, value="yes"; else, value="no"; end
end
