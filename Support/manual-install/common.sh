# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# Shared constants and helpers for install.sh / uninstall.sh / status.sh (sourced, not executed).
# The values must match FanControl/Sources/FanControlXPC/FanControlHelperConstants.swift and
# ManualInstallMode.swift (checked by FanControlXPCTests/ManualInstallModeTests).

LABEL="com.example.dynamicnotch.DynamicNotch.fanfi"          # launchdLabel == machServiceName == helperIdentifier
APP_BUNDLE_ID="com.example.dynamicnotch.DynamicNotch"         # appBundleIdentifier
HELPER_IN_APP="Contents/MacOS/FanControlHelper"               # helperExecutableName inside the app
HELPER_DEST="/Library/PrivilegedHelperTools/${LABEL}"         # manualHelperPath
PLIST_DEST="/Library/LaunchDaemons/${LABEL}.plist"            # manualLaunchDaemonPlistPath
ENV_KEY="FANCONTROL_CLIENT_REQUIREMENT"                       # clientRequirementEnvironmentKey
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/${LABEL}.manual.plist"

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
