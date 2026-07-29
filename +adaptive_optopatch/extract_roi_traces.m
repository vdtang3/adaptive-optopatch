function result = extract_roi_traces(experimentDirectory, reference, options)
%EXTRACT_ROI_TRACES Stream a Luminos movie and extract corrected soma traces.
arguments
    experimentDirectory (1,1) string
    reference (1,1) struct
    options.BackgroundMode (1,1) string {mustBeMember(options.BackgroundMode,["none","local_annulus","null_roi"])} = "local_annulus"
    options.NullRoiMask = []
    options.AnnulusInnerPixels (1,1) double {mustBeNonnegative,mustBeInteger} = 2
    options.AnnulusOuterPixels (1,1) double {mustBePositive,mustBeInteger} = 8
    options.MotionCorrection (1,1) string {mustBeMember(options.MotionCorrection,["none","integer_translation"])} = "none"
    options.MaximumShiftPixels (1,1) double {mustBeNonnegative,mustBeInteger} = 5
    options.PhotobleachCorrection (1,1) string {mustBeMember(options.PhotobleachCorrection,["none","linear"])} = "none"
    options.FrameRateHz (1,1) double = NaN
    options.MaximumFrames (1,1) double {mustBePositive} = Inf
end
if options.AnnulusOuterPixels<=options.AnnulusInnerPixels
    error("adaptive_optopatch:InvalidAnnulus", ...
        "AnnulusOuterPixels must exceed AnnulusInnerPixels.");
end
outputDataPath=fullfile(experimentDirectory,"output_data.mat");
metadata=adaptive_optopatch.load_luminos_metadata(outputDataPath);
camera=metadata.voltage_camera;
nColumns=double(camera.ROI(2)); nRows=double(camera.ROI(4));
if any([nRows nColumns]~=reference.image_size)
    error("adaptive_optopatch:ReferenceMovieSizeMismatch", ...
        "Reference masks do not match the acquired camera ROI.");
end
moviePath=fullfile(experimentDirectory,camera.frames_file);
listing=dir(moviePath);
if isempty(listing), error("adaptive_optopatch:MissingMovie","File not found: %s",moviePath); end
bitDepth=double(camera.bit_depth);
if isempty(bitDepth) || ~ismember(bitDepth,[8 16]), bitDepth=16; end
bytesPerPixel=bitDepth/8;
nFrames=floor(double(listing.bytes)/(nRows*nColumns*bytesPerPixel));
nFrames=min(nFrames,options.MaximumFrames);
nFrames=floor(nFrames);
nCells=size(reference.roi_masks,3);

annulusMasks=false(nRows,nColumns,nCells);
allSomata=any(reference.roi_masks,3);
if options.BackgroundMode=="local_annulus"
    outerStrel=strel("disk",options.AnnulusOuterPixels,0);
    innerStrel=strel("disk",options.AnnulusInnerPixels,0);
    for c=1:nCells
        annulusMasks(:,:,c)=imdilate(reference.roi_masks(:,:,c),outerStrel) & ...
            ~imdilate(reference.roi_masks(:,:,c),innerStrel) & ~allSomata;
        if ~any(annulusMasks(:,:,c),"all")
            error("adaptive_optopatch:EmptyAnnulus", ...
                "Local background annulus is empty for cell %d.",c);
        end
    end
elseif options.BackgroundMode=="null_roi"
    if isempty(options.NullRoiMask) || ...
            any(size(options.NullRoiMask)~=[nRows nColumns])
        error("adaptive_optopatch:InvalidNullRoi", ...
            "NullRoiMask must match the movie dimensions.");
    end
    nullMask=logical(options.NullRoiMask);
    if ~any(nullMask,"all"), error("adaptive_optopatch:EmptyNullRoi","Null ROI is empty."); end
end

