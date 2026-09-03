# Pulse protocols

These MATLAB scripts create timing-only `pulse_protocol.mat` artifacts for the
Adaptive Optopatch GUI. Edit the parameters near the top of a script, run it,
and load the resulting MAT file with **Load protocol…**.

| Script | Use |
|---|---|
| `create_connectivity_screen_protocol.m` | Many pulses with randomized dark gaps |
| `create_regular_pulse_protocol.m` | Pulses at one fixed repetition rate |
| `create_stf_frequency_mix_protocol.m` | Randomly interleaved single, 50 Hz, and 100 Hz events |
| `create_paired_pulse_protocol.m` | Randomly interleaved paired-pulse intervals |
| `create_custom_event_protocol.m` | Explicit onsets, durations, and relative amplitudes |

By default, scripts write validated files to `pulse-protocols/generated/`. That
directory is ignored by Git because generated protocols are experiment inputs,
not source code. Each script leaves the generated protocol in the MATLAB
workspace as `protocol` for inspection.

The `amplitude_fraction` field is relative. Absolute mod488 or Pockels voltage
is selected and frozen in the acquisition GUI. A fraction of `1` uses that full
configured voltage, `0.5` uses half of it, and `0` is a null event.

For reproducibility, archive the generated MAT file with the experiment and
retain the script parameters and random seed used to create it.
