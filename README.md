<div align="center">

# uc-steer

### Your mouse does more. Even on the other Mac.

Bring your favorite SteerMouse shortcuts and scroll direction to Universal Control.

**Native macOS menu bar app · Encrypted local connections · [MIT licensed](LICENSE)**

[Get started](#get-started) · [Gesture forwarding](#bring-your-gesture-button-along) · [Compatibility](#know-before-you-install)

</div>

---

Universal Control moves your pointer between Macs. Your [SteerMouse](https://plentycom.jp/en/steermouse/) customizations don't follow: the receiving Mac can't see the physical mouse, and special buttons can still trigger actions on the Mac you left behind.

**uc-steer bridges that gap.** Run it on each Mac to apply that Mac's supported SteerMouse settings to incoming mouse events—and send otherwise stranded gesture-button presses to the Mac you choose.

- **Keep your shortcuts close.** Open Mission Control, show the desktop, or move between Spaces with your middle and auxiliary buttons.
- **Scroll your way.** Carry over SteerMouse's scroll-direction reversal for wheels with both directions reversed.
- **Bring the gesture button along.** Forward buttons Universal Control doesn't carry, including the MX Master's gesture button.
- **Stay out of the way.** A menu bar app with Start at Login, peer connection status, and no separate mapping editor to maintain.

## Get started

You'll need **SteerMouse configured on each Mac**, working Universal Control between them, and Xcode or the Command Line Tools (`swiftc`) to build the app. Read the [compatibility note](#know-before-you-install) before installing.

Run on **each Mac**:

```sh
git clone https://github.com/andyhite/uc-steer.git
cd uc-steer
./install.sh
```

The installer builds the app, places it in `/Applications`, and opens it. It stops only your account's uc-steer processes and aborts if they do not quit within about ten seconds. Failed upgrades restore the previous app, even if rollback is interrupted again.

1. Allow **uc-steer** in **System Settings → Privacy & Security → Accessibility**.
2. Click the mouse icon in the menu bar and enable **Start at Login**.
3. Configure your preferred actions in SteerMouse on each Mac. Each Mac uses its own settings—not a synced copy.

Mouse profiles match automatically by vendor and product ID. If you use Bluetooth on one Mac and a receiver on another, choose the matching SteerMouse profile from the mouse's submenu. Profiles with the same name show their device IDs and distinct numbers; selections remember the exact SteerMouse profile rather than its name.

<details>
<summary><strong>Optional: keep permissions across reinstalls</strong></summary>

Before installing, open **Keychain Access → Certificate Assistant → Create a Certificate…** and create a certificate named `uc-steer dev`, with **Identity Type: Self-Signed Root** and **Certificate Type: Code Signing**. If codesign asks to access the key, choose **Always Allow**.

For an existing certificate with another name, use `CODESIGN_IDENTITY="name" ./install.sh`. Without a certificate, the app is signed ad hoc and macOS asks for permissions again after each reinstall.

</details>

## Bring your gesture button along

1. On one Mac, open **Pairing Key…** from the menu, save the key, and copy it.
2. On the other Macs, paste that key into **Pairing Key…** and save.
3. Allow local-network access when macOS asks.
4. On the Mac with the mouse connected, choose a destination under **Forward Gestures To**.

**You choose the destination; it doesn't track the pointer.** Forwarding defaults to **Off**. Change the destination when switching Macs, and turn it **Off** for an iPad. If the selected Mac is unavailable, new presses stay local—another Mac is never substituted.

Destinations are remembered by a persistent peer identity exchanged inside the encrypted connection, not by the Mac's Bonjour name. Renaming a Mac preserves its selection; another Mac reusing that name does not take its place. If a forwarded release is missed, the next press releases the old route before being handled normally.

Connections are encrypted over your local network. Keep the pairing key private: anyone with it can send mouse-button actions to your Macs. Stable identities prevent accidental name substitution; they are not separate credentials protecting against another holder of the same key. Each app accepts at most 32 incoming connections. Connections must complete the TLS/identity handshake within ten seconds, and each started frame must finish within ten seconds; healthy idle connections stay open.

If the keychain cannot be read, the menu offers **Retry Pairing Key…** instead of generating a replacement. Unlock the login keychain or allow access, then retry; the saved key is not changed by a read failure.

## Know before you install

**Focused support, not a full SteerMouse replacement.** uc-steer applies Mission Control, Application Windows, Desktop, Move Left a Space, and Move Right a Space to buttons **3–32**, using the receiving Mac's configured Mission Control keyboard shortcuts. Other actions pass through as plain clicks. Scroll reversal is supported when SteerMouse reverses both directions of a wheel.

It does **not** apply left/right-button mappings, scroll or cursor speed, per-app settings, or modifier+button combinations.

> **Compatibility:** The build targets macOS 13+, but the private Universal Control integration has only been investigated on macOS 27. The deployment target is not a guarantee of compatibility with older macOS releases.

<details>
<summary><strong>Updates, diagnostics & removal</strong></summary>

**Update:** Run `git pull && ./install.sh` from the repository folder on every Mac. Update all Macs together: versions without the identity handshake cannot forward to this version. Pairing keys are retained, but old name-only forwarding destinations reset to **Off**; select the intended Mac again once connected. Old profile-name overrides migrate only when the name identifies exactly one profile; ambiguous overrides reset to Automatic and should be selected again.

Temporary SteerMouse settings read failures retry on the next relevant input or menu refresh, at most once per second, even if the settings file has not changed.

**If device names disappear or controls stop:** Mouse names and vendor/product IDs come from macOS HID services. Older versions displayed missing metadata as `?`, permanently cached failed sender lookups, and could forward an unresolved device as `0000:0000`. The app now reads fresh HID clients into value snapshots about once a second, off the input callback, and invalidates them on wake/session activation. Failed or over-two-second-old snapshots are not used for input matching. A newly unresolved gesture stays local rather than being forwarded with an invented identity; it can work again once metadata returns. A missing name alone is shown as `Unknown mouse (vendor:product)`, and cannot replace a known name from another service for the same device.

**Capture an intermittent failure on both Macs:**

1. Enable **Debug Logging** in each menu before reproducing the problem. The setting persists across restarts.
2. When it happens, choose **Log Diagnostics** on each Mac **before restarting**. This records the running app's cached device data before a fresh read, raw HID metadata, settings mappings, permissions, event-tap and Universal Control input state, owned presses, and peer connections.
3. Save the recent history on each Mac, label which Mac it came from, and note the failure time and any preceding sleep, reconnect, or device switch:

   ```sh
   log show --last 30m --style compact --predicate 'subsystem == "com.andyhite.uc-steer"' > ~/Desktop/uc-steer.log
   ```

Device changes, missing/recovered metadata, tap failures and connection teardown reasons are logged by default. Debug Logging adds button-routing decisions, profile matches, discovery and connection details; these are also retained in the normal macOS unified log, subject to macOS retention. It does not log keystroke content, pointer coordinates, device serial numbers, pairing keys, or raw network payloads. Logs do include device/peer names, IDs and diagnostic paths; review them before sharing. Disable Debug Logging after capture to reduce volume.

**Inspect a fresh process's settings and detected mice:**

```sh
/Applications/uc-steer.app/Contents/MacOS/uc-steer --check
```

`--check` starts a separate process: it cannot see the running app's cached metadata, event tap, held presses, or connections. Use **Log Diagnostics** for those.

**Stream logs:**

```sh
log stream --predicate 'subsystem == "com.andyhite.uc-steer"'
```

**Run regression checks:** `sh test.sh`. This checks the entire production source set against the macOS 13 deployment target, input ownership/replay, HID metadata loss/recovery and stale background-read invalidation, profile recovery, disposable Keychain operations, loopback-only authenticated transport and resource limits, and sandboxed installer rollback. It does not install the app, post live mouse events, or verify multi-Mac hardware behavior.

**Uninstall:** Turn off **Start at Login**, run `./install.sh uninstall`, and remove uc-steer from **System Settings → Privacy & Security → Accessibility**.

</details>
