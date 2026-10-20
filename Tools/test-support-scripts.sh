#!/bin/bash
# Self-test of the FanControl support scripts (Support/lib.sh, identifiers.sh,
# embed-helper-config.sh, manual-install/*). Needs no root and changes nothing outside a
# temporary work directory: it builds a fake, ad-hoc signed app bundle with a fake helper binary
# carrying an embedded __TEXT,__info_plist, then exercises the library functions and runs the
# scripts in their no-root modes only (--help, --dry-run, status.sh). Refuses to run as root.
#
#   Tools/test-support-scripts.sh [--keep] [--work-dir DIR] [--no-shellcheck]
#
# Requires clang (Xcode or Command Line Tools), codesign, plutil, lipo, launchctl.
# Uses the launchd label com.example.fanfi-selftest.helper, which must not be installed.
#
# Each test runs the library in its own subshell (lib) on purpose, so that no test sees another's
# state; the library's globals are therefore always "modified in a subshell".
# shellcheck disable=SC2031
set -euo pipefail

FC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT="$FC_ROOT/Support"
MANUAL="$SUPPORT/manual-install"
COMMON="$MANUAL/common.sh"

KEEP=0
WORK=""
SHELLCHECK=1
while (( $# > 0 )); do
    case "$1" in
        --keep) KEEP=1 ;;
        --work-dir) WORK="${2:?--work-dir needs a directory}"; shift ;;
        --no-shellcheck) SHELLCHECK=0 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
    esac
    shift
done
if [[ -z "$WORK" ]]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/fanfi-selftest.XXXXXX")"
else
    mkdir -p "$WORK"
    WORK="$(cd "$WORK" && pwd -P)"
fi
if (( ! KEEP )); then trap 'rm -rf "$WORK"' EXIT; fi

# Never as root: the scripts under test are only ever run in their no-root modes (--help,
# --dry-run, status.sh), but a root run of a mistaken test must not be able to install anything.
[[ "$EUID" != 0 ]] || { echo "error: run the self-test as your user, not as root" >&2; exit 1; }

# Isolate from the caller's overrides.
unset FANCONTROL_HELPER_IDENTIFIER FANCONTROL_MACH_SERVICE_NAME FANCONTROL_CLIENT_BUNDLE_IDENTIFIER
unset TARGET_BUILD_DIR WRAPPER_NAME

T_APP_ID="com.example.fanfi-selftest.app"
T_HELPER_ID="com.example.fanfi-selftest.helper"
HOST_ARCH="$(uname -m)"
OTHER_ARCH="x86_64"
[[ "$HOST_ARCH" != x86_64 ]] || OTHER_ARCH="arm64"

