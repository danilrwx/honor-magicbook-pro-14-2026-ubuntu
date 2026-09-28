#!/usr/bin/env bash
# install.sh — raise the OLED minimum backlight level by feeding the display
# driver a patched VBT.
#
# Background:
#   intel_backlight does not pass the sysfs value to the hardware. i915/xe map
#   the user range [0..max_brightness] onto [pwm_level_min..pwm_level_max], and
#   pwm_level_min comes from the VBT:
#
#       pwm_level_min = scale(vbt.backlight.min_brightness, 0, 255, 0, pwm_max)
#
#   On this machine the VBT declares 6/255, which lands on 17/704 = 2.4% PWM
#   duty. That is the floor the firmware considers acceptable, and this panel
#   does not render it evenly: at that duty the OLED shows a colour cast and
#   visible blotches. "0%" in any desktop environment lands exactly there.
#
#   Raising that one value fixes two things at once. The floor moves up out of
#   the ugly region, and the whole slider is rescaled rather than clipped, so
#   the first brightness step stops tripling the light output (2.41% -> 7.24%
#   at the factory floor).
#
#   The driver takes a VBT from a file when told to, validates the signature
#   and the sizes, and falls back to the firmware's own copy on any failure.
#   Worst case is therefore stock behaviour, not a dark screen.
#
# The blob is extracted from this machine at install time and patched in place.
# Nothing panel-specific is shipped in the repository, because the VBT belongs
# to the BIOS revision of the unit it came from.
#
# Usage:
#   sudo bash install.sh                # uses VBT_MIN below
#   sudo VBT_MIN=20 bash install.sh     # after running measure-floor.sh
#
# Reruns are safe and always patch from the saved factory copy, so changing
# VBT_MIN and re-running does the right thing.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

# 12/255 = 33/704 = 4.69% duty. Measured on the reference unit: 3.55% still
# showed the colour cast and the blotches, 3.98% was clean, so the threshold
# sits between them and this leaves two steps of margin. Panels vary, so run
# measure-floor.sh and override if yours disagrees.
# The value itself lives in this fix's own directory for the machine, as
# backlight_min in patch/oled-backlight/<model>/<board>/recipe.conf; see
# the check further down, which also accepts a VBT_MIN override.

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR=/usr/lib/firmware/honor
# Named after the board this was dumped from, not after the machine this script
# was written on. The blob IS that machine's VBT with one byte changed, so a
# name that says which machine is the honest one, and uninstall.sh globs.
# FW_NAME, FW_PATH and FW_PARAM are set once the profile is loaded, below.
STATE_DIR=/var/lib/honor
FACTORY="${STATE_DIR}/vbt-factory.bin"
STAMP="${STATE_DIR}/oled-backlight.stamp"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/honor-oled-backlight-backup-${TS}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. is this fix meant for this machine ------------------------------------
# Tier B: the blob is read off this machine, but the floor written into it was
# measured by eye on one panel, so it needs a verified profile.
source "${SRC_DIR}/../../lib/gate.sh"
honor_gate oled-backlight

FW_NAME="$(profile_get model)-vbt.bin"
FW_NAME="${FW_NAME,,}"
FW_PATH="${FW_DIR}/${FW_NAME}"
# request_firmware() looks under /usr/lib/firmware, so the parameter is the path
# relative to that.
FW_PARAM="honor/${FW_NAME}"

# vbt-factory.bin under the old path is the only copy of this machine's
# untouched VBT, so it is moved rather than dropped.
legacy_move /var/lib/honor-zqcp "$STATE_DIR"
legacy_drop /etc/udev/rules.d/99-honor-zqcp-backlight-nonzero.rules

BIOS=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "unknown")
log "profile $(profile_get model), BIOS $BIOS"

if [[ "$(profile_get panel)" == "lcd" ]]; then
    warn "$(profile_get model) has an LCD panel. Raising the firmware floor is
    aimed at OLED panels that cannot render very low duty evenly; on an LCD
    this most likely just costs you the bottom of the range."
