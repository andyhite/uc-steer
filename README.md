# uc-steer

Applies your SteerMouse settings to a mouse you use through Universal Control.

SteerMouse only applies settings to mice plugged into the Mac it runs on. When Universal Control moves the
pointer to your other Mac, SteerMouse there can't see the mouse, so your button mappings and scroll direction
stop working. uc-steer runs on that Mac, reads its SteerMouse settings for the mouse, and applies them to the
input Universal Control forwards.

## What it applies

- Button actions from SteerMouse's Mission Control group: Mission Control, Application Windows, Desktop,
  Move Left a Space, Move Right a Space.
- Scroll direction, when SteerMouse reverses both directions of a wheel.

Other button actions and scroll remaps pass through unchanged, with one line in the log. Not applied: scroll
speed, cursor speed, per-app settings, modifier+button combos.

Universal Control never forwards the MX Master's gesture button, so its action still runs on the Mac the mouse
is plugged into.

## Install

Needs Xcode or the Command Line Tools (`swiftc`). On each Mac:

1. Create a code signing certificate once in Keychain Access
   (`/System/Library/CoreServices/Applications/Keychain Access.app`): Certificate Assistant > Create a
   Certificate…, Name `uc-steer dev`, Identity Type Self-Signed Root, Certificate Type Code Signing.
2. Run `./install.sh`.
3. If a keychain dialog asks to let codesign use the key, click Always Allow.
4. Allow uc-steer when macOS asks for Accessibility permission.

Every build is signed with that certificate, so reinstalls keep the permission. When the certificate expires
(365 days by default), create a new one with the same name, reinstall, and allow uc-steer again.

uc-steer only acts on input that arrives through Universal Control, so it does nothing on the Mac the mouse is
plugged into.

## Check

`~/.local/bin/uc-steer --check` lists the SteerMouse settings uc-steer will apply and the Universal Control
devices on this Mac right now. Log: `~/Library/Logs/uc-steer.log`.

## Uninstall

`./install.sh uninstall`, then remove uc-steer from System Settings > Privacy & Security > Accessibility.
