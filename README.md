# uc-steer

Makes your [SteerMouse](https://plentycom.jp/en/steermouse/) settings work for a mouse you use through
Universal Control.

SteerMouse only applies settings to mice connected to the Mac it runs on. When Universal Control moves the
pointer to another Mac, SteerMouse there can't see the mouse, so button mappings and scroll direction stop
working. Buttons that SteerMouse reads from the mouse itself, like the MX Master's gesture button, are worse:
their action still runs on the Mac the mouse is connected to.

uc-steer is a menu bar app you run on each Mac. It:

- applies that Mac's SteerMouse settings to the clicks and scrolling Universal Control forwards to it;
- sends SteerMouse's actions for the other buttons to the Mac the pointer is on, over your local network.

It works in either direction: whichever Mac the mouse is connected to sends, the Mac with the pointer acts.

## Install

Needs macOS 13 or later, SteerMouse, and Xcode or the Command Line Tools (`swiftc`). On each Mac:

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

## Forward the gesture button

1. On one Mac, choose Pairing Key… in the menu, then Save. Copy the key.
2. On each other Mac, choose Pairing Key…, paste the key, then Save.
3. Allow uc-steer when macOS asks to find devices on your local network.

The menu lists the other Macs and whether they're connected. The menu bar icon dims while the pointer is on
another Mac.

Anyone with the key can make your Macs perform mouse and keyboard input, so keep it private. Connections are
encrypted (TLS with a key derived from the pairing key).

## Choose settings for a mouse

The menu lists the mice Universal Control brings in from your other Macs. Each one uses the SteerMouse settings
for the device with the same vendor and product ID. To use another device's settings, for example when the
mouse connects to this Mac differently (Bluetooth instead of a receiver), choose it in that mouse's submenu.

## What it applies

- Button actions from SteerMouse's Mission Control group: Mission Control, Application Windows, Desktop,
  Move Left a Space, Move Right a Space. Other actions pass through as plain clicks.
- Scroll direction, when SteerMouse reverses both directions of a wheel.
- Forwarded actions that SteerMouse performs with keystrokes, clicks or scrolling. A forwarded shortcut does
  whatever that shortcut does on the receiving Mac.

Not applied: scroll speed, cursor speed, per-app settings, modifier+button combinations, and forwarded actions
that SteerMouse performs another way, like opening an app or a URL. Those still run on the Mac the mouse is
connected to.

## How it works

- SteerMouse's event tap matches each event's sender (undocumented CGEvent field 87, the registry ID of the HID
  service) against the mice it opened. Universal Control's copy of a remote mouse is a virtual HID service with
  no IORegistry entry, so SteerMouse ignores it. uc-steer catches those events and applies the settings itself.
- Universal Control publishes where the pointer is in an undocumented notification,
  `user.uid.<uid>.com.apple.universalcontrol.inputstate`. While the pointer is on another Mac, uc-steer drops
  the input events SteerMouse posts and sends them to the other Macs, and the Mac with the pointer posts them.
  If Apple removes that notification, forwarding stops and actions run where the mouse is connected.

## Check

`/Applications/uc-steer.app/Contents/MacOS/uc-steer --check` lists the SteerMouse settings uc-steer will apply
and the Universal Control mice on this Mac right now.

Log: `log stream --predicate 'subsystem == "com.andyhite.uc-steer"'`

## Uninstall

Turn off Start at Login in the menu, then run `./install.sh uninstall` and remove uc-steer from System Settings
> Privacy & Security > Accessibility.
