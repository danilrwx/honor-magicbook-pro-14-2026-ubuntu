#!/usr/bin/env bash
# Does the work that cannot run inside a pacman transaction.
#
# Started by /usr/local/lib/honor/rebuild.sh through systemd-run, so it
# runs outside the transaction with a normal environment: the pacman database
# is unlocked (needed by the fingerprint package build) and the network is
# reachable (needed by every installer, which fetches its sources from the
# matching kernel tag).
#
# Reads: REPO, LOG, and either KVERS (modules) or BUILD_USER (fingerprint).

set -uo pipefail

REPO="${REPO:?}"
LOG="${LOG:-/var/log/honor-autorebuild.log}"
mode="${1:-}"

w() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

wait_for_pacman() {
    local i
    for ((i = 0; i < 120; i++)); do
        [[ -e /var/lib/pacman/db.lck ]] || return 0
        sleep 5
    done
    w "pacman database still locked after 10 minutes, giving up"
    return 1
}

# Debian and Ubuntu: the hook fires from inside the apt transaction, and the
# xe rebuild installs linux-source through apt itself.
wait_for_apt() {
    local i
    command -v fuser >/dev/null || return 0
    for ((i = 0; i < 120; i++)); do
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || return 0
        sleep 5
    done
    w "dpkg still locked after 10 minutes, giving up"
    return 1
}

case "$mode" in
modules)
    w "=== deferred module rebuild: ${KVERS:-none} ==="
    wait_for_pacman || exit 0
    wait_for_apt || exit 0
    for k in ${KVERS:-}; do
        if [[ ! -e "/usr/lib/modules/${k}/build/Makefile" ]]; then
            w "${k}: no kernel headers, skipped"
            continue
        fi
        # xe.ko is one module shared by several patches, and the overlay is
        # per kernel version, so a kernel update leaves the new kernel running
        # the stock module with every one of them gone. It is rebuilt only if
        # it was installed: the stamp records which patches went in, and
        # XE_ONLY reproduces exactly that set rather than whatever the profile
        # would ask for today. The first installer does the build; the rest see
        # the stamp and return.
        if [[ -r /var/lib/honor/xe-module.stamp ]]; then
            xe_want=$(sed -n 's/^wanted=//p' /var/lib/honor/xe-module.stamp)
            for fix in ${xe_want:-}; do
                [[ -x "${REPO}/patch/${fix}/install.sh" || -r "${REPO}/patch/${fix}/install.sh" ]] || continue
                rc=0
                XE_ONLY="$xe_want" KVER="$k" bash "${REPO}/patch/${fix}/install.sh" >>"$LOG" 2>&1 || rc=$?
                case "$rc" in
                    0) w "${fix} ${k}: ok" ;;
                    3) w "${fix} ${k}: not applicable to this kernel, skipped" ;;
                    *) w "${fix} ${k}: FAILED (rc=${rc}), run: sudo XE_ONLY='${xe_want}' KVER=${k} bash ${REPO}/patch/${fix}/install.sh" ;;
                esac
            done
        else
            w "no /var/lib/honor/xe-module.stamp, so no xe.ko overlay to rebuild"
        fi

        # hotkeys builds a module overlay too, so a kernel update drops it
        # just like the two audio ones.
        for fix in headset-mic sof-audio hotkeys; do
            rc=0
            KVER="$k" bash "${REPO}/patch/${fix}/install.sh" >>"$LOG" 2>&1 || rc=$?
            case "$rc" in
                0) w "${fix} ${k}: ok" ;;
                3) w "${fix} ${k}: not applicable to this kernel, skipped" ;;
                *) w "${fix} ${k}: FAILED (rc=${rc}), run: sudo KVER=${k} bash ${REPO}/patch/${fix}/install.sh" ;;
            esac
        done
    done
    w "=== deferred module rebuild done ==="
    ;;

fingerprint)
    w "=== deferred fingerprint rebuild ==="
    wait_for_pacman || exit 0
    rc=0
    SUDO_USER="${BUILD_USER:-root}" bash "${REPO}/patch/fingerprint/install.sh" >>"$LOG" 2>&1 || rc=$?
    if (( rc == 0 )); then
        w "fingerprint: ok"
    else
        w "fingerprint: FAILED (rc=${rc}), run: sudo bash ${REPO}/patch/fingerprint/install.sh"
    fi
    ;;

*)
    w "deferred: unknown mode '${mode}'"
    ;;
esac

exit 0
