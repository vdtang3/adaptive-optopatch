function value=manifest_runtime_owner(owner,modality)
%MANIFEST_RUNTIME_OWNER Who drives one declared output during one modality.
%   value=MANIFEST_RUNTIME_OWNER(owner,modality) reads a manifest entry's
%   per-modality ownership declaration and returns the one that applies to
%   the acquisition about to happen: "buffered", "imperative", "suppressed",
%   "operator", "luminos" or "unknown".
%
%   One function because three different places now ask the same question
%   and must get the same answer. The waveform builders decide what to
%   install from it, ACCOUNT_STIMULATION_OUTPUTS decides what is a violation
%   from it, and NEUTRALIZE_ALL_STIMULATION decides what to command from it.
%   If the modality-to-field mapping lived in each of them, the run-time
%   safety behaviour and the check that is supposed to police it could
%   disagree about the same output - which is exactly the class of bug the
%   manifest exists to make impossible.
%
%   See also VIRTUAL_UPRIGHT_STIMULATION_MANIFEST, ACCOUNT_STIMULATION_OUTPUTS,
%   NEUTRALIZE_ALL_STIMULATION.
arguments
    owner (1,1) struct
    modality (1,1) string {mustBeMember(modality, ...
        ["1p_dmd","2p_spiral","mixed","unknown"])}
end
switch modality
    case "1p_dmd",    value=string(owner.one_photon);
    case "2p_spiral", value=string(owner.two_photon);
    case "mixed"
        % Mixed was answered with the 1P value until the 2P outputs gained
        % a modality-dependent answer: a 1P-only run suppresses them and a
        % mixed run drives them from the planned 2P waveforms. Entries that
        % do not care still default their mixed value to the 1P one, in the
        % manifest rather than here.
        value=string(owner.mixed);
    otherwise,        value="unknown";
end
end
