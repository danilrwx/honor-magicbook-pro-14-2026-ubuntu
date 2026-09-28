#!/usr/bin/env bash
# install-sof-ipc4-fix.sh — fetch the running kernel's sound/soc/sof tree
# from the upstream stable tree, apply Peter Ujfalusi's IPC4 copier-payload
# refresh patch (thesofproject/linux PR #5762), build snd-sof.ko out-of-tree
# against the installed kernel headers, and drop the resulting
# snd-sof.ko.zst into the modules `updates/` overlay so it loads instead of
# the unpatched in-tree module.
#
# Background:
#   On Panther Lake (and other Intel SOF platforms), the IPC4 ipc_config_data
#   buffer for copier widgets is built once during ipc_prepare and cached.
#   On suspend/resume, host and link DMA streams are released and re-allocated
#   with potentially different stream tags, but because the widget list
#   persists across suspend, sof_pcm_hw_params skips
#   sof_pcm_setup_connected_widgets and ipc_prepare never runs again. The
#   stale cached payload is then sent to firmware with boot-time DMA channel
#   assignments → DMA channel conflicts → firmware panic and dead audio.
#
#   This is the documented root cause behind thesofproject/sof#10700
#   "Dell XPS 14 DA14260 (Panther Lake): DSP error when unsuspending".
#
#   On the specific HONOR ZQC-P unit this repo was developed on, the
#   upstream race did NOT reproduce: a pavucontrol + rtcwake -m mem -s 8
#   ×3 cycle test produced zero `DSP panic!` entries in `dmesg`, and
#   the six boots logged in the local journal also contain zero. We
#   ship the backport anyway as a preventive measure — the upstream
#   fix is a clean one-file patch from the SOF maintainer, and the
#   workflow that triggers the race is application-driven (which
#   PipeWire / pavucontrol versions, when streams are open at the
#   moment of suspend, etc.), so it may surface here later.
#
#   The honor-fnf7-watch.service in this repo counts EVERY transition
#   of /sys/kernel/debug/sof/fw_state. Many of those are part of the
#   runtime PM D3 cycle (kernel transiently flags fw_state=CRASHED
#   when an IPC drops during D3 entry, then auto-recovers to
#   NOT_STARTED). They are NOT the same as the firmware-reported DSP
#   panic from upstream #10700 and should NOT be used to estimate
#   the rate of real firmware crashes.
#
#   The fix refreshes copier_data (and for DAI copiers, the dma_config_tlv
#   trailer) in ipc_config_data inside sof_ipc4_widget_setup right before
#   the IPC message is sent. Touches one file:
#     sound/soc/sof/ipc4-topology.c   (+33 lines)
#
# This is a workaround for as long as the upstream patch under
# patch/sof-audio/0001-ASoC-SOF-ipc4-topology-Refresh-copier-IPC-payload-before-widget-setup.patch
# has not yet landed in the kernel being used. Once the change is in the
# running kernel's ipc4-topology.c this script becomes a no-op (it will
# detect the existing edit and skip the rebuild, removing any stale overlay).
#
# Reruns are safe — running it after a kernel update will rebuild against
# the new headers automatically.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

# Override with KVER=... to build for a kernel other than the running one -
# used by the pacman hook in patch/auto-rebuild/.
KVER="${KVER:-$(uname -r)}"
BUILD_DIR="/usr/lib/modules/${KVER}/build"
UPDATES_DIR="/usr/lib/modules/${KVER}/updates"
KO_NAME="snd-sof.ko.zst"
KO_OVERLAY="${UPDATES_DIR}/${KO_NAME}"
KO_INTREE="/usr/lib/modules/${KVER}/kernel/sound/soc/sof/${KO_NAME}"
BACKUP="/root/${KO_NAME}.orig"
WORK=$(mktemp -d /tmp/sof-ipc4-fix-XXXXXX)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/0001-ASoC-SOF-ipc4-topology-Refresh-copier-IPC-payload-before-widget-setup.patch"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

req() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
# Tier B: the backport itself is generic kernel code, but whether this race is
# worth carrying at all is a per-platform judgement, so it stays behind a
# verified profile.
source "${SCRIPT_DIR}/../../lib/gate.sh"
honor_gate sof-audio

# Every fix is looked up the same way, including the ones that carry no
# numbers of their own: patch/sof-audio/<model>/<board>/ records that this
# machine was considered and on what evidence. See lib/variant.sh.
if ! variant_find "$SCRIPT_DIR"; then
    echo "[fatal] this fix has nothing for $(profile_get model) board ${PROFILE_BOARD:-?}." >&2
    echo "        Covered: $(variant_known "$SCRIPT_DIR")" >&2
    exit 1
