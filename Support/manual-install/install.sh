#!/bin/bash
# Manual (personal use) installation of FanControlHelper as a LaunchDaemon, for ad-hoc
# signed builds without a Team ID (no SMAppService). See docs/helper.md
# 「手動インストール（個人利用モード）」 and README.md.
#
# - verifies the app and its embedded helper (Contents/MacOS/FanControlHelper),
# - reads the identifiers (label = Mach service, helper and app identifiers) from the helper's
#   embedded Info.plist (docs/helper.md "Configuring identifiers"); no edits needed per host,
# - pins the app's cdhash into the LaunchDaemon's FANCONTROL_CLIENT_REQUIREMENT,
# - installs the helper to /Library/PrivilegedHelperTools/<label> (root:wheel 0755) and the
#   plist to /Library/LaunchDaemons/<label>.plist (root:wheel 0644), then bootstraps it.
# Idempotent: re-run after every rebuild of the app (its cdhash changes). When the installed
# files are already exactly what it would install and the job is loaded, it changes nothing
# (the running helper is not restarted) unless --force is given.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
    cat <<USAGE
usage: sudo $FC_PROG [--dry-run] [--force] [--app] /path/to/App.app

Installs the FanControlHelper embedded in App.app as a LaunchDaemon pinned to App.app's cdhash.

  -n, --dry-run   verify and print the generated plist and the commands; change nothing (no root)
  -f, --force     reinstall and restart the helper even if the installed files are current
      --app PATH  the app (same as the positional argument)
  -h, --help      show this help
USAGE
}

FORCE=0
handle_option() {
    case "$1" in
        -f|--force) FORCE=1 ;;
        *) return 1 ;;
    esac
}

parse_cli "$@"
take_app_argument required
require_root

# --- 1. Check the app and the embedded helper -------------------------------------------
APP="$(resolve_app "$APP")"
HELPER_SRC="$APP/$HELPER_IN_APP"
load_identifiers_from_app "$APP"
assert_label_allowed
info "Identifiers (from the helper's embedded Info.plist): $(describe_identifiers)"

bundle_id="$(bundle_identifier "$APP")"
[[ "$bundle_id" == "$APP_BUNDLE_ID" ]] || die "the app's CFBundleIdentifier is '$bundle_id', expected '$APP_BUNDLE_ID' (FanControlClientBundleIdentifier)"

info "Verifying signatures"
codesign --verify --strict --verbose=1 "$APP" || die "app signature is invalid: $APP"
codesign --verify --strict --verbose=1 "$HELPER_SRC" || die "helper signature is invalid: $HELPER_SRC"

app_ident="$(signing_identifier "$APP")"
[[ "$app_ident" == "$APP_BUNDLE_ID" ]] || die "app signing identifier is '$app_ident', expected '$APP_BUNDLE_ID'"
helper_ident="$(signing_identifier "$HELPER_SRC")"
[[ "$helper_ident" == "$HELPER_ID" ]] || die "helper signing identifier is '$helper_ident', expected '$HELPER_ID' (FanControlHelperIdentifier)"

if has_entitlement_key "$HELPER_SRC" com.apple.application-identifier; then
    warn "the helper carries com.apple.application-identifier (injected by Xcode). If launchd/AMFI refuses to"
    warn "start it (see 'log show --predicate \"process == \\\"amfid\\\" OR sender == \\\"AppleMobileFileIntegrity\\\"\"'),"
    warn "see docs/helper.md 「手動インストール（個人利用モード）」."
fi

# The cdhash pin only stops a *different build* from connecting. A same-user process can still
# run code inside the pinned app if the app allows debugging (get-task-allow) or loads unsigned
# libraries (disable-library-validation); the helper's allowlist + range checks bound what it can
# do. See docs/helper.md 「脅威モデル」.
if has_true_entitlement "$APP" com.apple.security.get-task-allow; then
    warn "the app carries com.apple.security.get-task-allow (Debug build): any process of your user can"
    warn "attach to it (task_for_pid / lldb) and use the helper through it. For the build you pin, prefer"
    warn "Release, or Debug with CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO (docs/helper.md 「脅威モデル」)."