# --- Tiny test framework -------------------------------------------------------------------
PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$1"; }
fail() {
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s\n' "$1"
    [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/      | /'
}

# lib <command…>: runs a command (usually a test function) in a subshell with common.sh sourced
lib() {
    (
        set -euo pipefail
        # shellcheck source-path=SCRIPTDIR/.. source=Support/manual-install/common.sh
        source "$COMMON"
        "$@"
    )
}

# expect_ok <description> <command…>
expect_ok() {
    local desc="$1" out
    shift
    if out="$("$@" 2>&1)"; then pass "$desc"; else fail "$desc" "status $?: $out"; fi
}

# expect_fail <description> <exit-status|any> <expected-output-substring> <command…>
expect_fail() {
    local desc="$1" want_status="$2" want="$3" out status=0
    shift 3
    out="$("$@" 2>&1)" || status=$?
    if (( status == 0 )); then
        fail "$desc" "expected failure, got status 0: $out"
    elif [[ "$want_status" != any && "$status" != "$want_status" ]]; then
        fail "$desc" "expected status $want_status, got $status: $out"
    elif [[ "$out" != *"$want"* ]]; then
        fail "$desc" "output lacks '$want': $out"
    else
        pass "$desc"
    fi
}

# expect_output <description> <expected-output-substring> <command…>: succeeds and prints it
expect_output() {
    local desc="$1" want="$2" out status=0
    shift 2
    out="$("$@" 2>&1)" || status=$?
    if (( status != 0 )); then
        fail "$desc" "status $status: $out"
    elif [[ "$out" != *"$want"* ]]; then
        fail "$desc" "output lacks '$want': $out"
    else
        pass "$desc"
    fi
}

# expect_eq <description> <actual> <expected>
expect_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# --- Fixtures ------------------------------------------------------------------------------
FX="$WORK/fixtures"
mkdir -p "$FX"

# write_plist <file> <key> <value> …: XML plist of string values
write_plist() {
    local f="$1"
    shift
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n' > "$f"
    while (( $# >= 2 )); do
        printf '\t<key>%s</key>\n\t<string>%s</string>\n' "$1" "$2" >> "$f"
        shift 2
    done
    printf '</dict>\n</plist>\n' >> "$f"
    plutil -lint -s "$f" >/dev/null
}

# compile <out> <embedded-plist-or-empty> <arch>…
compile() {
    local out="$1" plist="$2"
    shift 2
    local -a flags=()
    local arch
    for arch in "$@"; do flags+=(-arch "$arch"); done
    if [[ -n "$plist" ]]; then flags+=("-Wl,-sectcreate,__TEXT,__info_plist,$plist"); fi
    [[ -f "$FX/main.c" ]] || printf 'int main(void) { return 0; }\n' > "$FX/main.c"
    xcrun clang "$FX/main.c" -o "$out" "${flags[@]}"
}

FC_KEYS=(FanControlHelperIdentifier "$T_HELPER_ID" FanControlMachServiceName "$T_HELPER_ID"
         FanControlClientBundleIdentifier "$T_APP_ID")
write_plist "$FX/helper-info.plist" CFBundleIdentifier "$T_HELPER_ID" "${FC_KEYS[@]}"

# make_app <App.app> <app-info-has-keys:0|1> <helper-signing-identifier>
make_app() {
    local app="$1" with_keys="$2" helper_ident="$3"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    if (( with_keys )); then
        write_plist "$app/Contents/Info.plist" CFBundleIdentifier "$T_APP_ID" CFBundleExecutable FakeApp \
            CFBundlePackageType APPL "${FC_KEYS[@]}"
    else
        write_plist "$app/Contents/Info.plist" CFBundleIdentifier "$T_APP_ID" CFBundleExecutable FakeApp \
            CFBundlePackageType APPL
    fi
    cp "$FX/bin/app" "$app/Contents/MacOS/FakeApp"
    cp "$FX/bin/helper" "$app/Contents/MacOS/FanControlHelper"
    codesign -s - -f -i "$helper_ident" "$app/Contents/MacOS/FanControlHelper" 2>/dev/null
    codesign -s - -f "$app" 2>/dev/null
}

echo "== Building fixtures in $WORK"
mkdir -p "$FX/bin"
compile "$FX/bin/app" "" "$HOST_ARCH"
compile "$FX/bin/helper" "$FX/helper-info.plist" "$HOST_ARCH"
write_plist "$FX/other-helper-info.plist" FanControlHelperIdentifier com.example.fanfi-selftest.other \
    FanControlClientBundleIdentifier "$T_APP_ID"
compile "$FX/bin/helper-other" "$FX/other-helper-info.plist" "$HOST_ARCH"
compile "$FX/bin/plain" "" "$HOST_ARCH"                          # no embedded Info.plist
compile "$FX/bin/universal" "" "$HOST_ARCH" "$OTHER_ARCH"
compile "$FX/bin/foreign" "" "$OTHER_ARCH"
for b in plain universal foreign; do codesign -s - -f -i "com.example.fanfi-selftest.$b" "$FX/bin/$b" 2>/dev/null; done
cp "$FX/bin/plain" "$FX/bin/unsigned"
codesign --remove-signature "$FX/bin/unsigned" 2>/dev/null || true
printf 'not a plist\n' > "$FX/garbage.txt"

FAKE_APP="$FX/FakeApp.app"
make_app "$FAKE_APP" 1 "$T_HELPER_ID"
make_app "$FX/NoKeys.app" 0 "$T_HELPER_ID"                       # app Info.plist resolves to the defaults
make_app "$FX/WrongSigner.app" 1 "com.example.fanfi-selftest.impostor"
ln -s "$FAKE_APP" "$FX/link-to-app.app"

# --- 1. Syntax and shellcheck -------------------------------------------------------------
echo "== Syntax"
SCRIPTS=("$SUPPORT/lib.sh" "$SUPPORT/identifiers.sh" "$SUPPORT/embed-helper-config.sh"
         "$MANUAL/common.sh" "$MANUAL/install.sh" "$MANUAL/uninstall.sh" "$MANUAL/status.sh"
         "$FC_ROOT/Tools/test-support-scripts.sh")
for s in "${SCRIPTS[@]}"; do expect_ok "bash -n ${s#"$FC_ROOT"/}" bash -n "$s"; done
for s in "$SUPPORT/embed-helper-config.sh" "$MANUAL/install.sh" "$MANUAL/uninstall.sh" "$MANUAL/status.sh"; do
    expect_ok "executable ${s#"$FC_ROOT"/}" test -x "$s"
    expect_ok "set -euo pipefail in ${s#"$FC_ROOT"/}" grep -qx 'set -euo pipefail' "$s"
done
if (( SHELLCHECK )); then
    if command -v shellcheck >/dev/null; then
        expect_ok "shellcheck -x (all scripts)" shellcheck -x "${SCRIPTS[@]}"
    else
        echo "skip  shellcheck (not installed)"
    fi
fi

# --- 2. Identifiers ------------------------------------------------------------------------
echo "== Identifiers"
for v in a com.example.x A-b.c-D.0 "$(printf 'a%.0s' {1..255})"; do
    expect_ok "is_identifier '${v:0:40}'" lib is_identifier "$v"
done
for v in "" com..x .com com. "com.ex ample" "com/x" "com.é" "com_x" "$(printf 'a%.0s' {1..256})"; do
    expect_fail "! is_identifier '${v:0:40}'" 1 "" lib is_identifier "$v"
done
expect_ok "is_team_id ABCDE12345" lib is_team_id ABCDE12345
for v in abcde12345 ABCDE1234 ABCDE123456 "ABCDE 1234"; do
    expect_fail "! is_team_id '$v'" 1 "" lib is_team_id "$v"
done

ids() { set_identifiers "$@"; printf '%s|%s|%s|%s' "$HELPER_ID" "$LABEL" "$APP_BUNDLE_ID" "$TEAM_ID"; }
D_H="com.example.dynamicnotch.DynamicNotch.fanfi"
D_C="com.example.dynamicnotch.DynamicNotch"
expect_eq "defaults" "$(lib ids "" "" "")" "$D_H|$D_H|$D_C|"
expect_eq "helper <- Mach service" "$(lib ids "" a.b c.d)" "a.b|a.b|c.d|"
expect_eq "Mach service <- helper" "$(lib ids a.b "" c.d)" "a.b|a.b|c.d|"
expect_eq "independent Mach service" "$(lib ids a.b a.svc c.d TEAM000001)" "a.b|a.svc|c.d|TEAM000001"
expect_fail "client == helper" 1 "must differ" lib ids a.b "" a.b
expect_fail "bad helper id" 1 "invalid helper identifier" lib ids "a..b" "" c.d
expect_fail "bad Team ID" 1 "invalid Team ID" lib ids a.b "" c.d team
env_ids() { printf '%s|%s|%s' "$HELPER_ID" "$LABEL" "$APP_BUNDLE_ID"; }
expect_eq "environment overrides at load" \
    "$(FANCONTROL_MACH_SERVICE_NAME=x.svc FANCONTROL_CLIENT_BUNDLE_IDENTIFIER=x.app lib env_ids)" "x.svc|x.svc|x.app"
expect_fail "invalid environment override" 1 "invalid helper identifier" \
    env FANCONTROL_MACH_SERVICE_NAME='bad name' bash -c "source '$COMMON'"

from_plist() { resolve_identifiers_from_plist "$1"; printf '%s|%s|%s' "$HELPER_ID" "$LABEL" "$APP_BUNDLE_ID"; }
cp "$FX/helper-info.plist" "$FX/helper-info.bin.plist"
plutil -convert binary1 "$FX/helper-info.bin.plist"
expect_eq "resolve from XML plist" "$(lib from_plist "$FX/helper-info.plist")" "$T_HELPER_ID|$T_HELPER_ID|$T_APP_ID"
expect_eq "resolve from binary plist" "$(lib from_plist "$FX/helper-info.bin.plist")" "$T_HELPER_ID|$T_HELPER_ID|$T_APP_ID"
expect_eq "resolve the repository Helper-Info.plist" "$(lib from_plist "$SUPPORT/Helper-Info.plist")" "$D_H|$D_H|$D_C"
expect_fail "resolve from a non-plist" 1 "not a property list" lib from_plist "$FX/garbage.txt"
expect_fail "resolve from a missing file" 1 "cannot read" lib from_plist "$FX/missing.plist"

# --- 3. Embedded Info.plist ----------------------------------------------------------------
echo "== Embedded Info.plist"
embedded_ids() { embedded_info_plist "$1" "$_FC_TMPDIR/e.plist"; from_plist "$_FC_TMPDIR/e.plist"; }
expect_eq "embedded_info_plist (OpenStep from launchctl plist)" "$(lib embedded_ids "$FX/bin/helper")" "$T_HELPER_ID|$T_HELPER_ID|$T_APP_ID"
expect_fail "embedded_info_plist without the section" 1 "no embedded __TEXT,__info_plist" lib embedded_ids "$FX/bin/plain"
expect_fail "embedded_info_plist of a text file" 1 "no embedded __TEXT,__info_plist" lib embedded_ids "$FX/garbage.txt"

# --- 4. Bundles, code signing, files -------------------------------------------------------
echo "== Bundles and code signing"
expect_eq "resolve_app follows symlinks" "$(lib resolve_app "$FX/link-to-app.app")" "$FAKE_APP"
mkdir -p "$FX/Empty.app" "$FX/NoExe.app/Contents"
write_plist "$FX/NoExe.app/Contents/Info.plist" CFBundleIdentifier "$T_APP_ID" CFBundleExecutable Missing
expect_fail "resolve_app: not a directory" 1 "not a directory" lib resolve_app "$FX/nope.app"
expect_fail "resolve_app: no Info.plist" 1 "no Contents/Info.plist" lib resolve_app "$FX/Empty.app"
expect_fail "resolve_app: no executable" 1 "main executable not found" lib resolve_app "$FX/NoExe.app"

codesign_cdhash() { codesign -dvvv "$@" 2>&1 | sed -n 's/^CDHash=//p'; }
expect_eq "cdhash_of a thin binary" "$(lib cdhash_of "$FX/bin/plain")" "$(codesign_cdhash "$FX/bin/plain")"
expect_eq "cdhash_of an app bundle" "$(lib cdhash_of "$FAKE_APP")" "$(codesign_cdhash "$FAKE_APP")"
expect_eq "cdhash_of a universal binary picks the $HOST_ARCH slice" \
    "$(lib cdhash_of "$FX/bin/universal" 2>/dev/null)" "$(codesign_cdhash --arch "$HOST_ARCH" "$FX/bin/universal")"
expect_fail "cdhash_of a $OTHER_ARCH-only binary" 1 "$OTHER_ARCH only" lib cdhash_of "$FX/bin/foreign"
expect_fail "cdhash_of an unsigned binary" 1 "" lib cdhash_of "$FX/bin/unsigned"
expect_fail "cdhash_of a text file" 1 "not a Mach-O file" lib cdhash_of "$FX/garbage.txt"
expect_ok "is_cdhash (40 lower-case hex)" lib is_cdhash 0123456789abcdef0123456789abcdef01234567
for v in 0123456789ABCDEF0123456789ABCDEF01234567 0123 "0123456789abcdef0123456789abcdef0123456g"; do
    expect_fail "! is_cdhash '${v:0:12}…'" 1 "" lib is_cdhash "$v"
done
expect_eq "signing_identifier" "$(lib signing_identifier "$FAKE_APP/Contents/MacOS/FanControlHelper")" "$T_HELPER_ID"
expect_eq "signing_identifier of unsigned code is empty" "$(lib signing_identifier "$FX/bin/unsigned")" ""
expect_fail "has_true_entitlement (none)" 1 "" lib has_true_entitlement "$FX/bin/plain" com.apple.security.get-task-allow

expect_ok "is_root_protected /bin/ls" lib is_root_protected /bin/ls
expect_fail "! is_root_protected (user-owned)" 1 "" lib is_root_protected "$FX/garbage.txt"
expect_fail "! is_root_protected /private/tmp (world-writable)" 1 "" lib is_root_protected /private/tmp
expect_fail "! is_root_protected (missing)" 1 "" lib is_root_protected "$FX/missing"

# --- 5. Manual-install layer ---------------------------------------------------------------
echo "== Manual-install layer"
HASH=0123456789abcdef0123456789abcdef01234567
expect_eq "client_requirement" "$(lib client_requirement "$HASH")" "identifier \"$D_C\" and cdhash H\"$HASH\""
expect_eq "template carries the placeholder" "$(lib pinned_requirement "$MANUAL/FanControlHelper.manual.plist")" "__FILLED_IN_BY_INSTALL_SH__"
paths() { printf '%s %s' "$HELPER_DEST" "$PLIST_DEST"; }
expect_eq "paths follow LABEL" "$(FANCONTROL_MACH_SERVICE_NAME=x.svc lib paths)" \
    "/Library/PrivilegedHelperTools/x.svc /Library/LaunchDaemons/x.svc.plist"
expect_fail "assert_label_allowed refuses com.apple.*" 1 "refusing" env FANCONTROL_MACH_SERVICE_NAME=com.apple.x \
    FANCONTROL_HELPER_IDENTIFIER=com.apple.x bash -c "source '$COMMON'; assert_label_allowed"

gen() {
    load_identifiers_from_app "$FAKE_APP"
    generate_manual_plist "$1" "$(client_requirement "$HASH")"
}
lib gen "$FX/generated.plist" >/dev/null
expect_eq "generated Label" "$(plutil -extract Label raw -o - "$FX/generated.plist")" "$T_HELPER_ID"
expect_eq "generated Program" "$(plutil -extract Program raw -o - "$FX/generated.plist")" "/Library/PrivilegedHelperTools/$T_HELPER_ID"
expect_eq "generated MachServices" "$(plutil -extract MachServices json -o - "$FX/generated.plist" | tr -d '[:space:]')" "{\"$T_HELPER_ID\":true}"
expect_eq "generated requirement" "$(plutil -extract EnvironmentVariables.FANCONTROL_CLIENT_REQUIREMENT raw -o - "$FX/generated.plist")" \
    "identifier \"$T_APP_ID\" and cdhash H\"$HASH\""
expect_eq "generated RunAtLoad" "$(plutil -extract RunAtLoad raw -o - "$FX/generated.plist")" "false"
expect_fail "generated plist has no BundleProgram" any "" plutil -extract BundleProgram raw -o - "$FX/generated.plist"

S="$FX/state"
mkdir -p "$S"
printf 'helper-v1' > "$S/src-helper"
printf 'plist-v1' > "$S/new.plist"
expect_eq "install_state: absent" "$(lib install_state "$S/src-helper" "$S/new.plist" "$S/h" "$S/p")" absent
cp "$S/src-helper" "$S/h"
expect_eq "install_state: helper only -> stale" "$(lib install_state "$S/src-helper" "$S/new.plist" "$S/h" "$S/p")" stale
cp "$S/new.plist" "$S/p"
expect_eq "install_state: identical but user-owned -> stale" "$(lib install_state "$S/src-helper" "$S/new.plist" "$S/h" "$S/p")" stale
# Stub: fixture files cannot be root-owned without root.
# shellcheck disable=SC2329  # is_root_protected is called by install_state
as_root_owned() { is_root_protected() { [[ -f "$1" ]]; }; install_state "$@"; }
expect_eq "install_state: identical + root-protected -> current" "$(lib as_root_owned "$S/src-helper" "$S/new.plist" "$S/h" "$S/p")" current
printf 'plist-v2' > "$S/new.plist"
expect_eq "install_state: new pin -> stale" "$(lib as_root_owned "$S/src-helper" "$S/new.plist" "$S/h" "$S/p")" stale

app_ids() { load_identifiers_from_app "$1"; printf '%s|%s|%s|%s' "$HELPER_ID" "$LABEL" "$APP_BUNDLE_ID" "$PLIST_DEST"; }
expect_eq "load_identifiers_from_app" "$(lib app_ids "$FAKE_APP")" "$T_HELPER_ID|$T_HELPER_ID|$T_APP_ID|/Library/LaunchDaemons/$T_HELPER_ID.plist"
expect_fail "load_identifiers_from_app: app Info.plist disagrees" 1 "the app's Info.plist resolves to" lib app_ids "$FX/NoKeys.app"
expect_fail "load_identifiers_from_app: contradicting override" 1 "FANCONTROL_MACH_SERVICE_NAME=x.svc" \
    env FANCONTROL_MACH_SERVICE_NAME=x.svc bash -c "source '$COMMON'; load_identifiers_from_app '$FAKE_APP'"
expect_ok "load_identifiers_from_app: matching override" \
    env FANCONTROL_MACH_SERVICE_NAME="$T_HELPER_ID" bash -c "source '$COMMON'; load_identifiers_from_app '$FAKE_APP'"
expect_fail "load_identifiers_from_app: no helper" 1 "helper not found inside the app" lib app_ids "$FX/NoExe.app"
tmpdir_gone() { local d; d="$(bash -c "source '$COMMON'; printf '%s' \"\$_FC_TMPDIR\"")"; [[ -n "$d" && ! -e "$d" ]]; }
expect_ok "temporary directory removed on exit" tmpdir_gone

# --- 6. Command line -----------------------------------------------------------------------
echo "== Command line"
# shellcheck disable=SC2329  # usage is called by parse_cli
cli() { usage() { echo USAGE; }; parse_cli "$@"; take_app_argument; printf 'dry=%s app=%s' "$DRY_RUN" "$APP"; }
expect_eq "parse_cli positional app" "$(lib cli /x.app)" "dry=0 app=/x.app"
expect_eq "parse_cli --app PATH -n" "$(lib cli --app /x.app -n)" "dry=1 app=/x.app"
expect_eq "parse_cli --app=PATH --dry-run" "$(lib cli --dry-run --app=/x.app)" "dry=1 app=/x.app"
expect_eq "parse_cli -- -weird.app" "$(lib cli -- -weird.app)" "dry=0 app=-weird.app"
expect_eq "parse_cli --help" "$(lib cli --help)" "USAGE"
expect_fail "parse_cli unknown option" 64 "unknown option: --bogus" lib cli --bogus
expect_fail "parse_cli two apps" 64 "more than one app" lib cli --app /a.app /b.app
expect_fail "parse_cli extra arguments" 64 "unexpected arguments" lib cli /a.app /b.app
expect_fail "parse_cli --app without a path" 64 "--app needs a path" lib cli --app
# shellcheck disable=SC2329  # usage is called by parse_cli
root_check() { usage() { :; }; parse_cli "$@"; require_root; echo passed; }
expect_fail "require_root refuses a non-root user" 1 "must be run as root: sudo $0 --app /x.app" lib root_check --app /x.app
expect_eq "require_root is skipped with --dry-run" "$(lib root_check -n --app /x.app)" "passed"

# --- 7. The scripts (no root) --------------------------------------------------------------
echo "== Scripts"
for s in install.sh uninstall.sh status.sh; do
    expect_output "$s --help" "usage:" "$MANUAL/$s" --dry-run --help
    expect_fail "$s --bogus" 64 "unknown option" "$MANUAL/$s" --dry-run --bogus
done
expect_output "embed-helper-config.sh --help" "usage:" "$SUPPORT/embed-helper-config.sh" --help

expect_fail "install.sh without an app" 64 "no app given" "$MANUAL/install.sh" --dry-run
APP_HASH="$(codesign_cdhash "$FAKE_APP")"
expect_output "install.sh --dry-run pins the app cdhash" "cdhash H\"$APP_HASH\"" "$MANUAL/install.sh" --dry-run --app "$FAKE_APP"
expect_output "install.sh --dry-run prints the install commands" \
    "[dry-run] install -o root -g wheel -m 0755 $FAKE_APP/Contents/MacOS/FanControlHelper /Library/PrivilegedHelperTools/$T_HELPER_ID" \
    "$MANUAL/install.sh" -n "$FAKE_APP"
expect_output "install.sh --dry-run bootstraps the label" "[dry-run] launchctl bootstrap system /Library/LaunchDaemons/$T_HELPER_ID.plist" \
    "$MANUAL/install.sh" -n "$FAKE_APP"
expect_fail "install.sh refuses a helper signed with another identifier" 1 "helper signing identifier is 'com.example.fanfi-selftest.impostor'" \
    "$MANUAL/install.sh" --dry-run "$FX/WrongSigner.app"
expect_fail "install.sh refuses mismatching identifiers" 1 "the app's Info.plist resolves to" "$MANUAL/install.sh" --dry-run "$FX/NoKeys.app"
expect_fail "install.sh refuses a non-bundle" 1 "no Contents/Info.plist" "$MANUAL/install.sh" --dry-run "$FX/Empty.app"
expect_output "uninstall.sh --dry-run with nothing installed" "Nothing to remove." "$MANUAL/uninstall.sh" --dry-run --app "$FAKE_APP"
expect_output "uninstall.sh --dry-run reads the label from the app" "Label: $T_HELPER_ID" "$MANUAL/uninstall.sh" -n "$FAKE_APP"
expect_fail "status.sh reports a missing installation" 1 "missing  /Library/LaunchDaemons/$T_HELPER_ID.plist" "$MANUAL/status.sh" "$FAKE_APP"

# embed-helper-config.sh on a copy of the app
EMB="$FX/Embed.app"
make_app "$EMB" 0 "$T_HELPER_ID"
before="$(plutil -convert xml1 -o - "$EMB/Contents/Info.plist")"
expect_output "embed --dry-run" "Would write $EMB/Contents/Library/LaunchDaemons/$T_HELPER_ID.plist" \
    "$SUPPORT/embed-helper-config.sh" --dry-run "$FX/helper-info.plist" "$EMB"
expect_eq "embed --dry-run changed nothing" "$(plutil -convert xml1 -o - "$EMB/Contents/Info.plist")" "$before"
expect_ok "embed-helper-config.sh writes the app" "$SUPPORT/embed-helper-config.sh" "$FX/helper-info.plist" --app "$EMB"
expect_eq "embed: FanControlMachServiceName" "$(plutil -extract FanControlMachServiceName raw -o - "$EMB/Contents/Info.plist")" "$T_HELPER_ID"
expect_fail "embed: no Team ID key without a Team ID" any "" plutil -extract FanControlClientTeamID raw -o - "$EMB/Contents/Info.plist"
DAEMON="$EMB/Contents/Library/LaunchDaemons/$T_HELPER_ID.plist"
expect_eq "embed: LaunchDaemon AssociatedBundleIdentifiers" "$(plutil -extract AssociatedBundleIdentifiers.0 raw -o - "$DAEMON")" "$T_APP_ID"
first="$(cat "$EMB/Contents/Info.plist" "$DAEMON")"
"$SUPPORT/embed-helper-config.sh" "$FX/helper-info.plist" "$EMB" >/dev/null 2>&1
expect_eq "embed is idempotent" "$(cat "$EMB/Contents/Info.plist" "$DAEMON")" "$first"
expect_ok "install.sh --dry-run accepts the embedded app (after re-signing)" bash -c \
    "codesign -s - -f '$EMB' 2>/dev/null && '$MANUAL/install.sh' --dry-run '$EMB' >/dev/null"
cp -R "$EMB" "$FX/Other.app"
plutil -replace CFBundleIdentifier -string com.example.other "$FX/Other.app/Contents/Info.plist"
expect_fail "embed refuses a mismatching CFBundleIdentifier" 1 "the helper would reject this app" \
    "$SUPPORT/embed-helper-config.sh" "$FX/helper-info.plist" "$FX/Other.app"
cp -R "$EMB" "$FX/StaleHelper.app"
cp "$FX/bin/helper-other" "$FX/StaleHelper.app/Contents/MacOS/FanControlHelper"
expect_fail "embed refuses an embedded helper with other identifiers" 1 "rebuild the helper with the same Helper-Info.plist" \
    "$SUPPORT/embed-helper-config.sh" "$FX/helper-info.plist" "$FX/StaleHelper.app"
cp -R "$EMB" "$FX/NoHelper.app"
rm "$FX/NoHelper.app/Contents/MacOS/FanControlHelper"
expect_output "embed warns when the helper is not embedded yet" "not found (yet)" \
    "$SUPPORT/embed-helper-config.sh" "$FX/helper-info.plist" "$FX/NoHelper.app"
expect_fail "embed without app outside Xcode" 64 "not running inside Xcode" "$SUPPORT/embed-helper-config.sh" "$FX/helper-info.plist"
expect_ok "embed with TARGET_BUILD_DIR/WRAPPER_NAME" env TARGET_BUILD_DIR="$FX" WRAPPER_NAME=Embed.app \
    "$SUPPORT/embed-helper-config.sh" "$FX/helper-info.plist"
mkdir -p "$FX/ld"
expect_eq "embed --launchd-plist-only prints the path" \
    "$("$SUPPORT/embed-helper-config.sh" --launchd-plist-only "$SUPPORT/Helper-Info.plist" "$FX/ld")" "$FX/ld/$D_H.plist"
expect_eq "generated SMAppService plist == checked-in LaunchDaemons plist" \
    "$(plutil -convert xml1 -o - "$FX/ld/$D_H.plist")" "$(plutil -convert xml1 -o - "$SUPPORT/LaunchDaemons/$D_H.plist")"
expect_fail "embed --launchd-plist-only needs an output dir" 64 "needs <Helper-Info.plist> <output-dir>" \
    "$SUPPORT/embed-helper-config.sh" --launchd-plist-only "$SUPPORT/Helper-Info.plist"

echo
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
if (( KEEP )); then printf 'work directory kept: %s\n' "$WORK"; fi
(( FAILED == 0 ))
