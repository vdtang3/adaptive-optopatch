function result=analyze_galvo_calibration_acquisition(experimentFolder,plan,options)
%ANALYZE_GALVO_CALIBRATION_ACQUISITION Detect Camera 1 spot at each grid point.
arguments
    experimentFolder (1,1) string
    plan (1,1) struct
    options.MaximumRmsePixels (1,1) double {mustBePositive} = 2
    options.DetectionRadiusPixels (1,1) double {mustBePositive} = 8
    options.MinimumDetectionSnr (1,1) double {mustBePositive} = 4
end
located=adaptive_optopatch.find_luminos_experiment(experimentFolder);
metadata=adaptive_optopatch.load_luminos_metadata(located.output_data_path);
camera=metadata.voltage_camera;
rows=double(camera.ROI(4)); columns=double(camera.ROI(2));
left=double(camera.ROI(1)); top=double(camera.ROI(3));
binning=double(camera.bin);
if isempty(binning) || binning<1, binning=1; end
movie=fullfile(located.experiment_directory,camera.frames_file);
listing=dir(movie);
bytesPerPixel=double(camera.bit_depth)/8;
nFrames=floor(double(listing.bytes)/(rows*columns*bytesPerPixel));
fid=fopen(movie,"r","ieee-le");
if fid<0, error("adaptive_optopatch:MovieOpenFailed","Could not open %s.",movie); end
cleanup=onCleanup(@()fclose(fid));
if camera.bit_depth==8, precision="*uint8"; else, precision="*uint16"; end
nPoints=numel(plan.points);
expectedLastFrame=0;
for k=1:nPoints
    if ~isempty(plan.points(k).expected_frame_indices)
        expectedLastFrame=max(expectedLastFrame, ...
            max(double(plan.points(k).expected_frame_indices)));
    end
end
recordingComplete=nFrames>=expectedLastFrame;
averages=cell(nPoints,1);
for k=1:nPoints
    indices=double(plan.points(k).expected_frame_indices(:));
    indices=indices(indices>=1 & indices<=nFrames);
    if isempty(indices), continue; end
    image=zeros(rows,columns);
    for frame=reshape(indices,1,[])
        offset=(frame-1)*rows*columns*bytesPerPixel;
        if fseek(fid,offset,"bof")~=0, continue; end
        raw=fread(fid,rows*columns,precision);
        if numel(raw)~=rows*columns, continue; end
        image=image+double(permute(reshape(raw,columns,rows),[2 1]));
    end
    averages{k}=single(image/numel(indices));
end

% The sample can contain structures brighter than the attenuated laser
% spot.  Estimate the stationary image from the median across grid
% positions, then detect only the feature that moves with the galvos.
valid=~cellfun(@isempty,averages);
if any(valid)
    stack=cat(3,averages{valid});
    stationaryBackground=median(stack,3);
else
    stationaryBackground=zeros(rows,columns,"single");
end
centroids=nan(nPoints,2); snr=nan(nPoints,1); used=false(nPoints,1);
detectionImages=cell(nPoints,1);
[xx,yy]=meshgrid(1:columns,1:rows);
for k=1:nPoints
    if isempty(averages{k}), continue; end
    difference=double(averages{k}-stationaryBackground);
    smooth=imgaussfilt(difference,1.5);
    background=median(smooth,"all");
    residual=smooth-background;
    noise=1.4826*median(abs(residual),"all")+eps;
    [peak,linearIndex]=max(residual,[],"all");
    [peakY,peakX]=ind2sub(size(smooth),linearIndex);
    local=hypot(xx-peakX,yy-peakY)<=options.DetectionRadiusPixels;
    weights=max(residual,0).*local;
    total=sum(weights,"all");
    if total<=0, continue; end
    localX=sum(xx.*weights,"all")/total;
    localY=sum(yy.*weights,"all")/total;
    centroids(k,:)=[left+(localX-0.5)*binning, ...
        top+(localY-0.5)*binning];
    snr(k)=peak/noise;
    used(k)=isfinite(snr(k)) && snr(k)>=options.MinimumDetectionSnr;
    detectionImages{k}=single(residual);
end
if ~recordingComplete
    calibration=struct("passed",false,"issues", ...
        sprintf(['Camera 1 recording ended after %d frames, but the ' ...
        'calibration required at least %d frames. The spots that were ' ...
        'recorded passed detection (%d of %d planned points).'], ...
        nFrames,expectedLastFrame,sum(used),nPoints));
elseif sum(used)>=6
    calibration=adaptive_optopatch.fit_galvo_camera_calibration( ...
        plan.grid_volts(used,:),centroids(used,:), ...
        "MaximumRmsePixels",options.MaximumRmsePixels);
else
    calibration=struct("passed",false,"issues", ...
        sprintf(['Only %d of %d calibration spots passed automatic ' ...
        'detection (minimum SNR %.2f; detected SNR range %.2f to %.2f).'], ...
        sum(used),nPoints,options.MinimumDetectionSnr, ...
        min(snr,[],"omitnan"),max(snr,[],"omitnan")));
end
pointTable=table((1:nPoints)',plan.grid_volts(:,1),plan.grid_volts(:,2), ...
    centroids(:,1),centroids(:,2),snr,used, ...
    'VariableNames',{'point_index','galvo_x_v','galvo_y_v', ...
    'camera_x','camera_y','detection_snr','use'});
result=struct("schema_version","0.1.0","created_at", ...
    string(datetime("now","TimeZone","local")), ...
    "experiment_directory",located.experiment_directory, ...
    "camera",camera,"plan",plan,"points",pointTable, ...
    "average_images",{averages}, ...
    "stationary_background_image",stationaryBackground, ...
    "detection_images",{detectionImages}, ...
    "recorded_frame_count",nFrames, ...
    "expected_last_calibration_frame",expectedLastFrame, ...
    "recording_complete",recordingComplete, ...
    "minimum_detection_snr",options.MinimumDetectionSnr, ...
    "calibration",calibration);
end
