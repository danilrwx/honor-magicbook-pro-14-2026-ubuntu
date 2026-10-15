# shellcheck shell=bash
#
# PROFILE, PROFILE_BOARD and PROFILE_BOARD_MATCH are this file's interface. Every
# installer sources it and reads them, which shellcheck cannot see from here.
# shellcheck disable=SC2034
#
# Device profile parser and the trust tiers that decide what an installer is
# allowed to do. Source this, do not execute it.
#
# A profile is strict key=value, in a base block followed by one or more board
# sections. It is PARSED, never sourced: profiles arrive through issues from
# people we do not know, and `source`-ing one would be arbitrary code execution
# as root.
#
# Comments are whole lines beginning with '#'. There are no inline comments, so
# a '#' inside a value is just a character.
#
# --- why there are sections ---------------------------------------------------
#
# HONOR sells one product code as several machines. ZQC-P is board M1010 with a
# Core Ultra X9 388H here, and board M1050 with a Core Ultra 5 338H in the
# report on issue #1. Same sys_vendor, same product_name, different silicon.
#
# The old format had one flat block per product, so `status=verified` and every
# constant measured on M1010 applied to every ZQC-P that ever boots this
# repository, M1050 included. board_version was recorded but only ever consulted
# to break a tie between two candidate files, which on a product with a single
# file never happened.
#
# So the unit of trust is the board revision, and that is what a section is.
# Everything that can differ between revisions lives in one, including status.
# The base block holds only what identifies the product itself.
#
#   model=ZQC-P
#   dmi_vendor=HONOR
#   dmi_product=ZQC-P
#
#   [board M1010]
#   status=verified
#   platform=pantherlake
#   fixes=...
#
#   [board M1050]
#   status=reported
#   ...
#
# A section header may name several revisions that are the same machine,
# `[board M1110 M1120]`, and `[board *]` is an explicit catch-all for revisions
# of this product that have no section of their own.
#
# A machine whose board_version matches no section and where the profile has no
# `[board *]` gets the base block with status forced down to `probed`. It is
# never refused outright, because the tier A fixes derive their own inputs and
# are worth having, and it never inherits `verified`, because nobody measured
# that revision. See profile_select_board.

# --- schema -------------------------------------------------------------------
PROFILE_KEYS=(
    # identity and trust
    model name year platform dgpu
    status origin verified_kernel verified_bios verified_distro
    # There is deliberately no dmi_board_version key: the section header is the
    # board revision, and a second place to write it down is a second place for
    # it to be wrong.
    dmi_vendor dmi_product dmi_sku dmi_board
    # hardware inventory: facts, all of them fillable from a hardware dump, and
    # all of them confirmable on a bus by the installer that reads them.
    touchscreen_hid touchpad_hid audio_ssid fingerprint_usb
    panel backlight_max camera_usb
    cpu
    # There are deliberately no fix parameters here. A backlight floor, the EC
    # tachometer offsets, the charge pairs an EC arms and the alc269.c fixup a
    # codec needs are not descriptions of the machine, they are what one fix has
    # to do on it, and they live with that fix in
    # patch/<fix>/<model>/<board>/recipe.conf. Keeping them there is what makes
    # preparing a fix for a board a matter of writing one file rather than
    # editing a file that every other board also reads.
    # which fixes apply
    fixes
)

# The base block holds these and nothing else: what identifies the product, and
# what selects the file in the first place. A section that set dmi_product would
# describe a different product and belongs in its own file.
#
# The converse is the point of the format. Every other key is a reading, a
# measurement or a decision about one board revision, so it has to be claimed by
# a section. That is enforced, not merely documented: allowing a hardware id or
# a status in the base block is what let a value measured on M1010 apply to
# every ZQC-P that ever boots this repository.
PROFILE_BASE_ONLY_KEYS=(model name year dmi_vendor dmi_product)

