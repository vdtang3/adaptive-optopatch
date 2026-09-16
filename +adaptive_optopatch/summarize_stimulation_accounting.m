function summary=summarize_stimulation_accounting(reports)
%SUMMARIZE_STIMULATION_ACCOUNTING Roll a run's per-trial accounting together.
%   summary=SUMMARIZE_STIMULATION_ACCOUNTING(reports) collapses the
%   per-trial reports a run measured into the one struct archived as
%   run.stimulation_accounting, so a finished run answers "was anything
%   unaccounted anywhere in this" without reopening each trial.
%
%   The per-trial reports are kept whole alongside the roll-up. The
%   summary is what gets read first; the detail - which terminal, what
%   wavefile, which samples - is what a commissioning session needs when
%   the answer is yes.
arguments
    reports cell
end
reports=reports(~cellfun(@isempty,reports));
summary=struct("schema_version","1.0.0","trial_count",numel(reports), ...
    "reports",{reports},"unaccounted_terminals",strings(0,1), ...
    "violations",strings(0,1),"warnings",strings(0,1), ...
    "observations",strings(0,1),"policy","");
for k=1:numel(reports)
    summary.unaccounted_terminals=[summary.unaccounted_terminals; ...
        reports{k}.unaccounted_terminals];
    summary.violations=[summary.violations;reports{k}.violations];
    summary.warnings=[summary.warnings;reports{k}.warnings];
    summary.observations=[summary.observations;reports{k}.observations];
    summary.policy=reports{k}.policy;
end
summary.unaccounted_terminals=unique(summary.unaccounted_terminals,"stable");
summary.violations=unique(summary.violations,"stable");
summary.warnings=unique(summary.warnings,"stable");
summary.observations=unique(summary.observations,"stable");
summary.passed=isempty(summary.violations);
end
