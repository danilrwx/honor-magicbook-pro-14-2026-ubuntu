# Contributing

Thanks for taking the time. This repository collects fixes that make a HONOR
MagicBook usable under Linux: patched ACPI tables, kernel-module quirks,
HID-BPF programs and a few installers that tie them together.

Two things are worth knowing before you start.

**Every installer runs as root and edits things that decide whether the
machine boots**: firmware tables, the initramfs, the kernel command line,
kernel modules. Precision matters more here than speed.

**Almost everything here was derived from one physical machine**, a HONOR
MagicBook Pro 14 2026 (`ZQC-P`, model M1010) on CachyOS. Anything you can
confirm, or contradict, on different hardware or a different distribution is
genuinely useful, and saying "I could not test this" is a perfectly good
contribution note.

## Device profiles, and why the installer may refuse

`apply_patch.sh` identifies the machine before it touches anything. It reads
DMI, picks the matching file in [`devices/`](devices/), and stops if there is
none. That is deliberate: step 2 installs an ACPI table dumped from one
specific unit's firmware, and a foreign SSDT is not a fix that fails quietly.

A profile is one file per product, holding one `[board ...]` section per board
revision, and each section carries its own `status`. HONOR ships one product
code as several machines, so trust is per board and each section is judged on
its own evidence.

| `status` | Meaning | What may run |
|---|---|---|
| `verified` | somebody ran these fixes on that board | everything that section lists |
| `reported` | built from a hardware dump, never run | tier A only, and only with `ALLOW_UNVERIFIED=1` |
| `draft` | assembled from public information | same as `reported` |

A board revision no section describes is not refused. It keeps the product
identity and runs as `probed`, and every fix declines by name.

**Almost every profile enables nothing.** Their data came from hardware probe
databases and other people's repositories, which says what is in a machine, not
that anything was installed on it. A fix is listed when somebody runs it on that
board and reports back. Sending that report is the single most useful thing
anybody with one of these laptops can do, and `ZQC-P` `M1050` is there to show
it works: nine fixes are listed on that board because its owner reported in
detail three times.

