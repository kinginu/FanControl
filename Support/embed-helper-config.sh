#!/bin/bash
# Propagates the FanControl identifiers from the helper's Info.plist (Helper-Info.plist, the one
# embedded into FanControlHelper with -sectcreate) to the host app, so app, helper and launchd
# agree without editing Swift. docs/helper.md "Configuring identifiers".
#
# As an Xcode Run Script phase of the APP target (after "Copy Files"/embedding, before signing,
# with ENABLE_USER_SCRIPT_SANDBOXING = NO and $(TARGET_BUILD_DIR)/$(INFOPLIST_PATH) as an input
# file so it runs after ProcessInfoPlistFile), omit the app: it uses $TARGET_BUILD_DIR/$WRAPPER_NAME.
# It
#   1. resolves FanControlHelperIdentifier / FanControlMachServiceName /
#      FanControlClientBundleIdentifier / FanControlClientTeamID with the same fallbacks as
#      FanControlIdentifiers.swift (Support/identifiers.sh),
#   2. checks the app's CFBundleIdentifier against FanControlClientBundleIdentifier, and that the
#      helper embedded at Contents/MacOS/FanControlHelper carries the same identifiers in its
#      __TEXT,__info_plist (its code-signing identifier is checked by install.sh and, at connect
#      time, by the app),
#   3. writes the four keys into <App>/Contents/Info.plist (FanControlHelperConstants reads them
#      in the app),
#   4. writes the SMAppService LaunchDaemon plist <App>/Contents/Library/LaunchDaemons/<label>.plist
#      (Label, BundleProgram, MachServices, AssociatedBundleIdentifiers).
# Idempotent: running it twice leaves the same files.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=identifiers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/identifiers.sh"

usage() {
    cat <<USAGE
usage: $FC_PROG [--dry-run] <Helper-Info.plist> [[--app] App.app]
       $FC_PROG [--dry-run] --launchd-plist-only <Helper-Info.plist> <output-dir>

Copies the FanControl* identifiers of Helper-Info.plist into App.app's Info.plist and writes
App.app/Contents/Library/LaunchDaemons/<label>.plist. Without an app (Xcode Run Script phase),
the app is \$TARGET_BUILD_DIR/\$WRAPPER_NAME.

  -n, --dry-run             print what would be written; change nothing
      --app PATH            the app (same as the second positional argument)
      --launchd-plist-only  only write <output-dir>/<label>.plist and print its path
  -h, --help                show this help
USAGE
}

LAUNCHD_ONLY=0
handle_option() {
    case "$1" in
        --launchd-plist-only) LAUNCHD_ONLY=1 ;;
        *) return 1 ;;
    esac
}

# write_launchd_plist <output-file>: the SMAppService LaunchDaemon (values are validated
# reverse-DNS identifiers, safe to interpolate into XML).
write_launchd_plist() {
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/FanControlHelper</string>
	<key>MachServices</key>
	<dict>
		<key>${LABEL}</key>
		<true/>
	</dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>${APP_BUNDLE_ID}</string>
	</array>
	<key>RunAtLoad</key>
	<false/>
	<key>ProcessType</key>
	<string>Adaptive</string>
</dict>
</plist>
PLIST
    plutil -lint -s "$1" >/dev/null || die "generated $1 is invalid"
}

parse_cli "$@"
(( FC_NARGS >= 1 )) || usage_error "no Helper-Info.plist given"
HELPER_INFO="${FC_ARGS[0]}"
resolve_identifiers_from_plist "$HELPER_INFO"

# --- --launchd-plist-only ------------------------------------------------------------------
if (( LAUNCHD_ONLY )); then
    [[ -z "$APP" ]] || usage_error "--launchd-plist-only takes no app"
    (( FC_NARGS == 2 )) || usage_error "--launchd-plist-only needs <Helper-Info.plist> <output-dir>"
    out="${FC_ARGS[1]}/${LABEL}.plist"
    if (( DRY_RUN )); then
        preview="$(fc_tmpfile launchd.plist)"
        write_launchd_plist "$preview"
        info "Would write $out:" >&2
        cat "$preview"
        exit 0
    fi
    mkdir -p "${FC_ARGS[1]}"
    write_launchd_plist "$out"
    printf '%s\n' "$out"
    exit 0
