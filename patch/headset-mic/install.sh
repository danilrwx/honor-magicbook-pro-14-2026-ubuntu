#!/usr/bin/env bash
# install.sh — the 3.5 mm headset microphone on the ALC256, without rebuilding
# anything. The fix this board needs is pin 0x19 as a headset mic without its
# own jack detect (0x01a1913c), chained into the kernel's headset-mode
# lifecycle, and the stock alc269 driver already has exactly that as a named
# model. So the whole fix is one module option naming it, read by the SOF
# driver (hda_model=) or, on a legacy HDA setup, by snd-hda-intel (model=):
#
#   /etc/modprobe.d/honor-headset-mic.conf
#
# The codec module stays the signed in-tree one, so there is nothing to sign,
# nothing to rebuild after a kernel update, and nothing that can hang the boot
# (a rebuilt monolithic alc269 did, on the split realtek layout of 7.0).
# Takes effect on the next boot: under SOF the codec cannot be re-probed live
# (hwC0D0/reconfig returns EBUSY).
#
# The upstream-style patch in zqc-p/M1010/alc269-headset-mic.patch is kept as
# the SSID quirk to send upstream; once a kernel carries it, the option is
# redundant but harmless.
#
# Reruns are safe.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tier B: the subsystem id and the choice of fixup are model specific, and
# getting either wrong reconfigures the codec pins on real hardware.
source "${SCRIPT_DIR}/../../lib/gate.sh"
honor_gate headset-mic

fatal() { echo "[fatal] $*" >&2; exit 1; }

# patch/headset-mic/<model>/<board>/, the same two words the profile used.
variant_find "$SCRIPT_DIR" || fatal \
"this fix has nothing for $(profile_get model) board ${PROFILE_BOARD:-?}.
        Covered: $(variant_known "$SCRIPT_DIR")
        The quirk is a pin configuration written for one codec on one board, so
        a machine has to be added deliberately. See patch/headset-mic/README.md."

AUDIO_SSID="$(gate_param audio_ssid)" || fatal \
"$(profile_get model) does not record audio_ssid. Read it with:
          for d in /sys/bus/pci/devices/*; do
              case \"\$(cat \$d/class)\" in 0x0401*|0x0403*)
                  echo \"\$(cat \$d/subsystem_vendor):\$(cat \$d/subsystem_device)\";;
              esac
          done"

# `fixup` is the name of a model in alc269.c's fixup_models[], which is what
# hda_model=/model= take.
FIXUP_NAME="$(recipe_param fixup)" || fatal \
"patch/headset-mic/${VARIANT_FOR}/recipe.conf does not record fixup, so there is
        no way to know which alc269.c model this board needs. That has to be
        worked out on the machine itself."

# The board directory says which codec it was written against; the machine says
# what it has. A pin configuration handed to the wrong codec is not a no-op.
variant_check_device "$AUDIO_SSID" || fatal \
"$(profile_get model) board ${PROFILE_BOARD:-?} was written against codec
        $(recipe_get device), and this machine reports $AUDIO_SSID. Nothing has
        been written. Please open an issue with both ids."

echo "[ok] machine $(variant_note)"
echo "[ok] codec ${AUDIO_SSID}, model ${FIXUP_NAME}"

legacy_drop /etc/wireplumber/wireplumber.conf.d/51-honor-zqcp-mic-priority.conf

# --- WirePlumber: keep the internal DMIC as the default capture source -------
# The quirk uses JACK_DETECT_OVERRIDE, so the jack input is always reported
# present and WirePlumber ranks it (priority.session 2000) above the built-in
# digital microphone array (1648). That makes an empty jack the default
# recording device, and it breaks the mic-mute LED, because the kernel's
# control-LED group only tracks the DMIC control. Rank the jack input below
# the array; it stays fully usable, it is simply no longer the default.
WP_RULE="${SCRIPT_DIR}/51-honor-mic-priority.conf"
WP_DIR="/etc/wireplumber/wireplumber.conf.d"
if [[ -f "$WP_RULE" ]]; then
    echo "[*] installing ${WP_DIR}/$(basename "$WP_RULE")"
    install -d -m 0755 "$WP_DIR"
    install -m 0644 "$WP_RULE" "$WP_DIR/"

    # WirePlumber remembers a manually chosen default source and that choice
    # outranks the priority rule. Drop a stale one so the rule decides.
    WP_USER="${SUDO_USER:-}"
    if [[ -n "$WP_USER" && "$WP_USER" != "root" ]]; then
        WP_HOME=$(getent passwd "$WP_USER" | cut -d: -f6)
        rm -f "${WP_HOME}/.local/state/wireplumber/default-nodes"
        WP_RD="/run/user/$(id -u "$WP_USER" 2>/dev/null || echo 0)"
        if [[ -d "$WP_RD" ]]; then
            sudo -u "$WP_USER" \
                XDG_RUNTIME_DIR="$WP_RD" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=${WP_RD}/bus" \
                systemctl --user restart wireplumber 2>/dev/null \
                && echo "[ok] wireplumber restarted for ${WP_USER}" \
                || echo "[*] restart wireplumber (or log out and back in) to apply"
        fi
    else
        echo "[*] restart wireplumber (or log out and back in) to apply"
    fi
else
    echo "[warn] ${WP_RULE##*/} not found next to this script - skipping the"
    echo "       capture-priority rule. The 3.5 mm jack input may become the"
    echo "       default source and the mic-mute LED will not follow Fn+F7."
