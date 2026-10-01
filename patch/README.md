# Fixes for HONOR MagicBook Pro 14 AI (ZQC-P / M1010)

Each subdirectory is one self-contained fix: the patch or source it needs, an
`install.sh`, and a `README.md` explaining what is broken and why the fix looks
the way it does. Every installer is safe to re-run and locates its own files,
so it can be invoked directly from anywhere.

## Layout

Inside a fix, everything that belongs to **one machine** is under

```
patch/<fix>/<model>/<board>/recipe.conf
```

the same two words `devices/<model>.conf` uses to identify a machine, and the
same split one level further down. The profile says what the machine *is*: its
identity, its trust, the ids of the parts fitted. The directory here says what
this fix has to *do* on it: which table to install, which program to build,
which EC offsets to read, which floor the panel wants.

That is what makes preparing a fix for a new machine a matter of writing one
file next to the machines that already have one, instead of finding the place
inside an installer where the last machine was special-cased and adding a
branch beside it. Two machines that need the same files do not get two copies:
the second is a `recipe.conf` holding `same_as=<model>/<board>` and nothing
else, and `tools/selftest.sh` refuses two identical files under one fix so a
copy cannot be made by accident and then drift.

`any` in place of the board revision is the directory form of the profile's
`[board *]`: it means every revision of that model, and it is what to write when
something is known to be in a model and nobody can say which revision.

To add a machine to a fix:

1. `mkdir -p patch/<fix>/<model>/<board>/`. Model lowercase, board exactly as
   its `[board ...]` header spells it.
2. Write `recipe.conf`. `name`, `status` and `origin` always. `device=<vid>:<pid>`
   where the fix can see the part on a bus, and the installer will then refuse
   if the unit in front of it has a different one: a profile records what a
   board usually ships, the bus records what it shipped.
3. If the machine needs the same files as one already here, add
   `same_as=<model>/<board>` and stop. Otherwise put the files in that directory
   and name them in the recipe.
4. List the fix in that board's section of its profile.

[`lib/variant.sh`](../lib/variant.sh) does the lookup for every fix.
[`docs/ADDING-A-MODEL.md`](../docs/ADDING-A-MODEL.md) is the wider procedure for
a machine nobody has described yet.

Developed and tested on BIOS 1.10, Core Ultra X9 388H (Panther Lake), CachyOS,
kernel 7.1.5.

Which fixes an installer will run depends on the device profile in
[`devices/`](../devices/) that matches the machine. Thirteen further HONOR
MagicBook profiles are recognised, all of them from somebody else's hardware or
from a hardware probe rather than from a machine anybody here owns; on those,
only the fixes that cannot carry another machine's constants are offered, and
on several of them the honest answer is that nothing here applies at all. See
[`docs/hardware/`](../docs/hardware/) for what is known about each, and
[`docs/ADDING-A-MODEL.md`](../docs/ADDING-A-MODEL.md) for adding one.

## Status

