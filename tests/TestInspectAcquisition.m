classdef TestInspectAcquisition < matlab.unittest.TestCase
    %TESTINSPECTACQUISITION Synthetic quick-look linkage and display tests.
    methods (Test)
        function canonicalRoisAndCellIdsAreLoadedWithoutUserInput(testCase)
            fixture=make_fixture(testCase,"1p_dmd",[1.2 0.7]);
            viewer=inspect_acquisition(fixture.experiment,"Visible","off");
            cleanup=onCleanup(@()delete(viewer.figure)); %#ok<NASGU>

            testCase.verifyEqual(viewer.roi_source,"reference.roi_masks");
            testCase.verifyEqual(viewer.cell_ids,["cell_001";"cell_002"]);
            testCase.verifySize(viewer.traces.raw_traces,[10 2]);
            testCase.verifyEqual(viewer.traces.raw_traces(4,:),[900 1000]);
            testCase.verifyGreaterThan(viewer.display_dff(4,1),0, ...
                "A fluorescence decrease must display as upward voltage activity.");
            testCase.verifyEqual(viewer.traces.background_mode,"none");
            testCase.verifyEqual(viewer.traces.motion_correction,"none");
            testCase.verifyEqual(viewer.traces.photobleach_correction,"none");
        end

        function daqTriggerPeriodIsAuthoritativeForTraceTiming(testCase)
            fixture=make_fixture(testCase,"1p_dmd",[1.2 0.7], ...
                "CameraTriggerSource","DAQ","DaqTriggerPeriodMs",1, ...
                "CameraFrameRateHz",17,"CameraExposureTime",250);
            viewer=inspect_acquisition(fixture.experiment,"Visible","off");
            cleanup=onCleanup(@()delete(viewer.figure)); %#ok<NASGU>

            testCase.verifyEqual(viewer.traces.frame_rate_hz,1000);
            testCase.verifyEqual(viewer.traces.tvec,(0:9)'/1000, ...
                "AbsTol",1e-12);
            testCase.verifyEqual(viewer.traces.tvec(end),9/1000, ...
                "AbsTol",1e-12);
        end

        function invalidDaqTriggerPeriodFailsInsteadOfUsingFallback(testCase)
            for period=[NaN 0 -1 Inf]
                fixture=make_fixture(testCase,"1p_dmd",[1.2 0.7], ...
                    "CameraTriggerSource","Trigger each Frame (DAQ)", ...
                    "DaqTriggerPeriodMs",period,"CameraFrameRateHz",17, ...
                    "CameraExposureTime",250);
                testCase.verifyError(@()inspect_acquisition( ...
                    fixture.experiment,"Visible","off"), ...
                    "adaptive_optopatch:InvalidCameraTriggerPeriod");
            end
        end

        function nonDaqCameraRetainsFrameRateFallback(testCase)
            fixture=make_fixture(testCase,"1p_dmd",[1.2 0.7], ...
                "CameraTriggerSource","Internal","DaqTriggerPeriodMs",0, ...
                "CameraFrameRateHz",25,"CameraExposureTime",100);
            viewer=inspect_acquisition(fixture.experiment,"Visible","off");
            cleanup=onCleanup(@()delete(viewer.figure)); %#ok<NASGU>

            testCase.verifyEqual(viewer.traces.frame_rate_hz,25);
            testCase.verifyEqual(viewer.traces.tvec(end),9/25, ...
                "AbsTol",1e-12);
        end

        function traceAndStimulationAxesHaveMatchingGeometry(testCase)
            fixture=make_fixture(testCase,"1p_dmd",[1.2 0.7]);
            viewer=inspect_acquisition(fixture.experiment,"Visible","off");
            cleanup=onCleanup(@()delete(viewer.figure)); %#ok<NASGU>
            drawnow;

            tracePosition=viewer.trace_axes.Position;
            stimulationPosition=viewer.stimulation_axes.Position;
            testCase.verifyEqual(tracePosition([1 3]), ...
                stimulationPosition([1 3]),"AbsTol",1e-6);
            testCase.verifyEqual(viewer.trace_axes.XLim, ...
                viewer.stimulation_axes.XLim,"AbsTol",1e-12);
            testCase.verifyTrue(isvalid(viewer.reference_axes));
            testCase.verifyNotEmpty(findall(viewer.reference_axes,"Type","image"));
            testCase.verifyNotEqual(viewer.reference_axes.Parent, ...
                viewer.trace_axes.Parent, ...
                "The ROI panel must remain outside the shared plotting column.");
        end

        function onePhotonUsesExecutedMod488TimingAndAmplitude(testCase)
            fixture=make_fixture(testCase,"1p_dmd",[1.2 0.7]);
            viewer=inspect_acquisition(fixture.experiment,"Visible","off");
            cleanup=onCleanup(@()delete(viewer.figure)); %#ok<NASGU>

            testCase.verifyEqual(viewer.stimulation.label,"mod488 command (V)");
            testCase.verifyEqual(viewer.stimulation.source, ...
                "adaptive_optopatch_record.pulse_schedule");
            testCase.verifyEqual(viewer.stimulation.events.onset_s,[0.1;0.5]);
            testCase.verifyEqual(viewer.stimulation.events.duration_s,[0.2;0.1]);
            testCase.verifyEqual(viewer.stimulation.events.command_voltage_v,[1.2;0.7]);
            testCase.verifyEqual(max(viewer.stimulation.command_v),1.2);
            testCase.verifyEqual(viewer.stimulation.time_s, ...
                [0;0.1;0.1;0.3;0.3;0.5;0.5;0.6;0.6;0.9], ...
                "AbsTol",1e-12);
            testCase.verifyEqual(viewer.stimulation.command_v, ...
                [0;0;1.2;1.2;0;0;0.7;0.7;0;0],"AbsTol",1e-12);
        end

        function twoPhotonUsesExecutedPockelsTimingAndAmplitude(testCase)
            fixture=make_fixture(testCase,"2p_spiral",[2.1 1.4]);
            viewer=inspect_acquisition(fixture.experiment,"Visible","off");
            cleanup=onCleanup(@()delete(viewer.figure)); %#ok<NASGU>

            testCase.verifyEqual(viewer.stimulation.label,"Pockels command (V)");
            testCase.verifyEqual(viewer.stimulation.events.command_voltage_v,[2.1;1.4]);
            testCase.verifyEqual(max(viewer.stimulation.command_v),2.1);
        end

        function stagedExecutedScheduleWinsOverFrozenSchedule(testCase)
            fixture=make_fixture(testCase,"2p_spiral",[0.2 0.2], ...
                "FrozenVoltage",2.5);
            viewer=inspect_acquisition(fixture.experiment,"Visible","off");
            cleanup=onCleanup(@()delete(viewer.figure)); %#ok<NASGU>

            testCase.verifyEqual( ...
                fixture.record.frozen_pulse_schedule.events.command_voltage_v, ...
                [2.5;2.5]);
            testCase.verifyEqual(viewer.stimulation.events.command_voltage_v,[0.2;0.2]);
            testCase.verifyFalse(any(viewer.stimulation.command_v==2.5));
        end

        function missingReferenceLinkFailsClearly(testCase)
            fixture=make_fixture(testCase,"1p_dmd",[1.2 0.7]);
            record=fixture.record;
            record=rmfield(record,["run_directory","reference_model_path"]);
            adaptive_optopatch_record=record; %#ok<NASGU>
            save(fullfile(fixture.experiment,"output_data.mat"), ...
                "adaptive_optopatch_record","-append");

            testCase.verifyError(@()inspect_acquisition( ...
                fixture.experiment,"Visible","off"), ...
                "adaptive_optopatch:AcquisitionReferenceLinkMissing");
        end

        function conflictingReferenceLinksFailClearly(testCase)
            fixture=make_fixture(testCase,"1p_dmd",[1.2 0.7]);
            alternate=fullfile(fixture.root,"alternate_reference.mat");
            reference=fixture.reference; %#ok<NASGU>
            save(alternate,"reference");
            record=fixture.record;
            record.reference_model_path=string(alternate);
            adaptive_optopatch_record=record; %#ok<NASGU>
            save(fullfile(fixture.experiment,"output_data.mat"), ...
                "adaptive_optopatch_record","-append");

            testCase.verifyError(@()inspect_acquisition( ...
                fixture.experiment,"Visible","off"), ...
                "adaptive_optopatch:AmbiguousAcquisitionReference");
        end
    end
