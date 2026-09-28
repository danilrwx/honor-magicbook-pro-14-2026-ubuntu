#!/usr/bin/env bash
# uninstall.sh — remove the package-manager hooks that re-apply the fixes.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the auto-rebuild hooks"
# Both styles, because a machine may have been moved between distributions:
# pacman hooks on Arch, /etc/kernel/postinst.d on Debian and Ubuntu. Removing
# one that was never installed is not an error.
u_rm /etc/pacman.d/hooks/95-honor-kernel-modules.hook \
     /etc/pacman.d/hooks/96-honor-libfprint.hook \
     /etc/kernel/postinst.d/95-honor-kernel-modules \
     /usr/local/lib/honor/rebuild.sh \
     /usr/local/lib/honor/deferred.sh \
     /etc/honor-autorebuild.conf \
     /etc/honor-zqcp-autorebuild.conf \
     /etc/pacman.d/hooks/95-honor-zqcp-kernel-modules.hook \
     /etc/pacman.d/hooks/96-honor-zqcp-libfprint.hook \
     /usr/local/lib/honor/repo \
  || echo "    nothing installed"
rmdir --ignore-fail-on-non-empty /usr/local/lib/honor 2>/dev/null || true

echo
echo "    Anything still installed that lives inside a kernel module or inside"
echo "    libfprint will now be silently reverted by the next update of that"
echo "    package. Re-run its installer by hand after one, or put these hooks"
echo "    back with patch/auto-rebuild/install.sh."
u_done
