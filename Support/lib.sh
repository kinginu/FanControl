# shellcheck shell=bash
# Generic shell library of the FanControl support scripts (sourced, never executed).
#
#   Support/lib.sh                    this file: logging, die, dry-run runner, CLI parsing, root
#                                     check, temporary files, plist / bundle / code-signing helpers
#   Support/identifiers.sh            FanControl identifier rules (mirrors FanControlIdentifiers.swift)
#   Support/manual-install/common.sh  manual-install paths, client requirement, launchd helpers
#
# Callers run under `set -euo pipefail` with /bin/bash (3.2): no namerefs, no mapfile, and an empty
# array must be expanded as ${a[@]+"${a[@]}"}. Functions that fail call die(); when called inside
# $(...), die() only ends the subshell, so always assign such results on their own line
# (`x="$(f)"`, which propagates the status under `set -e`), never inside `local x="$(f)"`.

[[ -z "${_FC_LIB_LOADED:-}" ]] || return 0
_FC_LIB_LOADED=1

FC_PROG="$(basename "$0")"

# --- Logging -------------------------------------------------------------------------------
# info on stdout (progress), warn and die on stderr.
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# usage_error <message>: bad command line (exit 64, EX_USAGE). The caller defines usage().
usage_error() {
    printf '%s: %s\n' "$FC_PROG" "$*" >&2
    printf "Try '%s --help'.\n" "$FC_PROG" >&2
    exit 64
}

# --- Temporary files -----------------------------------------------------------------------
# One private (0700) directory per run, removed on exit. fc_tmpfile only computes a path, so it
# is safe inside $(...). Scripts that source this library must not install their own EXIT trap.
# As root, always under the sticky /private/tmp: a $TMPDIR kept through sudo would be a directory
# the invoking user owns, where they could swap the generated plist before root installs it.
if [[ "${EUID}" == 0 ]]; then
    _FC_TMPBASE="/private/tmp"
else
    _FC_TMPBASE="${TMPDIR:-/tmp}"
    _FC_TMPBASE="${_FC_TMPBASE%/}"
fi
_FC_TMPDIR="$(mktemp -d "${_FC_TMPBASE}/fanfi.XXXXXX")"
trap 'rm -rf "${_FC_TMPDIR}"' EXIT   # the script's exit status is preserved

# fc_tmpfile <name>: path of a fresh file name inside the run's temporary directory
fc_tmpfile() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "fc_tmpfile: bad name '$1'"
    printf '%s/%s\n' "$_FC_TMPDIR" "$1"
}

