#!/usr/bin/env bash
# install.sh — the built-in microphone array as one clean source.
#
# SOF hands PipeWire the array as four channels, the two microphones and the
# DSP's beam twice, the beam in opposite phase. Every application downmixes all
# four, the voice partly cancels, and the result sounds hollow and far away. The
# fix is a PipeWire config, nothing built:
#
#   /etc/pipewire/pipewire.conf.d/51-honor-dmic-array.conf
#
# a source, "Built-in Microphone", made of the two microphones alone through
# WebRTC (high-pass, noise suppression, gain control, echo cancellation), ranked
# above the raw array so it becomes the default. The raw array stays listed.
#
# Reruns are safe.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR=/etc/pipewire/pipewire.conf.d
CONF="${SCRIPT_DIR}/51-honor-dmic-array.conf"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# Tier B: the channel layout, which channels are microphones and which the beam,
# was measured on one board. On another it could pick the beam, or nothing.
source "${SCRIPT_DIR}/../../lib/gate.sh"
honor_gate dmic-array

variant_find "$SCRIPT_DIR" || die \
    "this fix has nothing for $(profile_get model) board ${PROFILE_BOARD:-?}.
    Covered: $(variant_known "$SCRIPT_DIR")"
SOURCE="$(recipe_get source)"
[[ -n "$SOURCE" ]] || die "patch/dmic-array/${VARIANT_FOR}/recipe.conf does not record source."
grep -qF "\"${SOURCE}\"" "$CONF" || die "51-honor-dmic-array.conf does not target ${SOURCE}."
log "machine $(variant_note)"

command -v pipewire >/dev/null || die "PipeWire is not installed; this fix is a PipeWire config."
AEC=""
for d in /usr/lib/*/spa-0.2/aec /usr/lib/spa-0.2/aec /usr/lib64/spa-0.2/aec; do
    [[ -f "$d/libspa-aec-webrtc.so" ]] && AEC="$d" && break
done
[[ -n "$AEC" ]] || die "PipeWire's WebRTC plugin (spa-0.2/aec/libspa-aec-webrtc.so) is missing.
    Install it (Debian/Ubuntu: libspa-0.2-modules, Arch: pipewire) and rerun."

log "installing ${CONF_DIR}/$(basename "$CONF")"
install -d -m 0755 "$CONF_DIR"
install -m 0644 "$CONF" "$CONF_DIR/"

# WirePlumber remembers a default source somebody picked by hand, and that
# outranks the priority, so drop it, as patch/headset-mic does, and restart the
# user's audio so the source exists now rather than at the next login.
U="${SUDO_USER:-}"
if [[ -n "$U" && "$U" != root ]]; then
    UH="$(getent passwd "$U" | cut -d: -f6)"
    rm -f "${UH}/.local/state/wireplumber/default-nodes"
    RD="/run/user/$(id -u "$U")"
    if [[ -d "$RD" ]]; then
        as_user() { sudo -u "$U" XDG_RUNTIME_DIR="$RD" DBUS_SESSION_BUS_ADDRESS="unix:path=${RD}/bus" "$@"; }
        if as_user systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null; then
            sleep 3
            dump="$(as_user pw-dump 2>/dev/null || true)"
            if [[ "$dump" != *"\"${SOURCE}\""* ]]; then
                warn "the raw array ${SOURCE} is not in ${U}'s session; the source will stay silent"
            elif [[ "$dump" == *'"honor-dmic"'* ]]; then
                log "\"Built-in Microphone\" is up for ${U}"
            else
                warn "PipeWire did not create the source; see journalctl --user -u pipewire"
            fi
        else
            log "restart PipeWire (or log out and back in) to apply"
        fi
    fi
else
    log "restart PipeWire (or log out and back in) to apply"
fi
