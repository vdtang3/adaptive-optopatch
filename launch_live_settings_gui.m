function app = launch_live_settings_gui(luminosApp)
%LAUNCH_LIVE_SETTINGS_GUI Snapshot active Luminos settings for review.
snapshot=adaptive_optopatch.snapshot_luminos_settings(luminosApp);
app=adaptive_optopatch.SettingsReviewApp(snapshot);
end
