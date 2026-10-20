# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# Shared constants and helpers for install.sh / uninstall.sh / status.sh (sourced, not executed).
# The values must match FanControl/Sources/FanControlXPC/FanControlHelperConstants.swift and
# ManualInstallMode.swift (checked by FanControlXPCTests/ManualInstallModeTests).
#
# Identifiers (HELPER_ID, LABEL, APP_BUNDLE_ID) come from ../identifiers.sh: built-in defaults,
# overridable with FANCONTROL_HELPER_IDENTIFIER / FANCONTROL_MACH_SERVICE_NAME /
# FANCONTROL_CLIENT_BUNDLE_IDENTIFIER. Given an app, the scripts read them from the helper's
# embedded Info.plist instead (load_identifiers_from_app), so a host with its own identifiers
# needs no edits here. docs/helper.md "Configuring identifiers".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR/.. source=identifiers.sh
source "${SCRIPT_DIR}/../identifiers.sh"

HELPER_IN_APP="Contents/MacOS/FanControlHelper"               # helperExecutableName inside the app
ENV_KEY="FANCONTROL_CLIENT_REQUIREMENT"                       # clientRequirementEnvironmentKey
TEMPLATE="${SCRIPT_DIR}/FanControlHelper.manual.plist"

# apply_paths: derive the installed paths from LABEL (call after the identifiers change)
apply_paths() {
    HELPER_DEST="/Library/PrivilegedHelperTools/${LABEL}"     # manualHelperPath
    PLIST_DEST="/Library/LaunchDaemons/${LABEL}.plist"        # manualLaunchDaemonPlistPath
}
apply_paths

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*"; }

# client_requirement <cdhash>: exactly FanControlHelperConstants.manualModeClientRequirement(cdhash:)
client_requirement() {
    printf 'identifier "%s" and cdhash H"%s"' "$APP_BUNDLE_ID" "$1"
}

# is_cdhash <value>: 40 lower-case hex digits
is_cdhash() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# signing_identifier <path>: the "Identifier=" of the code signature
signing_identifier() {
    codesign -dvvv "$1" 2>&1 | sed -n 's/^Identifier=//p' | head -n 1
}

# cdhash_of <path-to-code>: cdhash of the slice the host runs (codesign -dvvv "CDHash=").
# Thin binaries: that slice. Universal binaries: the host architecture's slice is picked
# explicitly with --arch; if the host architecture is missing, fail.
cdhash_of() {
    local code="$1" exe="$1" archs host count hash
    if [[ -d "$code" ]]; then
        local name
        name="$(plutil -extract CFBundleExecutable raw -o - "$code/Contents/Info.plist" 2>/dev/null)" \
            || die "cannot read CFBundleExecutable from $code/Contents/Info.plist"
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
    local out
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
    xml="$(codesign -d --entitlements - --xml "$1" 2>/dev/null | tr -d '[:space:]')" || return 1
    [[ "$xml" == *"<key>$2</key><true/>"* ]]
}

# pinned_requirement <plist>: FANCONTROL_CLIENT_REQUIREMENT of a LaunchDaemon plist (empty if none)
pinned_requirement() {
    plutil -extract "EnvironmentVariables.${ENV_KEY}" raw -o - "$1" 2>/dev/null || true
}

# loaded_service_path: "path = …" of the loaded system/$LABEL job, empty if not loaded / not readable
loaded_service_path() {
    { launchctl print "system/${LABEL}" 2>/dev/null || true; } | sed -n 's/^[[:space:]]*path = //p' | head -n 1
}

is_loaded() {
    launchctl print "system/${LABEL}" >/dev/null 2>&1
}

# load_identifiers_from_app <App.app>: identifiers from the helper's embedded Info.plist
# (<App>/Contents/MacOS/FanControlHelper, what the helper itself reads at runtime). Fails if
# an environment override contradicts them, or if the app's own Info.plist sets FanControl*
# keys that resolve differently (the app would then talk to another service).
load_identifiers_from_app() {
    local app="$1" helper="$1/$HELPER_IN_APP" tmp
    [[ -f "$helper" ]] || die "helper not found inside the app: $helper"
    tmp="$(mktemp -t fanfi-ids)"
    embedded_info_plist "$helper" "$tmp"
    resolve_identifiers_from_plist "$tmp"
    rm -f "$tmp"
    local h="$HELPER_ID" l="$LABEL" c="$APP_BUNDLE_ID" t="$TEAM_ID"
    [[ -z "${FANCONTROL_HELPER_IDENTIFIER:-}" || "$FANCONTROL_HELPER_IDENTIFIER" == "$h" ]] \
        || die "FANCONTROL_HELPER_IDENTIFIER=$FANCONTROL_HELPER_IDENTIFIER, but the helper's Info.plist says $h"
    [[ -z "${FANCONTROL_MACH_SERVICE_NAME:-}" || "$FANCONTROL_MACH_SERVICE_NAME" == "$l" ]] \
        || die "FANCONTROL_MACH_SERVICE_NAME=$FANCONTROL_MACH_SERVICE_NAME, but the helper's Info.plist says $l"
    [[ -z "${FANCONTROL_CLIENT_BUNDLE_IDENTIFIER:-}" || "$FANCONTROL_CLIENT_BUNDLE_IDENTIFIER" == "$c" ]] \
        || die "FANCONTROL_CLIENT_BUNDLE_IDENTIFIER=$FANCONTROL_CLIENT_BUNDLE_IDENTIFIER, but the helper's Info.plist says $c"
    # The app resolves its own Info.plist with the same rules (FanControlIdentifiers).
    resolve_identifiers_from_plist "$app/Contents/Info.plist"
    if [[ "$HELPER_ID|$LABEL|$APP_BUNDLE_ID" != "$h|$l|$c" ]]; then
        die "the app's Info.plist resolves to helper '$HELPER_ID', service '$LABEL', client '$APP_BUNDLE_ID', but the embedded helper's to '$h', '$l', '$c'. Set the same FanControl* keys in both (Support/embed-helper-config.sh)."
    fi
    set_identifiers "$h" "$l" "$c" "$t"
    apply_paths
}
