# Headset microphone on the 3.5 mm jack — ALC256 model option

Working: the jack's microphone is captured cleanly.

## The problem

Plugging a headset into the combo jack gives working playback but no capture —
the headset microphone is not exposed at all.

The codec is a Realtek ALC256. Its behaviour on any given laptop depends on a
per-machine quirk table keyed by PCI subsystem id, which now lives in
`sound/hda/codecs/realtek/alc269.c` — `sound/pci/hda/patch_realtek.c` no longer
exists in current kernels. This unit reports SSID **`1ee7:209d`**, which has no
entry, so the driver falls back to generic pin defaults that leave the headset
mic pin unconfigured.

## The fix

What this board needs is pin `0x19` as a headset microphone without its own
jack detect (`0x01a1913c`), chained into the kernel's headset-mode lifecycle
(`alc_fixup_headset_mode` on probe, init and resume). The stock `alc269` driver
already carries exactly that as a named model, `alc255-dell2`
(`ALC255_FIXUP_DELL2_MIC_NO_PRESENCE` → `ALC255_FIXUP_HEADSET_MODE_NO_HP_MIC`,
which also sets the CTIA jack type), so no code is needed, only a module option
naming it:

```sh
sudo bash patch/headset-mic/install.sh     # then reboot
```

It writes `/etc/modprobe.d/honor-headset-mic.conf`:

```
options snd_sof_intel_hda_generic hda_model=alc255-dell2
options snd_hda_intel model=alc255-dell2
```

The first line is the one that matters: on this machine the codec sits behind
the SOF driver, whose `hda_model=` is handed to the codec as its model name. The
second covers a legacy `snd-hda-intel` boot (`snd_intel_dspcfg.dsp_driver=1`).
The HDMI codec has no models and ignores the option.

The codec module stays the signed in-tree one: nothing to build or sign, and
nothing to redo after a kernel update. The option only takes effect at boot.
Under SOF the codec cannot be re-probed live, `hwC0D0/reconfig` returns
`EBUSY`.

Earlier revisions of this fix rebuilt a monolithic `snd-hda-codec-alc269` with a
new `SND_PCI_QUIRK`. On 7.0, where the Realtek codecs are split into per-codec
modules on top of `snd-hda-codec-realtek-lib`, that overlay hangs the machine
at boot. `install.sh` removes any such overlay it finds (and restores an
in-place backup from the revision before that), so rerunning it is the upgrade
path.

## Verified

On a ZQC-P M1010 (Core Ultra 5 338H), kernel 7.0.0-34, 2026-10-01: after a
reboot `/sys/class/sound/hwC0D0/modelname` reads `alc255-dell2`,
`driver_pin_configs` has `0x19 0x01a1913c`, PipeWire lists the jack as
`sof-hda-dsp Stereo Microphone` next to the digital array, and a headset
microphone records. `tools/status.sh` checks the first two.

## Upstream

This is the most obviously upstreamable change in the repo — a single table
entry, exactly like the hundreds already in that file. It should be submitted
to `alsa-devel`; once merged, drop this directory. `zqc-p/M1010/alc269-headset-mic.patch`
is that entry (with its own fixup body; pointing the quirk at the existing
`ALC255_FIXUP_DELL2_MIC_NO_PRESENCE` would do the same in one line).

## Default capture source and the mic-mute LED

The model sets pin `0x19` to `0x01a1913c`, which includes `JACK_DETECT_OVERRIDE`
because this codec reports no jack presence for that pin. The port is therefore
always "available", and WirePlumber ranked the resulting source above the
built-in microphone array:

| Source | UCM name | `priority.session` |
|---|---|---|
| 3.5 mm jack input | `HiFi__Mic2__source` | 2000 |
| built-in digital array | `HiFi__Mic1__source` | 1648 |

Two things broke as a result:

1. with nothing plugged into the jack, the default recording device was a dead
   analog input;