# Bounds, because a profile is untrusted input that arrives in a pull request.
# Nothing here is a security boundary on its own, the character class below is
# that, but a file with three thousand sections took a minute to reject and said
# nothing while it did: the duplicate-revision check compares every header
# against every earlier one, so the cost is quadratic. The largest real profile
# has five sections and the longest real value is under a hundred characters, so
# these caps are far above anything legitimate and turn a hang into a sentence.
PROFILE_MAX_SECTIONS=64
PROFILE_MAX_VALUE=512

# --- trust tiers --------------------------------------------------------------
# A  Derives its inputs from the running machine, or matches on a device id and
#    simply finds nothing on hardware it was not meant for. Safe to offer on a
#    profile nobody has verified.
# B  Carries model specific constants. Getting them wrong misconfigures real
#    hardware, so these need status=verified.
# C  Installs a binary taken from one machine's firmware, with no way to check
#    at run time that it belongs there.
#
# oled-backlight looks like tier A because it reads the VBT off the running
# machine, but backlight_min was measured on one panel. Until somebody measures
# it on theirs it is tier B.
#
# acpi-override is tier A, which needs explaining because it installs firmware.
# It does not decide from the profile. Before installing anything it finds the
# live table by its OEM table id and compares the md5 against the stock table
# this repository carries, and refuses unless they are equal. That is a direct
# measurement of the running machine and it is strictly stronger than asking
# which model this is: the I2C_DEVT table turns out to be byte-identical between
# ZQC-P and XWC-P, so the model was never the thing that mattered. A profile
# still has to list the fix for it to run at all.
# -g because this file may be sourced from inside a function, where a plain
# `declare` would make the array local and it would vanish on return.
declare -gA FIX_TIER=(
    [micmute]=A
    [touchpad-edge]=A
    [fingerprint]=A
    [cdclk-ptl]=A
    [psr-band]=A
    [edp-dsc]=A
    [auto-rebuild]=A
    [headset-mic]=B
    [sof-audio]=B
    [battery]=B
    [hotkeys]=B
    [hotkey-actions]=A
    [dmic-array]=B
    [fan]=B
    [oled-backlight]=B
    [acpi-override]=A
)

# The order a `fixes=` list is written in.
#
# It is the order apply_patch.sh runs them, so reading a profile and reading a
# run put the same things in the same place, and two sections of one file can be
# compared line by line instead of by searching. Left to itself the order
# drifted: the two ZQC-P sections listed the same kind of thing in two different
# sequences and neither was wrong, which is exactly the sort of difference that
# hides a real one.
#
# Not a second copy of FIX_TIER: tools/selftest.sh checks that the two name the
# same set of fixes, so a fix added to one and forgotten in the other is caught
# rather than silently sorted last.
declare -ga FIX_ORDER=(
    acpi-override
    psr-band
    oled-backlight
    cdclk-ptl
    edp-dsc
    headset-mic
    sof-audio
    micmute
    touchpad-edge
    fan
    fingerprint
    battery
    hotkeys
    hotkey-actions
    dmic-array
    auto-rebuild
)

# fix_order_sorted <fix> [<fix> ...] -> the same fixes in FIX_ORDER order
#
# For writing a profile, and for saying in an error message what the line should
# have looked like.
fix_order_sorted() {
    local want=" $* " f out=()
    for f in "${FIX_ORDER[@]}"; do
        [[ "$want" == *" $f "* ]] && out+=("$f")
    done
    printf '%s' "${out[*]}"
}

# The parsed file: a base block, and PROFILE_SECT_N sections. Bash has no nested
# arrays, so section values live in one associative array under "<index>|<key>".
declare -gA PROFILE=()
declare -gA PROFILE_BASE=()
declare -gA PROFILE_SECT=()
declare -ga PROFILE_SECT_BOARDS=()
PROFILE_SECT_N=0
PROFILE_FILE=""

# Set by profile_select_board.
PROFILE_BOARD=""
# exact     the machine's board_version is named by a section
# wildcard  no section names it, but the profile has [board *]
# none      neither, so status was forced down to probed
# unselected  profile_load ran but nobody has chosen a board yet
PROFILE_BOARD_MATCH="unselected"

_profile_err() { printf 'profile: %s\n' "$*" >&2; }