fi
if has_true_entitlement "$APP" com.apple.security.cs.disable-library-validation; then
    warn "the app carries com.apple.security.cs.disable-library-validation: a replaced framework inside the"
    warn "bundle would load without changing the pinned cdhash. Needed for ad-hoc + Hardened Runtime with"
    warn "embedded frameworks; keep the app bundle writable only by you (docs/helper.md 「脅威モデル」)."
fi

APP_CDHASH="$(cdhash_of "$APP")"
HELPER_CDHASH="$(cdhash_of "$HELPER_SRC")"
REQUIREMENT="$(client_requirement "$APP_CDHASH")"
info "App:    $APP"
info "        identifier $app_ident, cdhash $APP_CDHASH"
info "Helper: $HELPER_SRC"
info "        identifier $helper_ident, cdhash $HELPER_CDHASH"
info "Client requirement: $REQUIREMENT"

# --- 2. Refuse to clobber an SMAppService registration or another vendor's job ------------
existing_path="$(loaded_service_path)"
if [[ -n "$existing_path" && "$existing_path" != "$PLIST_DEST" ]]; then
    die "system/$LABEL is already loaded from '$existing_path' (SMAppService?). Unregister it first (app / System Settings ▸ Login Items), then re-run."
fi
if [[ -e "$PLIST_DEST" && -z "$(pinned_requirement "$PLIST_DEST")" ]]; then
    die "$PLIST_DEST exists but has no ${ENV_KEY}; it was not installed by this script. Remove it yourself if it is stale."
fi

# --- 3. Generate the LaunchDaemon plist ---------------------------------------------------
NEW_PLIST="$(fc_tmpfile launchdaemon.plist)"
generate_manual_plist "$NEW_PLIST" "$REQUIREMENT"
if (( DRY_RUN )); then
    info "Generated $PLIST_DEST (preview):"
    cat "$NEW_PLIST"
fi

# --- 4. Install (skipped when already current) --------------------------------------------
state="$(install_state "$HELPER_SRC" "$NEW_PLIST")"
loaded=0
job_state="not loaded"
if is_loaded; then loaded=1; job_state=loaded; fi
info "Installed files: $state; system/$LABEL: $job_state"

if [[ "$state" == current ]] && (( loaded && ! FORCE )); then
    info "Already installed and up to date; nothing to do (--force reinstalls and restarts the helper)."
    exit 0
fi

if [[ "$state" != current ]] || (( FORCE )); then
    bootout_job

    info "Installing helper to $HELPER_DEST"
    run install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
    run install -o root -g wheel -m 0755 "$HELPER_SRC" "$HELPER_DEST"
    if (( ! DRY_RUN )); then
        codesign --verify --strict "$HELPER_DEST" || die "installed helper fails codesign --verify"
        installed_hash="$(cdhash_of "$HELPER_DEST")"
        [[ "$installed_hash" == "$HELPER_CDHASH" ]] || die "installed helper cdhash $installed_hash differs from the source ($HELPER_CDHASH)"
    fi

    info "Installing $PLIST_DEST"
    run install -o root -g wheel -m 0644 "$NEW_PLIST" "$PLIST_DEST"
fi

info "Bootstrapping system/$LABEL (on demand via its Mach service; RunAtLoad false)"
run launchctl enable "system/$LABEL"
run launchctl bootstrap system "$PLIST_DEST"

if (( DRY_RUN )); then
    info "Dry run: nothing was changed."
    exit 0
fi

info "launchctl print system/$LABEL (summary)"
print_job_summary
cat <<MSG

Installed. Launch the app and use "Helper version" (or open a write session) to connect.
After rebuilding or replacing the app, run this script again (the pinned cdhash changes).
Remove with: sudo $SCRIPT_DIR/uninstall.sh --app "$APP"
MSG