2. the mic-mute LED stopped following Fn+F7.

The LED failure is worth spelling out, because the obvious fix does not work.
The kernel's control-LED layer (`snd_ctl_led`) drives the `audio-micmute`
trigger that `huawei-wmi` puts on `/sys/class/leds/platform::micmute`. The SOF
machine driver attaches exactly one control to the mic LED group,
`Dmic0 Capture Switch`. Fn+F7 mutes the *default source*, which was the analog
path, so it toggled `Capture Switch` instead and the LED never moved.

Attaching `Capture Switch` to the group as well does **not** help, because
`snd_ctl_led` uses AND semantics:

```c
UPDATE_ROUTE(route, snd_ctl_led_get(lctl));   /* OR of "is unmuted" */
...
led_trigger_event(trig, route ? LED_OFF : LED_ON);
```

The LED lights only when *every* attached control is muted. With both attached,
muting one leaves the other unmuted and the LED stays dark. Verified live.

`51-honor-mic-priority.conf` fixes it at the right layer: it lowers the
jack input to `priority.session = 1400`, below the array. The array becomes the
default again, Fn+F7 mutes `Dmic0 Capture Switch`, and the LED follows. The jack
input stays fully usable, applications can still select it.

`install.sh` drops the file into `/etc/wireplumber/wireplumber.conf.d/`,
removes a stale `~/.local/state/wireplumber/default-nodes` (a manually chosen
default outranks the priority rule) and restarts WirePlumber for the invoking
user.

Verify:

```sh
wpctl status | sed -n '/Sources:/,/Filters/p'     # the array must carry the *
wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1
cat /sys/class/leds/platform::micmute/brightness  # 1
wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0
cat /sys/class/leds/platform::micmute/brightness  # 0
```

Known remaining limit: mute the jack input while it is *not* the default and
the LED will not move, for the same AND reason. Nothing in the kernel's
control-LED design covers "whichever mic the desktop is currently using".

## Surviving kernel updates

Nothing to do: the option lives in `/etc/modprobe.d/` and applies to whatever
kernel boots, and the codec module is the packaged one.

---

## Upstream status

**Never submitted.** A tree-wide grep for `1ee7` in Linux 7.1.8 and in current
`master` finds exactly two `SND_PCI_QUIRK` entries, and neither is this
machine:

| SSID | Machine | Fixup | Landed |
|---|---|---|---|
| `1ee7:2078` | HONOR BRB-X M1010 | `ALC2XX_FIXUP_HEADSET_MIC` | v6.17, commit `b26e2afb3834` |
| `1ee7:2081` | HONOR MRB-XXX M1020 | a board-specific pin table | v7.1, commit `d9448dca4235` |

So `1ee7:209d` is a genuine gap, and the model option will be needed until
somebody sends the one-line patch.

Both precedents are useful, and the first one especially: it was accepted from
an ordinary contributor and it uses **exactly the fixup this repository
applies**. ["ALSA: hda/realtek: Fix headset mic on HONOR BRB-X"](https://patchwork.kernel.org/project/alsa-devel/list/?series=&q=HONOR+BRB-X)
is the template — same vendor, same codec, same fixup, three lines of diff.
The MRB-XXX one shows what to do instead if `ALC2XX_FIXUP_HEADSET_MIC` had not
been enough: its own pin table,
`{0x14,0x90170111},{0x19,0x03a1113c},{0x1a,0x22a190a0},{0x1b,0x90170110}`.

Also worth knowing: **`M1010` does not identify a machine.** The upstream
`1ee7:2078` entry is labelled "HONOR BRB-X M1010" — a different product name
with the same DMI `product_version` string as this unit, and a different audio
subsystem id. Never key anything on `product_version` alone.

None of `1ee7:209d`, `2066`, `207a`, `204d`, `2059`, `2074` or `210c` — the
subsystem ids recorded across [`devices/`](../../devices/) — has an entry
upstream.