_profile_in_list() { # <needle> <haystack...>
    local needle="$1" item
    shift
    for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

# _profile_words <array-name> <string>
# Splits <string> on whitespace into the named array, WITHOUT filename expansion.
#
# One of the board revisions this has to split is the literal `*`. Both
# `for b in $list` and `for b in $(some_function)` would expand that into the
# contents of the working directory, so the catch-all section would never be
# found and every unknown revision would silently fall through to the
# no-section path. read -ra does not expand paths, and the result never passes
# back through an unquoted expansion.
_profile_words() {
    local -n _dest="$1"
    _dest=()
    read -ra _dest <<< "$2"
}

# profile_load <file>  -> 0 on success, 1 on a malformed file
#
# On success the base block is in PROFILE_BASE and the sections in PROFILE_SECT.
# PROFILE itself holds the base block only, so that a caller which just wants
# the model name does not have to pick a board first. Anything that depends on
# what is true of the machine in front of you must call profile_select_board.
profile_load() {
    local file="$1" lineno=0 line key val sect=-1 boards k
    local -A _seen_keys=()
    [[ -r "$file" ]] || { _profile_err "cannot read $file"; return 1; }

    PROFILE=()
    PROFILE_BASE=()
    PROFILE_SECT=()
    PROFILE_SECT_BOARDS=()
    PROFILE_SECT_N=0
    PROFILE_FILE="$file"
    PROFILE_BOARD=""
    PROFILE_BOARD_MATCH="unselected"

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))

        # trim both ends
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        if [[ "$line" == \#* ]]; then
            # A device profile is data. Everything that needs explaining belongs
            # in docs/hardware/<model>.md, so that a diff of a profile stays
            # readable and one fact does not end up recorded in two places that
            # then drift apart. TEMPLATE.conf is the exception: it exists to be
            # read, and its comments are the field reference.
            if [[ "$(basename "$file")" != "TEMPLATE.conf" && -z "${PROFILE_QUIET:-}" ]]; then
                printf 'profile: %s:%s: comment in a device profile.\n' "$file" "$lineno" >&2
                printf '    Profiles carry data. The explanation belongs in docs/hardware/.\n' >&2
            fi
            continue
        fi
        [[ -z "$line" ]] && continue

        # --- section header ---------------------------------------------------
        if [[ "$line" == \[* ]]; then
            if [[ ! "$line" =~ ^\[board[[:space:]]+([^]]+)\]$ ]]; then
                _profile_err "$file:$lineno: not a section header: $line
    The only section this format has is [board <revision> ...], for example
    [board M1010], [board M1110 M1120], or [board *] as a catch-all."
                return 1
            fi
            boards="${BASH_REMATCH[1]}"
            boards="${boards#"${boards%%[![:space:]]*}"}"
            boards="${boards%"${boards##*[![:space:]]}"}"
            # Validated one token at a time. A regex holding a literal space
            # cannot be written unquoted on the right of =~: bash word-splits it
            # and the bracket expression falls apart.
            local tok tok_re='^([A-Za-z0-9][A-Za-z0-9_.-]*|\*)$'
            local -a _new_boards=()
            _profile_words _new_boards "$boards"
            for tok in "${_new_boards[@]}"; do
                if [[ ! "$tok" =~ $tok_re ]]; then
                    _profile_err "$file:$lineno: bad board revision '$tok'.
    A revision looks like M1010, or * for the catch-all section."
                    return 1
                fi
            done
            # A revision must not be claimed by two sections in one file: which
            # one wins would then depend on the order they happen to appear in.
            local existing b nb
            local -a _old_boards=()
            for existing in "${PROFILE_SECT_BOARDS[@]}"; do
                _profile_words _old_boards "$existing"
                for b in "${_old_boards[@]}"; do
                    for nb in "${_new_boards[@]}"; do
                        if [[ "$b" == "$nb" ]]; then
                            _profile_err "$file:$lineno: board revision '$b' is already claimed by an earlier section."
                            return 1
                        fi
                    done
                done
            done
            if (( PROFILE_SECT_N >= PROFILE_MAX_SECTIONS )); then
                _profile_err "$file:$lineno: more than ${PROFILE_MAX_SECTIONS} board sections.
    A product does not have that many revisions; something has gone wrong with
    this file."
                return 1
            fi
            PROFILE_SECT_BOARDS+=("$boards")
            sect=$PROFILE_SECT_N
            PROFILE_SECT_N=$((PROFILE_SECT_N + 1))
            continue
        fi

        if [[ "$line" != *=* ]]; then
            _profile_err "$file:$lineno: not a key=value line: $line"
            return 1
        fi

        key="${line%%=*}"
        val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"

        if [[ ! "$key" =~ ^[a-z][a-z0-9_]*$ ]]; then
            _profile_err "$file:$lineno: bad key name '$key'"
            return 1
        fi

        if ! _profile_in_list "$key" "${PROFILE_KEYS[@]}"; then
            _profile_err "$file:$lineno: unknown key '$key'.
    A typo here would silently drop a value, so it is an error, not a warning.
    Valid keys are listed in devices/TEMPLATE.conf."
            return 1
        fi

        if (( ${#val} > PROFILE_MAX_VALUE )); then
            _profile_err "$file:$lineno: value of '$key' is ${#val} characters.
    Nothing here is longer than a sentence; the limit is ${PROFILE_MAX_VALUE}."
            return 1
        fi

        # Values end up as arguments to installers that run as root. A profile
        # is never sourced, so this cannot execute on its own, but keeping the
        # charset boring means a value can never grow teeth downstream either.
        if [[ ! "$val" =~ ^[A-Za-z0-9\ _.,:+/()-]*$ ]]; then
            _profile_err "$file:$lineno: value of '$key' contains characters that are not allowed here.
    Permitted: letters, digits, space, and _ . , : + / ( ) -"
            return 1
        fi

        # The same key twice takes the last value and says nothing, so a
        # hand-edited profile can carry panel=oled and panel=lcd and behave as
        # the second one. Same shape as a fix name listed twice: invisible at
        # run time, wrong on the page.
        if [[ -n "${_seen_keys[${sect}|${key}]:-}" ]]; then
            _profile_err "$file:$lineno: '$key' is set twice in the same block."
            return 1
        fi
        _seen_keys["${sect}|${key}"]=1

        if (( sect < 0 )); then
            if ! _profile_in_list "$key" "${PROFILE_BASE_ONLY_KEYS[@]}"; then
                _profile_err "$file:$lineno: '$key' belongs to a board section, not the base block.
    The base block holds only what identifies the product: ${PROFILE_BASE_ONLY_KEYS[*]}.
    Everything else is a statement about one board revision. HONOR ships one
    product code as several machines, so a value in the base block would apply
    a reading taken on one of them to all of them, which is the mistake this
    format exists to prevent. Move it under a [board ...] section; if it really
    is true of every revision, say so by putting it in [board *]."
                return 1
            fi
            PROFILE_BASE["$key"]="$val"
        else
            if _profile_in_list "$key" "${PROFILE_BASE_ONLY_KEYS[@]}"; then
                _profile_err "$file:$lineno: '$key' identifies the product and cannot vary by board.
    It is what selects this file; a section that changed it would describe a
    different product and belongs in its own file."
                return 1
            fi
            PROFILE_SECT["${sect}|${key}"]="$val"
        fi
    done < "$file"

    for k in "${!PROFILE_BASE[@]}"; do PROFILE["$k"]="${PROFILE_BASE[$k]}"; done

    profile_validate || return 1
}

# profile_validate -> 0 if the loaded profile makes sense
profile_validate() {
    local f i status
    for f in model dmi_vendor dmi_product; do
        if [[ -z "${PROFILE_BASE[$f]:-}" ]]; then
            _profile_err "${PROFILE_FILE}: '$f' is required in the base block and is empty"
            return 1
        fi
    done

    if (( PROFILE_SECT_N == 0 )); then
        _profile_err "${PROFILE_FILE}: no [board ...] section.
    Trust is per board revision, so a profile has to say which revision it
    describes. If you know of only one and cannot name it, use [board *].
    devices/TEMPLATE.conf has the shape."
        return 1
    fi

    for (( i = 0; i < PROFILE_SECT_N; i++ )); do
        status="${PROFILE_SECT[${i}|status]:-}"
        if [[ -z "$status" ]]; then
            _profile_err "${PROFILE_FILE}: [board ${PROFILE_SECT_BOARDS[$i]}] has no status.
    Every section has to say how much it is trusted; there is no default."
            return 1
        fi
        case "$status" in
            verified|reported|probed|draft) ;;
            *) _profile_err "${PROFILE_FILE}: [board ${PROFILE_SECT_BOARDS[$i]}]: status must be verified, reported, probed or draft, got '$status'"
               return 1 ;;
        esac

        case "$(_profile_effective "$i" platform unknown)" in
            pantherlake|arrowlake|meteorlake|raptorlake|amd|unknown) ;;
            *) _profile_err "${PROFILE_FILE}: [board ${PROFILE_SECT_BOARDS[$i]}]: unrecognised platform '$(_profile_effective "$i" platform unknown)'"
               return 1 ;;
        esac

        case "$(_profile_effective "$i" dgpu unknown)" in
            none|nvidia|unknown) ;;
            *) _profile_err "${PROFILE_FILE}: [board ${PROFILE_SECT_BOARDS[$i]}]: dgpu must be none, nvidia or unknown, got '$(_profile_effective "$i" dgpu unknown)'"
               return 1 ;;
        esac

        local fix
        local -a seen_fixes=()
        for fix in $(_profile_effective "$i" fixes ""); do
            if [[ -z "${FIX_TIER[$fix]:-}" ]]; then
                _profile_err "${PROFILE_FILE}: [board ${PROFILE_SECT_BOARDS[$i]}] lists fix '$fix', which has no trust tier.
    Add it to FIX_TIER in lib/profile.sh before listing it here."
                return 1
            fi
            # A name twice does nothing at run time, which is exactly why it
            # survives review: profile_lists_fix matches the first one and the
            # second is invisible. It is still a mistake in a hand-edited list,
            # and the honest thing is to say so rather than tidy it silently.
            if _profile_in_list "$fix" "${seen_fixes[@]}"; then
                _profile_err "${PROFILE_FILE}: [board ${PROFILE_SECT_BOARDS[$i]}] lists '$fix' twice."
                return 1
            fi
            seen_fixes+=("$fix")
        done
    done
}