Fixes are sorted into trust tiers, assigned in
[`lib/profile.sh`](lib/profile.sh) and explained with the status words in
[`docs/hardware/README.md`](docs/hardware/README.md#what-the-status-words-mean).
A new fix needs a tier before a profile may list it, and `tools/selftest.sh`
refuses one that has no tier.

Check what you have. The third line is the one that decides which section
applies, and it is the one people forget to include in a report:

```sh
cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name \
    /sys/class/dmi/id/board_version
ls devices/
```

## Ways to help

### Report a bug

Use the bug report template. What makes a report actionable here:

- `sys_vendor`, `product_name` and BIOS version from `/sys/class/dmi/id/`
- distribution and `uname -r`
- which fix misbehaves, and whether it was installed through
  `apply_patch.sh` or its own `install.sh`
- the installer output, and `journalctl -k -b -0` around the failure

### Add a model

This is the most valuable thing right now. The repository has been run on
exactly one machine, and the constants that matter, PCI subsystem IDs, USB and
HID ids, EC register offsets, panel VBT, are different on every model. One
further board is `verified` on the strength of a dump and its owner's reports,
which is the most a second machine has managed so far.

A profile is strict `key=value`, described field by field in
[`devices/TEMPLATE.conf`](devices/TEMPLATE.conf). It is parsed, never sourced,
because profiles arrive from people we do not know and run as root. Unknown
keys are an error rather than a warning, so a typo cannot silently drop a
value, and anything you have not read off the hardware is written as
`unknown` rather than guessed.

A profile holds **hardware inventory** and nothing else: everything that can be
read off a running unit or found in a dump, plus what identifies the machine and
how far it is trusted. Device ids, panel type, `max_brightness`. A dump alone is
enough to fill it in, which is why a `reported` profile can be complete. Several
of these accept a space separated list, for models sold with different parts in
different regions; the installer probes for the one actually fitted rather than
trusting the first entry.

What a **fix** needs in order to run on that machine is not in the profile. It
lives with the fix:

```
patch/<fix>/<model>/<board>/recipe.conf
```

Same two words, one level further down. `patch/fan/zqc-p/M1010/` holds that
board's EC tachometer offsets, `patch/oled-backlight/zqc-p/M1010/` its backlight
floor, `patch/micmute/zqc-p/M1010/` the HID-BPF program for the touchscreen it
ships. None of those describes the machine; they describe what one fix does on
it, and none of them can be derived from a dump. Somebody had to measure or
choose each with the laptop in front of them, and that is the practical
difference between `reported` and `verified`.

The layout, and the steps to add a machine to a fix, are in
[`patch/README.md`](patch/README.md#layout). `tools/selftest.sh` enforces the
rules there, so a mistake in one is a failed check rather than a surprise on
somebody's laptop.

Use the "Hardware dump for a new model" template. It lists the commands to run.
Everything it asks for is read-only.

Two warnings about the dump:

- `/sys/class/dmi/id/product_serial` and `board_serial` identify your machine.
  Do not paste them. The template's commands avoid them.
- The ACPI tables and the registry extract are large. Attach them as files
  rather than pasting.

### Confirm or contradict something

If a fix works on your machine, say so with your model, BIOS, distribution and
kernel version. If a documented measurement does not reproduce, that is worth
its own issue. Several entries here were corrected exactly that way.

### Send a patch

Small, self-contained changes are easiest to review. If you are restructuring
something, open an issue first so the approach can be agreed before you spend
the time.

## How the repository is laid out

Each fix is one directory under `patch/`, and it is self-contained:

```
patch/<fix>/
├── README.md      what is broken, why the fix looks like this, what was ruled out
├── install.sh     idempotent, locates its own files, works when run directly
└── <the patch, source or BPF program it needs>
```

`apply_patch.sh` at the repository root runs all of them in order.
`uninstall_patch.sh` reverts them. Neither is a replacement for the individual
installers, which must keep working on their own.

The whole tree:

```
HONOR_ZQC-P_M1010/
├── README.md                       # this file
├── apply_patch.sh                  # one-shot installer (idempotent)
├── uninstall_patch.sh              # revert installer
├── CONTRIBUTING.md                 # conventions for installers, how to add a model
├── docs/
│   └── ADDING-A-MODEL.md           # dump -> profile -> verified, step by step
├── tools/
│   ├── collect-hwinfo.sh           # read-only hardware dump for a new profile
│   ├── dump-acpi.sh                # read-only ACPI table dump
│   └── selftest.sh                 # run this after touching a profile or a lib
├── devices/                        # one profile per product, one section per board
│   ├── zqc-p.conf                  #   [board M1010] verified, [board M1050] reported
│   ├── xwc-p.conf ... fmi-xx.conf  #   thirteen more, recognised, all fixes off
│   └── TEMPLATE.conf               #   field by field reference for a new one
├── lib/
│   ├── profile.sh                  # profile parser, validator and trust tiers
│   ├── detect.sh                   # DMI plus PCI -> which profile applies
│   ├── gate.sh                     # the check every installer runs, and migration helpers
│   ├── variant.sh                  # patch/<fix>/<model>/<board>/ — the per-machine parts
│   ├── ksrc.sh                     # which upstream tag matches the running kernel
│   └── distro.sh                   # what differs between distributions
├── patch/                          # one self-contained directory per fix
│   ├── README.md                   # index + status table
│   ├── acpi-override/              # patched SSDT27 — touchpad, touchscreen, keyboard
│   │   ├── zqc-p/M1010/            #   the table, and the recipe that names it
│   │   ├── zqc-p/M1050/            #   same_as=zqc-p/M1010
│   │   ├── xwc-p/M1110/            #   same_as — the table is byte-identical there
│   │   └── acpi_override.install   #   mkinitcpio install hook (early CPIO)
│   ├── keyboard-atkbd/             # upstream quirk, reference only, needs a kernel rebuild
│   │   ├── zqc-p/M1010/            #   the patch, and the recipe that names it
│   │   └── README.md
│   ├── auto-rebuild/               # package-manager hooks: keep fixes applied across updates
│   │   ├── zqc-p/M1010/            #   every fix has these, even the ones with no numbers
│   │   ├── zqc-p/M1050/
│   │   ├── rebuild.sh              #   dispatcher, installed to /usr/local/lib/honor/
│   │   ├── 95-honor-kernel-modules.hook
│   │   ├── 96-honor-libfprint.hook
│   │   └── install.sh
│   ├── oled-backlight/             # firmware backlight floor is too low for this panel
│   │   ├── zqc-p/M1010/            #   backlight_min=12, measured by eye
│   │   ├── zqc-p/M1050/            #   backlight_min=unknown, same panel, nobody has looked
│   │   ├── vbt-min.py              #   inspect / patch brightness_min_level in a VBT
│   │   ├── measure-floor.sh        #   find the lowest duty the panel renders evenly
│   │   ├── install.sh              #   extract, patch, initramfs + cmdline
│   │   └── uninstall.sh
│   ├── psr-band/                   # PSR2 selective update paints a band under the pointer
│   │   ├── zqc-p/M1010/            #   what was seen, and on what
│   │   ├── zqc-p/M1050/
│   │   ├── install.sh              #   set the PSR level on the cmdline, and live
│   │   └── uninstall.sh
│   ├── battery/                    # the charge limit the EC quietly ignores
│   │   ├── zqc-p/M1010/            #   presets=40-70 70-90 95-100, each read back at EC 0x85
│   │   ├── zqc-p/M1050/
│   │   ├── honor-battery-threshold.sh
│   │   ├── honor-battery-threshold.service
│   │   └── install.sh
│   ├── hotkey-actions/             # acts on the keys no desktop binds
│   │   └── zqc-p/M1010/
│   ├── hotkeys/                    # Fn keys the huawei-wmi keymap does not know
│   │   ├── zqc-p/M1010/            #   keymap patch + hwdb, captured on that board
│   │   ├── zqc-p/M1050/            #   same_as=zqc-p/M1010
│   │   └── install.sh
│   ├── cdclk-ptl/                  # boot-time screen corruption on kernels 7.1.6+
│   │   ├── zqc-p/M1010/            #   the defect, and where it was seen
│   │   ├── zqc-p/M1050/
│   │   ├── 0001-drm-i915-cdclk-avoid-spurious-cdclk-sanitization-on-PTL.patch
│   │   └── install.sh              #   rebuild xe.ko from the distro kernel source
│   ├── edp-dsc/                    # panel driven at 6 bpc because DSC is never tried
│   │   ├── zqc-p/M1010/
│   │   ├── zqc-p/M1050/
│   │   ├── 0001-drm-i915-dp-prefer-DSC-over-driving-eDP-below-8-bpc.patch
│   │   └── install.sh              #   both xe patches build through lib/xe-build.sh
│   ├── touchpad-edge/              # left-edge slide gesture -> brightness keys
│   │   ├── zqc-p/M1010/            #   HID-BPF device-event hook + recipe
│   │   ├── zqc-p/M1050/            #   same_as=zqc-p/M1010
│   │   └── install.sh              #   build + install via udev-hid-bpf
│   ├── micmute/                    # phantom KEY_MICMUTE from the touchscreen
│   │   ├── zqc-p/M1010/            #   HID-BPF descriptor fixup + recipe
│   │   ├── zqc-p/M1050/            #   same_as=zqc-p/M1010
│   │   └── install.sh              #   build + install via udev-hid-bpf
│   ├── headset-mic/                # ALC256 model for PCI SSID 1ee7:209d
│   │   ├── zqc-p/M1010/            #   the model name + the alc269.c quirk for upstream
│   │   ├── zqc-p/M1050/            #   same_as=zqc-p/M1010
│   │   └── install.sh              #   modprobe option hda_model=
│   ├── sof-audio/                  # preventive IPC4 backport (PR #5762)
│   │   ├── zqc-p/M1010/
│   │   ├── zqc-p/M1050/
│   │   ├── 0001-ASoC-SOF-ipc4-topology-Refresh-copier-IPC-payload-before-widget-setup.patch
│   │   └── install.sh              #   build+install snd-sof.ko (updates/ overlay)
│   ├── fingerprint/                # one reader per board, see its README
│   │   ├── zqc-p/M1010/            #   Goodix 27c6:6f94, global units
│   │   ├── zqc-p/M1050/            #   EgisTec 1c7a:05aa, Chinese units
│   │   ├── fmb-p/any/              #   FPC 10a5:9924, revision not known
│   │   ├── PKGBUILD                #   pacman-owned rebuild, avoids file conflicts
│   │   └── install.sh
│   └── fan/                        # honor-ec-sensors — EC fan tachometers (read-only)
│       ├── zqc-p/M1010/            #   ec_fan0=0x2c ec_fan1=0x2e, from the DSDT
│       ├── zqc-p/M1050/            #   the same, from that board own dump
│       ├── honor-ec-sensors.c
│       ├── Makefile / dkms.conf
│       └── install.sh
├── build/
│   ├── build_patch.sh              # iasl + checksum recompute + revision bump
│   └── extract_oem_acpi.sh         # dump live ACPI tables for new investigations
├── dump/                          # everything read off a real machine
│   ├── acpi/<model>/              #   firmware tables, .aml and .dsl
│   └── win11/<model>/             #   ACPI (no MSDM), PnP list, scoped registry
└── tools/
    ├── collect-hwinfo.sh          # read-only dump for a new device profile
    └── dump-acpi.sh               # this machine's ACPI tables, for dump/acpi/
```

Every subdirectory of `patch/` also carries its own `README.md` with the
measurements behind the fix and the approaches that were ruled out.

---

## Conventions for installers

These are not style preferences, they are what keeps the scripts safe to run
twice on a machine somebody depends on.

- `#!/usr/bin/env bash` and `set -euo pipefail`.
- Refuse to run unless `EUID` is 0, with the exact command to retry.
- **Idempotent.** Running twice must be a no-op the second time, and must not
  stack duplicate entries in `mkinitcpio.conf`, the kernel command line or
  udev rules.
- **Gate on the hardware you are about to touch.** Source `lib/gate.sh` and
  call `honor_gate <fix-name>` early. It identifies the machine, refuses on an
  unknown one, and enforces the trust tier. It also honours `HONOR_PROFILE`,
  which `apply_patch.sh` exports, so the detection is not repeated.
- **Take model-specific values from the profile, not from the script.** Use
  `gate_param <key> [ENV_OVERRIDE]`. A constant baked into an installer is a
  constant that will eventually reach the wrong laptop. Where a value is baked
  into something else, a patch file or a driver's DMI table, cross-check it
  against the profile and refuse on a mismatch rather than proceeding.
- **Back up before overwriting**, and print where the backup went.
- **Kernel modules go to `/usr/lib/modules/$KVER/updates/`.** `depmod` searches
  that before `kernel/`, so the packaged module is never overwritten and
  removal is one `rm`. Never write into `kernel/`.
- **Compare `vermagic`** against the running kernel before installing a module
  you built.
- Accept a `KVER` override where it makes sense. On a rolling distribution
  there is regularly a kernel installed but not yet booted.
- Explain the risky step in a comment. Future readers, including the person
  who wrote it, need to know why the odd-looking line is there.

A fix that needs an uninstall path beyond deleting a file should ship
`uninstall.sh` next to `install.sh`, and `uninstall_patch.sh` should call it.

## Distributions

Everything that differs between distributions lives in
[`lib/distro.sh`](lib/distro.sh), and gated installers get it for free through
`lib/gate.sh`. Use it rather than calling `mkinitcpio` or editing
`/etc/default/limine` directly:

| Instead of | Use |
|---|---|
| `zcat /proc/config.gz` | `distro_kernel_config_cat`, `distro_kernel_config_has` |
| `mkinitcpio -P`, `limine-update` | `distro_initramfs_rebuild` |
| editing `/etc/default/limine` | `distro_cmdline_add`, `distro_cmdline_remove` |
| `pacman -S` | `distro_pkg_install`, `distro_kernel_headers_pkg` |
| assuming `.ko.zst` | `distro_module_suffix`, `distro_module_install` |

Where a fact can be observed rather than inferred from the distribution's
name, observe it. The module compression is read off the distribution's own
modules, so a distribution nobody here has ever run still gets it right.

**Honest status:** the Arch and CachyOS paths are exercised on real hardware.
The Debian, Ubuntu and Fedora branches are written from their documented
behaviour and are **not yet tested on those systems**. If you run one of them,
saying whether it worked is a genuinely useful contribution.

Fetching kernel sources by tag from `raw.githubusercontent.com`, and using
DKMS for out-of-tree modules, already work everywhere and need no
abstraction.

## Documentation

Every fix directory has a `README.md`, and it is expected to record the
reasoning, not just the recipe: what the symptom was, what the measurement
showed, and which approaches were tried and rejected. Several fixes here look
strange until you read why the obvious version does not work.

State plainly what was verified and what was inferred. A number that came from
a datasheet and a number that came from a measurement should not read the same.

## Commits

One logical change per commit. Subject as `area: what changed`, lowercase
after the colon, in the imperative:

```
oled-backlight: raise the panel minimum through a patched VBT
```

The body is where the value is. Say what was observed, what the cause turned
out to be, and why this is the fix rather than the other one. Include the
evidence: register values, log lines, upstream commit hashes.

## Upstream first

If a fix belongs in the kernel, `libfprint` or another project, say so in the
directory's README and link the submission. The intent is for this repository
to shrink as things land, and it has: the `atkbd` quirk and the SOF copier fix
both reached Linux 7.2, and the Panther Lake cdclk fix is queued for 7.3.
[`patch/README.md`](patch/README.md#upstream) tracks where each one stands,
including the ones nobody has sent yet and the one somebody else is already
sending.

Before writing a fix, check whether upstream has done it. Several things this
family needs are already in the kernel and easy to miss — per-model `atkbd`
quirks, `hid-multitouch` entries for two of the touchpads, vendor-wide
`iwlwifi` regulatory entries. [`docs/hardware/README.md`](docs/hardware/README.md#what-the-kernel-knows-about-honor)
lists everything the kernel knows about HONOR.

## Licence

By contributing you agree that your work is published under the MIT licence in
[`LICENSE`](LICENSE).