fi
echo "[*] machine: $(variant_note)"

req curl
req zstdcat
req zstd
req make
req patch
# The module has to come from the same compiler family as the kernel.
MAKEVARS=()
if distro_kernel_config_has CONFIG_CC_IS_CLANG=y "$KVER"; then
    MAKEVARS=(LLVM=1 LLVM_IAS=1)
    req clang
    req ld.lld
    req llvm-objcopy
fi
req depmod
req modprobe
req modinfo

echo "[*] kernel  = ${KVER}"
echo "[*] target  = ${KO_OVERLAY}"
echo "[*] patch   = ${PATCH_FILE}"

if [[ ! -f "$PATCH_FILE" ]]; then
    echo "[fatal] patch file not found: $PATCH_FILE" >&2
    exit 1
fi

# The rebuilt module has to be loadable. Where the kernel enforces signatures
# (Secure Boot + lockdown, CONFIG_MODULE_SIG_FORCE=y, module.sig_enforce=1) it
# is signed below with the machine owner key; refuse only when that is not
# possible either.
if distro_unsigned_blocked && ! distro_can_sign "$KVER"; then
    echo "[fatal] the kernel only loads signed modules and there is no way to sign here." >&2
    echo "        $(cat /sys/kernel/security/lockdown 2>/dev/null)" >&2
    echo "        Needs the kernel headers and, on Debian/Ubuntu, shim-signed." >&2
    exit 1
fi

# Verify build infrastructure is present.
if [[ ! -f "${BUILD_DIR}/Makefile" || ! -f "${BUILD_DIR}/Module.symvers" ]]; then
    echo "[fatal] kernel build dir incomplete: ${BUILD_DIR}" >&2
    echo "        install the matching linux-*-headers package and re-run."
    exit 1
fi
if [[ ! -d "${BUILD_DIR}/sound/soc/sof" ]]; then
    echo "[fatal] ${BUILD_DIR}/sound/soc/sof missing" >&2
    echo "        the kernel headers package does not expose the sound/soc/sof"
    echo "        subtree; a different distro / kernel layout is needed."
    exit 1
fi

# Fetch upstream sources matching the running kernel's tag, from the
# stable-tree mirror. lib/ksrc.sh resolves which tag that is and confirms it
# against the Makefile there, which matters more here than anywhere else: the
# check just below decides whether to skip this fix entirely, and it would
# reach the wrong answer against a tree that is not the running kernel.
ksrc_resolve

# Detect whether the running kernel's in-tree ipc4-topology.c already has
# the fix merged. We check for the distinctive comment text the upstream
# patch adds — if the kernel package was rebuilt with PR #5762 included
# (or its eventual upstream commit), there's nothing for us to do and
# any prior overlay can be removed as redundant.
echo "[*] checking upstream ${KSRC_TAG} for whether the fix is already merged"
ksrc_fetch "sound/soc/sof/ipc4-topology.c" "${WORK}/_check_ipc4-topology.c"
if grep -qF 'Refresh copier_data in ipc_config_data for host copiers' \
        "${WORK}/_check_ipc4-topology.c"; then
    echo "[ok] in-tree ipc4-topology.c at ${KSRC_TAG} already contains the fix."
    if [[ -f "$KO_OVERLAY" ]]; then
        echo "[*] removing redundant overlay $KO_OVERLAY"
        rm -f "$KO_OVERLAY"
        rmdir --ignore-fail-on-non-empty "$UPDATES_DIR" 2>/dev/null || true
        depmod -a "$KVER"
    fi
    exit 0
fi

# Skip rebuild if our overlay is already in place AND its srcversion matches
# what the patch would produce. The srcversion is a content hash of the
# constituent .c sources at build time; if we already built and installed
# the patched module against this kernel, modinfo will show the overlay
# path and a srcversion that came from patched sources.
overlay_is_patched() {
    [[ -f "$KO_OVERLAY" ]] || return 1
    # If modinfo from any source on the system reports the overlay path,
    # the depmod cache already prefers it — and the file is what it is.
    # Compare its srcversion against the in-tree baseline: a difference
    # means our overlay is a distinct build, presumably the patched one.
    local sv_overlay sv_intree
    sv_overlay=$(modinfo -F srcversion "$KO_OVERLAY" 2>/dev/null || true)
    sv_intree=$( modinfo -F srcversion "$KO_INTREE"  2>/dev/null || true)
    [[ -n "$sv_overlay" && "$sv_overlay" != "$sv_intree" ]]
}
if overlay_is_patched; then
    echo "[ok] overlay already present at $KO_OVERLAY with a different srcversion"
    echo "     than the in-tree module — assumed to be the patched build."
    echo "     Delete the overlay file and re-run if you want a fresh rebuild."
    exit 0