fi

# The floor comes from this board's own directory under the fix, unless the
# caller overrides it, which is what somebody measuring their own panel wants.
variant_find "$SRC_DIR" || die \
    "this fix has nothing for $(profile_get model) board ${PROFILE_BOARD:-?}.
    Covered: $(variant_known "$SRC_DIR")"
log "machine: $(variant_note)"
VBT_MIN="$(recipe_param backlight_min VBT_MIN)" || die \
    "patch/oled-backlight/${VARIANT_FOR}/recipe.conf has no backlight_min and
    none was given. Run measure-floor.sh on this panel, then either pass
    VBT_MIN=<n> or write it there."

[[ "$VBT_MIN" =~ ^[0-9]+$ ]] || die "VBT_MIN must be a number, got '$VBT_MIN'"
(( VBT_MIN >= 1 && VBT_MIN <= 64 )) || \
    die "VBT_MIN must be 1..64 (i915 clamps the VBT minimum to 64/255)"
# The panel's own 4320 Hz dimming only runs at low brightness and is gone
# somewhere around 15% duty, so a high floor trades blotches for 200 Hz
# flicker. See README, "Do not raise the floor too far".
if (( VBT_MIN > 30 )); then
    warn "VBT_MIN ${VBT_MIN}/255 is above the practical ceiling of 30/255:
    past roughly 15% duty the panel drops out of its high frequency dimming
    mode and you are left with the bare 200 Hz PWM. Continuing anyway."
fi

# --- 2. Which driver owns the panel -------------------------------------------
DRV=""
for d in /sys/class/drm/card*/device/driver; do
    [[ -e "$d" ]] || continue
    case "$(basename "$(readlink -f "$d")")" in
        xe)   DRV=xe;   break ;;
        i915) DRV=i915; break ;;
    esac
done
[[ -n "$DRV" ]] || die "neither xe nor i915 is bound to a display device"
log "display driver: $DRV (parameter ${DRV}.vbt_firmware)"

BL=/sys/class/backlight/intel_backlight
if [[ -r "$BL/max_brightness" ]]; then
    log "backlight: max_brightness $(< "$BL/max_brightness"), current $(< "$BL/brightness")"
else
    warn "$BL not found — the fix still installs, but verify it after reboot"
fi

# --- 3. Obtain the factory VBT ------------------------------------------------
mkdir -p "$STATE_DIR" "$BACKUP"

if [[ -f "$FACTORY" ]]; then
    OLD_BIOS=$(sed -n 's/^bios_version=//p' "$STAMP" 2>/dev/null || true)
    if [[ -n "$OLD_BIOS" && "$OLD_BIOS" != "$BIOS" ]]; then
        warn "the saved factory VBT was taken under BIOS $OLD_BIOS, this machine now"
        warn "runs BIOS $BIOS. The blob may be stale. To rebuild it from scratch:"
        warn "    sudo PURGE=1 bash uninstall.sh   # then reboot, then run this again"
    fi
    log "using the saved factory VBT ($FACTORY)"
