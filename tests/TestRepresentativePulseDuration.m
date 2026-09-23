classdef TestRepresentativePulseDuration < matlab.unittest.TestCase
    %TESTREPRESENTATIVEPULSEDURATION One rule, everywhere.
    %   A protocol whose events are not all the same length has to be sized
    %   by ONE duration, and it must be the same one in the preview and in
    %   the plan. It was not: buildPlan used the shortest light event and
    %   currentPulseDurationMs - which every preview goes through - used the
    %   FIRST event of the first acquisition. With a non-uniform protocol an
    %   operator therefore aimed with 2P spiral geometry built at one
    %   duration and ran geometry built at another, with nothing on screen
    %   to say so.
    %
    %   The rule is the SHORTEST light event, because the number being sized
    %   is a spiral cycle count: geometry built for a 20 ms pulse cannot
    %   complete inside a 10 ms one.

    methods (Test)
        function theShortestLightEventIsTheRepresentativeOne(testCase)
            protocol=testCase.nonUniformProtocol();
            value=adaptive_optopatch.representative_pulse_duration_ms(protocol,5);
            testCase.verifyEqual(value,8,"AbsTol",1e-12, ...
                "8 ms is the shortest, though 20 ms comes first.");
        end

        function theControllerAgreesWithTheHelper(testCase)
            % currentPulseDurationMs is what every preview sizes its bundle
            % by; buildPlan is what the run sizes its bundle by.
            controller=testCase.controllerWith(testCase.nonUniformProtocol());
            testCase.verifyEqual(controller.currentPulseDurationMs(),8, ...
                "AbsTol",1e-12);

            controller.updatePlan();
            % The plan's own bundle was built at the same duration: its 2P
            % spiral metrics are the ones the preview drew.
            testCase.verifyEqual( ...
                controller.ActiveRunPlan.targets.parameters.pulse_duration_ms, ...
                controller.currentPulseDurationMs(),"AbsTol",1e-12);
        end

        function orderDoesNotChangeTheAnswer(testCase)
            % The old rule was "the first one", so reordering the
            % acquisitions changed what previews were built at.
            forward=testCase.nonUniformProtocol();
            reversed=forward;
            reversed.acquisitions=flip(forward.acquisitions);
            testCase.verifyEqual( ...
                adaptive_optopatch.representative_pulse_duration_ms(reversed,5), ...
                adaptive_optopatch.representative_pulse_duration_ms(forward,5));
        end

        function nullEventsDoNotCount(testCase)
            % A dark control acquisition has a duration and emits no light;
            % sizing a spiral by it would be meaningless.
            protocol=testCase.nonUniformProtocol("IncludeNull",true);
            testCase.verifyEqual( ...
                adaptive_optopatch.representative_pulse_duration_ms(protocol,5), ...
                8,"AbsTol",1e-12);
        end

        function aProtocolWithNoLightFallsBackToTheCallersDefault(testCase)
            % A scheduler-backed template with no finite duration, or an
            % all-null protocol: the caller owns the sensible default.
            empty=struct("acquisitions",struct("events", ...
                table(1,"c","none",0.1,NaN,true,NaN,NaN,'VariableNames', ...
                {'pulse_id','condition_id','stimulation_source','onset_s', ...
                 'duration_s','is_null','command_voltage_v', ...
                 'blue_mask_adjustment_pixels'})));
            testCase.verifyEqual( ...
                adaptive_optopatch.representative_pulse_duration_ms(empty,7),7);
            testCase.verifyEqual( ...
                adaptive_optopatch.representative_pulse_duration_ms([],7),7);
        end

        function orientationDoesNotChangeTheAnswer(testCase)
            forward=testCase.nonUniformProtocol();
            column=forward;
            column.acquisitions=reshape(forward.acquisitions,[],1);
            row=forward;
            row.acquisitions=reshape(forward.acquisitions,1,[]);
            testCase.verifyEqual( ...
                adaptive_optopatch.representative_pulse_duration_ms(column,5), ...
                adaptive_optopatch.representative_pulse_duration_ms(row,5));
        end
    end

    methods (Access=private)
        function protocol=nonUniformProtocol(testCase,options)
            arguments
                testCase %#ok<INUSA>
                options.IncludeNull (1,1) logical = false
            end
            % 20 ms first, then 8 ms: the shortest is deliberately NOT first.
            acquisitions=[testCase.acquisition("slow",0.020,0.1,false), ...
                testCase.acquisition("fast",0.008,0.1,false)];
            if options.IncludeNull
                acquisitions(end+1)=testCase.acquisition("dark",0.500,0.1,true);
            end
            protocol=struct("schema_version","4.0.0", ...
                "artifact_type","experiment_definition", ...
                "protocol_id","non_uniform_durations", ...
                "protocol_type","non_uniform_durations", ...
                "target_policy","each_stimulation_enabled_cell", ...
                "event_order","ordered","random_seed",3, ...
                "parameter_sources",struct("command_voltage_v", ...
                    ["event","acquisition","protocol","fov_cell"]), ...
                "parameters",struct,"acquisitions",acquisitions);
            protocol=adaptive_optopatch.normalize_protocol(protocol);
        end

        function acquisition=acquisition(~,name,duration,onset,isNull)
            pulse_id=1;
            condition_id=string(name);
            if isNull, stimulation_source="none"; else, stimulation_source="1p_dmd"; end
            onset_s=onset;
            duration_s=duration;
            is_null=isNull;
            if isNull, command_voltage_v=0; else, command_voltage_v=1.4; end
            blue_mask_adjustment_pixels=NaN;
            events=table(pulse_id,condition_id,stimulation_source,onset_s, ...
                duration_s,is_null,command_voltage_v,blue_mask_adjustment_pixels);
            acquisition=struct("acquisition_id",string(name),"events",events, ...
                "parameters",struct,"event_order_realized",true, ...
                "target_repetitions",1,"post_delay_s",0.05);
        end

        function controller=controllerWith(testCase,protocol)
            controller=adaptive_optopatch.AdaptiveOptopatchController( ...
                "LuminosApp",simulatedLuminosApp("CameraRoi",[974 100 984 80]), ...
                "RunRoot",testCase.temporaryFolder());
            testCase.addTeardown(@()delete(controller));
            image=uint16(reshape(mod(1:80*100,4096),80,100));
            camera=struct("name","Orca Fusion","ROI",[0 0 100 80],"bin",1, ...
                "x_world_limits",[974 1074],"y_world_limits",[984 1064]);
            root=testCase.temporaryFolder();
            info=struct("snapshot_name","duration_test", ...
                "snapshot_directory",string(root), ...
                "snapshot_path",string(fullfile(root,"snapshot.mat")), ...
                "metadata",struct("rig_name","Virtual_Upright", ...
                    "voltage_camera",camera));
            controller.setReferenceData(image,info, ...
                {[25 25; 40 25; 40 40; 25 40]});
            controller.setPlanParameter("mode","1p_dmd");
            controller.setCellBlueVoltage("cell_001",1.4);
            controller.setProtocol(protocol);
        end

        function root=temporaryFolder(testCase)
            root=string(tempname);
            mkdir(root);
            testCase.addTeardown(@()remove_if_present(root));
        end
    end
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