| Area | Status | Fix |
|---|---|---|
| Touchpad, touchscreen, internal keyboard | works | [`acpi-override/`](acpi-override/) — patched SSDT27 plus `i8042.dumbkbd=1`. **Prerequisite for a usable machine** |
| Microphone mutes itself, mic-mute LED flickers | works | [`micmute/`](micmute/) — HID-BPF fixup for the touchscreen's vendor collection |
| Fingerprint reader, Goodix `27c6:6f94` | works | [`fingerprint/`](fingerprint/) — two-line `libfprint` id patch |
| Headset microphone, 3.5 mm jack | works | [`headset-mic/`](headset-mic/) — the stock `alc255-dell2` model as a modprobe option, no rebuild |
| OLED minimum brightness too low, uneven steps | works | [`oled-backlight/`](oled-backlight/) — patched VBT raises the firmware's backlight floor |
| Faint wide band follows the mouse pointer | works | [`psr-band/`](psr-band/) — PSR2 selective update can only refresh whole scanlines, so every partial update is a full-width band; limits PSR to PSR1, which has none |
| Touchpad left-edge slide does nothing | works | [`touchpad-edge/`](touchpad-edge/) — HID-BPF turns the vendor gesture report into brightness keys |
| Garbled screen at boot on 7.1.6+ | works | [`cdclk-ptl/`](cdclk-ptl/) — rebuilds `xe.ko` with the upstream CDCLK fix for Panther Lake. Merged to `drm-intel-next` 2026-08-21, so expect it in 7.3 |
| Panel driven at 6 bits per colour, banding on gradients | works | [`edp-dsc/`](edp-dsc/) — the link cannot carry 8 bpc and the driver drops colour depth before it will compress; a kernel patch makes it prefer DSC on eDP, with a fallback to the old behaviour |
| Battery charge limit ignored | works | [`battery/`](battery/) — the EC arms only for HONOR's preset pairs; everything else is stored and silently dropped |
| Performance and camera keys inert | works | [`hotkey-actions/`](hotkey-actions/) — acts on the keys no desktop binds |
| Fn keys dead, `Unknown key pressed` | works | [`hotkeys/`](hotkeys/) — HONOR codes added to the `huawei-wmi` keymap |
| Fan RPM readout | works | [`fan/`](fan/) — `honor-ec-sensors` module |
| Fan speed control | not available | [`fan/README.md`](fan/README.md) — every OS-side path to a duty cycle was tested, the EC ignores all of them, and the one documented HONOR method (`WTER`) is absent from this firmware. Selecting the EC's fan *curve* does work, is measured, and is not shipped |
| SOF DSP suspend/resume panic | preventive | [`sof-audio/`](sof-audio/) — upstream IPC4 backport; the race never reproduced on this unit. **Merged upstream, released in 7.2** |
| Fixes reverted by package updates | handled | [`auto-rebuild/`](auto-rebuild/) — package-manager hooks that rebuild them automatically |
| Internal keyboard, Caps Lock LED | **merged upstream** | [`keyboard-atkbd/`](keyboard-atkbd/) — the `atkbd` DMI quirk is in Linux 7.2 and queued for 7.1.10. There, drop `i8042.dumbkbd=1` and the LED works |

## Installing

`apply_patch.sh` in the repository root runs all of them in one go and is the
intended entry point for a fresh install. `uninstall_patch.sh` reverts it.
Every step after the ACPI override is independent and only warns on failure.

Optional steps: `SKIP_OLED=1`, `SKIP_EDGE=1`, `SKIP_FAN=1`,
`SKIP_FINGERPRINT=1`, and `SKIP_CDCLK=1` / `SKIP_DSC=1` for the two that
rebuild `xe.ko`, which means downloading the distro kernel source and compiling
for a few minutes. The backlight floor defaults to `VBT_MIN=12`, measured on
two units; run [`oled-backlight/measure-floor.sh`](oled-backlight/measure-floor.sh)
if you want to check it against your own panel.

## One fix at a time

Every fix installs and removes on its own, from any directory, without going
through `apply_patch.sh`:

```sh
sudo bash patch/touchpad-edge/install.sh
sudo bash patch/touchpad-edge/uninstall.sh
```

Both are safe to re-run. Installing twice is a no-op; removing something that
was never installed says so and exits cleanly.

The two are not symmetrical in one respect, on purpose. **Installing is gated**:
the device profile has to describe this machine and list the fix, because
installing is a decision about hardware. **Removing is not gated.** The moments
when somebody most needs to take a fix off are exactly the ones where a gate
would refuse: the fix was dropped from the profile, a BIOS update changed the
DMI strings, the machine was recognised as the wrong board, or they are
reverting before filing a bug report. See [`lib/uninstall.sh`](../lib/uninstall.sh).

`uninstall_patch.sh` is an orchestrator over these: it calls each
`patch/<fix>/uninstall.sh` in order, then rebuilds the initramfs and the
bootloader config once at the end rather than fifteen times.