end

function fixture=make_fixture(testCase,mode,executedVoltage,options)
arguments
    testCase
    mode (1,1) string
    executedVoltage (1,2) double
    options.FrozenVoltage (1,1) double = NaN
    options.CameraTriggerSource (1,1) string = ""
    options.DaqTriggerPeriodMs (1,1) double = NaN
    options.CameraFrameRateHz (1,1) double = 10
    options.CameraExposureTime (1,1) double = 100
end
root=tempname; mkdir(root);
testCase.addTeardown(@()remove_if_present(root));
runDirectory=fullfile(root,"adaptive_optopatch_run"); mkdir(runDirectory);
experiment=fullfile(root,"luminos_experiment"); mkdir(experiment);

nRows=6; nColumns=7;
referenceImage=1000*ones(nRows,nColumns);
masks=false(nRows,nColumns,2);
masks(2:3,2:3,1)=true;
masks(4:5,5:6,2)=true;
camera=struct("ROI",[0 nColumns 0 nRows],"bin",1, ...
    "x_world_limits",[0 nColumns],"y_world_limits",[0 nRows]);
metadata=struct("rig_name","Virtual_Upright","voltage_camera",camera);
reference=adaptive_optopatch.create_reference_model( ...
    referenceImage,masks,metadata,"CellIds",["cell_001";"cell_002"]);
