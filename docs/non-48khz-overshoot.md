# Non-48 kHz destination overshoot

Referenced from the [README](../README.md#limitations). This is the full measurement
record behind the limitation "non-48 kHz destinations work, but intermittently show a
peak 6.8–7.6% above the source tone — the cause is not established." Nothing here has
been softened from the original finding; it was moved out of the README verbatim so
the top-level Limitations list stays skimmable.

Tested with a 44.1 kHz virtual device (`spotroute selftest`, 8 runs): every run passed
with real, non-zero audio, but 2 of the 8 measured peak ≈0.267–0.269 against a source
amplitude of 0.25 (6.8–7.6% high); a matching-rate 48 kHz destination showed no such
outliers across the same number of runs. An earlier version of this document
attributed the overshoot to sample-rate-conversion ripple; that explanation does not
survive its own numbers and has been retracted here. The total SRC error for a 440 Hz
tone at these rates is bounded around 0.04% (the intersample-peak deficit is
`1 − cos(π·440/48000) ≈ 0.0004`) — two orders of magnitude below what was measured.
The intermittency argues against a phase-dependent steady-state effect too:
`Metrics.peak` is a monotone running max over roughly 132,000 samples per run, so a
true steady-state ripple would visit its worst phase in every run and should have
produced 8 outliers out of 8, not 2. Benign candidates (the tone's onset transient,
the HAL's own output-start ramp) and one non-benign candidate (an occasional
drift-compensation sample slip, which would be audible) remain undistinguished, so
"not corruption" is not yet an earned conclusion. The falsifiable test that would
settle it: log the callback index at which the peak occurs, or reset `peak` after the
first N callbacks — if the outliers vanish, it was the tone's onset transient. Until
that test is run, treat a non-48 kHz destination as not guaranteed to sound
bit-identical to a matching-rate one.
