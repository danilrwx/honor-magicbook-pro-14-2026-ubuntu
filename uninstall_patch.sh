#!/usr/bin/env bash
# uninstall_patch.sh — revert everything apply_patch.sh installed. Run as root.
#
# This is an orchestrator and almost nothing else. Each fix knows how to remove
# itself, in patch/<fix>/uninstall.sh, and that is the same script you would run
# on its own to take one fix off:
#
#     sudo bash patch/fan/uninstall.sh
#
# Keeping the knowledge there rather than here is what stops the two drifting
# apart. The version of this file that listed every path itself had already
# fallen behind in one place: it removed the fingerprint stamp nowhere, and it
# knew nothing about /etc/modprobe.d/honor-ec-sensors.conf.
#
# What is left here is what genuinely belongs to the whole operation: the order,
# the sweep of names from before the rename, one initramfs and bootloader
# rebuild at the end instead of one per fix, and the summary.
#
# Deliberately NOT `set -e`. This is the recovery path: a machine reaching for
# it may already be in an odd state, and a failure in one fix must not stop the
# rest. Every step reports for itself and the exit status reflects the total.

set -uo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/distro.sh"

KVER="${KVER:-$(uname -r)}"
FAILURES=0

# The order the fixes come off in. It mirrors the order they go on in, so that
# anything depending on something else is removed before the thing it depends
# on. keyboard-atkbd sits next to acpi-override because apply_patch.sh installs
# its parameter alongside the ACPI override, not because they share code.
#
# fingerprint is included: apply_patch.sh installs it, so a full revert takes it
# off. It is the one step that runs a package transaction, so SKIP_FINGERPRINT=1
# leaves the patched libfprint alone.
#
# cdclk-ptl removes the whole locally built xe.ko, edp-dsc included: one module,
# and there is no partial removal. edp-dsc is therefore not in this list.
ORDER=(
    acpi-override
    keyboard-atkbd
    headset-mic
    sof-audio
    auto-rebuild
    micmute
    touchpad-edge
    oled-backlight
    cdclk-ptl
    psr-band
    battery
    hotkeys
    hotkey-actions
    fan
    fingerprint
)

n=0
total=$(( ${#ORDER[@]} + 2 ))
for fix in "${ORDER[@]}"; do
    n=$(( n + 1 ))
    u="${SCRIPT_DIR}/patch/${fix}/uninstall.sh"
    printf '\n[%d/%d] %s\n' "$n" "$total" "$fix"
    if [[ "$fix" == fingerprint && "${SKIP_FINGERPRINT:-0}" == "1" ]]; then
        echo "    skipped — SKIP_FINGERPRINT=1"
        continue
    fi
    if [[ ! -f "$u" ]]; then
        printf '    [warn] %s is missing; this checkout is incomplete\n' "$u" >&2
        FAILURES=$(( FAILURES + 1 ))
        continue
    fi
    # REGEN=0: the initramfs and the bootloader config are rebuilt once, at the
    # end. Rebuilding them fifteen times would be slow and no safer.
    if ! REGEN=0 KVER="$KVER" bash "$u"; then
        printf '    [warn] patch/%s/uninstall.sh reported a problem\n' "$fix" >&2
        FAILURES=$(( FAILURES + 1 ))
    fi
done

# --- what belongs to the whole operation --------------------------------------

n=$(( n + 1 ))
printf '\n[%d/%d] Remove anything left under the pre-rename names\n' "$n" "$total"
# Everything installed at runtime used to carry "zqcp" in its name. Each
# installer migrates the artefact it owns, deliberately not more: running one
# installer must not delete a rule it is not going to reinstall. Here a blanket
# sweep is right, because everything is going anyway.
modprobe -r honor-zqcp-hwmon 2>/dev/null || rmmod honor_zqcp_hwmon 2>/dev/null || true
if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q '^honor-zqcp-hwmon'; then
    dkms remove -m honor-zqcp-hwmon -v 1.0 --all >/dev/null 2>&1 \
        && echo "    removed DKMS module honor-zqcp-hwmon"
fi
shopt -s nullglob
rm -rfv /usr/src/honor-zqcp-hwmon-1.0 \
        /usr/local/lib/honor-zqcp \
        /var/lib/honor-zqcp \
        /var/lib/honor/apply.stamp \
        /etc/modules-load.d/honor-zqcp-hwmon.conf \
        /etc/honor-zqcp-autorebuild.conf \
        /etc/pacman.d/hooks/95-honor-zqcp-kernel-modules.hook \
        /etc/pacman.d/hooks/96-honor-zqcp-libfprint.hook \
        /etc/wireplumber/wireplumber.conf.d/51-honor-zqcp-mic-priority.conf \
        /etc/udev/rules.d/99-honor-zqcp-backlight-nonzero.rules \
        /usr/lib/modules/*/updates/honor-zqcp-hwmon.ko* 2>/dev/null || true
shopt -u nullglob
rmdir --ignore-fail-on-non-empty /usr/local/lib/honor /var/lib/honor 2>/dev/null || true
depmod -a "$KVER" 2>/dev/null || true

n=$(( n + 1 ))
printf '\n[%d/%d] Rebuild the initramfs and the bootloader config\n' "$n" "$total"
# Once, here, rather than inside each fix: they were all run with REGEN=0.
distro_initramfs_rebuild || {
    echo "    [warn] rebuild the initramfs yourself before rebooting" >&2
    FAILURES=$(( FAILURES + 1 ))
}
distro_bootloader_update || {
    echo "    [warn] regenerate your bootloader config yourself" >&2
    FAILURES=$(( FAILURES + 1 ))
}

# --- what the machine looks like afterwards -----------------------------------

cat <<'EOF'

Done. Reboot to fully revert.

What stops working, on the reference machine:

  * the touchpad and touchscreen, because the corrected ACPI table is gone
  * the 3.5 mm jack headset microphone
  * fan RPM in sensors and desktop widgets
  * the fingerprint reader
  * the HONOR Fn keys that the packaged huawei-wmi keymap does not know,
    and the performance and camera keys that had a service behind them
  * the battery charge limit, which goes back to charging to 100%

What comes back:

  * the phantom KEY_MICMUTE device, so the microphone starts muting itself
  * the wide faint band that follows the pointer, if this panel shows it
  * the OLED backlight's firmware floor, blotches and colour cast included
  * 6 bits per colour on the internal panel, if edp-dsc had been installed
  * the garbled screen during boot on a kernel from 7.1.6 without the
    upstream CDCLK fix
EOF

if (( FAILURES )); then
    printf '\n%d step(s) reported a problem. Read the [warn] lines above.\n' "$FAILURES" >&2
    exit 1
fi
echo
echo "Every step completed."