# _profile_effective <section-index> <key> <default>
# The value a section actually has: its own, else the base block's, else the
# default. This is the inheritance rule, in one place.
_profile_effective() {
    local i="$1" key="$2" def="${3:-}" v
    v="${PROFILE_SECT[${i}|${key}]:-}"
    [[ -n "$v" ]] || v="${PROFILE_BASE[$key]:-}"
    [[ -n "$v" ]] || v="$def"
    printf '%s' "$v"
}

# profile_sections -> prints one line per section: "<index> <boards> <status>"
profile_sections() {
    local i
    for (( i = 0; i < PROFILE_SECT_N; i++ )); do
        printf '%s %s %s\n' "$i" "${PROFILE_SECT_BOARDS[$i]}" "${PROFILE_SECT[${i}|status]:-}"
    done
}

# profile_offers <key> <value> -> 0 if the base block or ANY section of the
# loaded file carries that value.
#
# Used while narrowing between candidate FILES, before a board has been picked.
# A file is still in the running if any revision it describes could be this
# machine; which revision it actually is gets settled afterwards.
profile_offers() {
    local key="$1" want="$2" i v pv
    local -a _hdr=()
    # The board revision is the section header, not a key.
    if [[ "$key" == dmi_board_version ]]; then
        for (( i = 0; i < PROFILE_SECT_N; i++ )); do
            _profile_words _hdr "${PROFILE_SECT_BOARDS[$i]}"
            for pv in "${_hdr[@]}"; do
                [[ "$pv" == "$want" || "$pv" == "*" ]] && return 0
            done
        done
        return 1
    fi
    for (( i = 0; i < PROFILE_SECT_N; i++ )); do
        v="$(_profile_effective "$i" "$key" unknown)"
        for pv in $v; do
            [[ "$pv" == "$want" ]] && return 0
        done
    done
    return 1
}

