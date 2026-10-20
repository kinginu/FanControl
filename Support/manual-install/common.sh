# shellcheck shell=bash
# Manual-install layer shared by install.sh / uninstall.sh / status.sh (sourced, not executed):
# installed paths, the client requirement, the LaunchDaemon template and launchd queries.
# The values must match FanControl/Sources/FanControlXPC/FanControlHelperConstants.swift and
# ManualInstallMode.swift (checked by FanControlXPCTests/ManualInstallScriptConsistencyTests).
#
# Generic helpers (logging, die, run, parse_cli, require_root, resolve_app, plist and codesign
# helpers) come from ../lib.sh; the identifiers (HELPER_ID, LABEL, APP_BUNDLE_ID) from
# ../identifiers.sh: built-in defaults, overridable with FANCONTROL_HELPER_IDENTIFIER /
# FANCONTROL_MACH_SERVICE_NAME / FANCONTROL_CLIENT_BUNDLE_IDENTIFIER. Given an app, the scripts
# read them from the helper's embedded Info.plist instead (load_identifiers_from_app), so a host
# with its own identifiers needs no edits here. docs/helper.md "Configuring identifiers".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/.. source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/.. source=../identifiers.sh
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

# client_requirement <cdhash>: exactly FanControlHelperConstants.manualModeClientRequirement(cdhash:)
client_requirement() {
    printf 'identifier "%s" and cdhash H"%s"' "$APP_BUNDLE_ID" "$1"
}

# pinned_requirement <plist>: FANCONTROL_CLIENT_REQUIREMENT of a LaunchDaemon plist (empty if none)
pinned_requirement() {
    plist_string "$1" "EnvironmentVariables.${ENV_KEY}"
}

# assert_label_allowed: never install or remove a job in Apple's namespace
assert_label_allowed() {
    [[ "$LABEL" != com.apple.* ]] || die "refusing to manage a job labelled $LABEL"
}

# --- launchd -------------------------------------------------------------------------------
# loaded_service_path: "path = …" of the loaded system/$LABEL job, empty if not loaded / not readable
loaded_service_path() {
    { launchctl print "system/${LABEL}" 2>/dev/null || true; } \
        | awk '/^[[:space:]]*path = / { sub(/^[[:space:]]*path = /, ""); print; exit }'
}

is_loaded() {
    launchctl print "system/${LABEL}" >/dev/null 2>&1
}

# wait_until_unloaded: up to 5 s for system/$LABEL to disappear after a bootout
wait_until_unloaded() {
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        is_loaded || return 0
        sleep 0.5
    done
    ! is_loaded
}

# bootout_job: stops system/$LABEL if loaded (launchd sends SIGTERM; the helper hands the fans
# back to macOS before exiting). Dies if it is still loaded afterwards.
bootout_job() {
    is_loaded || return 0
    info "Stopping system/$LABEL (fans return to automatic on SIGTERM)"
    if (( DRY_RUN )); then
        run launchctl bootout "system/$LABEL"
        return 0
    fi
    launchctl bootout "system/$LABEL" || warn "launchctl bootout system/$LABEL failed (checking whether it stopped anyway)"
    wait_until_unloaded || die "system/$LABEL is still loaded after bootout"
}

# print_job_summary: the interesting lines of `launchctl print system/$LABEL`
print_job_summary() {
    local out
    if out="$(launchctl print "system/${LABEL}" 2>&1)"; then
        printf '%s\n' "$out" \
            | grep -E '^[[:space:]]*(state|path|program|pid|last exit code|runs|FANCONTROL_CLIENT_REQUIREMENT)( =|=>|:)' \
            || true
    else
        printf 'launchctl print system/%s: not loaded, or not readable without root (%s)\n' \
            "$LABEL" "$(printf '%s\n' "$out" | head -n 1)"
    fi
}

# --- Identifiers from an app ---------------------------------------------------------------
# load_identifiers_from_app <App.app>: identifiers from the helper's embedded Info.plist
# (<App>/Contents/MacOS/FanControlHelper, what the helper itself reads at runtime). Fails if
# an environment override contradicts them, or if the app's own Info.plist sets FanControl*
# keys that resolve differently (the app would then talk to another service).
load_identifiers_from_app() {
    local app="$1" helper="$1/$HELPER_IN_APP" embedded h l c t
    [[ -f "$helper" ]] || die "helper not found inside the app: $helper"
    embedded="$(fc_tmpfile embedded-helper-info.plist)"
    embedded_info_plist "$helper" "$embedded"
    resolve_identifiers_from_plist "$embedded"
    h="$HELPER_ID" l="$LABEL" c="$APP_BUNDLE_ID" t="$TEAM_ID"
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

# --- The LaunchDaemon plist ----------------------------------------------------------------
# generate_manual_plist <out-file> <client-requirement>: the template filled in for LABEL, as XML.
# Values are validated reverse-DNS identifiers / a fixed-format requirement.
generate_manual_plist() {
    local out="$1" requirement="$2"
    [[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"
    cp "$TEMPLATE" "$out"
    plutil -replace Label -string "$LABEL" "$out"
    plutil -replace Program -string "$HELPER_DEST" "$out"
    plutil -replace MachServices -json "{\"${LABEL}\":true}" "$out"
    plutil -replace "EnvironmentVariables.${ENV_KEY}" -string "$requirement" "$out"
    plutil -convert xml1 "$out"
    plutil -lint -s "$out" >/dev/null || die "generated plist is invalid"
    [[ "$(pinned_requirement "$out")" == "$requirement" ]] || die "generated plist does not contain the requirement"
    [[ "$(plist_string "$out" Label)" == "$LABEL" ]] || die "generated plist has the wrong Label"
    [[ "$(plist_string "$out" Program)" == "$HELPER_DEST" ]] || die "generated plist has the wrong Program"
    [[ "$(plutil -extract MachServices json -o - "$out" | tr -d '[:space:]')" == "{\"${LABEL}\":true}" ]] \
        || die "generated plist has the wrong MachServices"
}

# install_state <helper-src> <new-plist> [<helper-dest> <plist-dest>]: compares what install.sh
# would install with what is installed (defaults: HELPER_DEST / PLIST_DEST). Prints
#   current   both installed files are byte-identical to the new ones and root-protected
#   absent    neither file is installed
#   stale     anything else (a different build, a different pin, wrong owner/mode, one file only)
install_state() {
    local src="$1" plist="$2" hdest="${3:-$HELPER_DEST}" pdest="${4:-$PLIST_DEST}"
    if [[ ! -e "$hdest" && ! -e "$pdest" ]]; then
        echo absent
    elif same_file_contents "$src" "$hdest" && same_file_contents "$plist" "$pdest" \
        && is_root_protected "$hdest" && is_root_protected "$pdest"; then
        echo current
    else
        echo stale
    fi
}
