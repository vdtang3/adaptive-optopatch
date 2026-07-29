function [referenceImage, info] = read_reference_image(inputPath, options)
%READ_REFERENCE_IMAGE Average sampled frames from the Luminos voltage camera.
% Uses the same little-endian layout and transpose convention as readBinMov.
arguments
    inputPath (1,1) string
    options.NumberOfSamples (1,1) double {mustBePositive,mustBeInteger} = 200
    options.FirstFrame (1,1) double {mustBePositive,mustBeInteger} = 1
    options.LastFrame (1,1) double {mustBePositive} = Inf
end

if isfolder(inputPath)
    located=adaptive_optopatch.find_luminos_experiment(inputPath);
    experimentDirectory = located.experiment_directory;
    outputDataPath = located.output_data_path;
else
    outputDataPath = inputPath;
    experimentDirectory = string(fileparts(inputPath));
end
metadata = adaptive_optopatch.load_luminos_metadata(outputDataPath);
camera = metadata.voltage_camera;
if numel(camera.ROI) < 4
    error("adaptive_optopatch:MissingCameraRoi", ...
        "Voltage-camera ROI metadata is missing or malformed.");
end
nColumns = double(camera.ROI(2));
nRows = double(camera.ROI(4));
moviePath = fullfile(experimentDirectory,camera.frames_file);
if ~isfile(moviePath)
    error("adaptive_optopatch:MissingMovie", "File not found: %s", moviePath);
end

bitDepth = double(camera.bit_depth);
if isempty(bitDepth) || ~ismember(bitDepth,[8 16]), bitDepth = 16; end
bytesPerPixel = bitDepth/8;
listing = dir(moviePath);
nFrames = floor(double(listing.bytes)/(nRows*nColumns*bytesPerPixel));
lastFrame = min(options.LastFrame,nFrames);
if isfinite(lastFrame) && fix(lastFrame) ~= lastFrame
    error("adaptive_optopatch:InvalidLastFrame","LastFrame must be an integer or Inf.");
end
if options.FirstFrame > lastFrame
    error("adaptive_optopatch:InvalidFrameRange", ...
        "FirstFrame exceeds the number of complete movie frames (%d).",nFrames);
end
nSamples = min(options.NumberOfSamples,lastFrame-options.FirstFrame+1);
frameIndices = unique(round(linspace(options.FirstFrame,lastFrame,nSamples)));

fid = fopen(moviePath,"r","ieee-le");
cleanup = onCleanup(@() fclose(fid));
accumulator = zeros(nRows,nColumns);
if bitDepth == 8, precision = "*uint8"; else, precision = "*uint16"; end
for k = 1:numel(frameIndices)
    offset = (frameIndices(k)-1)*nRows*nColumns*bytesPerPixel;
    status = fseek(fid,offset,"bof");
    if status ~= 0, error("adaptive_optopatch:MovieSeekFailed","Could not seek in %s",moviePath); end
    raw = fread(fid,nRows*nColumns,precision);
    if numel(raw) ~= nRows*nColumns
        error("adaptive_optopatch:IncompleteFrame","Frame %d is incomplete.",frameIndices(k));
    end
    frame = permute(reshape(raw,nColumns,nRows),[2 1]);
    accumulator = accumulator + double(frame);
end
referenceImage = single(accumulator/numel(frameIndices));
info = struct("metadata",metadata,"experiment_directory",experimentDirectory, ...
    "movie_path",moviePath,"image_size",[nRows nColumns], ...
    "number_of_frames",nFrames,"sampled_frames",frameIndices, ...
    "bit_depth",bitDepth);
end
