#!/bin/bash
# Manual (personal use) installation of FanControlHelper as a LaunchDaemon, for ad-hoc
# signed builds without a Team ID (no SMAppService). See docs/helper.md
# 「手動インストール（個人利用モード）」.
#
#   sudo ./install.sh [--dry-run] /path/to/DynamicNotch.app
#
# - verifies the app and its embedded helper (Contents/MacOS/FanControlHelper),
# - pins the app's cdhash into the LaunchDaemon's FANCONTROL_CLIENT_REQUIREMENT,
# - installs the helper to /Library/PrivilegedHelperTools/<label> (root:wheel 0755) and the
#   plist to /Library/LaunchDaemons/<label>.plist (root:wheel 0644), then bootstraps it.
# Idempotent: re-run after every rebuild of the app (its cdhash changes).
# --dry-run: no root needed, changes nothing; prints the generated plist and the commands.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() { printf 'usage: sudo %s [--dry-run] /path/to/App.app\n' "$(basename "$0")" >&2; exit 64; }

DRY_RUN=0
APP=""
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        -h|--help) usage ;;
        -*) printf 'unknown option: %s\n' "$arg" >&2; usage ;;
        *) [[ -z "$APP" ]] || usage; APP="$arg" ;;
    esac
done
[[ -n "$APP" ]] || usage

run() {
    if (( DRY_RUN )); then
        printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

if (( ! DRY_RUN )) && [[ "$(id -u)" != 0 ]]; then
    die "must be run as root: sudo $0 $APP   (or --dry-run to preview)"
fi
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

# --- 1. Check the app and the embedded helper -------------------------------------------
[[ -d "$APP" ]] || die "not a directory: $APP"
APP="$(cd "$APP" && pwd -P)"
HELPER_SRC="$APP/$HELPER_IN_APP"
[[ -f "$HELPER_SRC" ]] || die "helper not found inside the app: $HELPER_SRC"

bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" \
    || die "cannot read CFBundleIdentifier of $APP"
[[ "$bundle_id" == "$APP_BUNDLE_ID" ]] || die "bundle identifier is '$bundle_id', expected '$APP_BUNDLE_ID'"

info "Verifying signatures"
codesign --verify --strict --verbose=1 "$APP" || die "app signature is invalid: $APP"
codesign --verify --strict --verbose=1 "$HELPER_SRC" || die "helper signature is invalid: $HELPER_SRC"

app_ident="$(signing_identifier "$APP")"
[[ "$app_ident" == "$APP_BUNDLE_ID" ]] || die "app signing identifier is '$app_ident', expected '$APP_BUNDLE_ID'"
helper_ident="$(signing_identifier "$HELPER_SRC")"
[[ "$helper_ident" == "$LABEL" ]] || die "helper signing identifier is '$helper_ident', expected '$LABEL'"

if codesign -d --entitlements - --xml "$HELPER_SRC" 2>/dev/null | grep -q 'com.apple.application-identifier'; then
    warn "the helper carries com.apple.application-identifier (injected by Xcode). If launchd/AMFI refuses to"
    warn "start it (see 'log show --predicate \"process == \\\"amfid\\\" OR sender == \\\"AppleMobileFileIntegrity\\\"\"'),"
    warn "see docs/helper.md 「手動インストール（個人利用モード）」."
fi

APP_CDHASH="$(cdhash_of "$APP")"
HELPER_CDHASH="$(cdhash_of "$HELPER_SRC")"
REQUIREMENT="$(client_requirement "$APP_CDHASH")"
info "App:    $APP"
info "        identifier $app_ident, cdhash $APP_CDHASH"
info "Helper: $HELPER_SRC"
info "        identifier $helper_ident, cdhash $HELPER_CDHASH"
info "Client requirement: $REQUIREMENT"

# --- 2. Refuse to clobber an SMAppService registration ---------------------------------
existing_path="$(loaded_service_path)"
if [[ -n "$existing_path" && "$existing_path" != "$PLIST_DEST" ]]; then
    die "system/$LABEL is already loaded from '$existing_path' (SMAppService?). Unregister it first (app / System Settings ▸ Login Items), then re-run."
fi

# --- 3. Generate the LaunchDaemon plist ---------------------------------------------
TMP_PLIST="$(mktemp -t fanfi-manual-plist)"
trap 'rm -f "$TMP_PLIST"' EXIT
cp "$TEMPLATE" "$TMP_PLIST"
plutil -replace Label -string "$LABEL" "$TMP_PLIST"
plutil -replace Program -string "$HELPER_DEST" "$TMP_PLIST"
plutil -replace "EnvironmentVariables.${ENV_KEY}" -string "$REQUIREMENT" "$TMP_PLIST"
plutil -convert xml1 "$TMP_PLIST"
plutil -lint -s "$TMP_PLIST" || die "generated plist is invalid"
[[ "$(pinned_requirement "$TMP_PLIST")" == "$REQUIREMENT" ]] || die "generated plist does not contain the requirement"
if (( DRY_RUN )); then
    info "Generated $PLIST_DEST (preview):"
    cat "$TMP_PLIST"
fi

# --- 4. Install -------------------------------------------------------------------
if is_loaded; then
    info "Stopping the loaded helper (fans return to automatic on SIGTERM)"
    if (( DRY_RUN )); then
        run launchctl bootout "system/$LABEL"
    else
        launchctl bootout "system/$LABEL" || warn "bootout returned $? (continuing)"
        for _ in 1 2 3 4 5 6 7 8 9 10; do is_loaded || break; sleep 0.5; done
        is_loaded && die "system/$LABEL is still loaded after bootout"
    fi
fi

info "Installing helper to $HELPER_DEST"
run install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
run install -o root -g wheel -m 0755 "$HELPER_SRC" "$HELPER_DEST"
if (( ! DRY_RUN )); then
    codesign --verify --strict "$HELPER_DEST" || die "installed helper fails codesign --verify"
    [[ "$(cdhash_of "$HELPER_DEST")" == "$HELPER_CDHASH" ]] || die "installed helper cdhash differs from the source"
fi

info "Installing $PLIST_DEST"
run install -o root -g wheel -m 0644 "$TMP_PLIST" "$PLIST_DEST"

info "Bootstrapping system/$LABEL (on demand via its Mach service; RunAtLoad false)"
run launchctl enable "system/$LABEL"
run launchctl bootstrap system "$PLIST_DEST"

if (( DRY_RUN )); then
    info "Dry run: nothing was changed."
    exit 0
fi

info "launchctl print system/$LABEL (summary)"
launchctl print "system/$LABEL" | grep -E '^[[:space:]]*(state|path|program|pid|last exit code|runs|FANCONTROL_CLIENT_REQUIREMENT)( =|=>|:)' || true
cat <<MSG

Installed. Launch the app and use "Helper version" (or open a write session) to connect.
After rebuilding or replacing the app, run this script again (the pinned cdhash changes).
Remove with: sudo $(dirname "$0")/uninstall.sh
MSG
