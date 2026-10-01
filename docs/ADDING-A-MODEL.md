# Adding a model

This repository was built from one physical laptop. Everything that makes a
fix work on it, PCI subsystem ids, USB and HID ids, EC register offsets, the
panel's VBT, an ACPI table, is different on every other model. So adding a
model is mostly a matter of getting those values, and the code is already
arranged to accept them.

There are three stages, and the first one is the only one that needs the
hardware.

## 1. Send a dump

```sh
sudo bash tools/collect-hwinfo.sh
```

Read-only. It reads sysfs, runs `lspci` and `lsusb`, copies the ACPI tables and
the video BIOS table, and writes one `honor-hwinfo-<model>-<date>.tar.gz` of
about 200 KB.

It never reads `product_serial`, `board_serial`, `chassis_serial` or
`product_uuid`, and it checks the collected text for them anyway before
packing. Look inside if you would rather see for yourself:

```sh
tar xzf honor-hwinfo-*.tar.gz -O ./report.txt | less
```

Attach it to an issue using the **Hardware dump for a new model** template, and
say what is actually broken on your machine under Linux. That last part matters
as much as the dump: a fix nobody needs is not worth carrying.

## 2. Write a profile

Copy [`devices/TEMPLATE.conf`](../devices/TEMPLATE.conf) to
`devices/<model-in-lowercase>.conf` and fill it in from the dump.

### The shape: a small base block, then one section per board revision