# profile_select_board <board_version>
#
# Materialises PROFILE as the base block overlaid with the section that
# describes this machine, and records how confident that choice is in
# PROFILE_BOARD_MATCH. Always succeeds: an unrecognised revision is a reason to
# trust the profile less, not a reason to refuse to run.
profile_select_board() {
    local bv="$1" i b chosen=-1 wildcard=-1 k
    local -a _hdr=()
    PROFILE_BOARD="$bv"

    for (( i = 0; i < PROFILE_SECT_N; i++ )); do
        _profile_words _hdr "${PROFILE_SECT_BOARDS[$i]}"
        for b in "${_hdr[@]}"; do
            if [[ "$b" == "*" ]]; then
                wildcard=$i
            elif [[ -n "$bv" && "$b" == "$bv" ]]; then
                chosen=$i
            fi
        done
        (( chosen >= 0 )) && break
    done

    PROFILE=()
    for k in "${!PROFILE_BASE[@]}"; do PROFILE["$k"]="${PROFILE_BASE[$k]}"; done

    if (( chosen >= 0 )); then
        PROFILE_BOARD_MATCH="exact"
    elif (( wildcard >= 0 )); then
        chosen=$wildcard
        PROFILE_BOARD_MATCH="wildcard"
    else
        # Nothing describes this revision. Keep the product-level facts, drop
        # the trust: the constants in every section were measured somewhere
        # else. probed is the weakest status that still means "this is a real
        # machine", and it unlocks tier A and nothing more.
        PROFILE_BOARD_MATCH="none"
        PROFILE[status]="probed"
        PROFILE[origin]="board revision ${bv:-unreported} is not described in $(basename "$PROFILE_FILE")"
        return 0
    fi

    for k in "${PROFILE_KEYS[@]}"; do
        [[ -n "${PROFILE_SECT[${chosen}|${k}]:-}" ]] && PROFILE["$k"]="${PROFILE_SECT[${chosen}|${k}]}"
    done
    # The board revision is not copied into PROFILE. PROFILE_BOARD already holds
    # what the machine reports, and the section header can be a list or `*`, so
    # a key here would be a second, sometimes wrong, answer to the same question.
    return 0
}

