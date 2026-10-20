# shellcheck shell=bash
# FanControl identifiers for shell scripts (sourced, not executed). Mirrors
# Sources/FanControlXPC/FanControlIdentifiers.swift: same Info.plist keys, same defaults,
# same fallbacks, same validation (checked by FanControlXPCTests/IdentifierConfigurationConsistencyTests
# and by Tools/test-support-scripts.sh).
#
#   Info.plist key                      shell variable   fallback
#   FanControlHelperIdentifier          HELPER_ID        FanControlMachServiceName, else the default
#   FanControlMachServiceName           LABEL            HELPER_ID (launchd Label == Mach service)
#   FanControlClientBundleIdentifier    APP_BUNDLE_ID    the default
#   FanControlClientTeamID              TEAM_ID          empty
#
# Single place to change the defaults for a host without an Info.plist at hand
# (e.g. uninstall.sh): the environment variables FANCONTROL_HELPER_IDENTIFIER,
# FANCONTROL_MACH_SERVICE_NAME and FANCONTROL_CLIENT_BUNDLE_IDENTIFIER override the
# built-in defaults below. Pass them through sudo explicitly:
#   sudo FANCONTROL_MACH_SERVICE_NAME=com.acme.Notch.helper ./uninstall.sh
# Values read from an Info.plist (resolve_identifiers_from_plist) take precedence.

[[ -z "${_FC_IDENTIFIERS_LOADED:-}" ]] || return 0
_FC_IDENTIFIERS_LOADED=1

# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/.. source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DEFAULT_HELPER_ID="com.example.dynamicnotch.DynamicNotch.fanfi"   # FanControlIdentifiers.defaultHelperIdentifier
DEFAULT_APP_BUNDLE_ID="com.example.dynamicnotch.DynamicNotch"      # FanControlIdentifiers.defaultClientBundleIdentifier

# Resolved identifiers (set_identifiers); read by the scripts that source this file.
HELPER_ID=""
LABEL=""
APP_BUNDLE_ID=""
TEAM_ID=""

# is_identifier <value>: reverse-DNS identifier (FanControlIdentifiers.isValidIdentifier)
is_identifier() {
    local LC_ALL=C v="$1"
    (( ${#v} >= 1 && ${#v} <= 255 )) || return 1
    [[ "$v" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$ ]]
}

# is_team_id <value>: 10 upper-case letters / digits (FanControlIdentifiers.isValidTeamID)
is_team_id() {
    local LC_ALL=C
    [[ "$1" =~ ^[A-Z0-9]{10}$ ]]
}

# set_identifiers <helper-id> <mach-service-or-empty> <client-bundle-id> [<team-id>]
# Applies the fallbacks, validates and sets HELPER_ID / LABEL / APP_BUNDLE_ID / TEAM_ID.
set_identifiers() {
    local helper="$1" mach="$2" client="$3" team="${4:-}"
    [[ -n "$helper" ]] || helper="${mach:-$DEFAULT_HELPER_ID}"
    [[ -n "$mach" ]] || mach="$helper"
    [[ -n "$client" ]] || client="$DEFAULT_APP_BUNDLE_ID"
    is_identifier "$helper" || die "invalid helper identifier: '$helper'"
    is_identifier "$mach"   || die "invalid Mach service name: '$mach'"
    is_identifier "$client" || die "invalid client bundle identifier: '$client'"
    [[ "$client" != "$helper" ]] || die "the client bundle identifier and the helper identifier must differ ('$client')"
    if [[ -n "$team" ]] && ! is_team_id "$team"; then die "invalid Team ID: '$team'"; fi
    HELPER_ID="$helper"
    LABEL="$mach"
    APP_BUNDLE_ID="$client"
    TEAM_ID="$team"
}

# resolve_identifiers_from_plist <plist-file>: XML / binary / OpenStep plist with the
# FanControl* keys (Helper-Info.plist, an app's Info.plist, launchctl plist output).
# Missing keys use the built-in defaults (not the environment overrides).
resolve_identifiers_from_plist() {
    local f="$1" helper mach client team
    require_plist "$f"
    helper="$(plist_string "$f" FanControlHelperIdentifier)"
    mach="$(plist_string "$f" FanControlMachServiceName)"
    client="$(plist_string "$f" FanControlClientBundleIdentifier)"
    team="$(plist_string "$f" FanControlClientTeamID)"
    set_identifiers "$helper" "$mach" "$client" "$team"
}

# describe_identifiers: one line for logs
describe_identifiers() {
    printf 'helper %s, Mach service/label %s, client %s%s\n' \
        "$HELPER_ID" "$LABEL" "$APP_BUNDLE_ID" "${TEAM_ID:+, Team ID $TEAM_ID}"
}

# Initial values: built-in defaults, overridable from the environment.
set_identifiers "${FANCONTROL_HELPER_IDENTIFIER:-}" "${FANCONTROL_MACH_SERVICE_NAME:-}" \
                "${FANCONTROL_CLIENT_BUNDLE_IDENTIFIER:-}"
