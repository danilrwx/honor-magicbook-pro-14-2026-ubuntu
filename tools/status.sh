#!/usr/bin/env bash
# status.sh — one line per fix: is it in effect on this machine right now.
#
#   green ✔  applied and in effect
#   red   ✘  listed for this machine but not in effect
#   grey  ○  not applicable here, or in effect with a caveat worth reading
#
# Reads only. Root is needed for the ACPI table and the kernel journal; without
# it those two lines say so instead of guessing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/profile.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/detect.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/distro.sh"

if [[ -t 1 ]]; then G=$'\033[1;32m' R=$'\033[1;31m' Y=$'\033[0;90m' N=$'\033[0m'; else G='' R='' Y='' N=''; fi
ok()  { printf '%s✔ %-15s%s %s\n' "$G" "$1" "$N" "${2:-}"; }
bad() { printf '%s✘ %-15s%s %s\n' "$R" "$1" "$N" "${2:-}"; }
meh() { printf '%s○ %-15s%s %s\n' "$Y" "$1" "$N" "${2:-}"; }

KVER="$(uname -r)"
KBASE="${KVER%%-*}"
MODDIR="/usr/lib/modules/$KVER"
ROOT_OK=$(( EUID == 0 ))

detect_profile "$ROOT/devices" >/dev/null 2>&1 || { echo "no profile for $(detect_describe)"; exit 1; }
echo "Machine     : $(detect_describe)"
echo "Kernel      : $KVER"
if distro_secure_boot_on; then
    sb="on"
    # Captured, not piped: mokutil --test-key exits non-zero for an enrolled
    # key and grep -q ends pipelines early, and both trip pipefail.
    if [[ -r "$MOK_DIR/MOK.der" ]] && grep -q 'already enrolled' <<< "$(mokutil --test-key "$MOK_DIR/MOK.der" 2>/dev/null)"; then
        sb+=", signing key enrolled"
    elif [[ -r "$MOK_DIR/MOK.der" ]]; then
        sb+=", signing key NOT enrolled"
    else
        sb+=", no signing key"
    fi
else
    sb="off"
fi
echo "Secure Boot : $sb"
stamp="$(sed -n 's/^rev=//p' /var/lib/honor/apply.stamp 2>/dev/null)"
[[ -n "$stamp" ]] && stamp="revision ${stamp:0:12}"
echo "Applied     : ${stamp:-never}"
(( ROOT_OK )) || echo "(not root: the ACPI and journal checks are skipped)"
echo

