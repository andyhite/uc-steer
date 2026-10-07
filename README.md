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

The installer builds the app, places it in `/Applications`, and opens it.

1. Allow **uc-steer** in **System Settings → Privacy & Security → Accessibility**.
2. Click the mouse icon in the menu bar and enable **Start at Login**.
3. Configure your preferred actions in SteerMouse on each Mac. Each Mac uses its own settings—not a synced copy.

Mouse profiles match automatically by vendor and product ID. If you use Bluetooth on one Mac and a receiver on another, choose the matching SteerMouse profile from the mouse's submenu.

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

Connections are encrypted over your local network. Keep the pairing key private: anyone with it can send mouse-button actions to your Macs.

## Know before you install

**Focused support, not a full SteerMouse replacement.** uc-steer applies Mission Control, Application Windows, Desktop, Move Left a Space, and Move Right a Space to buttons **3–32**, using the receiving Mac's configured Mission Control keyboard shortcuts. Other actions pass through as plain clicks. Scroll reversal is supported when SteerMouse reverses both directions of a wheel.

It does **not** apply left/right-button mappings, scroll or cursor speed, per-app settings, or modifier+button combinations.

> **Compatibility:** The build targets macOS 13+, but the private Universal Control integration has only been investigated on macOS 27. The deployment target is not a guarantee of compatibility with older macOS releases.

<details>
<summary><strong>Updates, diagnostics & removal</strong></summary>

**Update:** Run `git pull && ./install.sh` from the repository folder on every Mac. Keep all Macs on the same version; older broadcast-based versions cannot forward to current versions. Pairing keys are retained, but when upgrading from an older broadcast-based version, select a forwarding destination to enable forwarding.

**Inspect settings and detected mice:**

```sh
/Applications/uc-steer.app/Contents/MacOS/uc-steer --check
```

**Stream logs:**

```sh
log stream --predicate 'subsystem == "com.andyhite.uc-steer"'
```

**Run regression checks:** `sh test.sh`. These do not verify multi-Mac hardware behavior.

**Uninstall:** Turn off **Start at Login**, run `./install.sh uninstall`, and remove uc-steer from **System Settings → Privacy & Security → Accessibility**.

</details>
