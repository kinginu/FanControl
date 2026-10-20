#!/bin/bash
# Removes the manual (personal use) installation of FanControlHelper made by install.sh.
# The label comes from the app's embedded helper Info.plist when an app is given, otherwise from
# the defaults / FANCONTROL_* overrides (../identifiers.sh), e.g.
#   sudo FANCONTROL_MACH_SERVICE_NAME=com.acme.Notch.helper ./uninstall.sh
# launchd sends SIGTERM on bootout; the helper restores automatic fan control before exiting.
# Only touches what install.sh wrote: a LaunchDaemon plist without FANCONTROL_CLIENT_REQUIREMENT
# (another vendor's job, e.g. a mistyped label) is refused, and without our plist the helper file
# is only removed if it is signed with the helper identifier. Idempotent: with nothing installed
# it reports that and exits 0.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
    cat <<USAGE
usage: sudo $FC_PROG [--dry-run] [[--app] /path/to/App.app]

Stops and removes the FanControlHelper LaunchDaemon installed by install.sh. The app (optional)
supplies the label; without it the defaults or FANCONTROL_* environment overrides are used.

  -n, --dry-run   print what would be removed; change nothing (no root)
      --app PATH  the app (same as the positional argument)
  -h, --help      show this help
USAGE
}

parse_cli "$@"
take_app_argument
require_root

if [[ -n "$APP" ]]; then
    APP="$(resolve_app "$APP")"
    load_identifiers_from_app "$APP"
fi
assert_label_allowed
info "Label: $LABEL"

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
            warn "$HELPER_DEST is signed as '${helper_ident:-<unsigned>}', not '$HELPER_ID'; leaving it in place (remove it yourself if it is stale)."
            remove_helper=0
        fi
    fi
fi

if is_loaded; then
    bootout_job
else
    info "system/$LABEL is not loaded (or not visible without root)"
fi

targets=("$PLIST_DEST")
if (( remove_helper )); then targets+=("$HELPER_DEST"); fi
removed=0
for f in "${targets[@]}"; do
    if [[ -e "$f" || -L "$f" ]]; then
        info "Removing $f"
        run rm -f "$f"
        removed=1
    else
        info "$f not present"
    fi
done
if (( removed && DRY_RUN )); then
    info "Dry run: nothing was changed."
elif (( removed )); then
    info "Done."
else
    info "Nothing to remove."
fi