Two of them will make the machine worse if you run them without reading the
output first:

| | |
|---|---|
| `acpi-override/uninstall.sh` | the touchpad and touchscreen stop working at the next boot |
| `keyboard-atkbd/uninstall.sh` | on a kernel without the upstream `atkbd` quirk, removing `i8042.dumbkbd=1` can leave you at a login screen with no internal keyboard. Have a USB keyboard to hand |

## Surviving updates

With [`auto-rebuild/`](auto-rebuild/) installed, nothing has to be redone by
hand. `apply_patch.sh` installs it as its last step.

| Fix | What an update does | Handled by |
|---|---|---|
| `acpi-override/` | nothing, it is a firmware file | — |
| `micmute/` | nothing, the BPF object is CO-RE | — |
| `touchpad-edge/` | nothing, the BPF object is CO-RE | — |
| `oled-backlight/` | nothing on a kernel update; a **BIOS** update invalidates the blob | re-run `install.sh` |
| `fan/` | rebuilt automatically | DKMS |
| `headset-mic/` | nothing, it is a modprobe option for the packaged module | — |
| `sof-audio/` | same | `auto-rebuild/` hook |
| `fingerprint/` | a libfprint update replaces the patched package | `auto-rebuild/` hook |
| `battery/` | a desktop battery applet can overwrite the armed pair | the installed units re-apply it at boot and resume |
| `hotkeys/` | a kernel update leaves the new kernel without the overlay | `auto-rebuild/` hook |
| `cdclk-ptl/` | a kernel update leaves the new kernel without the overlay | re-run `install.sh`, deliberately not hooked |

Without the hooks, re-run `sof-audio/install.sh` after every kernel update, and `fingerprint/install.sh` after every libfprint
update.

On a rolling distribution you will regularly have a kernel installed but not
yet booted, at which point the running kernel's headers no longer exist and
nothing can build. `fan/` and `sof-audio/` accept a `KVER`
override to pre-build for the installed kernel instead:

```sh
sudo KVER=7.1.5-1-cachyos bash patch/fan/install.sh
```

## Upstream

Where each of these stands, checked 2026-08-22. Each fix's own README carries
the detail and the commit ids.

**Already merged — these directories are on their way out:**

| Fix | Where it landed |
|---|---|
| [`keyboard-atkbd/`](keyboard-atkbd/) | Linux **7.2**, commit `410c44b10967`, queued for 7.1.10 |
| [`sof-audio/`](sof-audio/) | Linux **7.2**, from thesofproject PR #5762; 7.1.10 too |
| [`cdclk-ptl/`](cdclk-ptl/) | `drm-intel-next` 2026-08-21, commit `1786d2688781`, `Cc: stable`. Expect **7.3**, then a 7.1.y/7.2.y backport. Note upstream's fix has a different shape from the patch here |

**Never submitted, and small enough to belong upstream:**

- the `libfprint` id addition for Goodix `27c6:6f94` — no merge request, no
  issue, and the same is true of `1c7a:05aa` in `egismoc`
- the `SND_PCI_QUIRK` entry for PCI SSID `1ee7:209d`. Two HONOR entries are
  already in `alc269.c` and one of them uses exactly this fixup
- an `atkbd` entry for `XWC-P`, the one HONOR MagicBook missing from that table

**Submitted by somebody else, coordinate before sending:**

- the `huawei-wmi` keycodes. Ruzal Daminov has a series in flight covering
  `0x288` and more, with mappings identical to
  [`hotkeys/`](hotkeys/). Do not post a competing patch
- `libfprint` MR 611 covers `10a5:9924`; it is open and currently unmergeable

**Staying here:** the SSDT override is firmware-specific and belongs to the
machine. The mic-mute fix works around a real kernel bug in `hid-input.c`,
described in [`micmute/README.md`](micmute/README.md); an HID-BPF program for it
would be the first HONOR entry in `drivers/hid/bpf/progs/`, which currently has
thirty vendor programs and nothing for this one.
