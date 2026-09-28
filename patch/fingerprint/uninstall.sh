#!/usr/bin/env bash
# uninstall.sh — go back to the distribution: reinstall its libfprint package.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Reverting libfprint"
# Not the lock in /var/lock: flock does not need the file removed, and deleting
# one while another process holds it is how two runs end up both thinking they
# have it.
u_rm /var/lib/honor/fingerprint.stamp
rmdir --ignore-fail-on-non-empty /var/lib/honor 2>/dev/null || true

# --- the SDCP prefix, first, because it outranks everything else ---------------
# The EgisTec recipe does not patch the distribution's libfprint. It builds
# upstream's SDCP branch into /opt and puts that ahead of the system library for
# every program through ld.so.conf.d. Reinstalling the distribution package
# below would therefore change nothing at all while this is still in place: the
# loader would keep handing out the one in /opt.
SDCP_PREFIX=/opt/honor-libfprint-sdcp
SDCP_LDCONF=/etc/ld.so.conf.d/00-honor-libfprint-sdcp.conf
if [[ -e "$SDCP_PREFIX" || -e "$SDCP_LDCONF" ]]; then
    u_log "Removing the SDCP libfprint prefix"
    u_rm "$SDCP_LDCONF" "$SDCP_PREFIX"
    ldconfig 2>/dev/null || u_fail "ldconfig failed; run it by hand"
    echo "    the system libfprint is in charge again"
fi

if command -v pacman >/dev/null 2>&1; then
    # The patched build is a package with a bumped pkgrel, so pacman owns the
    # files and putting the repository version back is one transaction. -S
    # alone would see the local one as newer and do nothing.
    if pacman -Q libfprint >/dev/null 2>&1; then
        u_log "Reinstalling the repository libfprint over the local build"
        pacman -S --noconfirm libfprint >/dev/null 2>&1 \
            && echo "    now at $(pacman -Q libfprint | awk '{print $2}')" \
            || u_fail "pacman -S libfprint failed; run it by hand"
    else
        echo "    libfprint is not installed"
    fi
    BUILD_USER="${SUDO_USER:-}"
    if [[ -n "$BUILD_USER" ]]; then
        BUILD_HOME="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
        [[ -n "$BUILD_HOME" ]] && u_rm "${BUILD_HOME}/.cache/honor-libfprint-build"
    fi
elif command -v apt-get >/dev/null 2>&1; then
    # The patched build is the distribution's own package with a +honor suffix,
    # held. Unhold it and put the archive version back.
    held="$(dpkg-query -W -f '${Package} ${Version}\n' 'libfprint-2-*' 2>/dev/null | awk '/\+honor/ {print $1}')"
    if [[ -n "$held" ]]; then
        u_log "Reinstalling the archive libfprint over the local build"
        targets=()
        for p in $held; do
            v="$(apt-cache madison "$p" 2>/dev/null | awk '!/\+honor/ {print $3; exit}')"
            [[ -n "$v" ]] && targets+=("${p}=${v}")
        done
        # shellcheck disable=SC2086
        apt-mark unhold $held >/dev/null 2>&1 || true
        if (( ${#targets[@]} )) && apt-get install -y --allow-downgrades "${targets[@]}" >/dev/null 2>&1; then
            echo "    now at $(dpkg-query -W -f '${Version}' libfprint-2-2 2>/dev/null)"
        else
            u_fail "apt-get install failed; run it by hand: apt-get install --allow-downgrades ${targets[*]:-libfprint-2-2}"
        fi
    else
        echo "    no held honor build of libfprint installed"
    fi
else
    u_warn "This fix installs through the distribution's package manager on Arch,
    Debian and Ubuntu, and by 'ninja install' into /usr elsewhere. There is no
    record of which files that wrote, so reinstall your distribution's
    libfprint package:
        Fedora:         sudo dnf reinstall libfprint"
fi

echo "    the reader stops being recognised and fprintd will not see it."
echo "    Enrolled fingerprints live on the sensor and are untouched."
u_done