fi

# The file list is read from the tree itself rather than hardcoded: it drifts
# between kernel versions, and a stale list means either a missing source or a
# build against files that no longer exist. Only the top level of
# sound/soc/sof/ is taken. The per-platform subdirectories (intel, amd, imx,
# mediatek, xtensa) build separate modules that this patch does not touch, and
# pulling them in would cascade into codec and SoundWire dependencies.
echo "[*] listing sound/soc/sof at ${KSRC_TAG}"
mapfile -t SOF_FILES < <(
    ksrc_list_dir sound/soc/sof \
    | grep -E '\.(c|h)$|^Makefile$|^Kconfig$' || true
)

if (( ${#SOF_FILES[@]} < 20 )); then
    echo "[fatal] could not list sound/soc/sof at ${KSRC_TAG} (got ${#SOF_FILES[@]} entries)." >&2
    echo "        GitHub API unreachable or rate-limited. Retry later." >&2
    exit 1
fi
echo "[*] fetching ${#SOF_FILES[@]} SOF common sources"
for f in "${SOF_FILES[@]}"; do
    ksrc_fetch "sound/soc/sof/${f}" "${WORK}/sof/${f}"
done

# sof-acpi-dev.c and friends include a few headers from the platform
# subdirectories. Headers only: no .c files, so no extra objects are built.
for sub in intel amd; do
    while read -r h; do
        [[ -n "$h" ]] || continue
        ksrc_fetch_opt "sound/soc/sof/${sub}/${h}" "${WORK}/sof/${sub}/${h}" || true
    done < <(ksrc_list_dir "sound/soc/sof/${sub}" | grep -E '\.h$' || true)
done

# sof-acpi-dev.c #includes "../../codecs/hdac_hda.h" via sound/soc/intel/.
# Stage just the headers it needs into a sibling tree so the relative
# include paths resolve.
mkdir -p "${WORK}/intel/common"
for h in soc-intel-quirks.h sof-function-topology-lib.h \
         soc-acpi-intel-sdca-quirks.h soc-acpi-intel-sdw-mockup-match.h; do
    ksrc_fetch_opt "sound/soc/intel/common/${h}" "${WORK}/intel/common/${h}" || true
done

# Apply our patch.
echo "[*] applying ${PATCH_FILE##*/}"
(
    cd "$WORK"
    # The patch header references a/sound/soc/sof/ipc4-topology.c but the file
    # is staged at sof/ipc4-topology.c, so strip all four leading components
    # and apply inside sof/.
    if ! patch -p4 --no-backup-if-mismatch -d sof < "$PATCH_FILE"; then
        echo "[skip] the backport does not apply to ${KSRC_TAG}'s ipc4-topology.c." >&2
        echo "       That kernel's SOF tree has drifted from the one the patch" >&2
        echo "       was written against. Nothing is installed for ${KVER}." >&2
        exit 3
    fi
)

# Strip subdir descents from the SOF Makefile — they would force the build
# system to recurse into intel/, amd/, etc. which we deliberately don't
# stage. snd-sof.ko itself does not need them.
sed -i -E '/^obj-\$\(CONFIG_SND_SOC_SOF_[A-Z_]+\) \+= [a-z]+\/$/d' \
    "${WORK}/sof/Makefile"

# Stage the patched tree into the kernel headers' sound/soc/sof so that the
# in-tree kbuild infrastructure can drive an M= modules build. We touch the
# headers package because kbuild needs to see source under its tree, but we
# only place files that came from upstream (re-runnable, idempotent) and we
# do NOT delete anything that was there before.
echo "[*] staging sources into ${BUILD_DIR}/sound/soc/sof"
for f in "${WORK}/sof"/*; do
    if [[ -d "$f" ]]; then
        # platform subdirectory of headers (intel/, amd/) - copy the headers,
        # never any .c, so kbuild does not try to build those modules
        install -d -m 0755 "${BUILD_DIR}/sound/soc/sof/$(basename "$f")"
        for h in "$f"/*.h; do
            [[ -e "$h" ]] || continue
            install -m 0644 "$h" \
                "${BUILD_DIR}/sound/soc/sof/$(basename "$f")/$(basename "$h")"
        done
        continue
    fi
    install -m 0644 "$f" "${BUILD_DIR}/sound/soc/sof/$(basename "$f")"
done
# sof-acpi-dev.c expects sound/soc/intel/common/soc-intel-quirks.h to be
# reachable via "../intel/common/...". Mirror that in the build tree too.
mkdir -p "${BUILD_DIR}/sound/soc/intel/common"
for f in "${WORK}/intel/common"/*; do
    [[ -e "$f" ]] || continue
    install -m 0644 "$f" "${BUILD_DIR}/sound/soc/intel/common/$(basename "$f")"
done

echo "[*] building snd-sof.ko (${MAKEVARS[*]:-gcc})"
( cd "$BUILD_DIR" && make "${MAKEVARS[@]}" \
    M=sound/soc/sof modules ) 2>&1 | tail -12

BUILT_KO="${BUILD_DIR}/sound/soc/sof/snd-sof.ko"
if [[ ! -f "$BUILT_KO" ]]; then
    echo "[fatal] build did not produce ${BUILT_KO}" >&2
    exit 1
fi

# Sanity-check that the produced module's srcversion differs from the
# in-tree one — otherwise the patch did not actually change the binary.
SV_BUILT=$( modinfo -F srcversion "$BUILT_KO" 2>/dev/null || true)
SV_INTREE=$(modinfo -F srcversion "$KO_INTREE" 2>/dev/null || true)
if [[ -n "$SV_INTREE" && "$SV_BUILT" == "$SV_INTREE" ]]; then
    echo "[fatal] built srcversion == in-tree srcversion (${SV_BUILT})" >&2
    echo "        patch did not change the compiled output — bail out rather" >&2
    echo "        than install an indistinguishable module." >&2
    exit 1
fi

if [[ ! -f "$BACKUP" && -f "$KO_INTREE" ]]; then
    echo "[*] backing up in-tree ${KO_INTREE} → ${BACKUP}"
    cp -a "$KO_INTREE" "$BACKUP"
fi

echo "[*] installing patched module to ${KO_OVERLAY}"
install -d -m 0755 "$UPDATES_DIR"
distro_module_sign "$BUILT_KO" "$KVER" || { echo "[fatal] signing the module failed" >&2; exit 1; }
zstd -19 -q --force "$BUILT_KO" -o "${WORK}/${KO_NAME}"
install -m 0644 "${WORK}/${KO_NAME}" "$KO_OVERLAY"
depmod -a "$KVER"

# Verify the overlay is what modinfo now resolves to. Compare the files, not the
# two strings: on a usr-merged system /lib is a symlink to /usr/lib, depmod
# reports the /lib spelling, and a textual comparison then warned about a
# correct install on every run.
RESOLVED=$(modinfo -F filename snd_sof 2>/dev/null || true)
if ! [[ -e "$RESOLVED" && -e "$KO_OVERLAY" && "$RESOLVED" -ef "$KO_OVERLAY" ]]; then
    echo "[warn] modinfo resolves snd_sof to:"
    echo "       ${RESOLVED:-nothing}"
    echo "       (expected $KO_OVERLAY). depmod ordering may need investigation."
fi

cat <<EOF

════════════════════════════════════════════════════════════════════
  SOF IPC4 copier-payload refresh installed.

  Overlay: $KO_OVERLAY
  Backup of original in-tree module: $BACKUP
  (delete the overlay file and re-run depmod to revert.)

  After REBOOT the patched snd-sof.ko will load instead of the in-tree
  one. The fix prevents the stale-DMA-channel race that crashes the
  Panther Lake DSP firmware on suspend/resume — see
  thesofproject/sof#10700 for the upstream tracking issue.

  Direct repro from the upstream issue (to validate the fix):
    open pavucontrol, leave it running, then
    \$ sudo rtcwake -m mem -s 5
    repeat 2-3 times. With this fix in place, the DSP must NOT panic
    (check journalctl -k -b | grep -i 'sof' for clean output).

  The reliable metric for "is the patch doing anything visible" is the
  count of firmware-reported panics in the journal:
    \$ journalctl -b 0 -k | grep -c 'DSP panic'
  This should stay at 0. The CRASHED count in
  /var/log/honor-fnf7-watch.log is NOT a reliable indicator — it
  conflates firmware panics with benign runtime PM D3 transitions.

  Re-run this script after every kernel update to keep the fix.
════════════════════════════════════════════════════════════════════
EOF
