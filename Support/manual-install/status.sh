#!/bin/bash
# Read-only status of the manual (personal use) FanControlHelper installation. No root needed.
# Without an app, the label comes from the defaults / FANCONTROL_* overrides (../identifiers.sh);
# with an app, from its embedded helper's Info.plist, and the app's cdhash is checked against the
# pinned one. Exit status: 0 = installed (and, given an app, pinned to it), 1 = something to fix.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
    cat <<USAGE
usage: $FC_PROG [[--app] /path/to/App.app]

Shows the installed helper and LaunchDaemon plist, the pinned client requirement and the launchd
state. Given an app, also checks that the app's cdhash is the pinned one. Always read-only
(--dry-run is accepted and changes nothing).

      --app PATH  the app (same as the positional argument)
  -h, --help      show this help
USAGE
}

parse_cli "$@"
take_app_argument

if [[ -n "$APP" ]]; then
    APP="$(resolve_app "$APP")"
    load_identifiers_from_app "$APP"
fi
printf 'label: %s   app: %s\n' "$LABEL" "$APP_BUNDLE_ID"

rc=0
for f in "$PLIST_DEST" "$HELPER_DEST"; do
    if [[ -e "$f" ]]; then
        printf 'present  %s  (%s)\n' "$f" "$(stat -f '%Su:%Sg %Sp' "$f")"
        is_root_protected "$f" || { warn "$f is not root-owned or is writable by group/others (the app will not trust it)"; rc=1; }
    else
        printf 'missing  %s\n' "$f"
        rc=1
    fi
done

pinned=""
if [[ -r "$PLIST_DEST" ]]; then
    pinned="$(pinned_requirement "$PLIST_DEST")"
    program="$(plist_string "$PLIST_DEST" Program)"
    printf 'pinned client requirement: %s\n' "${pinned:-<none>}"
    printf 'Program: %s\n' "${program:-?}"
fi
if [[ -e "$HELPER_DEST" ]]; then
    installed_hash="$(cdhash_of "$HELPER_DEST")"
    printf 'installed helper cdhash:   %s\n' "$installed_hash"
fi

if [[ -n "$APP" ]]; then
    app_hash="$(cdhash_of "$APP")"
    printf 'app cdhash:                %s  (%s)\n' "$app_hash" "$APP"
    if [[ "$pinned" == "$(client_requirement "$app_hash")" ]]; then
        echo "=> the app's cdhash matches the pinned requirement"
    elif [[ -z "$pinned" ]]; then
        echo "=> NOT INSTALLED (no pinned requirement). Install: sudo $SCRIPT_DIR/install.sh --app \"$APP\""
        rc=1
    else
        echo "=> MISMATCH: the helper will reject this app. Re-run: sudo $SCRIPT_DIR/install.sh --app \"$APP\""
        rc=1
    fi
    helper_in_app="$APP/$HELPER_IN_APP"
    if [[ -f "$helper_in_app" && -e "$HELPER_DEST" ]] && ! cmp -s "$helper_in_app" "$HELPER_DEST"; then
        echo "note: the installed helper differs from the one inside the app (re-run install.sh to update it)"
    fi
fi

echo
print_job_summary
exit "$rc"
