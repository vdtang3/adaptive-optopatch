function pattern=inspect_spinning_disk_pattern(moviePath,imageSize,bitDepth,frameCount)
%INSPECT_SPINNING_DISK_PATTERN Measure the recurring 12-frame image pattern.
period=12;
rows=imageSize(1); columns=imageSize(2);
if bitDepth==8, precision="*uint8"; else, precision="*uint16"; end
phaseSum=zeros(rows,columns,period);
phaseCount=zeros(period,1);
fid=fopen(moviePath,"r","ieee-le");
if fid<0
    error("adaptive_optopatch:MovieOpenFailed","Could not open %s",moviePath);
end
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
for frameIndex=1:frameCount
    raw=fread(fid,rows*columns,precision);
    if numel(raw)~=rows*columns, break; end
    phase=mod(frameIndex-1,period)+1;
    phaseSum(:,:,phase)=phaseSum(:,:,phase)+ ...
        double(reshape(raw,columns,rows)');
    phaseCount(phase)=phaseCount(phase)+1;
end
phaseMean=phaseSum./reshape(max(phaseCount,1),1,1,period);
grandMean=sum(phaseSum,3)/max(sum(phaseCount),1);
relativePattern=phaseMean./max(grandMean,eps)-1;
relativePattern(:,:,phaseCount==0)=NaN;
pattern=struct("period_frames",period,"phase_frame_count",phaseCount, ...
    "relative_phase_images",relativePattern, ...
    "phase_rms_fraction",squeeze(sqrt(mean(relativePattern.^2,[1 2],"omitnan"))), ...
    "corrected_movie_written",false);
end
