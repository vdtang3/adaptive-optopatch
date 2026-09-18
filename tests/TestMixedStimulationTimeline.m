classdef TestMixedStimulationTimeline < matlab.unittest.TestCase
    %TESTMIXEDSTIMULATIONTIMELINE One acquisition, two stimulation sources.
    %   An acquisition may mix 1P DMD and 2P spiral events, and when it does
    %   there is still exactly ONE timeline: one set of samples, one DMD
    %   index sequence consumed only by the 1P rows, and no second
    %   compilation pass. The parity tests are the load-bearing ones - a
    %   pure-1P or pure-2P acquisition compiled by the mixed builder must
    %   produce the same samples the hardened single-modality builder does,
    %   so the mixed path is not a third implementation.
    %
    %   Named for that behaviour rather than for a schema version. It was
    %   TestMixedStimulationSchema4; every event carrying a stimulation
    %   source is what makes mixing expressible, and the explicit refusal of
    %   a schema-3 definition stays here because that is the compatibility
    %   boundary this behaviour introduced.
    methods (Test)
        function sourceIsRequiredAndSchemaThreeIsRejected(testCase)
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            missing=definition;
            missing.acquisitions.events=removevars( ...
                missing.acquisitions.events,"stimulation_source");
            testCase.verifyError(@()adaptive_optopatch.normalize_protocol(missing), ...
                "adaptive_optopatch:InvalidProtocol");
            obsolete=definition; obsolete.schema_version="3.0.0";
            testCase.verifyError(@()adaptive_optopatch.normalize_protocol(obsolete), ...
                "adaptive_optopatch:ObsoleteProtocolSchema");
        end

        function nullAndSourceRulesAreBidirectional(testCase)
            definition=adaptive_optopatch.generate_screen_protocol( ...
                "PulseCount",1,"ModulatorVoltage",1);
            definition.acquisitions.events.is_null=true;
            report=adaptive_optopatch.validate_protocol(definition);
            testCase.verifyFalse(report.passed);
            testCase.verifyTrue(any(contains(report.issues,"Null events")));
            definition.acquisitions.events.stimulation_source="none";
            definition.acquisitions.events.command_voltage_v=0;
            testCase.verifyTrue(adaptive_optopatch.validate_protocol(definition).passed);
        end

        function mixedCompilerOwnsOneCommonTimeline(testCase)
            protocol=mixed_resolved_protocol();
            rate=200000; n=rate;
            wave=struct("sample_rate_hz",rate,"x_v",zeros(n,1), ...
                "y_v",zeros(n,1),"pockels_v",zeros(n,1), ...
                "preflight",struct,"per_pulse",struct([]), ...
                "requested_acquisition_duration_s",1, ...
                "actual_acquisition_duration_s",1,"automatic_extension_s",0);
            wave.pockels_v(floor(0.6*rate)+1:ceil(0.61*rate))=0.25;
            props=struct("rate",rate,"clock_source","Internal Dev1", ...
                "trigger_source","Dev1/PFI9","daq_master",true);
            ambient=struct("ao",stale("mod488","Dev1/ao2",3), ...
                "do",stale("DMD Trigger","Dev1/port0/line4",1));
            plan=struct("dmd_trigger_s",0.1);
            [configured,wfm,summary]= ...
                adaptive_optopatch.build_luminos_mixed_waveform_config( ...
                props,ambient,protocol,"TwoPhotonWaveforms",wave, ...
                "DmdSequencePlan",plan);
            testCase.verifyTrue(summary.has_mixed_sources);
            testCase.verifyEqual(summary.onephoton_event_count,1);
            testCase.verifyEqual(summary.twophoton_event_count,1);
            ao=adaptive_optopatch.compile_output_samples(configured,wfm.ao, ...
                adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list);
            digital=adaptive_optopatch.compile_output_samples(configured,wfm.do, ...
                adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list);
            mod=terminal(ao,"Dev1/ao2"); pockels=terminal(ao,"Dev1/ao3");
            dmd=terminal(digital,"Dev1/port0/line4");
            at=@(seconds)floor(seconds*rate)+1;
            testCase.verifyEqual(mod.samples(at(0.205)),0.2,"AbsTol",1e-12);
            testCase.verifyEqual(pockels.samples(at(0.205)),0,"AbsTol",1e-12);
            testCase.verifyEqual(mod.samples(at(0.605)),0,"AbsTol",1e-12);
            testCase.verifyEqual(pockels.samples(at(0.605)),0.25,"AbsTol",1e-12);
            testCase.verifyEqual([mod.samples(at(0.4)) pockels.samples(at(0.4))],[0 0]);
            testCase.verifyEqual(dmd.samples(at(0.605)),0);
        end

        function onlyOnePhotonRowsConsumeDmdIndices(testCase)
            protocol=mixed_resolved_protocol();
            testCase.verifyEqual(protocol.events.dmd_pattern_index,[1;0]);
        end

        function pureOnePhotonMatchesHardenedBuilderSamples(testCase)
            protocol=subset_protocol(mixed_resolved_protocol(),"1p_dmd");
            props=active_props(); ambient=empty_wfm();
            plan=struct("dmd_trigger_s",0.1,"unique_camera_masks",false(1));
            [oldProps,old]=adaptive_optopatch.build_luminos_1p_waveform_config( ...
                props,ambient,protocol,adaptive_optopatch.virtual_upright_1p_profile(), ...
                "DmdSequencePlan",plan);
            [newProps,new]=adaptive_optopatch.build_luminos_mixed_waveform_config( ...
                props,ambient,protocol,"DmdSequencePlan",plan);
            verify_same_outputs(testCase,oldProps,old,newProps,new);
        end

        function pureTwoPhotonMatchesHardenedBuilderSamples(testCase)
            protocol=subset_protocol(mixed_resolved_protocol(),"2p_spiral");
            n=200000; wave=struct("sample_rate_hz",200000,"x_v",zeros(n,1), ...
                "y_v",zeros(n,1),"pockels_v",zeros(n,1), ...
                "preflight",struct,"per_pulse",struct([]), ...
                "requested_acquisition_duration_s",1, ...
                "actual_acquisition_duration_s",1,"automatic_extension_s",0);
            wave.pockels_v(120001:122000)=0.25;
            props=active_props(); ambient=empty_wfm();
            [oldProps,old]=adaptive_optopatch.build_luminos_2p_waveform_config( ...
                props,ambient,wave);
            [newProps,new]=adaptive_optopatch.build_luminos_mixed_waveform_config( ...
                props,ambient,protocol,"TwoPhotonWaveforms",wave);
            verify_same_outputs(testCase,oldProps,old,newProps,new);
        end
    end
