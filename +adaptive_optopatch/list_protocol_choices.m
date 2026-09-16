function choices=list_protocol_choices(options)
%LIST_PROTOCOL_CHOICES Pulse protocols a frontend may ask to have loaded.
%   MATLAB owns discovery. A frontend picks a stable choice_id out of this
%   list and asks for it by that name; it never sends a filesystem path, and
%   nothing outside this function decides which files are offerable. That is
%   the whole point of the indirection: a browser that can name a path can
%   name any path.
%
%   Every candidate is opened and validated here rather than at load time,
%   so a file that is not a schema-3 protocol is reported as unloadable in
%   the list instead of failing after the operator has chosen it. The list
%   is small - a handful of generated MAT files - and is read on demand, not
%   on a poll.
%
%   choice_id is derived from the file name, disambiguated with a numeric
%   suffix when two roots contain the same name, and is stable for as long
%   as the same files are present. It is an identifier for one listing, not
%   a durable handle: callers resolve it against the listing they were
%   given, which is what AdaptiveOptopatchController does.
arguments
    options.Roots string = strings(0,1)
end

roots=unique(reshape(options.Roots,[],1),"stable");
choices=empty_choice_array();
seen=strings(0,1);
for root=reshape(roots,1,[])
    if strlength(root)==0 || ~isfolder(root), continue; end
    listing=dir(fullfile(root,"*.mat"));
    [~,order]=sort(string({listing.name}));
    for entry=reshape(listing(order),1,[])
        if entry.isdir, continue; end
        path=string(fullfile(entry.folder,entry.name));
        if any(seen==path), continue; end
        seen(end+1,1)=path; %#ok<AGROW>
        choices(end+1,1)=describe_choice(path,choices); %#ok<AGROW>
    end
end
end

function choice=describe_choice(path,existing)
[folder,name]=fileparts(path);
choice=empty_choice();
choice.choice_id=unique_choice_id(name,existing);
choice.name=string(name);
choice.folder=string(folder);
choice.path=string(path);
try
    protocol=adaptive_optopatch.load_protocol(path);
    summary=adaptive_optopatch.summarize_protocol(protocol);
    choice.loadable=true;
    choice.protocol_id=string(summary.protocol_id);
    choice.protocol_type=string(summary.protocol_type);
    choice.target_policy=string(summary.target_policy);
    choice.event_order=string(summary.event_order);
    choice.acquisition_count=double(summary.definition_acquisition_count);
    choice.event_count=double(summary.event_count);
catch exception
    % Listed, and listed as unloadable. A stale or half-written MAT file in
    % the protocol folder must not hide every other protocol beside it.
    choice.issue=string(exception.message);
end
end

function id=unique_choice_id(name,existing)
id=string(name);
if isempty(existing), return; end
taken=[existing.choice_id];
suffix=2;
while any(taken==id)
    id=string(name)+"#"+string(suffix);
    suffix=suffix+1;
end
end

function choice=empty_choice()
choice=struct("choice_id","","name","","folder","","path","", ...
    "loadable",false,"issue","","protocol_id","","protocol_type","", ...
    "target_policy","","event_order","","acquisition_count",0, ...
    "event_count",0);
end

function choices=empty_choice_array()
choices=repmat(empty_choice(),0,1);
end