fi

# --- App mode ------------------------------------------------------------------------------
(( FC_NARGS <= 2 )) || usage_error "unexpected arguments: ${FC_ARGS[*]:2}"
if (( FC_NARGS == 2 )); then
    [[ -z "$APP" ]] || usage_error "more than one app given"
    APP="${FC_ARGS[1]}"
fi
if [[ -z "$APP" ]]; then
    [[ -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" ]] || usage_error "no app given and not running inside Xcode"
    APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
fi
APP="$(resolve_app "$APP")"
APP_INFO="$APP/Contents/Info.plist"

bundle_id="$(bundle_identifier "$APP")"
[[ "$bundle_id" == "$APP_BUNDLE_ID" ]] \
    || die "the app's CFBundleIdentifier is '$bundle_id' but $HELPER_INFO sets FanControlClientBundleIdentifier '$APP_BUNDLE_ID' (the helper would reject this app)"
helper_bundle_id="$(plist_string "$HELPER_INFO" CFBundleIdentifier)"
if [[ -n "$helper_bundle_id" && "$helper_bundle_id" != "$HELPER_ID" ]]; then
    warn "$HELPER_INFO: CFBundleIdentifier $helper_bundle_id != FanControlHelperIdentifier $HELPER_ID"
fi

# The helper already copied into the app must carry the same identifiers (a stale helper from
# an earlier build, or one built with another Helper-Info.plist, would serve another label).
EMBEDDED_HELPER="$APP/Contents/MacOS/FanControlHelper"
if [[ -f "$EMBEDDED_HELPER" ]]; then
    expected="$(describe_identifiers)"
    embedded="$(fc_tmpfile embedded-helper-info.plist)"
    embedded_info_plist "$EMBEDDED_HELPER" "$embedded"
    resolve_identifiers_from_plist "$embedded"
    actual="$(describe_identifiers)"
    [[ "$actual" == "$expected" ]] \
        || die "$EMBEDDED_HELPER embeds identifiers ($actual) that differ from $HELPER_INFO ($expected); rebuild the helper with the same Helper-Info.plist"
else
    warn "$EMBEDDED_HELPER not found (yet); embed the helper before this phase"
fi

DAEMONS="$APP/Contents/Library/LaunchDaemons"
DAEMON_PLIST="$DAEMONS/${LABEL}.plist"

if (( DRY_RUN )); then
    info "Would set in $APP_INFO: FanControlHelperIdentifier=$HELPER_ID FanControlMachServiceName=$LABEL FanControlClientBundleIdentifier=$APP_BUNDLE_ID FanControlClientTeamID=${TEAM_ID:-<removed>}"
    preview="$(fc_tmpfile launchd.plist)"
    write_launchd_plist "$preview"
    info "Would write $DAEMON_PLIST:"
    cat "$preview"
    exit 0
fi

plutil -replace FanControlHelperIdentifier -string "$HELPER_ID" "$APP_INFO"
plutil -replace FanControlMachServiceName -string "$LABEL" "$APP_INFO"
plutil -replace FanControlClientBundleIdentifier -string "$APP_BUNDLE_ID" "$APP_INFO"
if [[ -n "$TEAM_ID" ]]; then
    plutil -replace FanControlClientTeamID -string "$TEAM_ID" "$APP_INFO"
else
    plutil -remove FanControlClientTeamID "$APP_INFO" >/dev/null 2>&1 || true
fi

mkdir -p "$DAEMONS"
write_launchd_plist "$DAEMON_PLIST"
for other in "$DAEMONS"/*.plist; do
    [[ -e "$other" && "$other" != "$DAEMON_PLIST" ]] || continue
    warn "$other is not the FanControl LaunchDaemon (${LABEL}.plist); stale copy?"
done
printf 'FanControl identifiers: %s\n' "$(describe_identifiers)"
