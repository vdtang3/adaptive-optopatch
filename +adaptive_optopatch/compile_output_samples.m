function terminals=compile_output_samples(globalProps,records,aliasList)
%COMPILE_OUTPUT_SAMPLES Samples that would appear on each physical terminal.
%   terminals=COMPILE_OUTPUT_SAMPLES(globalProps,records,aliasList) takes
%   one subsystem's wfm_data records and returns what Luminos would put on
%   the wire for each physical output, so that accounting can measure a
%   line rather than believe a record.
%
%   It reproduces DAQ.Build_Waveforms_DevicePartitioned: the time vector
%   from Calculate_tvec, remove_aliases on every port, grouping by the
%   de-aliased port string exactly as Resolve_Output_Waveforms_By_Port
%   groups it, Combine_Output_Waveforms over each group, then data(end)=0.
%
%   Two records whose ports survive aliasing as different strings but name
%   one physical terminal do NOT merge here, because they do not merge in
%   Luminos either: it resolves two channels and hands DAQmx the same
%   terminal twice. They are reported instead, through canonical_terminal,
%   so accounting can say what really happened rather than average it away.
%
%   tests/compile_wfm_data_to_samples.m is a deliberately separate
%   transcription of the same Luminos code, kept independent so that the
%   tests proving AO's waveforms correct do not share an implementation
%   with the runtime check that also has to be correct. A test asserts the
%   two agree; if this ever drifts from Luminos, that is where it shows.
arguments
    globalProps (1,1) struct
    records
    aliasList cell = adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list
end
terminals=struct("port",{},"canonical_terminal",{},"samples",{}, ...
    "record_indices",{},"record_count",{});
if isempty(records), return; end
adaptive_optopatch.require_luminos_waveform_functions();

numSamples=round(double(globalProps.total_time)*double(globalProps.rate));
tvec=linspace(0,1/double(globalProps.rate)*(numSamples-1),numSamples);

ports=strings(1,numel(records));
for k=1:numel(records)
    ports(k)=adaptive_optopatch.resolve_terminal_alias( ...
        string(records(k).port),aliasList);
end
uniquePorts=unique(ports,"stable");
for p=1:numel(uniquePorts)
    matching=find(ports==uniquePorts(p));
    samples=combine(tvec,records(matching));
    if ~isempty(samples), samples(end)=0; end
    terminals(end+1)=struct("port",uniquePorts(p), ...
        "canonical_terminal",adaptive_optopatch.canonical_terminal( ...
            uniquePorts(p),aliasList), ...
        "samples",samples,"record_indices",matching, ...
        "record_count",numel(matching)); %#ok<AGROW>
end
end

function data=combine(tvec,records)
data=evaluate(tvec,records(1));
for i=2:numel(records)
    operation="Addition";
    if isfield(records,"operation") && ~isempty(records(i).operation)
        operation=string(records(i).operation);
    end
    next=evaluate(tvec,records(i));
    switch operation
        case "Addition",       data=data+next;
        case "Multiplication", data=data.*next;
        case "Subtraction",    data=data-next;
        case "Division"
            nonzero=next~=0;
            data(nonzero)=data(nonzero)./next(nonzero);
        otherwise
            % Concatenation needs the timing struct and no AO path emits
            % it. Refusing beats guessing: a measured neutral that came
            % from an approximation would be worth nothing.
            error("adaptive_optopatch:UnsupportedWaveformOperation", ...
                ['Cannot account for a waveform combined with the ''%s'' ' ...
                 'operation. Extend compile_output_samples from ' ...
                 'DAQ.Combine_Output_Waveforms first.'],operation);
    end
end
end

function out=evaluate(tvec,record)
params=record.params;
if ~iscell(params), params=num2cell(params); end
out=reshape(feval(char(record.wavefile),tvec,params{:}),1,[]);
end
