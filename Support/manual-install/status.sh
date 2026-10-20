#!/bin/bash
# Read-only status of the manual (personal use) FanControlHelper installation. No root needed.
#   ./status.sh [/path/to/App.app]    # with an app: also checks that its cdhash is the pinned one
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

APP="${1:-}"
rc=0

for f in "$PLIST_DEST" "$HELPER_DEST"; do
    if [[ -e "$f" ]]; then
        printf 'present  %s  (%s)\n' "$f" "$(stat -f '%Su:%Sg %Sp' "$f")"
        [[ "$(stat -f '%u' "$f")" == 0 ]] || { warn "$f is not owned by root"; rc=1; }
    else
        printf 'missing  %s\n' "$f"
        rc=1
    fi
done

pinned=""
if [[ -r "$PLIST_DEST" ]]; then
    pinned="$(pinned_requirement "$PLIST_DEST")"
    printf 'pinned client requirement: %s\n' "${pinned:-<none>}"
    printf 'Program: %s\n' "$(plutil -extract Program raw -o - "$PLIST_DEST" 2>/dev/null || echo '?')"
fi
if [[ -e "$HELPER_DEST" ]]; then
    printf 'installed helper cdhash:   %s\n' "$(cdhash_of "$HELPER_DEST")"
fi

if [[ -n "$APP" ]]; then
    app_hash="$(cdhash_of "$APP")"
    printf 'app cdhash:                %s  (%s)\n' "$app_hash" "$APP"
    if [[ "$pinned" == "$(client_requirement "$app_hash")" ]]; then
        echo "=> the app's cdhash matches the pinned requirement"
    else
        echo "=> MISMATCH: the helper will reject this app. Re-run: sudo $(dirname "$0")/install.sh \"$APP\""
        rc=1
    fi
    helper_in_app="$APP/$HELPER_IN_APP"
    if [[ -f "$helper_in_app" && -e "$HELPER_DEST" ]] && ! cmp -s "$helper_in_app" "$HELPER_DEST"; then
        echo "note: the installed helper differs from the one inside the app (re-run install.sh to update it)"
    fi
fi

echo
if out="$(launchctl print "system/${LABEL}" 2>&1)"; then
    printf '%s\n' "$out" | grep -E '^[[:space:]]*(state|path|program|pid|last exit code|runs)( =|=>)' || true
else
    echo "launchctl print system/${LABEL}: not loaded or not readable without root ($(printf '%s' "$out" | head -n 1))"
fi
exit "$rc"