else
    if grep -q 'vbt_firmware=' /proc/cmdline; then
        die "the kernel is already booted with vbt_firmware= but $FACTORY is missing.
    The VBT exposed through debugfs is the patched one, so extracting it now
    would save a patched blob as the factory copy. Remove the parameter from
    the kernel command line, reboot, and run this again."
    fi

    mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug || \
        die "cannot mount debugfs, needed to read the VBT"

    VBT_DBG=$(ls /sys/kernel/debug/dri/*/i915_vbt 2>/dev/null | head -1 || true)
    [[ -n "$VBT_DBG" ]] || die "no i915_vbt in debugfs — is CONFIG_DEBUG_FS enabled?"

    cp "$VBT_DBG" "$FACTORY"
    [[ -s "$FACTORY" ]] || die "extracted VBT is empty"
    log "extracted the factory VBT from $VBT_DBG ($(stat -c%s "$FACTORY") bytes)"
fi
cp -a "$FACTORY" "$BACKUP/vbt-factory.bin"

# --- 4. Patch it --------------------------------------------------------------
log "patching brightness_min_level to ${VBT_MIN}/255"
python3 "${SRC_DIR}/vbt-min.py" patch "$FACTORY" "${STATE_DIR}/vbt-patched.bin" "$VBT_MIN" \
    || die "patching failed, nothing was installed"

install -Dm644 "${STATE_DIR}/vbt-patched.bin" "$FW_PATH"
log "installed $FW_PATH"

# --- 5. initramfs -------------------------------------------------------------
# xe.ko is pulled into the initramfs by the kms hook, so request_firmware()
# runs before the root filesystem is up. The blob has to travel with it.
#
# mkinitcpio has FILES= for exactly this. dracut and Debian's update-initramfs
# do not, and they stage firmware their own way, so on those this stops and says
# what to do rather than editing a file that is not there. It used to run the
# sed unguarded, which killed the script outright on every non-Arch machine.
if [[ -d /etc/initramfs-tools/hooks ]]; then
    # Debian and Ubuntu: a hook copies the blob into every initramfs.
    cat > /etc/initramfs-tools/hooks/honor-vbt <<EOF
#!/bin/sh
# Installed by patch/oled-backlight/install.sh: xe reads the VBT from the
# initramfs, before the root filesystem is mounted.
PREREQ=""
prereqs() { echo "\$PREREQ"; }
[ "\$1" = prereqs ] && { prereqs; exit 0; }
. /usr/share/initramfs-tools/hook-functions
copy_file firmware "$FW_PATH"
EOF
    chmod 0755 /etc/initramfs-tools/hooks/honor-vbt
    log "installed /etc/initramfs-tools/hooks/honor-vbt"
elif [[ ! -f /etc/mkinitcpio.conf ]]; then
    warn "no /etc/mkinitcpio.conf on this system ($(distro_family))."
    warn "The blob is installed at $FW_PATH and the kernel parameter is set, but"
    warn "the driver reads it before the root filesystem is mounted, so it also"
    warn "has to be inside the initramfs. Add it with your own generator:"
    warn ""
    warn "    dracut:            echo 'install_items+=\" $FW_PATH \"' \\"
    warn "                         > /etc/dracut.conf.d/honor-vbt.conf"
    warn "    update-initramfs:  add $FW_PATH via a hook in"
    warn "                         /etc/initramfs-tools/hooks/"
    warn ""
    warn "then rebuild the initramfs. Until then the panel keeps the firmware"
    warn "floor and nothing is broken."
else
cp -a /etc/mkinitcpio.conf "$BACKUP/mkinitcpio.conf"
if grep -q "$FW_NAME" /etc/mkinitcpio.conf; then
    log "mkinitcpio.conf already lists the blob in FILES="
elif grep -qE '^FILES=\(\)' /etc/mkinitcpio.conf; then
    sed -i "s|^FILES=()|FILES=(${FW_PATH})|" /etc/mkinitcpio.conf
    log "added $FW_PATH to FILES="
elif grep -qE '^FILES=\(' /etc/mkinitcpio.conf; then
    sed -i "s|^FILES=(|FILES=(${FW_PATH} |" /etc/mkinitcpio.conf
    log "prepended $FW_PATH to the existing FILES="
else
    printf 'FILES=(%s)\n' "$FW_PATH" >> /etc/mkinitcpio.conf
    log "appended a FILES= line"
fi
echo "    $(grep -E '^FILES=' /etc/mkinitcpio.conf)"
fi

# --- 5b. optional guard against a write of exactly 0 --------------------------
# The panel power decision is made on the user value before scaling, so the VBT
# floor cannot cover it. Opt-in, because it also overrides a deliberate blank
# through this interface; bl_power is the proper way to do that.
GUARD_RULE=/etc/udev/rules.d/99-honor-backlight-nonzero.rules
if [[ "${GUARD_ZERO:-0}" == "1" ]]; then
    install -Dm644 "${SRC_DIR}/99-honor-backlight-nonzero.rules" "$GUARD_RULE"
    udevadm control --reload
    log "installed the zero guard ($GUARD_RULE)"
elif [[ -f "$GUARD_RULE" ]]; then
    log "zero guard already present, leaving it (rm it to drop the guard)"
fi

# --- 6. kernel command line ---------------------------------------------------
CMDLINE_ARG="${DRV}.vbt_firmware=${FW_PARAM}"
# Through lib/distro.sh, which knows Limine, GRUB and systemd-boot and refuses
# rather than editing a shape it does not recognise. This block used to test for
# /etc/default/limine and tell everybody else to do it by hand, which meant the
# fix only ever installed itself on Arch with Limine.
CMDFILE="$(distro_cmdline_file 2>/dev/null || true)"
if [[ -n "$CMDFILE" && -f "$CMDFILE" ]]; then
    cp -a "$CMDFILE" "${BACKUP}/$(basename "$CMDFILE")"
    # Remove any previous one first: the driver name may have changed between
    # i915 and xe, and two vbt_firmware= parameters is not better than one.
    distro_cmdline_remove '(xe|i915)\.vbt_firmware=[^ "]*' || true
    distro_cmdline_add "$CMDLINE_ARG" \
        || warn "add $CMDLINE_ARG to your kernel command line yourself"
    distro_cmdline_show | sed 's/^/    /'
else
    warn "no kernel command line file found for $(distro_family)."
    warn "Add this to your bootloader's command line yourself:"
    warn "    $CMDLINE_ARG"
fi

# --- 7. regenerate ------------------------------------------------------------
# apply_patch.sh runs this step itself once, after every config edit, so it
# calls us with REGEN=0 to avoid rebuilding the initramfs twice.
if (( ${REGEN:-1} )); then
    log "regenerating the initramfs"
    distro_initramfs_rebuild || warn "rebuild the initramfs yourself"
    if command -v limine-update >/dev/null; then
        log "updating the Limine config"
        limine-update
    fi
else
    log "skipping the initramfs rebuild (REGEN=0), the caller will do it"
fi

cat > "$STAMP" <<EOF
# written by patch/oled-backlight/install.sh
date=$(date -Is)
bios_version=$BIOS
driver=$DRV
vbt_min=$VBT_MIN
firmware=$FW_PATH
EOF

# --- 8. report ----------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32m==>\033[0m') done. Reboot to pick it up.

  factory VBT kept at  $FACTORY
  backup of this run   $BACKUP
  minimum raised to    ${VBT_MIN}/255

After the reboot:

  # the parameter reached the driver
  cat /sys/module/${DRV}/parameters/vbt_firmware

  # request_firmware() succeeded at probe (a failure is drm_err, always printed)
  journalctl -k -b | grep -i 'VBT firmware'

  # the blob travelled in the initramfs, which is where probe looks for it
  sudo lsinitcpio /boot/*/linux-cachyos/initramfs | grep ${FW_NAME}

  # the floor moved. Use 1, not 0: writing 0 switches the panel off entirely
  # rather than selecting the lowest level.
  echo 1 | sudo tee $BL/brightness

For proof rather than inference, boot once with drm.debug=0x4 and read what
parse_lfp_backlight() logged:

  journalctl -k -b | grep -i 'VBT backlight PWM'      # expect: min brightness ${VBT_MIN}

Do NOT check /sys/kernel/debug/dri/0/i915_vbt. That node re-runs
request_firmware() when you read it, so it reports the file on disk rather than
what the driver parsed at boot. See README.

To change the level, re-run with a different VBT_MIN. To revert entirely, run
uninstall.sh in this directory.

If a BIOS update changes the VBT, the installed blob goes stale. This one was
built against BIOS $BIOS; re-run install.sh after any firmware update.
EOF