save(fullfile(runDirectory,"reference_model.mat"),"reference");

events=table([1;2],["cell_001";"cell_002"],[0.1;0.5],[0.2;0.1], ...
    [false;false],executedVoltage(:), ...
    'VariableNames',{'pulse_id','target_cell_id','onset_s','duration_s', ...
    'is_null','command_voltage_v'});
protocol=struct("acquisition_duration_s",0.9,"events",events);
trial=table(1,mode,'VariableNames',{'trial_id','stimulation_mode'});
record=struct( ...
    "trial",trial,"pulse_schedule",protocol, ...
    "run_directory",string(runDirectory), ...
    "reference_model_path",string(fullfile(runDirectory,"reference_model.mat")));
if isfinite(options.FrozenVoltage)
    frozen=protocol;
    frozen.events.command_voltage_v(:)=options.FrozenVoltage;
    record.frozen_pulse_schedule=frozen;
end
adaptive_optopatch_record=record; %#ok<NASGU>

appArchive=struct("rigName","Virtual_Upright");
cameraArchive=struct("deviceType","Camera","name","Orca Fusion", ...
    "cam_id","S/N: 001125","ROI",[0 nColumns 0 nRows],"bin",1, ...
    "bit_depth",16,"frames_requested",10, ...
    "frametrigger_source",options.CameraTriggerSource, ...
    "daqtrig_period_ms",options.DaqTriggerPeriodMs, ...
    "exposuretime",options.CameraExposureTime, ...
    "frame_rate",options.CameraFrameRateHz);
dmdArchive=struct("deviceType","DMD","name","DMD_Blue");
Device_Data={appArchive,cameraArchive,dmdArchive}; %#ok<NASGU>
save(fullfile(experiment,"output_data.mat"), ...
    "Device_Data","adaptive_optopatch_record");

fid=fopen(fullfile(experiment,"frames1.bin"),"w","ieee-le");
fileCleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
for frameIndex=1:10
    frame=uint16(referenceImage);
    if frameIndex==4, frame(masks(:,:,1))=900; end
    fwrite(fid,permute(frame,[2 1]),"uint16");
end

fixture=struct("root",root,"run_directory",runDirectory, ...
    "experiment",string(experiment),"reference",reference,"record",record);
end

function remove_if_present(folder)
if isfolder(folder), rmdir(folder,"s"); end
end
