#!/bin/sh
# Builds uc-steer and runs it at login as a LaunchAgent. `./install.sh uninstall` removes it.
set -eu
cd "$(dirname "$0")"

label=com.andyhite.uc-steer
identity="uc-steer dev"
bin="$HOME/.local/bin/uc-steer"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

launchctl bootout "$domain/$label" 2>/dev/null || true

if [ "${1:-}" = uninstall ]; then
    rm -f "$plist" "$bin"
    echo "Removed. Also delete uc-steer from System Settings > Privacy & Security > Accessibility."
    exit 0
fi

mkdir -p "$(dirname "$bin")" "$(dirname "$plist")"

# macOS ties the Accessibility permission to the code signature, so every build is signed with the same
# self-signed certificate. That keeps the permission across reinstalls.
if ! security find-identity -p codesigning | grep -q "\"$identity\""; then
    echo "Missing code signing certificate \"$identity\". Create it once in Keychain Access:"
    echo "  Keychain Access > Certificate Assistant > Create a Certificate..."
    echo "  Name: $identity / Identity Type: Self-Signed Root / Certificate Type: Code Signing"
    exit 1
fi

swiftc -O -swift-version 5 uc-steer.swift -o "$bin"
codesign --force --sign "$identity" --identifier "$label" "$bin"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>$bin</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/uc-steer.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/uc-steer.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$domain" "$plist"
echo "Installed. Allow uc-steer in System Settings > Privacy & Security > Accessibility when macOS asks."
echo "That's needed once per Mac: reinstalls are signed with the same identity and keep the permission."
echo "Log: ~/Library/Logs/uc-steer.log"
