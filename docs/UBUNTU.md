# Ubuntu

The repository was written on CachyOS. This branch makes it work on Ubuntu
26.04 as shipped: GRUB, Secure Boot on, the archive kernel. Debian should
behave the same, untested.

## Secure Boot

With Secure Boot on the kernel is locked down and loads only signed modules.
Two consequences:

- **Modules are signed.** Every overlay this repository builds (`xe`,
  `huawei-wmi`, `snd-sof`) is signed with the machine
  owner key in `/var/lib/shim-signed/mok/`, the same key dkms uses for
  `honor-ec-sensors`. `apply_patch.sh` creates the key if there is none and
  queues its enrolment with the one-time password `0000` (`MOK_PASSWORD=`
  overrides it). Reboot, press a key as soon as the blue MokManager screen
  appears (it times out in seconds), pick *Enroll MOK*, *Continue*, enter the
  password. One enrolment covers every module, now and after kernel updates.
  The password confirms the enrolment once and is then discarded; the secret
  is `MOK.priv`, readable by root only.
- **The ACPI override still applies.** Lockdown has a check against initrd
  table overrides, but the Ubuntu 7.0 kernel applies them regardless:
  `journalctl -k -b` shows `Kernel is locked down from EFI Secure Boot mode`
  followed by `ACPI: Table Upgrade: override [SSDT- HONOR-I2C_DEVT]`, and the
  live `SSDT27` is the patched one. `tools/status.sh` reports which of the two
  you got.

`lib/distro.sh` does the signing (`distro_module_sign`), and it is a no-op
where Secure Boot is off.

## What changed for Ubuntu

| Area | Before | Now |
|---|---|---|
| `xe.ko` source | vanilla tarball from kernel.org, which misses Ubuntu's drm patches | the `linux-source` package, the tree the archive kernel was built from |
| Compiler for `snd-sof` | clang forced | whatever built the kernel (`CONFIG_CC_IS_CLANG`), gcc on Ubuntu |
| `sof-audio` under lockdown | refused | signs the module instead, refuses only if it cannot |
| OLED backlight VBT | blob outside the initramfs, fix inert | `/etc/initramfs-tools/hooks/honor-vbt` copies it in |
| Fingerprint | `ninja install` of upstream master into `/usr`, off dpkg and off the multiarch path | `apt-get source libfprint`, the patch on top, `dpkg-buildpackage`, install, `apt-mark hold` |
| auto-rebuild | skipped on apt; hooks would run the user's checkout as root | installed; hooks run a root-owned copy in `/usr/local/lib/honor/repo` |
| `/var/tmp/honor-xe` | reused whatever was there | root-owned, mode 0700, refuses a tree owned by anyone else |

## What hung this unit

Earlier revisions of `patch/headset-mic/` built a monolithic
`snd-hda-codec-alc269` from upstream's `alc269.c`. The 7.0 kernel splits the
Realtek codecs into per-codec modules on top of `snd-hda-codec-realtek-lib`, and
that overlay hung the machine hard, without a panic, shortly after the root
filesystem was up. Bisected by booting with one overlay at a time: the VBT and
`snd-sof` overlays boot fine, `alc269` alone hangs. The fix is now the stock
`alc255-dell2` model as a modprobe option, no module at all, and `install.sh`
deletes an old overlay it finds. Recovery from a hang with an old revision:
recovery mode, delete
`/usr/lib/modules/<kver>/updates/snd-hda-codec-alc269.ko.zst`, `depmod -a`.

## Do not purge grub-pc

On a machine that moved from `grub-pc` to `grub-efi`, `grub-pc` lingers in the
`rc` state, and `dpkg --purge grub-pc` (a routine cleanup of removed packages)
deletes `/etc/default/grub`. That file carries everything this repository puts
on the command line (`i8042.dumbkbd=1`, `xe.enable_psr=1`, `xe.vbt_firmware=`)
and `GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"`. The next
`update-grub`, which any kernel install or removal runs, writes a `grub.cfg`
without them, and the boot after that has no touchpad, no internal keyboard and
the stock VBT. Restore from `/usr/share/grub/default/grub` and re-run
`apply_patch.sh` (or put the lines back by hand), then `update-grub`.

`apt-get source` needs `deb-src`; `patch/fingerprint/install.sh` adds it to
`/etc/apt/sources.list.d/*.sources` if missing. The held packages are
`libfprint-2-2` and `libfprint-2-tod1`; `apt-mark unhold` them once the archive
version carries the reader.

## Install

```sh
sudo ./apply_patch.sh
sudo reboot        # enrol the key in MokManager on the way up
```

Run it with the terminal as its stdout. Under `sudo ./apply_patch.sh | tee log`
sudo puts the command in a pty whose foreground group is not the pipe's, and
the first apt that has real work to do stops on SIGTTOU and never returns. To
keep a log, use `script -qfec "sudo ./apply_patch.sh" log`.

A run that finishes without a warning records its git revision in
`/var/lib/honor/apply.stamp`, and the same revision is not applied twice, so a
dotfiles installer can call `apply_patch.sh` on every run. `FORCE=1` repeats
everything.

After the reboot:

```sh
journalctl -k -b | grep -iE 'rejected|lockdown|honor'   # must show no rejected modules
modinfo -F filename xe huawei-wmi                        # updates/ where a fix was built
```

## Kernel updates

`/etc/kernel/postinst.d/95-honor-kernel-modules` rebuilds the overlays for the
new kernel from the root-owned copy, signing them with the enrolled key. The
`xe` rebuild pulls `linux-source` again, which tracks the newest ABI in the
archive; if the module refuses to load, boot the newest kernel and re-run
`patch/edp-dsc/install.sh`. After updating your checkout, re-run
`patch/auto-rebuild/install.sh` so the copy follows.

## Uninstall

`sudo ./uninstall_patch.sh` as before. It also removes the initramfs hook, the
repository copy, and puts the archive libfprint back. The machine owner key
stays enrolled; `mokutil --delete /var/lib/shim-signed/mok/MOK.der` removes it.
