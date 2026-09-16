function [wfmData,removed]=drop_ao_script_waveforms(wfmData)
%DROP_AO_SCRIPT_WAVEFORMS Take back every record a previous AO run added.
%   AO stamps script_owner on the records it puts into wfm_data, following
%   Luminos's own Append_Script_Waveform convention. This is the other half
%   of that convention: whatever AO left behind comes out again before AO
%   builds a new configuration.
%
%   Normally there is nothing to remove, because a run restores the
%   operator's captured wfm_data on the way out. What this covers is the
%   run that did not get that far - a crash between installing a waveform
%   and unwinding - after which the DAQ, which outlives the experiment, is
%   still holding an AO waveform that the next build would have treated as
%   somebody's ambient configuration.
%
%   Luminos's Drop_Script_Waveforms is the same idea against a live DAQ
%   object, and is what removes AO's entries when some other acquisition
%   starts. This works on the plain struct the waveform builders are
%   handed, and also covers the camera-triggered subsystems, which AO never
%   writes to but must not leave an entry in either.
owner=adaptive_optopatch.script_owner_tag();
removed=0;
for field=["ao","do","ao_camera_triggered","do_camera_triggered"]
    if ~isfield(wfmData,field), continue; end
    records=wfmData.(field);
    if isempty(records) || ~isfield(records,"script_owner"), continue; end
    keep=true(size(records));
    for k=1:numel(records)
        keep(k)=~isequal(string(records(k).script_owner),string(owner));
    end
    removed=removed+sum(~keep);
    wfmData.(field)=records(keep);
end
end
