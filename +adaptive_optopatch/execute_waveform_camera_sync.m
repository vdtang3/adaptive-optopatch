function execute_waveform_camera_sync(app,bins,varargin)
%EXECUTE_WAVEFORM_CAMERA_SYNC Dispatch acquisition to real or simulated backend.
arguments
    app
    bins
end
arguments (Repeating)
    varargin
end
if isa(app,"adaptive_optopatch.testing.SimulatedLuminosApp")
    app.simulateAcquisition(bins,varargin{:});
else
    Waveform_Camera_Sync_Acquisition(app,bins,varargin{:});
end
end
