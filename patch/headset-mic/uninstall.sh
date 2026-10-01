#!/usr/bin/env bash
# uninstall.sh — remove the ALC256 headset-microphone quirk.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the codec model option, any old codec overlay and the capture-priority rule"
u_rm /etc/modprobe.d/honor-headset-mic.conf \
     "/usr/lib/modules/${KVER}/updates/snd-hda-codec-alc269.ko.zst" \
     "/usr/lib/modules/${KVER}/updates/snd-hda-codec-alc269.ko" \
     /etc/wireplumber/wireplumber.conf.d/51-honor-mic-priority.conf \
     /etc/wireplumber/wireplumber.conf.d/51-honor-zqcp-mic-priority.conf \
  || echo "    nothing installed for ${KVER}"
rmdir --ignore-fail-on-non-empty \
      /etc/wireplumber/wireplumber.conf.d /etc/wireplumber 2>/dev/null || true

# An early version of this fix wrote the patched module over the packaged one
# instead of into updates/. If that was ever done here, the original is the
# only copy and it has to go back.
ALC_PATH="/usr/lib/modules/${KVER}/kernel/sound/hda/codecs/realtek/snd-hda-codec-alc269.ko.zst"
ALC_BACKUP="/root/snd-hda-codec-alc269.ko.zst.orig"
if [[ -f "$ALC_BACKUP" ]]; then
    u_log "Restoring the in-place backup"
    cp -av "$ALC_BACKUP" "$ALC_PATH" && rm -fv "$ALC_BACKUP"
fi

# Older still: a systemd unit firing EXECUTE_PIN_SENSE on every boot, made
# unnecessary by the kernel-side fixup.
u_unit_off honor-mic-jack-init.service
u_rm /etc/systemd/system/honor-mic-jack-init.service \
     /usr/local/bin/honor-mic-jack-init.sh
u_daemon_reload
u_depmod

echo "    after a reboot the 3.5 mm jack microphone stops working. The built-in array is"
echo "    unaffected, and the mic-mute LED goes back to following it, which is"
echo "    the side effect the WirePlumber rule above existed to undo."
u_done
