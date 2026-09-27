classdef TestRoiTraceExtractionPerformance < matlab.unittest.TestCase
    %TESTROITRACEEXTRACTIONPERFORMANCE How extraction time scales with ROI count.
    %   Times the original frame-wise loop against the chunked no-motion path
    %   on one synthetic movie, and prints both next to the cost of simply
    %   reading the movie. The frame-wise time grows with every ROI because
    %   each ROI is another pass over every frame; the chunked time should
    %   stay close to the read time. Only agreement is asserted: timings
    %   depend on the machine and are reported, never thresholded.
    properties (Constant)
        Rows=128
        Columns=256
        Frames=1500
        RoiCounts=[1 5 10 20 50]
    end

    properties
        Fixture
    end

    methods (TestClassSetup)
        function writeMovie(testCase)
            folder=string(tempname); mkdir(folder);
            testCase.addTeardown(@()rmdir(folder,"s"));
            nRows=testCase.Rows; nColumns=testCase.Columns;
            camera=struct("deviceType","Camera","name","Voltage", ...
                "cam_id","S/N: 001125","ROI",[0 nColumns 0 nRows],"bin",1, ...
                "bit_depth",16,"frames_requested",testCase.Frames, ...
                "exposuretime",1);
            dmd=struct("deviceType","DMD_Device","name","DMD_Blue");
            Device_Data={struct("rigName","Virtual_Upright"),camera,dmd}; %#ok<NASGU>
            save(fullfile(folder,"output_data.mat"),"Device_Data");
            moviePath=fullfile(folder,"frames1.bin");
            generator=RandStream("twister","Seed",11);
            fid=fopen(moviePath,"w","ieee-le");
            for f=1:testCase.Frames
                fwrite(fid,randi(generator,[900 1100],nColumns,nRows,"uint16"), ...
                    "uint16");
            end
            fclose(fid);
            metadata=adaptive_optopatch.load_luminos_metadata( ...
                fullfile(folder,"output_data.mat"));
            testCase.Fixture=struct("folder",folder,"movie_path",moviePath, ...
                "metadata",metadata);
        end
    end

    methods (Test)
        function chunkedExtractionIsInsensitiveToRoiCount(testCase)
            fixture=testCase.Fixture;
            nPixels=testCase.Rows*testCase.Columns;
            started=tic;
            fid=fopen(fixture.movie_path,"r","ieee-le");
            fread(fid,testCase.Frames*nPixels,"*uint16");
            fclose(fid);
            readSeconds=toc(started);

            counts=testCase.RoiCounts(:);
            frameWiseSeconds=zeros(size(counts));
            chunkedSeconds=zeros(size(counts));
            for k=1:numel(counts)
                masks=disk_grid(testCase.Rows,testCase.Columns,counts(k));
                reference=adaptive_optopatch.create_reference_model( ...
                    zeros(testCase.Rows,testCase.Columns),masks,fixture.metadata);
                started=tic;
                expected=frame_wise_roi_traces(fixture.movie_path,masks,16, ...
                    testCase.Frames);
                frameWiseSeconds(k)=toc(started);
                started=tic;
                actual=adaptive_optopatch.extract_roi_traces( ...
                    fixture.folder,reference,"BackgroundMode","none", ...
                    "MotionCorrection","none","PhotobleachCorrection","none");
                chunkedSeconds(k)=toc(started);
                testCase.verifyEqual(actual.raw_traces,expected.raw_traces);
                testCase.verifyEqual(actual.mean_image,expected.mean_image);
            end

            timings=table(counts,frameWiseSeconds,chunkedSeconds, ...
                frameWiseSeconds./chunkedSeconds, ...
                'VariableNames',{'rois','frame_wise_s','chunked_s','speedup'});
            fprintf("\nROI extraction, %d x %d x %d uint16 (raw read alone %.2f s)\n", ...
                testCase.Rows,testCase.Columns,testCase.Frames,readSeconds);
            disp(timings);
        end
    end
end

function masks=disk_grid(nRows,nColumns,count)
% Radius-6 somata on a regular grid, far enough apart not to touch.
[columnGrid,rowGrid]=meshgrid(1:nColumns,1:nRows);
spacing=16;
centersPerRow=floor((nColumns-spacing)/spacing);
masks=false(nRows,nColumns,count);
for c=1:count
    centerRow=spacing*(1+floor((c-1)/centersPerRow));
    centerColumn=spacing*(1+mod(c-1,centersPerRow));
    masks(:,:,c)=(rowGrid-centerRow).^2+(columnGrid-centerColumn).^2<=36;
end
end
