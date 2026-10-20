#!/bin/bash
# Removes the manual (personal use) installation of FanControlHelper made by install.sh.
#   sudo ./uninstall.sh [--dry-run] [/path/to/App.app]
# The label comes from the app's embedded helper Info.plist when an app is given, otherwise from
# the defaults / FANCONTROL_* overrides (../identifiers.sh), e.g.
#   sudo FANCONTROL_MACH_SERVICE_NAME=com.acme.Notch.helper ./uninstall.sh
# launchd sends SIGTERM on bootout; the helper restores automatic fan control before exiting.
# Only touches what install.sh wrote: a LaunchDaemon plist without FANCONTROL_CLIENT_REQUIREMENT
# (another vendor's job, e.g. a mistyped label) is refused, and without our plist the helper file
# is only removed if it is signed with the helper identifier.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() { printf 'usage: sudo %s [--dry-run] [/path/to/App.app]\n' "$(basename "$0")" >&2; exit 64; }
DRY_RUN=0
APP=""
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        -*) usage ;;
        *) [[ -z "$APP" ]] || usage; APP="$arg" ;;
    esac
done
if [[ -n "$APP" ]]; then
    load_identifiers_from_app "$APP"
fi
info "Label: $LABEL"
run() {
    if (( DRY_RUN )); then printf '[dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
if (( ! DRY_RUN )) && [[ "$(id -u)" != 0 ]]; then
    die "must be run as root: sudo $0   (or --dry-run to preview)"
fi

[[ "$LABEL" != com.apple.* ]] || die "refusing to remove a job labelled $LABEL"

existing_path="$(loaded_service_path)"
if [[ -n "$existing_path" && "$existing_path" != "$PLIST_DEST" ]]; then
    die "system/$LABEL is loaded from '$existing_path', not from $PLIST_DEST (SMAppService?). Unregister it from the app / System Settings instead."
fi

# Same rule as install.sh: never touch a LaunchDaemon (plist, job, program) this script did not
# install. install.sh's plist always carries the client requirement.
remove_helper=1
if [[ -e "$PLIST_DEST" ]]; then
    [[ -n "$(pinned_requirement "$PLIST_DEST")" ]] \
        || die "$PLIST_DEST has no ${ENV_KEY}; it was not installed by install.sh (wrong label?). Not touching it."
else
    if is_loaded; then
        die "system/$LABEL is loaded but $PLIST_DEST is missing; not booting out a job this script cannot attribute to install.sh. Use launchctl bootout system/$LABEL yourself if it is yours."
    fi
    # No plist to vouch for it: only remove a helper signed as ours.
    if [[ -e "$HELPER_DEST" ]]; then
        helper_ident="$(signing_identifier "$HELPER_DEST")"
        if [[ "$helper_ident" != "$HELPER_ID" ]]; then
            warn "$HELPER_DEST is signed as '${helper_ident}', not '$HELPER_ID'; leaving it in place (remove it yourself if it is stale)."
            remove_helper=0
        fi
    fi
fi

if is_loaded; then
    info "Stopping system/$LABEL"
    run launchctl bootout "system/$LABEL" || warn "bootout failed (continuing)"
    if (( ! DRY_RUN )); then
        for _ in 1 2 3 4 5 6 7 8 9 10; do is_loaded || break; sleep 0.5; done
        is_loaded && warn "system/$LABEL is still loaded"
    fi
else
    info "system/$LABEL is not loaded (or not visible without root)"
fi

targets=("$PLIST_DEST")
(( remove_helper )) && targets+=("$HELPER_DEST")
for f in "${targets[@]}"; do
    if [[ -e "$f" ]]; then
        info "Removing $f"
        run rm -f "$f"
    else
        info "$f not present"
    fi
done
info "Done."
