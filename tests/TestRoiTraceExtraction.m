classdef TestRoiTraceExtraction < matlab.unittest.TestCase
    %TESTROITRACEEXTRACTION Chunked ROI extraction reproduces the frame-wise loop.
    %   Camera counts are integers, so per-ROI pixel sums are exact in double
    %   and the chunked path is expected to agree with the original
    %   mean(frame(mask)) loop exactly, not merely within a tolerance.
    %   Movies longer than 500 frames cross the chunk boundary for these
    %   small frames (see MAX_CHUNK_FRAMES in extract_roi_traces).
    methods (Test)
        function multipleRoisMatchFrameWiseReferenceAcrossChunks(testCase)
            fixture=write_movie(testCase,random_movie("uint16",23,31,1203), ...
                three_masks(23,31));
            actual=extract_plain(fixture);
            verify_matches_reference(testCase,actual,fixture,1203);
        end

        function singleRoiMatchesFrameWiseReference(testCase)
            masks=false(23,31,1); masks(4:9,6:14,1)=true;
            fixture=write_movie(testCase,random_movie("uint16",23,31,640),masks);
            actual=extract_plain(fixture);
            testCase.verifySize(actual.raw_traces,[640 1]);
            verify_matches_reference(testCase,actual,fixture,640);
        end

        function eightBitMovieMatchesFrameWiseReference(testCase)
            fixture=write_movie(testCase,random_movie("uint8",23,31,1001), ...
                three_masks(23,31),"BitDepth",8);
            actual=extract_plain(fixture);
            verify_matches_reference(testCase,actual,fixture,1001);
        end

        function maximumFramesStopsPartwayThroughAChunk(testCase)
            fixture=write_movie(testCase,random_movie("uint16",23,31,1203), ...
                three_masks(23,31));
            actual=extract_plain(fixture,"MaximumFrames",777);
            testCase.verifySize(actual.raw_traces,[777 3]);
            verify_matches_reference(testCase,actual,fixture,777);
        end

        function backgroundModesMatchFrameWisePath(testCase)
            % A zero-pixel shift limit makes the retained motion-corrected,
            % frame-by-frame path an unregistered frame-wise extraction.
            fixture=write_movie(testCase,random_movie("uint16",23,31,620), ...
                three_masks(23,31));
            nullMask=false(23,31); nullMask(20:22,25:30)=true;
            common={"NullRoiMask",nullMask,"AnnulusInnerPixels",1, ...
                "AnnulusOuterPixels",3,"FrameRateHz",500};
            for mode=["local_annulus","null_roi"]
                chunked=adaptive_optopatch.extract_roi_traces( ...
                    fixture.folder,fixture.reference,"BackgroundMode",mode, ...
                    common{:});
                frameWise=adaptive_optopatch.extract_roi_traces( ...
                    fixture.folder,fixture.reference,"BackgroundMode",mode, ...
                    "MotionCorrection","integer_translation", ...
                    "MaximumShiftPixels",0,common{:});
                for field=["raw_traces","background_traces", ...
                        "corrected_traces","dff","tvec","mean_image"]
                    testCase.verifyEqual(chunked.(field),frameWise.(field), ...
                        mode+": "+field);
                end
            end
            nullOnly=adaptive_optopatch.extract_roi_traces( ...
                fixture.folder,fixture.reference,"BackgroundMode","null_roi", ...
                common{:});
            testCase.verifyEqual(nullOnly.background_traces, ...
                repmat(nullOnly.background_traces(:,1),1,3), ...
                "One null-region trace is shared by every cell.");
        end
    end
end

function actual=extract_plain(fixture,varargin)
actual=adaptive_optopatch.extract_roi_traces(fixture.folder,fixture.reference, ...
    "BackgroundMode","none","MotionCorrection","none", ...
    "PhotobleachCorrection","none","FrameRateHz",500,varargin{:});
end

function verify_matches_reference(testCase,actual,fixture,nFrames)
expected=frame_wise_roi_traces(fixture.movie_path, ...
    fixture.reference.roi_masks,fixture.bit_depth,nFrames);
testCase.verifyEqual(actual.raw_traces,expected.raw_traces);
testCase.verifyEqual(actual.mean_image,expected.mean_image);
testCase.verifyEqual(actual.background_traces,zeros(size(expected.raw_traces)));
testCase.verifyEqual(actual.corrected_traces,expected.raw_traces);
baseline=median(expected.raw_traces,1,"omitnan");
testCase.verifyEqual(median(actual.corrected_traces,1,"omitnan"),baseline);
testCase.verifyEqual(actual.dff, ...
    (expected.raw_traces-baseline)./max(abs(baseline),eps));
testCase.verifyEqual(actual.tvec,(0:nFrames-1)'/500);
end

function movie=random_movie(className,nRows,nColumns,nFrames)
% Full-range counts, so any loss of integer exactness would show.
generator=RandStream("twister","Seed",nFrames);
movie=randi(generator,[0 double(intmax(className))], ...
    nRows,nColumns,nFrames,className);
end

function masks=three_masks(nRows,nColumns)
% Non-overlapping somata of different sizes, including a single pixel.
masks=false(nRows,nColumns,3);
masks(3:5,3:6,1)=true;
masks(12:20,10:12,2)=true;
masks(8,25,3)=true;
end

function fixture=write_movie(testCase,movie,masks,options)
arguments
    testCase
    movie
    masks
    options.BitDepth (1,1) double = 16
end
folder=string(tempname); mkdir(folder);
testCase.addTeardown(@()rmdir(folder,"s"));
[nRows,nColumns,nFrames]=size(movie);
camera=struct("deviceType","Camera","name","Voltage", ...
    "cam_id","S/N: 001125","ROI",[0 nColumns 0 nRows],"bin",1, ...
    "bit_depth",options.BitDepth,"frames_requested",nFrames, ...
    "exposuretime",1);
dmd=struct("deviceType","DMD_Device","name","DMD_Blue");
Device_Data={struct("rigName","Virtual_Upright"),camera,dmd}; %#ok<NASGU>
save(fullfile(folder,"output_data.mat"),"Device_Data");
moviePath=fullfile(folder,"frames1.bin");
fid=fopen(moviePath,"w","ieee-le");
% Luminos writes each frame row-major.
fwrite(fid,permute(movie,[2 1 3]),class(movie));
fclose(fid);
metadata=adaptive_optopatch.load_luminos_metadata( ...
    fullfile(folder,"output_data.mat"));
reference=adaptive_optopatch.create_reference_model( ...
    zeros(nRows,nColumns),masks,metadata);
fixture=struct("folder",folder,"movie_path",moviePath, ...
    "reference",reference,"bit_depth",options.BitDepth);
end