# --- Command line --------------------------------------------------------------------------
# parse_cli "$@": the options shared by every script.
#   -h, --help              usage() on stdout, exit 0
#   -n, --dry-run           DRY_RUN=1: change nothing, print the commands instead (run())
#   --app <path>, --app=…   APP=<path> (one positional argument is also accepted as the app,
#                           see take_app_argument)
#   --                      end of options
# Other options go to the caller's handle_option <option> (return 0 if consumed), if defined.
# Positional arguments are collected in FC_ARGS (FC_NARGS = count).
DRY_RUN=0
APP=""
FC_ARGS=()
FC_NARGS=0
FC_CMDLINE=""
parse_cli() {
    FC_CMDLINE="$0$(printf ' %q' "$@")"
    while (( $# > 0 )); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            --app)
                (( $# >= 2 )) || usage_error "--app needs a path"
                _fc_set_app "$2"
                shift ;;
            --app=*) _fc_set_app "${1#--app=}" ;;
            --) shift; FC_ARGS+=("$@"); break ;;
            -*)
                if ! declare -F handle_option >/dev/null || ! handle_option "$1"; then
                    usage_error "unknown option: $1"
                fi ;;
            *) FC_ARGS+=("$1") ;;
        esac
        shift
    done
    FC_NARGS=${#FC_ARGS[@]}
}

_fc_set_app() {
    [[ -n "$1" ]] || usage_error "--app needs a path"
    [[ -z "$APP" ]] || usage_error "more than one app given"
    APP="$1"
}

# take_app_argument [required]: moves a single positional argument into APP (legacy form
# `script.sh /path/to/App.app`). Fails on extra arguments, or with "required" when no app is given.
take_app_argument() {
    if (( FC_NARGS == 1 )); then
        _fc_set_app "${FC_ARGS[0]}"
    elif (( FC_NARGS > 1 )); then
        usage_error "unexpected arguments: ${FC_ARGS[*]}"
    fi
    FC_ARGS=()
    FC_NARGS=0
    if [[ "${1:-}" == required && -z "$APP" ]]; then
        usage_error "no app given"
    fi
}

# run <command…>: runs the command, or prints it (shell-quoted) with --dry-run
run() {
    if (( DRY_RUN )); then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# require_root: dies unless running as root (skipped with --dry-run)
require_root() {
    (( DRY_RUN )) && return 0
    [[ "${EUID}" == 0 ]] || die "must be run as root: sudo ${FC_CMDLINE:-$0}   (or --dry-run to preview without root)"
}

# --- Property lists ------------------------------------------------------------------------
# plist_string <plist-file> <key-path>: string value, empty if absent or not a string
plist_string() {
    plutil -extract "$2" raw -expect string -o - "$1" 2>/dev/null || true
}

# require_plist <file>: dies unless <file> is a readable property list (XML, binary or OpenStep)
require_plist() {
    [[ -r "$1" ]] || die "cannot read $1"
    plutil -lint -s "$1" >/dev/null 2>&1 || die "not a property list: $1"
}

# plist_canonical <plist-file>: the plist as XML with sorted keys and no comments, for
# comparing two plists by content rather than by formatting
plist_canonical() {
    plutil -convert xml1 -o - "$1" 2>/dev/null || die "not a property list: $1"
}

# embedded_info_plist <mach-o> <out-file>: writes the __TEXT,__info_plist section of a bare
# executable (what Bundle.main.infoDictionary returns in it) to <out-file> as a property list.
# `launchctl plist` prints it in OpenStep format with a trailing ';' that plutil rejects.
embedded_info_plist() {
    local out
    [[ -f "$1" ]] || die "not a file: $1"
    out="$(launchctl plist __TEXT,__info_plist "$1" 2>&1)" || true
    [[ "$out" == \{* ]] || die "no embedded __TEXT,__info_plist in $1 (${out:-no output})"
    printf '%s\n' "$out" | sed '$ s/};[[:space:]]*$/}/' > "$2"
    plutil -lint -s "$2" >/dev/null 2>&1 || die "cannot parse the embedded Info.plist of $1"
}

# --- App bundles ---------------------------------------------------------------------------
# resolve_app <path>: absolute physical path of an app bundle, after checking that it has a
# property-list Contents/Info.plist with CFBundleIdentifier and CFBundleExecutable, and that the
# main executable exists.
resolve_app() {
    local path="$1" abs info exe
    [[ -n "$path" ]] || die "no app given"
    [[ -d "$path" ]] || die "not a directory: $path"
    abs="$(cd "$path" && pwd -P)" || die "cannot resolve $path"
    info="$abs/Contents/Info.plist"
    [[ -f "$info" ]] || die "not an app bundle (no Contents/Info.plist): $abs"
    require_plist "$info"
    [[ -n "$(plist_string "$info" CFBundleIdentifier)" ]] || die "$info has no CFBundleIdentifier"
    exe="$(plist_string "$info" CFBundleExecutable)"
    [[ -n "$exe" ]] || die "$info has no CFBundleExecutable"
    [[ -f "$abs/Contents/MacOS/$exe" ]] || die "main executable not found: $abs/Contents/MacOS/$exe"
    printf '%s\n' "$abs"
}

# bundle_identifier <App.app>: CFBundleIdentifier of the app's Info.plist (empty if none)
bundle_identifier() {
    plist_string "$1/Contents/Info.plist" CFBundleIdentifier
}

# --- Code signing --------------------------------------------------------------------------
# is_cdhash <value>: 40 lower-case hex digits (SHA-256 cdhash truncated, as codesign prints it)
is_cdhash() {
    local LC_ALL=C
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# signing_identifier <path>: the "Identifier=" of the code signature, empty if unsigned/unreadable
signing_identifier() {
    { codesign -dvvv "$1" 2>&1 || true; } | awk '/^Identifier=/ { print substr($0, 12); exit }'
}

# cdhash_of <path-to-code>: cdhash of the slice this Mac runs (codesign -dvvv "CDHash="). For a
# bundle, its main executable decides the architecture. Thin binaries must match the host
# architecture; universal ones are read with --arch <host> (fails without a host slice).
cdhash_of() {
    local code="$1" exe="$1" archs host out count hash name
    if [[ -d "$code" ]]; then
        name="$(plist_string "$code/Contents/Info.plist" CFBundleExecutable)"
        [[ -n "$name" ]] || die "cannot read CFBundleExecutable from $code/Contents/Info.plist"
        exe="$code/Contents/MacOS/$name"
    fi
    [[ -f "$exe" ]] || die "executable not found: $exe"
    archs="$(lipo -archs "$exe" 2>/dev/null)" || die "not a Mach-O file: $exe"
    host="$(uname -m)"
    local -a args=(-dvvv)
    if [[ "$archs" == *" "* ]]; then
        [[ " $archs " == *" $host "* ]] \
            || die "$exe is universal ($archs) without a $host slice; cannot pick the cdhash the running process will have"
        args+=(--arch "$host")
        info "$(basename "$exe") is universal ($archs); pinning the $host slice" >&2
    elif [[ "$archs" != "$host" ]]; then
        die "$exe is $archs only, but this Mac runs $host"
    fi
    out="$(codesign "${args[@]}" "$code" 2>&1)" || die "codesign -dvvv failed for $code: $out"
    count="$(printf '%s\n' "$out" | grep -c '^CDHash=' || true)"
    [[ "$count" == 1 ]] || die "expected exactly one CDHash= line for $code, got $count"
    hash="$(printf '%s\n' "$out" | sed -n 's/^CDHash=//p' | tr 'A-F' 'a-f')"
    is_cdhash "$hash" || die "unexpected CDHash value for $code: '$hash'"
    printf '%s\n' "$hash"
}

# has_true_entitlement <path-to-code> <entitlement-key>: succeeds if the code signature's
# entitlements set <key> to true (codesign --xml output, whitespace-insensitive).
has_true_entitlement() {
    local xml
    xml="$({ codesign -d --entitlements - --xml "$1" 2>/dev/null || true; } | tr -d '[:space:]')"
    [[ "$xml" == *"<key>$2</key><true/>"* ]]
}

# has_entitlement_key <path-to-code> <entitlement-key>: the entitlement is present (any value)
has_entitlement_key() {
    local xml
    xml="$({ codesign -d --entitlements - --xml "$1" 2>/dev/null || true; } | tr -d '[:space:]')"
    [[ "$xml" == *"<key>$2</key>"* ]]
}

# --- Files ---------------------------------------------------------------------------------
# is_root_protected <path>: owned by root and not writable by group or others
# (FanControlHelperConstants.isRootOwnedAndProtected)
is_root_protected() {
    local uid mode
    uid="$(stat -f '%u' "$1" 2>/dev/null)" || return 1
    mode="$(stat -f '%Lp' "$1" 2>/dev/null)" || return 1
    [[ "$uid" == 0 ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

# same_file_contents <a> <b>: both exist and are byte-identical
same_file_contents() {
    [[ -f "$1" && -f "$2" ]] && cmp -s "$1" "$2"
}
