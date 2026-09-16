function compiled=compile_wfm_data_to_samples(globalProps,records,options)
%COMPILE_WFM_DATA_TO_SAMPLES Compile wfm_data records to physical samples.
%   compiled=COMPILE_WFM_DATA_TO_SAMPLES(globalProps,records) reproduces the
%   part of Luminos's waveform build that decides what voltage actually
%   appears on a wire, and returns one sample vector per physical terminal.
%
%   Asserting that the right records exist in wfm_data does not test the
%   thing that goes wrong. The bugs this exists for all happen AFTER the
%   records leave AO: an alias resolves to a terminal AO thought it had
%   cleared, two records land on one line, and Combine_Output_Waveforms
%   multiplies or adds them into a waveform nobody wrote. The only way to
%   see that is to compile.
%
%   The steps mirror DAQ.Build_Waveforms_DevicePartitioned exactly:
%
%     1. tvec from Calculate_tvec: round(total_time*rate) samples spanning
%        0 to (n-1)/rate.
%     2. remove_aliases: every record's port becomes remove_al(port).
%     3. group by the de-aliased port string, EXACTLY and case-sensitively,
%        in first-appearance order - which is what Luminos does, and is why
%        two spellings of one terminal that survive aliasing do not merge
%        here but do collide on the hardware (see below).
%     4. Combine_Output_Waveforms over each group: the first record is
%        evaluated, then each later one is folded in under its own
%        operation, defaulting to Addition when the field is absent or
%        empty.
%     5. data(end)=0, the last-sample rule Luminos applies per terminal.
%
%   Each returned entry also carries canonical_terminal. When two entries
%   share one canonical terminal, Luminos has produced two channels for one
%   physical line: Resolve_Output_Waveforms_By_Port compared the port
%   strings and saw two, Get_Device_From_Terminal sends both to the same
%   device task, and DAQmx is then handed the same terminal twice. That is
%   reported as collides_with rather than silently merged, because merging
%   would describe an outcome the hardware does not produce.
%
%   Waveform functions are evaluated, not reimplemented: the real
%   awfm_constant, dwfm_pulse and the rest are taken from the Luminos
%   checkout beside this one.
arguments
    globalProps (1,1) struct
    records
    options.AliasList cell = adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list
end
adaptive_optopatch.require_luminos_waveform_functions();

compiled=struct("port",{},"canonical_terminal",{},"samples",{}, ...
    "record_names",{},"record_count",{},"collides_with",{});
if isempty(records), return; end

tvec=calculate_tvec(globalProps);
ports=strings(1,numel(records));
for k=1:numel(records)
    ports(k)=resolve_alias(string(records(k).port),options.AliasList);
end
uniquePorts=unique(ports,"stable");
for p=1:numel(uniquePorts)
    matching=find(ports==uniquePorts(p));
    samples=combine_output_waveforms(tvec,records(matching));
    if ~isempty(samples), samples(end)=0; end
    compiled(end+1)=struct( ...
        "port",uniquePorts(p), ...
        "canonical_terminal",adaptive_optopatch.canonical_terminal( ...
            uniquePorts(p),options.AliasList), ...
        "samples",samples, ...
        "record_names",strjoin(arrayfun( ...
            @(r)string(r.name),records(matching)),", "), ...
        "record_count",numel(matching), ...
        "collides_with",strings(1,0)); %#ok<AGROW>
end

canonical=[compiled.canonical_terminal];
for k=1:numel(compiled)
    others=setdiff(find(canonical==canonical(k)),k);
    compiled(k).collides_with=reshape(string([compiled(others).port]),1,[]);
end
end

function tvec=calculate_tvec(globalProps)
% DAQ.Calculate_tvec, unchanged.
numSamples=round(double(globalProps.total_time)*double(globalProps.rate));
tvec=linspace(0,1/double(globalProps.rate)*(numSamples-1),numSamples);
end

function data=combine_output_waveforms(tvec,records)
% DAQ.Combine_Output_Waveforms. Concatenation needs the timing struct, so
% it is rejected rather than approximated: no AO path emits it, and a
% wrong answer here would be worse than no answer.
data=calculate_waveform(tvec,records(1));
for i=2:numel(records)
    operation="Addition";
    if isfield(records,"operation") && ~isempty(records(i).operation)
        operation=string(records(i).operation);
    end
    next=calculate_waveform(tvec,records(i));
    switch operation
        case "Addition",       data=data+next;
        case "Multiplication", data=data.*next;
        case "Subtraction",    data=data-next;
        case "Division"
            nonzero=next~=0;
            data(nonzero)=data(nonzero)./next(nonzero);
        otherwise
            error("adaptive_optopatch:UnsupportedWaveformOperation", ...
                ['compile_wfm_data_to_samples does not reproduce the ''%s'' ' ...
                 'operation. Extend it from DAQ.Combine_Output_Waveforms ' ...
                 'before relying on a test that needs one.'],operation);
    end
end
end

function out=calculate_waveform(tvec,record)
% DAQ.Calculate_Waveform. Row orientation is forced because Luminos's own
% waveform functions return rows and a stray column would broadcast into a
% matrix when two records combine.
params=record.params;
if ~iscell(params), params=num2cell(params); end
out=reshape(feval(char(record.wavefile),tvec,params{:}),1,[]);
end

function value=resolve_alias(value,aliasList)
% DAQ.remove_al, applied as DAQ.remove_aliases applies it.
value=strip(value);
for j=1:size(aliasList,1)
    if strcmpi(value,strip(string(aliasList{j,2})))
        value=strip(string(aliasList{j,1}));
        return
    end
end
end
