# Built-in microphones sound hollow and far away

| | |
|---|---|
| Status | Fixed |
| Cause | SOF's capture layout, which every application downmixes |
| Fix | A PipeWire config: the two microphones alone, through WebRTC |
| Survives kernel updates | Yes, nothing to rebuild |

```sh
sudo bash patch/dmic-array/install.sh
```

## Symptom

The built-in microphone works, and sounds bad: hollow, thin, as if from the
next room, with the keyboard about as loud as the voice.

## Cause

SOF captures the array (`HiFi__Mic1__source`) as four channels, and they are
not four microphones:

| Channel | What it is | Evidence |
|---|---|---|
| FL | the microphone right of the camera, as seen from the seat | a scratch on the bezel there: FL 6 dB above FR |
| FR | the microphone left of the camera | a scratch there: FR 8 dB above FL, and 9 samples (48 kHz) earlier, so ≥ 6.4 cm apart |
| RL, RR | the DSP's TDFB beam, the same signal twice | RL and RR equal sample for sample; correlation −0.29 with FL, so opposite phase |

The mixer exposes the beam as `Dmic0 Capture TDFB beam switch` and `angle set
enum` (−90…90°, 0 by default). The topology is SOF's generic one, not tuned for
this lid: of four scratch points the beam heard the right edge of the palm rest
loudest.

Applications take all four channels and downmix them. The beam, in opposite
phase, partly cancels the microphones, and what is left is the hollow voice.
The two microphones on their own, summed, are already a beam: a voice from in
front of the screen reaches both at once (0 samples apart) and adds up, sound
from the side does not.

Voice over keyboard on a ZQC-P M1010, 5 s of typing then 5 s of talking,
recorded at once from the raw array and from the source this fix adds:

| Variant | Keyboard | Voice | Voice over keyboard |
|---|---|---|---|
| all four downmixed (as shipped) | −33.7 dB | −22.7 dB | 11.1 dB |
| FL + FR | −35.6 dB | −23.2 dB | 12.4 dB |
| the beam (RL) | −34.7 dB | −21.5 dB | 13.2 dB |
| the beam through WebRTC | −39.9 dB | −24.2 dB | 15.7 dB |

By ear FL + FR is the cleanest voice and the beam slightly coloured, so the fix
uses the two microphones and lets WebRTC deal with the keyboard.

## The fix

[`51-honor-dmic-array.conf`](51-honor-dmic-array.conf), installed into
`/etc/pipewire/pipewire.conf.d/`, loads PipeWire's echo-cancel module with the
WebRTC engine on FL and FR of the raw array: a high-pass, noise suppression,
gain control, and echo cancellation against the default sink's monitor. The
result is a source named **Built-in Microphone** (`honor-dmic`) at
`priority.session` 3000, above the raw array (1648) and the jack (1400, from
[`../headset-mic/`](../headset-mic/)), so it is the default. The raw array stays
listed for anyone who wants it.

The installer drops WirePlumber's remembered default source, which would
otherwise outrank the priority, and restarts the invoking user's PipeWire.

`SKIP_DMIC=1` leaves it out of `apply_patch.sh`.

## Not fixed

The channel layout itself comes from the SOF topology in `sof-firmware`. A
topology that captured the two microphones alone, or tuned the beam to this
geometry, is the proper fix and is out of reach of a config file.

## Verified

ZQC-P M1010, Ubuntu 26.04, kernel 7.0.0-38, PipeWire 1.6.2, WirePlumber 0.5.13,
2026-10-15.
