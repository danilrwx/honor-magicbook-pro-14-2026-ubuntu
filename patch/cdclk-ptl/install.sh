#!/usr/bin/env bash
# Rebuild xe.ko with the Panther Lake CDCLK sanitization fix.
#
# Since 7.1.6 the shared i915 display code forces a full CDCLK PLL
# disable+enable during driver load on every Panther Lake machine. The panel
# is already lit by the GOP at that point, so the screen shows garbage.
# See README.md in this directory for the trace.
#
# The fix is a 4-line upstream patch. It reached drm-intel-next on 2026-08-21
# and rides the merge window into Linux 7.3, so on any kernel you can install
# today the module has to be rebuilt locally. Only xe.ko is rebuilt: it compiles
# i915-display/intel_cdclk.o straight out of drivers/gpu/drm/i915/display/,
# so the whole kernel does not have to be built.
#
# The result is installed into /usr/lib/modules/$KVER/updates/, which depmod
# searches before kernel/, so the packaged module is never overwritten.
#
# There is only one xe.ko and this repository now has more than one patch that
# lives inside it, so the build itself is in lib/xe-build.sh and always carries
# every patch that applies to this machine. Running this installer therefore
# also keeps patch/edp-dsc/ in the module, and vice versa; running one does not
# quietly drop the other.
#
# Env knobs:
#   KVER=...     build for another installed kernel (default: running one)
#   JOBS=N       parallel compile jobs (default: nproc)
#   WORKDIR=...  where to unpack the source (default: /var/tmp/honor-xe)
#   KEEP_SRC=1   do not delete the source tree afterwards
#   FORCE=1      rebuild even when the installed module already matches
#   REGEN=0      do not regenerate the initramfs (the caller will)

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/0001-drm-i915-cdclk-avoid-spurious-cdclk-sanitization-on-PTL.patch"
KVER="${KVER:-$(uname -r)}"
# JOBS, WORKDIR, KEEP_SRC, REGEN and FORCE are read by lib/xe-build.sh from
# the environment; they are deliberately not given defaults here, or the
# builder's own would never apply.
MODDIR="/usr/lib/modules/${KVER}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. is this machine affected at all? -------------------------------------
[[ -f "$PATCH_FILE" ]] || die "patch not found: $PATCH_FILE"
[[ -d "$MODDIR" ]]     || die "no module tree for kernel $KVER"

# Tier A: the patch either applies to the kernel source or it does not, and the
# bug is a property of the display IP rather than of the model.
source "${SCRIPT_DIR}/../../lib/gate.sh"
honor_gate cdclk-ptl

# Every fix is looked up the same way, including the ones that carry no
# numbers of their own: patch/cdclk-ptl/<model>/<board>/ records that this
# machine was considered and on what evidence. See lib/variant.sh.
variant_find "$SCRIPT_DIR" || die \
    "this fix has nothing for $(profile_get model) board ${PROFILE_BOARD:-?}.
    Covered: $(variant_known "$SCRIPT_DIR")"
log "machine: $(variant_note)"

# The bug needs display IP 30, which arrived with Panther Lake. Earlier
# platforms still have the CD2X pipe field the sanitization compares.
if [[ "$(profile_get platform)" != "pantherlake" ]]; then
    die "$(profile_get model) is platform '$(profile_get platform)', and this
    regression only affects display IP version 30 and newer, which arrived with
    Panther Lake. Nothing to fix here."
fi

LSPCI_OUT="$(lspci -nn 2>/dev/null || true)"
if ! grep -qiE '00:02\.0 .*(Panther Lake|Wildcat Lake)' <<< "$LSPCI_OUT"; then
    warn "no Panther Lake / Wildcat Lake iGPU found on 00:02.0, though the"
    warn "profile says this is a Panther Lake machine. Continuing anyway."
fi

# The regression landed in v7.1.6 and is still unfixed in every later release.
# Anything older than that, or any tree that already carries the fix, needs
# nothing. The source check below is the authoritative one; this is just a
# friendly early exit. Not on Debian and Ubuntu: their kernels keep the base
# version and take stable fixes as backports (Ubuntu's 7.0.0-38 carries this
# regression), so only the source can tell.
KBASE="${KVER%%-*}"
OLDEST_BAD="7.1.6"
if ! command -v apt-get >/dev/null && [[ "$KBASE" != "$OLDEST_BAD" &&
      "$(printf '%s\n%s\n' "$KBASE" "$OLDEST_BAD" | sort -V | head -1)" == "$KBASE" ]]; then
    warn "kernel $KBASE predates the regression (it was introduced in $OLDEST_BAD)."
    warn "Nothing to fix here. Set FORCE=1 to build anyway."
    [[ "${FORCE:-0}" == "1" ]] || exit 0
fi

log "kernel  = $KVER"

# --- 2. hand over to the shared builder ---------------------------------------
# Everything from here on is common to every fix that lives inside xe.ko:
# toolchain, source, the full patch set, config, build, install, initramfs.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/xe-build.sh"
xe_build_install cdclk-ptl

log "done. Reboot, then check:"
echo "    modinfo xe | head -1                     # should point at updates/"
echo "    cat /var/lib/honor/xe-module.stamp       # what went into it"
