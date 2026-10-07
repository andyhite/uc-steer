#!/bin/sh
# Builds uc-steer.app, installs it in /Applications and opens it. `./install.sh uninstall` removes it.
set -eu
cd "$(dirname "$0")"

app=/Applications/uc-steer.app
# Signing every build with the same certificate keeps uc-steer's permissions across reinstalls (see README).
identity="${CODESIGN_IDENTITY:-uc-steer dev}"

stop_app() {
    pkill -x uc-steer || true
    while pgrep -x uc-steer >/dev/null; do sleep 0.2; done
}

if [ "${1:-}" = uninstall ]; then
    stop_app
    rm -rf "$app"
    echo "Removed. Also remove uc-steer from System Settings > Privacy & Security > Accessibility."
    exit 0
fi

if ! security find-identity -p codesigning | grep -q "\"$identity\""; then
    echo "No \"$identity\" code signing certificate: signing ad hoc, so macOS asks for permissions again after every reinstall."
    identity=-
fi

# Build and sign first: a failure here leaves the installed app running and untouched.
rm -rf build
mkdir -p build/uc-steer.app/Contents/MacOS
cp Info.plist build/uc-steer.app/Contents/
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o build/uc-steer.app/Contents/MacOS/uc-steer
codesign --force --sign "$identity" build/uc-steer.app

# Stage in a private mktemp dir next to the destination (same filesystem) so the swap is two renames.
stage=$(mktemp -d "$(dirname "$app")/.uc-steer.XXXXXX")
new="$stage/new"
old="$stage/old"
stopped=0
activating=0
committed=0
cleanup() {
    rc=$?
    trap - EXIT
    if [ "$committed" = 0 ]; then
        if [ -e "$old" ]; then
            rm -rf "$app"
            if ! mv "$old" "$app"; then
                echo "Install failed and the previous version could not be restored. It is kept at $old" >&2
                exit 1
            fi
            echo "Install failed; restored the previous version." >&2
        elif [ "$activating" = 1 ]; then
            rm -rf "$app" # fresh install: nothing to restore, drop the failed app
        fi
        if [ "$rc" -ne 0 ] && [ "$stopped" = 1 ] && [ -e "$app" ]; then open "$app" || true; fi
    fi
    rm -rf "$stage"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
cp -R build/uc-steer.app "$new"

stopped=1
stop_app
if [ -e "$app" ]; then
    mv "$app" "$old"
fi
activating=1
mv "$new" "$app"
open "$app"
committed=1 # never roll back past this point; the stage dir (incl. any leftover backup) is removed by cleanup
echo "Installed $app. Its menu bar icon is a mouse. Allow Accessibility when macOS asks."