kver_ge() { [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }
journal() { (( ROOT_OK )) && grep -qiE "$1" <<< "$(journalctl -k -b --no-pager 2>/dev/null)"; }
overlay_present() { compgen -G "$MODDIR/updates/$1.ko*" >/dev/null; }
overlay_loaded() {
    local f
    f="$(modinfo -k "$KVER" -F filename "$1" 2>/dev/null)"
    [[ "$f" == */updates/* && -d "/sys/module/${1//-/_}" ]]
}
# module <fix> <module>: the three states every module overlay can be in
module() {
    local fix="$1" m="$2"
    if overlay_loaded "$m"; then ok "$fix" "$m from updates/"
    elif overlay_present "$m"; then
        if journal "$m.*(rejected|signature)"; then bad "$fix" "$m overlay rejected: key not enrolled?"
        else bad "$fix" "$m overlay present but the stock module is loaded"; fi
    else bad "$fix" "no $m overlay for $KVER"; fi
}

for fix in acpi-override psr-band oled-backlight cdclk-ptl edp-dsc headset-mic sof-audio \
           micmute touchpad-edge fan fingerprint battery hotkeys hotkey-actions auto-rebuild; do
    profile_lists_fix "$fix" || { meh "$fix" "not listed for this board"; continue; }
    case "$fix" in
    acpi-override)
        if (( ! ROOT_OK )); then meh "$fix" "needs root to check"
        elif journal 'Table Upgrade: override.*I2C_DEVT'; then ok "$fix" "override active"
        elif journal 'locked down, ignoring table override'; then meh "$fix" "blocked by Secure Boot lockdown"
        elif [[ -f /boot/acpi_override.cpio ]]; then bad "$fix" "staged for GRUB but not active in this boot"
        else bad "$fix" "not installed"; fi ;;
    psr-band)
        if grep -q 'xe.enable_psr=1' /proc/cmdline; then ok "$fix" "PSR limited to PSR1"
        else bad "$fix" "xe.enable_psr=1 not on the command line"; fi ;;
    oled-backlight)
        if ! grep -q 'vbt_firmware=' /proc/cmdline; then bad "$fix" "vbt_firmware= not on the command line"
        elif [[ -f /etc/initramfs-tools/hooks/honor-vbt ]] || grep -qs 'vbt.bin' /etc/mkinitcpio.conf; then ok "$fix" "patched VBT in the initramfs"
        else meh "$fix" "blob installed but not in the initramfs, so the firmware floor is still used"; fi ;;
    cdclk-ptl)
        if ! kver_ge "$KBASE" 7.1.6; then meh "$fix" "kernel $KBASE predates the bug"
        elif grep -qs 'cdclk-ptl' /var/lib/honor/xe-module.stamp && overlay_loaded xe; then ok "$fix" "in the xe overlay"
        else module "$fix" xe; fi ;;
    edp-dsc)
        if grep -qs 'edp-dsc' /var/lib/honor/xe-module.stamp && overlay_loaded xe; then ok "$fix" "in the xe overlay"
        else module "$fix" xe; fi ;;
    headset-mic)
        want="$(sed -n 's/.*hda_model=\([^ ]*\).*/\1/p' /etc/modprobe.d/honor-headset-mic.conf 2>/dev/null | head -1)"
        have="$(cat /sys/class/sound/hwC*D0/modelname 2>/dev/null | head -1)"
        if [[ -z "$want" ]]; then bad "$fix" "no /etc/modprobe.d/honor-headset-mic.conf"
        elif [[ "$have" == "$want" ]]; then ok "$fix" "codec model $have"
        else bad "$fix" "option set to $want, codec runs ${have:-no model}: reboot?"; fi ;;
    sof-audio)   module "$fix" snd-sof ;;
    micmute)
        if compgen -G '/etc/udev-hid-bpf/*micmute*.bpf.o' >/dev/null; then
            if systemctl is-active --quiet honor-hid-bpf-reapply.service; then ok "$fix" "HID-BPF installed"
            else bad "$fix" "program installed but honor-hid-bpf-reapply.service failed"; fi
        else bad "$fix" "no HID-BPF program installed"; fi ;;
    touchpad-edge)
        if compgen -G '/etc/udev-hid-bpf/*edge*.bpf.o' >/dev/null; then ok "$fix" "HID-BPF installed"
        else bad "$fix" "no HID-BPF program installed"; fi ;;
    fan)
        if [[ -d /sys/module/honor_ec_sensors ]]; then ok "$fix" "honor-ec-sensors loaded"
        elif dkms status 2>/dev/null | grep -q '^honor-ec-sensors'; then bad "$fix" "built by dkms but not loaded: signature?"
        else bad "$fix" "not installed"; fi ;;
    fingerprint)
        v="$(dpkg-query -W -f '${Version}' libfprint-2-2 2>/dev/null || pacman -Q libfprint 2>/dev/null | awk '{print $2}')"
        if [[ -f /opt/honor-libfprint-sdcp/lib/libfprint-2.so && -f /etc/ld.so.conf.d/00-honor-libfprint-sdcp.conf ]]; then ok "$fix" "SDCP libfprint in /opt ahead of ${v:-?}"
        elif [[ "$v" == *honor* ]] || [[ -f /var/lib/honor/fingerprint.stamp ]]; then ok "$fix" "libfprint ${v:-?}"
        else bad "$fix" "distribution libfprint ${v:-?} without the reader"; fi ;;
    battery)
        t="$(cat /sys/devices/platform/huawei-wmi/charge_control_thresholds 2>/dev/null)"
        if [[ -f /etc/honor-battery.conf && -n "$t" ]]; then ok "$fix" "thresholds $t"
        elif [[ -n "$t" ]]; then bad "$fix" "no preset configured, EC reports $t"
        else bad "$fix" "huawei-wmi exposes no thresholds"; fi ;;
    hotkeys)
        if overlay_loaded huawei-wmi; then ok "$fix" "huawei-wmi from updates/"
        elif [[ -f /etc/udev/hwdb.d/61-honor-keyboard.hwdb ]]; then bad "$fix" "hwdb only, the patched huawei-wmi is not loaded"
        else module "$fix" huawei-wmi; fi ;;
    hotkey-actions)
        if systemctl is-active --quiet honor-hotkey-actions.service; then ok "$fix" "service running"
        elif systemctl is-enabled --quiet honor-hotkey-actions.service 2>/dev/null; then bad "$fix" "service enabled but not running"
        else bad "$fix" "service not installed"; fi ;;
    auto-rebuild)
        if [[ -f /etc/kernel/postinst.d/95-honor-kernel-modules || -f /etc/pacman.d/hooks/95-honor-kernel-modules.hook ]]; then ok "$fix" "kernel hook installed"
        else bad "$fix" "no kernel hook"; fi ;;
    esac
done
