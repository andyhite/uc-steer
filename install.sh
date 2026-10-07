#!/bin/sh
# Builds uc-steer.app, installs it in /Applications and opens it. `./install.sh uninstall` removes it.
set -eu
cd "$(dirname "$0")"

app=/Applications/uc-steer.app
# Signing every build with the same certificate keeps uc-steer's permissions across reinstalls (see README).
identity="${CODESIGN_IDENTITY:-uc-steer dev}"

pkill -x uc-steer || true
while pgrep -x uc-steer >/dev/null; do sleep 0.2; done

if [ "${1:-}" = uninstall ]; then
    rm -rf "$app"
    echo "Removed. Also remove uc-steer from System Settings > Privacy & Security > Accessibility."
    exit 0
fi

if ! security find-identity -p codesigning | grep -q "\"$identity\""; then
    echo "No \"$identity\" code signing certificate: signing ad hoc, so macOS asks for permissions again after every reinstall."
    identity=-
fi

rm -rf build
mkdir -p build/uc-steer.app/Contents/MacOS
cp Info.plist build/uc-steer.app/Contents/
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o build/uc-steer.app/Contents/MacOS/uc-steer
codesign --force --sign "$identity" build/uc-steer.app

rm -rf "$app"
cp -R build/uc-steer.app "$app"
open "$app"
echo "Installed $app. Its menu bar icon is a mouse. Allow Accessibility when macOS asks."
