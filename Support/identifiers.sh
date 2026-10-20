# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# FanControl identifiers for shell scripts (sourced, not executed). Mirrors
# Sources/FanControlXPC/FanControlIdentifiers.swift: same Info.plist keys, same defaults,
# same fallbacks, same validation (checked by FanControlXPCTests/ManualInstallScriptConsistencyTests).
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

DEFAULT_HELPER_ID="com.example.dynamicnotch.DynamicNotch.fanfi"   # FanControlIdentifiers.defaultHelperIdentifier
DEFAULT_APP_BUNDLE_ID="com.example.dynamicnotch.DynamicNotch"      # FanControlIdentifiers.defaultClientBundleIdentifier

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

# _fc_die: use the caller's die() if it exists
_fc_die() {
    if declare -F die >/dev/null; then die "$@"; else printf 'error: %s\n' "$*" >&2; exit 1; fi
}

# set_identifiers <helper-id> <mach-service-or-empty> <client-bundle-id> [<team-id>]
# Applies the fallbacks, validates and sets HELPER_ID / LABEL / APP_BUNDLE_ID / TEAM_ID.
set_identifiers() {
    local helper="$1" mach="$2" client="$3" team="${4:-}"
    [[ -n "$helper" ]] || helper="${mach:-$DEFAULT_HELPER_ID}"
    [[ -n "$mach" ]] || mach="$helper"
    [[ -n "$client" ]] || client="$DEFAULT_APP_BUNDLE_ID"
    is_identifier "$helper" || _fc_die "invalid helper identifier: '$helper'"
    is_identifier "$mach"   || _fc_die "invalid Mach service name: '$mach'"
    is_identifier "$client" || _fc_die "invalid client bundle identifier: '$client'"
    [[ "$client" != "$helper" ]] || _fc_die "the client bundle identifier and the helper identifier must differ ('$client')"
    if [[ -n "$team" ]] && ! is_team_id "$team"; then _fc_die "invalid Team ID: '$team'"; fi
    HELPER_ID="$helper"
    LABEL="$mach"
    APP_BUNDLE_ID="$client"
    TEAM_ID="$team"
}

# plist_string <plist-file> <key>: string value of a top-level key, empty if absent
plist_string() {
    plutil -extract "$2" raw -expect string -o - "$1" 2>/dev/null || true
}

# resolve_identifiers_from_plist <plist-file>: XML / binary / OpenStep plist with the
# FanControl* keys (Helper-Info.plist, an app's Info.plist, launchctl plist output).
# Missing keys use the built-in defaults (not the environment overrides).
resolve_identifiers_from_plist() {
    local f="$1"
    [[ -r "$f" ]] || _fc_die "cannot read $f"
    plutil -lint -s "$f" >/dev/null 2>&1 || _fc_die "not a property list: $f"
    set_identifiers "$(plist_string "$f" FanControlHelperIdentifier)" \
                    "$(plist_string "$f" FanControlMachServiceName)" \
                    "$(plist_string "$f" FanControlClientBundleIdentifier)" \
                    "$(plist_string "$f" FanControlClientTeamID)"
}

# embedded_info_plist <mach-o> <out-file>: writes the __TEXT,__info_plist section of a
# bare executable (what Bundle.main.infoDictionary returns in the helper) to <out-file>.
# `launchctl plist` prints it in OpenStep format with a trailing ';' that plutil rejects.
embedded_info_plist() {
    local out
    out="$(launchctl plist __TEXT,__info_plist "$1" 2>&1)" || true
    [[ "$out" == \{* ]] || _fc_die "no embedded __TEXT,__info_plist in $1 ($out)"
    printf '%s\n' "$out" | sed '$ s/};[[:space:]]*$/}/' > "$2"
    plutil -lint -s "$2" >/dev/null 2>&1 || _fc_die "cannot parse the embedded Info.plist of $1"
}

# Initial values: built-in defaults, overridable from the environment.
set_identifiers "${FANCONTROL_HELPER_IDENTIFIER:-}" "${FANCONTROL_MACH_SERVICE_NAME:-}" \
                "${FANCONTROL_CLIENT_BUNDLE_IDENTIFIER:-}"
