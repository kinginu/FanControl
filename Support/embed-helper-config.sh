#!/bin/bash
# Propagates the FanControl identifiers from the helper's Info.plist (Helper-Info.plist, the one
# embedded into FanControlHelper with -sectcreate) to the host app, so app, helper and launchd
# agree without editing Swift. docs/helper.md "Configuring identifiers".
#
#   embed-helper-config.sh <Helper-Info.plist> [/path/to/App.app]
#   embed-helper-config.sh --launchd-plist-only <Helper-Info.plist> <output-dir>
#
# As an Xcode Run Script phase of the APP target (after "Copy Files"/embedding, before signing,
# with ENABLE_USER_SCRIPT_SANDBOXING = NO and $(TARGET_BUILD_DIR)/$(INFOPLIST_PATH) as an input
# file so it runs after ProcessInfoPlistFile), omit the app: it uses $TARGET_BUILD_DIR/$WRAPPER_NAME.
# It
#   1. resolves FanControlHelperIdentifier / FanControlMachServiceName /
#      FanControlClientBundleIdentifier / FanControlClientTeamID with the same fallbacks as
#      FanControlIdentifiers.swift (Support/identifiers.sh),
#   2. checks the app's CFBundleIdentifier against FanControlClientBundleIdentifier (the helper's
#      code-signing identifier is checked by install.sh and, at connect time, by the app),
#   3. writes the four keys into <App>/Contents/Info.plist (FanControlHelperConstants reads them
#      in the app),
#   4. writes the SMAppService LaunchDaemon plist <App>/Contents/Library/LaunchDaemons/<label>.plist
#      (Label, BundleProgram, MachServices, AssociatedBundleIdentifiers).
set -euo pipefail
SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# shellcheck source-path=SCRIPTDIR source=identifiers.sh
source "${SUPPORT_DIR}/identifiers.sh"

usage() {
    printf 'usage: %s <Helper-Info.plist> [App.app]\n       %s --launchd-plist-only <Helper-Info.plist> <output-dir>\n' \
        "$(basename "$0")" "$(basename "$0")" >&2
    exit 64
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
    plutil -lint -s "$1" || die "generated $1 is invalid"
}

if [[ "${1:-}" == "--launchd-plist-only" ]]; then
    [[ $# == 3 ]] || usage
    resolve_identifiers_from_plist "$2"
    mkdir -p "$3"
    write_launchd_plist "$3/${LABEL}.plist"
    printf '%s\n' "$3/${LABEL}.plist"
    exit 0
fi

[[ $# == 1 || $# == 2 ]] || usage
HELPER_INFO="$1"
if [[ $# == 2 ]]; then
    APP="$2"
else
    [[ -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" ]] || die "no app given and not running inside Xcode"
    APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
fi
APP_INFO="$APP/Contents/Info.plist"
[[ -f "$APP_INFO" ]] || die "not an app bundle (no Contents/Info.plist): $APP"

resolve_identifiers_from_plist "$HELPER_INFO"

bundle_id="$(plist_string "$APP_INFO" CFBundleIdentifier)"
[[ "$bundle_id" == "$APP_BUNDLE_ID" ]] \
    || die "the app's CFBundleIdentifier is '$bundle_id' but $HELPER_INFO sets FanControlClientBundleIdentifier '$APP_BUNDLE_ID' (the helper would reject this app)"
helper_bundle_id="$(plist_string "$HELPER_INFO" CFBundleIdentifier)"
if [[ -n "$helper_bundle_id" && "$helper_bundle_id" != "$HELPER_ID" ]]; then
    printf 'warning: %s: CFBundleIdentifier %s != FanControlHelperIdentifier %s\n' "$HELPER_INFO" "$helper_bundle_id" "$HELPER_ID" >&2
fi

plutil -replace FanControlHelperIdentifier -string "$HELPER_ID" "$APP_INFO"
plutil -replace FanControlMachServiceName -string "$LABEL" "$APP_INFO"
plutil -replace FanControlClientBundleIdentifier -string "$APP_BUNDLE_ID" "$APP_INFO"
if [[ -n "$TEAM_ID" ]]; then
    plutil -replace FanControlClientTeamID -string "$TEAM_ID" "$APP_INFO"
else
    plutil -remove FanControlClientTeamID "$APP_INFO" >/dev/null 2>&1 || true
fi

DAEMONS="$APP/Contents/Library/LaunchDaemons"
mkdir -p "$DAEMONS"
write_launchd_plist "$DAEMONS/${LABEL}.plist"
for other in "$DAEMONS"/*.plist; do
    [[ "$other" == "$DAEMONS/${LABEL}.plist" ]] && continue
    printf 'warning: %s is not the FanControl LaunchDaemon (%s.plist); stale copy?\n' "$other" "$LABEL" >&2
done
printf 'FanControl identifiers: helper %s, Mach service %s, client %s%s\n' \
    "$HELPER_ID" "$LABEL" "$APP_BUNDLE_ID" "${TEAM_ID:+, Team ID $TEAM_ID}"
