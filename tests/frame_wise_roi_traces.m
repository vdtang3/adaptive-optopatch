function expected=frame_wise_roi_traces(moviePath,roiMasks,bitDepth,nFrames)
%FRAME_WISE_ROI_TRACES The original per-frame, per-ROI mean extraction.
%   This is the loop extract_roi_traces used for every acquisition before
%   its no-motion path moved to one sparse product per chunk of frames. It
%   is kept here, deliberately unoptimized, as the reference that path must
%   reproduce, and as the baseline the performance suite times it against.
[nRows,nColumns,nCells]=size(roiMasks);
if bitDepth==8, precision="*uint8"; else, precision="*uint16"; end
rawTraces=nan(nFrames,nCells);
frameSum=zeros(nRows,nColumns);
fid=fopen(moviePath,"r","ieee-le");
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
for f=1:nFrames
    raw=fread(fid,nRows*nColumns,precision);
    if numel(raw)~=nRows*nColumns, break; end
    frame=double(permute(reshape(raw,nColumns,nRows),[2 1]));
    frameSum=frameSum+frame;
    for c=1:nCells
        rawTraces(f,c)=mean(frame(roiMasks(:,:,c)),"omitnan");
    end
end
expected=struct("raw_traces",rawTraces,"mean_image",frameSum/nFrames);
end
