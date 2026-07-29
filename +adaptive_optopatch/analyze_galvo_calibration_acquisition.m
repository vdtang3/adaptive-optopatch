function result=analyze_galvo_calibration_acquisition(experimentFolder,plan,options)
%ANALYZE_GALVO_CALIBRATION_ACQUISITION Detect Camera 1 spot at each grid point.
arguments
    experimentFolder (1,1) string
    plan (1,1) struct
    options.MaximumRmsePixels (1,1) double {mustBePositive} = 2
    options.DetectionRadiusPixels (1,1) double {mustBePositive} = 8
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
centroids=nan(nPoints,2); snr=nan(nPoints,1); used=false(nPoints,1);
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
    image=image/numel(indices); averages{k}=single(image);
    smooth=imgaussfilt(image,1.5);
    background=median(smooth,"all");
    noise=1.4826*median(abs(smooth-background),"all")+eps;
    [peak,linearIndex]=max(smooth,[],"all");
    [peakY,peakX]=ind2sub(size(smooth),linearIndex);
    [xx,yy]=meshgrid(1:columns,1:rows);
    local=hypot(xx-peakX,yy-peakY)<=options.DetectionRadiusPixels;
    weights=max(smooth-background,0).*local;
    total=sum(weights,"all");
    if total<=0, continue; end
    localX=sum(xx.*weights,"all")/total;
    localY=sum(yy.*weights,"all")/total;
    centroids(k,:)=[left+(localX-0.5)*binning, ...
        top+(localY-0.5)*binning];
    snr(k)=(peak-background)/noise;
    used(k)=isfinite(snr(k)) && snr(k)>=5;
end
if sum(used)>=6
    calibration=adaptive_optopatch.fit_galvo_camera_calibration( ...
        plan.grid_volts(used,:),centroids(used,:), ...
        "MaximumRmsePixels",options.MaximumRmsePixels);
else
    calibration=struct("passed",false,"issues", ...
        "Fewer than six calibration spots passed automatic detection.");
end
pointTable=table((1:nPoints)',plan.grid_volts(:,1),plan.grid_volts(:,2), ...
    centroids(:,1),centroids(:,2),snr,used, ...
    'VariableNames',{'point_index','galvo_x_v','galvo_y_v', ...
    'camera_x','camera_y','detection_snr','use'});
result=struct("schema_version","0.1.0","created_at", ...
    string(datetime("now","TimeZone","local")), ...
    "experiment_directory",located.experiment_directory, ...
    "camera",camera,"plan",plan,"points",pointTable, ...
    "average_images",{averages},"calibration",calibration);
end