# profile_get <key> -> value, empty if unset
profile_get() { printf '%s' "${PROFILE[$1]:-}"; }

# profile_has <key> -> 0 if the key carries a real value
profile_has() {
    local v="${PROFILE[$1]:-}"
    [[ -n "$v" && "$v" != unknown ]]
}

# profile_lists_fix <fix> -> 0 if this board declares the fix as applicable
profile_lists_fix() {
    local fix want="$1"
    for fix in ${PROFILE[fixes]:-}; do
        [[ "$fix" == "$want" ]] && return 0
    done
    return 1
}

# profile_all_fixes -> every fix named by any section of the loaded file.
# For checks that ask "is this fix name real", where the board does not matter.
profile_all_fixes() {
    local i fix
    for (( i = 0; i < PROFILE_SECT_N; i++ )); do
        for fix in $(_profile_effective "$i" fixes ""); do printf '%s\n' "$fix"; done
    done | sort -u
}

# fix_allowed <fix> -> 0 if it may run against the selected board.
#
# Everything is allowed on a verified board. On reported, probed and draft only
# tier A, which by construction cannot carry another machine's constants.
#
# probed is the weakest of the three that carry real data: the ids came out of
# a hardware probe database, so they are genuine readings off a real machine,
# but nobody has run a single fix against one. It is deliberately no more
# permissive than draft.
fix_allowed() {
    local tier="${FIX_TIER[$1]:-C}"
    [[ "${PROFILE[status]:-draft}" == verified ]] && return 0
    [[ "$tier" == A ]]
}