HONOR ships one product code as several different machines. `ZQC-P` is board
`M1010` with a Core Ultra X9 388H here, and board `M1050` with a Core Ultra 5
338H in the report on [issue #1](https://github.com/rs0x29a/Linux-on-HONOR-MagicBook-14-Pro-2026-AI_ZQC-P_M1010/issues/1).
`FMB-P` is five board revisions across three SKUs. Same `sys_vendor`, same
`product_name`, different hardware.

So a profile is not a flat list of facts about a product. It is:

```
model=ZQC-P
name=HONOR MagicBook Pro 14 2026 (AI)
year=2026
dmi_vendor=HONOR
dmi_product=ZQC-P

[board M1010]
status=verified
platform=pantherlake
audio_ssid=1ee7:209d
fixes=acpi-override oled-backlight headset-mic fan battery ...

[board M1050]
status=reported
platform=pantherlake
fingerprint_usb=1c7a:05aa
fixes=acpi-override micmute touchpad-edge fingerprint ...
```

The base block holds **five keys and no others**: `model`, `name`, `year`,
`dmi_vendor`, `dmi_product`. They identify the product and they are what selects
the file. Everything else is a reading, a measurement or a decision about one
board revision, so it has to be claimed by a section. The parser enforces this;
a hardware id or a `status` in the base block is an error, not a style
preference. It is an error because it is the bug this format exists to prevent:
before board sections, `status=verified` on the ZQC-P profile applied to every
ZQC-P that ever booted this repository, `M1050` included, along with the
backlight floor, the audio subsystem id, the EC tachometer offsets and the
battery presets measured on `M1010`.

Two extra forms:

* `[board M1110 M1120]` when several revisions are provably the same machine.
  That takes evidence and usually there is none: the two XWC-P units differ in
  webcam supplier, DRA-XX `M1030` and `M1040` differ in CPU and in fingerprint
  reader. No profile here uses a merged header, and `tools/selftest.sh` rejects
  one until somebody does the comparison.
* `[board *]` when the product's revisions are genuinely unknown. `DRB-P` is the
  only honest case: no probe of a machine without the discrete GPU exists. It is
  not a default for revisions that ARE known, and selftest rejects it beside
  named sections.

A machine whose `board_version` matches no section, in a profile with no
`[board *]`, keeps the product identity and runs as `probed`. It is never
refused, and it never inherits somebody else's `verified`.

### What goes in a section

**Hardware inventory** is fact, and all of it is in the dump:

| Field | Where in the dump |
|---|---|
| the section header | `board_version` in the `DMI` section: `M1010`, `M1020` … |
| `dmi_board`, `dmi_sku` | the `DMI` section |
| `platform`, `cpu` | the CPU model. `cpu` is inventory only, nothing matches on it |
| `touchscreen_hid`, `touchpad_hid` | `HID devices`, the directory name is `BUS:VID:PID` |
| `audio_ssid` | `audio subsystem id` |
| `fingerprint_usb` | `USB`, the Goodix, EgisTec or Elan reader |
| `panel`, `backlight_max` | `backlight`, plus whether the panel is OLED |

There is deliberately **no `dmi_board_version` key**. The section header is the
board revision, and a second place to write it down is a second place for it to
be wrong.

**What a fix needs is not in the profile at all.** A backlight floor, the EC
tachometer offsets, the pairs an EC arms, the `alc269.c` fixup a codec needs:
none of them describes the machine, they describe what one fix has to do on it,
and none of them is in a dump. They live with the fix that reads them, in
`patch/<fix>/<model>/<board>/recipe.conf`:

| Fix | What its directory has to record |
|---|---|
| `fan` | `ec_fan0`, `ec_fan1`, the tachometer fields in that machine's DSDT |
| `battery` | `presets`, found by writing a pair and reading EC `0x85` |
| `oled-backlight` | `backlight_min`, measured by eye with `measure-floor.sh` |
| `headset-mic` | `fixup`, naming the `alc269.c` model (`fixup_models[]`) that board needs |

Until one of those exists the fix declines by name and says which value is
missing, which is more use than being silently absent.

Write `unknown` rather than guessing. A missing value produces a clear refusal;
a wrong one gets acted upon. Write `none` when you have looked and the part is
genuinely absent, which is a different statement and the only one that justifies
leaving a fix off the list.

### Two traps in the DMI values

**`dmi_product` is what the firmware says, not what the box said.** HONOR
sometimes wildcards the digits: every 2024 MagicBook Pro 16 reports the literal
string `DRA-XX`, whatever it was sold as. This repository carried four profiles
keyed on `DRA-54`, `DRA-56` and `DRA-72` for a while, and since matching is
exact, not one of them could ever have fired. Copy the string out of the dump.

**`dmi_sku` does not identify a model here.** `C233` is reported by ZQC-P,
XWC-P, an FMB-P, a DRA-XX and a BCC-N. Record it, but detection tries
`dmi_board` and the board revision first and falls back to `dmi_sku` last,
where it can only confirm a choice already narrowed.

### Which fixes to list

**None, until somebody runs one on that board and reports back.** Almost every
section in `devices/` ships with `fixes=` empty. The two that do not are `ZQC-P`
`M1010`, the machine this repository has, and `ZQC-P` `M1050`, whose owner
reported in enough detail across three issues to justify nine of them.

A profile whose `fixes=` is empty still does real work: it identifies the
machine, records what is in it, and makes every installer refuse by name instead
of acting. That refusal is the correct behaviour on hardware nobody has tested,
and it is what the whole board-section design exists to make possible.

The table below is the checklist for *after* a report arrives. It is not a
licence to fill the field in from a hardware dump: a probe is somebody else's
`lshw` output, not evidence that anything was installed and worked.

| Recorded fact | Follows |
|---|---|
| `platform=pantherlake` | `cdclk-ptl`, `sof-audio` |
| `panel=oled` on a link that cannot carry 8 bpc, **measured** | `edp-dsc` |
| `touchscreen_hid`, **and** `patch/micmute/<model>/<board>/` for this machine | `micmute` |
| `touchpad_hid`, **and** `patch/touchpad-edge/<model>/<board>/` for this machine | `touchpad-edge` |
| `panel=oled`, **and** `patch/oled-backlight/<model>/<board>/` records `backlight_min` | `oled-backlight` |
| `fingerprint_usb`, **and** `patch/fingerprint/<model>/<board>/` for this machine | `fingerprint` |
| `patch/fan/<model>/<board>/` records `ec_fan0` and `ec_fan1` | `fan` |
| `patch/battery/<model>/<board>/` records `presets` | `battery` |
| any of the above builds a module or rebuilds a library | `auto-rebuild` |

`psr-band` is deliberately absent from that table. Nothing in a profile
predicts it: whether PSR2 selective update is visible on a given panel is a
property of that panel, and the only honest way to find out is to move the
pointer across a flat grey window and look. List it once somebody has seen the
band on that board, not because the machine has an Intel iGPU and an eDP panel.

A recorded `fingerprint_usb` on its own is **not** enough. `27c6:5f10` and
`10a5:a921` are both real readers on real machines here and neither has a
recipe, so listing `fingerprint` for them would produce a fix that patches the
wrong id into the wrong driver. The same goes for `touchscreen_hid` and
`touchpad_hid`: those fixes rewrite one chip's report descriptor.

Once a fix is listed, listing a tier B one on a section that is not yet
`verified` is still worth doing: it will refuse, and the refusal names what is
missing. That is more useful than silence.

### When one board ships different parts

This is common: the same laptop ships a Goodix fingerprint reader in one market
and an EgisTec one in another, and both report the same DMI, right down to the
board revision.

That is not a reason for another section, because the difference is **visible on
the running machine** and a USB, HID or PCI id always is. List the
possibilities:

```
fingerprint_usb=27c6:6f94 1c7a:05aa
```

The installer probes the bus and uses the one actually fitted, so one section
covers both units. A field with one value behaves exactly as a one-element list.
`touchscreen_hid`, `touchpad_hid` and `audio_ssid` work the same way.

Keep the two kinds of identifier straight:

* the **board revision** is a discriminator. It has to be read from DMI before
  any fix runs, and it decides which section applies and how far it is trusted.
* everything else is **inventory**. It is in sysfs once the machine is up, so an
  installer confirms it against the bus rather than trusting the file. Never add
  an inventory key to what detection narrows on.

Where a fix needs **different code** per machine, not just a different id, it
keeps one directory per machine, `patch/<fix>/<model>/<board>/`, named the way
this file is. `patch/fingerprint/zqc-p/M1010/` carries the Goodix recipe and
`patch/fingerprint/zqc-p/M1050/` the EgisTec one, which is the whole reason that
fix is split at all: adding the EgisTec id to the Goodix driver would achieve
nothing, it needs libfprint's SDCP support.

The layout and the steps are in
[`patch/README.md`](../patch/README.md#layout). An installer refuses cleanly
when it has no directory for the machine, and refuses again if the part on the
bus is not the one that directory was written against.

Check it parses:

```sh
bash -c 'source lib/profile.sh; profile_load devices/<model>.conf && echo ok'
bash tools/selftest.sh
```

Unknown keys are an error, not a warning, so a typo cannot silently drop a
value. `selftest.sh` additionally proves that a revision your profile does not
describe cannot come out `verified`.

## 3. Verify it, then say so

A new section is `draft`, `probed` or `reported`. The status belongs to the
board, not to the product: one profile can hold a `verified` section and a
`reported` one, and that is the normal case once a second unit turns up.

| | What somebody did |
|---|---|
| `draft` | nothing. Model and platform from published specifications |
| `probed` | uploaded a hardware probe, or sent a dump. The ids are genuine readings, no fix was tried |
| `reported` | ran something on that machine and wrote it down, in another project |

All three behave identically as far as the installers are concerned: only the
fixes that cannot carry another machine's constants are allowed, meaning those
that read their inputs off the running machine, or match on a device id and
simply find nothing on hardware they were not meant for.

```sh
sudo ALLOW_UNVERIFIED=1 ./apply_patch.sh
```

Everything else stays disabled until somebody runs it on **that board** and it
works. When that happens, set `status=verified` in that section and record what
it was verified against:

```
status=verified
verified_kernel=6.11.0-generic
verified_bios=1.04
verified_distro=Ubuntu 24.04
```

Please do not set `verified` on the strength of a spec sheet, a DSDT that looks
similar to ours, or a different revision of the same product. The whole point of
the field is that somebody took the risk on that exact hardware.

## What the fixes need beyond a profile

Three of them need more than values, because the model-specific part is code
or a binary rather than a number:

| Fix | What a new model needs |
|---|---|
| `acpi-override` | the same table, or its own. The installer compares the md5 of your live `I2C_DEVT` against the stock one in `dump/acpi/` and refuses unless they match, so a model that happens to ship the identical table is covered for free — ZQC-P and XWC-P do — and one that does not gets a clean refusal. If yours differs, rebuild it from your own tables with `build/build_patch.sh` and [RESEARCH.md](RESEARCH.md) |
| `headset-mic` | the `alc269.c` model that fixes the jack, found by trying `hda_model=` candidates with a reboot each; a board no stock model fits needs an upstream quirk instead |
| `fan` | `ec_fan0` and `ec_fan1` for that board, read out of its own DSDT and written into `patch/fan/<model>/<board>/recipe.conf`. The installer passes them to the module as parameters, so nothing has to be added to the driver; it refuses if that file does not record them |

`fingerprint`, `micmute` and `touchpad-edge` are in between: the id comes from
the section and is confirmed on the bus, but the code is per device. Each keeps
a directory per part, named `<vid>-<pid>-<something-readable>` with a
`recipe.conf` in it, and the installer picks the one matching what it found.
Adding support for a second part is adding a directory, not editing an installer.

## Which fixes even apply

Some of it follows from the platform rather than the model:

| | 2026, Panther Lake | 2025, Arrow Lake | 2024, Meteor Lake |
|---|---|---|---|
| `cdclk-ptl` | yes, display IP 30 | no | no |
| `sof-audio` | relevant | probably not | probably not |
| everything else | depends on the parts fitted | same | same |

And some of it does not apply because upstream already handles it. Check before
writing a fix:

* the internal-keyboard `atkbd` quirk is upstream for `FMB-P` and `FMB-PM`
  (6.19), `BCC-N` (7.1) and `ZQC-P` (7.2, 7.1.10)
* the touchpads `347d:7853` (commit `9ffccb691adb`, in since v6.7) and
  `35cc:0104` (commit `7a5ab8071114`) already have `hid-multitouch` quirks
* `iwlwifi`'s regulatory allow-lists match `HONOR` vendor-wide, so Wi-Fi power
  tables need no per-model work
* the 2024 machines have no ACPI table failure at all

Models with a discrete NVIDIA GPU are supported only on their integrated-GPU
side. The proprietary driver, PRIME and graphics switching are out of scope
here; the `dgpu` field exists to tell two variants of the same `product_name`
apart, not to promise support.
