function records=append_wfm_record(records,record)
%APPEND_WFM_RECORD Add a record to a wfm_data list with mismatched fields.
%   Records that came out of a waveform builder carry script_owner and a
%   record a test writes by hand does not, and struct array concatenation
%   needs identical field sets on both sides. Same padding the builders and
%   Luminos's own Append_Script_Waveform do, so a test can put an ambient
%   record into an already-built configuration without saying how.
if isempty(records), records=record; return; end
fields=union(fieldnames(records),fieldnames(record),'stable');
for k=1:numel(fields)
    if ~isfield(records,fields{k}), [records.(fields{k})]=deal([]); end
    if ~isfield(record,fields{k}), record.(fields{k})=[]; end
end
records(end+1)=orderfields(record,records);
end
