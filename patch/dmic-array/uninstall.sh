#!/usr/bin/env bash
# uninstall.sh — remove the cleaned built-in microphone source.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the PipeWire config for the built-in microphone array"
u_rm /etc/pipewire/pipewire.conf.d/51-honor-dmic-array.conf || echo "    nothing installed"
rmdir --ignore-fail-on-non-empty /etc/pipewire/pipewire.conf.d /etc/pipewire 2>/dev/null || true
echo "    restart PipeWire (or log out and back in) to drop the source"
u_done
