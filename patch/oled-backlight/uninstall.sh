#!/usr/bin/env bash
# uninstall.sh — revert the patched VBT and go back to the firmware's own
# minimum backlight level.
#
# Dropping the kernel parameter alone is enough to restore stock behaviour;
# everything else here is tidying up. The saved factory VBT is kept by default
# so a later re-install does not have to boot without the parameter first. Pass
# PURGE=1 to remove that too.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

FW_DIR=/usr/lib/firmware/honor
STATE_DIR=/var/lib/honor
PURGE="${PURGE:-0}"

u_log "Removing the kernel parameter"
# Through lib/distro.sh, not by editing /etc/default/limine directly. This used
# to be a sed at a hardcoded limine path, so on GRUB or systemd-boot it printed
# "drop it by hand" for a case the library already handles.
if f="$(distro_cmdline_file 2>/dev/null)" && [[ -n "$f" ]]; then
    distro_cmdline_remove '(xe|i915)\.vbt_firmware=[^ "]*'
    distro_cmdline_show | sed 's/^/    /'
else
    u_warn "no kernel command line file found; drop (xe|i915).vbt_firmware=
    from your bootloader's command line by hand"
fi

u_log "Dropping the blob from the initramfs file list"
# mkinitcpio only. dracut and Debian's update-initramfs stage firmware
# differently and the installer does not use FILES= there, so there is nothing
# to undo. This used to run unguarded and killed the whole script on any
# machine without mkinitcpio, which is every Debian and Fedora one.
if [[ -f /etc/mkinitcpio.conf ]]; then
    sed -i -E "/^FILES=/ { s#${FW_DIR}/[A-Za-z0-9._-]+ *##; s#^FILES=\( *\)#FILES=()#; }" \
        /etc/mkinitcpio.conf
    echo "    $(grep -E '^FILES=' /etc/mkinitcpio.conf)"
else
    echo "    no /etc/mkinitcpio.conf on this system, nothing staged there"
fi

u_log "Removing the firmware blob and the optional zero guard"
u_rm /etc/udev/rules.d/99-honor-backlight-nonzero.rules \
     /etc/udev/rules.d/99-honor-zqcp-backlight-nonzero.rules
udevadm control --reload 2>/dev/null || true
# Off Arch the installer cannot edit an initramfs file list, so it asks for a
# dracut drop-in instead. Remove ours; a hand-written one is the user's.
u_rm /etc/dracut.conf.d/honor-vbt.conf /etc/initramfs-tools/hooks/honor-vbt
# Globbed: the blob is named after the model it was dumped from, so a machine
# that is not the reference one has a different file here.
shopt -s nullglob
u_rm "$FW_DIR"/*-vbt.bin || echo "    no blob installed"
shopt -u nullglob
rmdir --ignore-fail-on-non-empty "$FW_DIR" 2>/dev/null || true
u_rm "${STATE_DIR}/vbt-patched.bin" "${STATE_DIR}/oled-backlight.stamp" \
     /var/lib/honor-zqcp/vbt-patched.bin

if (( PURGE )); then
    u_rm "${STATE_DIR}/vbt-factory.bin"
    rmdir --ignore-fail-on-non-empty "$STATE_DIR" 2>/dev/null || true
else
    # This is the only copy of the untouched VBT. Getting it back means booting
    # once without the parameter, so it is kept unless somebody insists.
    [[ -f "${STATE_DIR}/vbt-factory.bin" ]] \
        && echo "    kept ${STATE_DIR}/vbt-factory.bin (PURGE=1 to remove it)"
fi

u_log "Rebuilding the initramfs and the bootloader config"
u_regen

cat <<'EOF'

    Reboot to go back to the firmware minimum. After that this must print
    nothing:

        grep -o 'vbt_firmware=[^ ]*' /proc/cmdline

    The panel's darkest settings come back, and so do the colour cast and the
    blotches at those settings, which is the trade this fix exists to make.
EOF
u_done
