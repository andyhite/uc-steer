# uc-steer

Makes your [SteerMouse](https://plentycom.jp/en/steermouse/) settings work for a mouse you use through
Universal Control.

SteerMouse only applies settings to mice connected to the Mac it runs on. When Universal Control moves the
pointer to another Mac, SteerMouse there can't see the mouse, so button mappings and scroll direction stop
working. Buttons that SteerMouse reads from the mouse itself, like the MX Master's gesture button, are worse:
their action still runs on the Mac the mouse is connected to.

uc-steer is a menu bar app you run on each Mac. It:

- applies that Mac's SteerMouse settings to the clicks and scrolling Universal Control forwards to it;
- sends buttons Universal Control doesn't forward to a Mac you explicitly select, over your local network.
  That Mac applies its SteerMouse settings to them too.

It works in either direction: choose a forwarding destination on whichever Mac has the mouse connected.

## Install

Needs SteerMouse and Xcode or the Command Line Tools (`swiftc`). The build targets macOS 13 or later,
but the private Universal Control integration has only been investigated on macOS 27; the deployment
target is not a compatibility guarantee for older releases. On each Mac:

1. Optional: create a code signing certificate in Keychain Access
   (`/System/Library/CoreServices/Applications/Keychain Access.app`): Certificate Assistant > Create a
   Certificate…, Name `uc-steer dev`, Identity Type Self-Signed Root, Certificate Type Code Signing. Without it,
   builds are signed ad hoc and macOS asks for permissions again after every reinstall. To use a certificate
   with another name, run `CODESIGN_IDENTITY="name" ./install.sh`.
2. `git clone https://github.com/andyhite/uc-steer.git && uc-steer/install.sh`. The script builds
   `uc-steer.app`, copies it to `/Applications` and opens it. If a keychain dialog asks to let codesign use the
   key, click Always Allow. To update later, run `git pull && ./install.sh` in the `uc-steer` folder.
3. Allow uc-steer in System Settings > Privacy & Security > Accessibility.
4. In the menu bar icon (a mouse), turn on Start at Login.

Configure the mouse in SteerMouse on every Mac you use it on. Each Mac applies its own SteerMouse settings.

Updates build, sign, and stage the replacement before stopping the installed app. The previous bundle is
kept until the replacement launches; failed replacement or launch attempts restore it. If restoration
itself fails, the installer prints the retained backup's path instead of deleting it.

## Forward the gesture button

1. On one Mac, choose Pairing Key… in the menu, then Save. Copy the key.
2. On each other Mac, choose Pairing Key…, paste the key, then Save.
3. Allow uc-steer when macOS asks to find devices on your local network.
4. On the Mac with the mouse connected, choose the receiving Mac in **Forward Gestures To**.
   The default is **Off**. Change the selection when switching Macs, and turn it **Off** for an iPad.

Destination selection is manual, not automatic pointer tracking. A selected Mac receives gesture actions
even if you move the pointer to a different remote device. No other peer receives those presses. If the
selected peer is unavailable, new presses stay local; uc-steer never substitutes another peer.
An already-forwarded press keeps its original route through release, even after changing the selection.
Disconnecting releases any pass-through clicks held by that connection.

Update **every Mac** together: the explicitly routed event format intentionally rejects older versions'
automatic broadcasts. Existing pairing keys are retained, but forwarding stays Off until you select a destination.

The menu lists the other Macs and whether they're connected. The menu bar icon dims while the pointer is on
another Mac.

Pairing-key changes take effect only after Keychain saves them successfully. A failed save or clear shows
an error and leaves the active key unchanged. Saving the same key does not reconnect peers.

Anyone with the key can make your Macs perform mouse button actions, so keep it private. Connections are
encrypted (TLS with a key derived from the pairing key).

## Choose settings for a mouse

The menu lists the mice Universal Control brings in from your other Macs. Each one uses the SteerMouse settings
for the device with the same vendor and product ID. To use another device's settings, for example when the
mouse connects to this Mac differently (Bluetooth instead of a receiver), choose it in that mouse's submenu.

## What it applies

- Buttons 3–32 (middle and auxiliary buttons): actions from SteerMouse's Mission Control group—Mission
  Control, Application Windows, Desktop, Move Left a Space, Move Right a Space. Left/right-button mappings
  are not applied. Other actions pass through as plain clicks. Each supported action uses the receiving
  Mac's keyboard shortcut (System Settings > Keyboard > Keyboard Shortcuts > Mission Control).
- Scroll direction, when SteerMouse reverses both directions of a wheel.

The same applies to forwarded buttons like the gesture button. Not applied: scroll speed, cursor speed,
per-app settings, modifier+button combinations.

## How it works

- SteerMouse's event tap matches each event's sender (undocumented CGEvent field 87, the registry ID of the HID
  service) against the mice it opened. Universal Control's copy of a remote mouse is a virtual HID service with
  no IORegistry entry, so SteerMouse ignores it. uc-steer catches those events and applies the settings itself.
- SteerMouse reads some buttons from the mouse itself (the MX Master's gesture button, over Logitech's HID++
  protocol), posts them as ordinary button events for that mouse, and maps those in its event tap. That happens
  on the Mac the mouse is connected to. The undocumented notification
  `user.uid.<uid>.com.apple.universalcontrol.inputstate` reports local HID input suppression, not the receiving
  Mac's identity. While pointer input is redirected, uc-steer forwards these buttons only to the selected Mac.
  A clear suppression bit also occurs on uninvolved Macs, so it is not used to accept incoming events.
  If the notification is unavailable, new presses stay local. The authoritative diagnostic interface requires
  Apple-private entitlements; uc-steer does not attempt to bypass them.

## Check

`/Applications/uc-steer.app/Contents/MacOS/uc-steer --check` lists the manually selected forwarding destination,
the SteerMouse settings uc-steer will apply, and the Universal Control mice on this Mac right now.

Log: `log stream --predicate 'subsystem == "com.andyhite.uc-steer"'`

Run `sh test.sh` for the focused regression checks. They build in a temporary directory and cover input
ownership without posting events, loopback-only TLS framing/reconnection, a disposable Keychain service
(with prompts disabled), and installer failure/rollback using temporary paths and stubbed system tools.
They do not install the app, change its real pairing key, or verify multi-Mac hardware behavior.

## Uninstall

Turn off Start at Login in the menu, then run `./install.sh uninstall` and remove uc-steer from System Settings
> Privacy & Security > Accessibility.