fi


# --- Drop what earlier iterations of this fix installed --------------------
# A rebuilt snd-hda-codec-alc269 in updates/ for any kernel: on 7.0 it hangs the
# machine at boot, and the option below makes it pointless everywhere.
dropped=0
for ko in /usr/lib/modules/*/updates/snd-hda-codec-alc269.ko*; do
    [[ -e "$ko" ]] || continue
    echo "[*] removing the rebuilt codec module $ko"
    rm -f "$ko"
    kv="${ko#/usr/lib/modules/}"; kv="${kv%%/*}"
    rmdir --ignore-fail-on-non-empty "/usr/lib/modules/${kv}/updates" 2>/dev/null || true
    depmod -a "$kv"
    dropped=1
done
# Older still: the patched module written over the packaged one, with the
# original backed up. Put it back if the backup matches the running kernel.
BACKUP="/root/snd-hda-codec-alc269.ko.zst.orig"
if [[ -f "$BACKUP" ]]; then
    KVER="$(uname -r)"
    if [[ "$(modinfo -F vermagic "$BACKUP" 2>/dev/null | awk '{print $1}')" == "$KVER" ]]; then
        echo "[*] restoring the packaged codec module from $BACKUP"
        install -m 0644 "$BACKUP" "/usr/lib/modules/${KVER}/kernel/sound/hda/codecs/realtek/snd-hda-codec-alc269.ko.zst"
        rm -f "$BACKUP"
        depmod -a "$KVER"
    else
        echo "[warn] $BACKUP is for another kernel, leaving it alone"
    fi
fi
# And the userspace hotfix from before that: a unit firing hda-verb on boot.
if systemctl is-enabled honor-mic-jack-init.service >/dev/null 2>&1; then
    echo "[*] removing legacy honor-mic-jack-init.service"
    systemctl disable --now honor-mic-jack-init.service >/dev/null 2>&1 || true
fi
rm -f /etc/systemd/system/honor-mic-jack-init.service /usr/local/bin/honor-mic-jack-init.sh
systemctl daemon-reload 2>/dev/null || true

# --- The fix: name the model -------------------------------------------------
# hda_model= applies to every codec on the SOF card; the HDMI codec has no
# models and ignores it. model= covers a machine booted with the legacy
# snd-hda-intel driver (snd_intel_dspcfg.dsp_driver=1).
CONF=/etc/modprobe.d/honor-headset-mic.conf
want="# patch/headset-mic: ALC256 ${AUDIO_SSID}, pin 0x19 as a headset mic without jack detect
options snd_sof_intel_hda_generic hda_model=${FIXUP_NAME}
options snd_hda_intel model=${FIXUP_NAME}"
if [[ -f "$CONF" ]] && [[ "$(cat "$CONF")" == "$want" ]]; then
    echo "[ok] $CONF already up to date"
else
    printf '%s\n' "$want" > "$CONF"
    chmod 0644 "$CONF"
    echo "[ok] wrote $CONF"
fi

now="$(cat /sys/class/sound/hwC*D0/modelname 2>/dev/null | head -1)"
if [[ "$now" == "$FIXUP_NAME" ]] && grep -qs '^0x19 0x01a1913c' /sys/class/sound/hwC*D0/driver_pin_configs; then
    echo "[ok] active in this boot: model ${now}, pin 0x19 = 0x01a1913c"
else
    echo "[*] takes effect on the next boot"
fi
(( dropped )) && echo "[*] the rebuilt codec module is gone; reboot before trusting audio"
exit 0
