classdef TestSpinningDiskPattern < matlab.unittest.TestCase
    methods (Test)
        function recoversTwelveFrameSpatialPatternWithoutChangingMovie(testCase)
            path=string(tempname)+".bin";
            testCase.addTeardown(@()delete(path));
            fid=fopen(path,"w","ieee-le");
            for frame=1:24
                image=uint16(100*ones(3,4));
                if mod(frame-1,12)==0, image(2,3)=124; end
                fwrite(fid,image',"uint16");
            end
            fclose(fid);
            before=dir(path);
            result=adaptive_optopatch.inspect_spinning_disk_pattern( ...
                path,[3 4],16,24);
            after=dir(path);
            testCase.verifyEqual(result.period_frames,12);
            testCase.verifyEqual(result.phase_frame_count,2*ones(12,1));
            testCase.verifyGreaterThan(result.relative_phase_images(2,3,1),0);
            testCase.verifyEqual(result.relative_phase_images(1,1,1),0);
            testCase.verifyEqual(after.bytes,before.bytes);
            testCase.verifyFalse(result.corrected_movie_written);
        end
    end
end