rawTraces=nan(nFrames,nCells);
backgroundTraces=zeros(nFrames,nCells);
shifts=zeros(nFrames,2);
registrationPeak=nan(nFrames,1);
template=double(reference.reference_image);
fid=fopen(moviePath,"r","ieee-le");
if fid<0, error("adaptive_optopatch:MovieOpenFailed","Could not open %s",moviePath); end
cleanup=onCleanup(@()fclose(fid));
if bitDepth==8, precision="*uint8"; else, precision="*uint16"; end
for f=1:nFrames
    raw=fread(fid,nRows*nColumns,precision);
    if numel(raw)~=nRows*nColumns, break; end
    frame=double(permute(reshape(raw,nColumns,nRows),[2 1]));
    if options.MotionCorrection=="integer_translation"
        [dy,dx,peak]=estimate_shift(frame,template,options.MaximumShiftPixels);
        shifts(f,:)=[dy dx]; registrationPeak(f)=peak;
        frame=shift_with_nan(frame,-dy,-dx);
    end
    for c=1:nCells
        rawTraces(f,c)=mean(frame(reference.roi_masks(:,:,c)),"omitnan");
        if options.BackgroundMode=="local_annulus"
            backgroundTraces(f,c)=mean(frame(annulusMasks(:,:,c)),"omitnan");
        elseif options.BackgroundMode=="null_roi"
            backgroundTraces(f,c)=mean(frame(nullMask),"omitnan");
        end
    end
end
corrected=rawTraces-backgroundTraces;
if options.PhotobleachCorrection=="linear"
    x=(1:nFrames)';
    for c=1:nCells
        ok=isfinite(corrected(:,c));
        p=polyfit(x(ok),corrected(ok,c),1);
        trend=polyval(p,x);
        corrected(:,c)=corrected(:,c)-trend+median(trend,"omitnan");
    end
end
baseline=median(corrected,1,"omitnan");
dff=(corrected-baseline)./max(abs(baseline),eps);
frameRate=options.FrameRateHz;
if ~isfinite(frameRate)
    frameRate=derive_frame_rate(camera);
end
if isfinite(frameRate), tvec=(0:nFrames-1)'/frameRate; else, tvec=(0:nFrames-1)'; end

result=struct("schema_version","0.2.0","experiment_directory",experimentDirectory, ...
    "movie_path",moviePath,"raw_traces",rawTraces, ...
    "background_traces",backgroundTraces,"corrected_traces",corrected, ...
    "dff",dff,"tvec",tvec,"frame_rate_hz",frameRate, ...
    "motion_shifts_yx",shifts,"registration_peak",registrationPeak, ...
    "background_mode",options.BackgroundMode, ...
    "motion_correction",options.MotionCorrection, ...
    "photobleach_correction",options.PhotobleachCorrection);
end

function rate=derive_frame_rate(camera)
rate=NaN;
if ~isempty(camera.frame_rate) && isfinite(double(camera.frame_rate))
    rate=double(camera.frame_rate); return
end
if ~isempty(camera.exposuretime)
    exposure=double(camera.exposuretime);
    if exposure>0
        if exposure>0.1, rate=1000/exposure; else, rate=1/exposure; end
    end
end
end

function [dy,dx,peak]=estimate_shift(frame,template,maxShift)
a=frame-mean(frame,"all","omitnan"); b=template-mean(template,"all","omitnan");
a(~isfinite(a))=0; b(~isfinite(b))=0;
c=real(ifft2(fft2(a).*conj(fft2(b))));
[nRows,nColumns]=size(c);
[~,idx]=max(c(:)); [py,px]=ind2sub(size(c),idx);
dy=py-1; dx=px-1;
if dy>nRows/2, dy=dy-nRows; end
if dx>nColumns/2, dx=dx-nColumns; end
dy=max(-maxShift,min(maxShift,dy)); dx=max(-maxShift,min(maxShift,dx));
peak=c(idx)/(sqrt(sum(a.^2,"all")*sum(b.^2,"all"))+eps);
end

function out=shift_with_nan(frame,dy,dx)
out=circshift(frame,[dy dx]);
if dy>0, out(1:dy,:)=NaN; elseif dy<0, out(end+dy+1:end,:)=NaN; end
if dx>0, out(:,1:dx)=NaN; elseif dx<0, out(:,end+dx+1:end)=NaN; end
end
