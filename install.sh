#!/bin/zsh
# Install a verified build, waiting for the destination app to quit if needed.
set -eu
cd "${0:A:h}"
source_app="${CONVERSE_APP_OUTPUT:-$PWD/.build/Converse.app}"
source_app="${source_app:A}"
destination="${1:-$HOME/Applications/Converse.app}"
destination="${destination:A}"
[[ "$destination" == *.app ]] || { print -u2 'Destination must end in .app'; exit 1; }
[[ "$source_app" != "$destination" ]] || { print -u2 'Build and installation paths must differ'; exit 1; }
# launchd has a different macOS privacy identity from the interactive app.
# A background replacement in a protected folder may be denied after quit.
case "$destination" in
    "$HOME/Documents/"*|"$HOME/Desktop/"*|"$HOME/Downloads/"*)
        if ps -axo comm= | /usr/bin/grep -Fxq "$destination/Contents/MacOS/Converse"; then
            print -u2 'Cannot queue a reliable background update inside Documents, Desktop or Downloads.'
            print -u2 'Install into ~/Applications/Converse.app instead, then quit and open that copy.'
            exit 2
        fi ;;
esac
codesign --verify --deep --strict "$source_app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")
root="$HOME/Library/Application Support/Converse Updates"
mkdir -p "$root"
chmod 700 "$root"
job=$(mktemp -d "$root/install.XXXXXXXX")
ditto --norsrc --noextattr "$source_app" "$job/Converse.app"
codesign --verify --deep --strict "$job/Converse.app"
source_digest=$(shasum -a 256 "$source_app/Contents/MacOS/Converse" | cut -d ' ' -f 1)
dock_command=$(command -v dockutil || true)
dock_label=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$source_app/Contents/Info.plist")
label="local.converse.install.${job:t}"
helper="$job/install.command"
{
    print '#!/bin/zsh'
    print 'set -eu'
    printf 'destination=%q\njob=%q\nexpected=%q\nversion=%q\ndock_command=%q\ndock_label=%q\n' "$destination" "$job" "$source_digest" "$version" "$dock_command" "$dock_label"
    cat <<'HELPER'
status_file="$job/status.txt"
fail() { print -r -- "FAILED: $1" > "$status_file"; exit 1; }
trap 'fail "Installer stopped; see install.log. The previous app is retained in this update folder if replacement began."' ZERR
trap 'rm -f "$job/agent.plist"' EXIT
print -r -- "WAITING: Converse $version is staged for $destination" > "$status_file"
# Only replace a bundle after every process using its executable has exited.
while ps -axo comm= | /usr/bin/grep -Fxq "$destination/Contents/MacOS/Converse"; do sleep 1; done
sleep 1
while ps -axo comm= | /usr/bin/grep -Fxq "$destination/Contents/MacOS/Converse"; do sleep 1; done
codesign --verify --deep --strict "$job/Converse.app"
actual=$(shasum -a 256 "$job/Converse.app/Contents/MacOS/Converse" | cut -d ' ' -f 1)
[[ "$actual" == "$expected" ]] || fail 'Staged build changed before installation'
mkdir -p "${destination:h}"
if [[ -e "$destination" ]]; then
    mv "$destination" "$job/Previous Converse.app"
fi
if ! mv "$job/Converse.app" "$destination"; then
    [[ ! -e "$job/Previous Converse.app" ]] || mv "$job/Previous Converse.app" "$destination"
    fail 'Could not replace the app; previous version restored'
fi
if ! codesign --verify --deep --strict "$destination"; then
    mv "$destination" "$job/Failed Converse.app"
    [[ ! -e "$job/Previous Converse.app" ]] || mv "$job/Previous Converse.app" "$destination"
    fail 'Installed signature check failed; previous version restored'
fi
# Keep an existing Converse shortcut pointed at the installed build. The
# supported Dock management CLI preserves the existing item's position.
if [[ -n "$dock_command" && -x "$dock_command" ]]; then
    dock_url=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).as_uri() + "/")' "$destination")
    current_dock=$($dock_command --list | awk -F '\t' -v label="$dock_label" '$1 == label {print $2}')
    if [[ -n "$current_dock" && "$current_dock" != "$dock_url" ]]; then
        if ! "$dock_command" --add "$destination" --replacing "$dock_label"; then
            print -r -- "INSTALLED: Converse $version at $destination; SHORTCUT REPAIR FAILED" > "$status_file"
            exit 1
        fi
        current_dock=$($dock_command --list | awk -F '\t' -v label="$dock_label" '$1 == label {print $2}')
        if [[ "$current_dock" != "$dock_url" ]]; then
            print -r -- "INSTALLED: Converse $version at $destination; SHORTCUT TARGET NOT VERIFIED" > "$status_file"
            exit 1
        fi
    fi
else
    print 'Dock shortcut was not verified automatically (dockutil unavailable).'
fi
print -r -- "INSTALLED: Converse $version at $destination" > "$status_file"
rm -f "$job/agent.plist"
HELPER
} > "$helper"
chmod 700 "$helper"
if ps -axo comm= | /usr/bin/grep -Fxq "$destination/Contents/MacOS/Converse"; then
    python3 - "$label" "$helper" "$job" <<'PY'
import plistlib, sys
from pathlib import Path
label, helper, job = sys.argv[1:]
Path(job, 'agent.plist').write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=['/bin/zsh',helper],RunAtLoad=True,ProcessType='Background',StandardOutPath=job+'/install.log',StandardErrorPath=job+'/install.log')))
PY
    launchctl bootstrap "gui/$(id -u)" "$job/agent.plist"
    print -r -- "Update queued. Quit Converse normally, wait a few seconds, then reopen it."
else
    /bin/zsh "$helper" > "$job/install.log" 2>&1
fi
print -r -- "Update status: $job/status.txt"
print -r -- "Previous app backup: $job/Previous Converse.app"