end

function protocol=subset_protocol(protocol,source)
protocol.events=protocol.events(protocol.events.stimulation_source==source,:);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function props=active_props()
props=struct("rate",200000,"clock_source","Internal Dev1", ...
    "trigger_source","Dev1/PFI9","daq_master",true);
end

function value=empty_wfm()
value=struct("ao",[],"do",[],"ai",[],"di",[],"ctri",[], ...
    "ao_camera_triggered",[],"do_camera_triggered",[]);
end

function verify_same_outputs(testCase,oldProps,old,newProps,new)
manifest=adaptive_optopatch.virtual_upright_stimulation_manifest();
for subsystem=["ao","do"]
    a=adaptive_optopatch.compile_output_samples(oldProps,old.(subsystem),manifest.alias_list);
    b=adaptive_optopatch.compile_output_samples(newProps,new.(subsystem),manifest.alias_list);
    [~,ia]=sort(string({a.canonical_terminal})); [~,ib]=sort(string({b.canonical_terminal}));
    testCase.verifyEqual(string({a(ia).canonical_terminal}),string({b(ib).canonical_terminal}));
    for k=1:numel(ia), testCase.verifyEqual(a(ia(k)).samples,b(ib(k)).samples); end
end
end

function protocol=mixed_resolved_protocol()
pulse_id=[1;2]; condition_id=["blue";"spiral"];
stimulation_source=["1p_dmd";"2p_spiral"];
target_cell_id=["cell_001";"cell_001"]; target_index=[1;1];
onset_s=[0.2;0.6]; duration_s=[0.01;0.01]; is_null=false(2,1);
command_voltage_v=[0.2;0.25]; blue_mask_adjustment_pixels=[0;NaN];
dmd_pattern_index=[1;0]; command_voltage_source=["event";"event"];
pulse_duration_source=["event";"event"];
blue_mask_adjustment_source=["event";"not_applicable"];
events=table(pulse_id,condition_id,stimulation_source,target_cell_id,target_index, ...
    onset_s,duration_s,is_null,command_voltage_v,blue_mask_adjustment_pixels, ...
    dmd_pattern_index,command_voltage_source,pulse_duration_source, ...
    blue_mask_adjustment_source);
parameters=struct("orange_expansion_pixels",2,"spiral_radius_um",5, ...
    "spiral_density_points_per_volt",10);
protocol=struct("schema_version","4.0.0","artifact_type","resolved_acquisition", ...
    "protocol_id","mixed","protocol_type","test","source_protocol_id","mixed", ...
    "acquisition_id","mixed","target_policy","each_stimulation_enabled_cell", ...
    "event_order","ordered","random_seed",1,"events",events, ...
    "parameters",parameters,"parameter_sources",struct, ...
    "acquisition_duration_s",1);
protocol=adaptive_optopatch.normalize_protocol(protocol);
end

function record=stale(name,port,value)
record=struct("name",name,"port",port,"wavefile","awfm_constant", ...
    "params",{{value}},"operation","Multiplication","concatTime",[]);
end

function value=terminal(values,port)
canonical=adaptive_optopatch.canonical_terminal(port, ...
    adaptive_optopatch.virtual_upright_stimulation_manifest().alias_list);
index=find(string({values.canonical_terminal})==canonical,1);
value=values(index);
end
