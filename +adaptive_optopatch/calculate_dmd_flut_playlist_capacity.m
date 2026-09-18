function capacity=calculate_dmd_flut_playlist_capacity(flutMaxEntries,uniqueMaskCount)
%CALCULATE_DMD_FLUT_PLAYLIST_CAPACITY Executable Luminos/ALP playlist size.
arguments
    flutMaxEntries (1,1) double {mustBePositive,mustBeInteger}
    uniqueMaskCount (1,1) double {mustBePositive,mustBeInteger}
end
% Luminos' tFlutWrite transfer buffer contains 4096 frame numbers. An ALP
% playlist referring to slots above 512 needs 18-bit entries, which consume
% two of the controller's 9-bit FLUT positions.
widthMultiplier=1+(uniqueMaskCount>512);
capacity=min(4096,floor(flutMaxEntries/widthMultiplier));
end
