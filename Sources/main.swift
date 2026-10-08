// uc-steer's menu bar item and settings. Input.swift handles input; Peers.swift talks to your other Macs.

import AppKit
import ServiceManagement
import notify

// MARK: Pairing key

var pairingKey: String?
var pairingKeyError: Error?

@discardableResult func reloadPairingKey() -> Bool {
    do {
        let key = try PairingKey.read()
        pairingKeyError = nil
        if key != pairingKey {
            pairingKey = key
            peers.start(key: key)
        }
        return true
    } catch {
        pairingKeyError = error
        log("can't read the pairing key: \(error.localizedDescription)")
        return false
    }
}

func editPairingKey() {
    // Never offer a replacement for a key we could not read, including after a rebuild or unlock.
    while !reloadPairingKey() {
        let failure = NSAlert()
        failure.messageText = "Couldn't read the pairing key"
        failure.informativeText = "\(pairingKeyError!.localizedDescription)\nUnlock the login keychain or allow access, then retry. Your saved key has not been changed."
        failure.addButton(withTitle: "Retry")
        failure.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard failure.runModal() == .alertFirstButtonReturn else { return }
    }
    let alert = NSAlert()
    alert.messageText = "Pairing Key"
    alert.informativeText = """
        uc-steer sends buttons Universal Control doesn't forward, like the MX Master's gesture button, to a Mac \
        you choose. Pairing with this key only authorizes Macs that share it; nothing is forwarded until you pick \
        a destination under "Forward Gestures To" in the menu (default Off). Copy the key into uc-steer on each \
        Mac, or paste it from another. Change the destination when switching Macs, and choose Off for an iPad. \
        Clear the key to turn forwarding off.
        """
    let field = NSTextField(string: pairingKey ?? PairingKey.generate())
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let new = key.isEmpty ? nil : key
    let status = PairingKey.save(new)
    guard status == errSecSuccess else {
        log("can't save the pairing key: \(status)")
        let failure = NSAlert()
        failure.messageText = "Couldn't save the pairing key"
        failure.informativeText = "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown"). The previous key is still in use."
        failure.runModal()
        return
    }
    guard new != pairingKey else { return }
    pairingKey = new
    peers.start(key: new)
}

func toggleStartAtLogin() {
    let login = SMAppService.mainApp
    do {
        if login.status == .enabled { try login.unregister() } else { try login.register() }
    } catch {
        log("can't change Start at Login: \(error)")
    }
    if login.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: Menu

// Runs a closure from a menu item.
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

// An item without an action shows as a disabled label.
func menuItem(_ title: String, checked: Bool = false, action: (() -> Void)? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    if let action {
        let target = MenuAction(action)
        item.target = target
        item.action = #selector(MenuAction.fire)
        item.representedObject = target  // menu items hold their target weakly
    }
    item.state = checked ? .on : .off
    return item
}

final class StatusMenu: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var inputStateWatch: Int32 = 0

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "uc-steer")
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        // The icon dims while the pointer is on another Mac.
        notify_register_dispatch(inputStateName, &inputStateWatch, .main) { [weak self] _ in self?.updateIcon() }
        updateIcon()
    }

    func updateIcon() { statusItem.button?.appearsDisabled = !pointerIsHere() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        reloadSettingsIfChanged()
        let mice = remoteMice()
        menu.addItem(menuItem(mice.isEmpty ? "No mice from other Macs" : "Mice from other Macs use the SteerMouse settings for:"))
        for mouse in mice { menu.addItem(settingsItem(mouse.name, mouse.id)) }

        menu.addItem(.separator())
        if pairingKeyError != nil {
            menu.addItem(menuItem("Pairing key unavailable — retry Pairing Key…"))
        }
        if pairingKey == nil && pairingKeyError == nil {
            menu.addItem(menuItem("Gesture button forwarding is off"))
        } else if pairingKey != nil {
            let peerStatus = peers.status
            if peerStatus.isEmpty { menu.addItem(menuItem("No other Macs with uc-steer found")) }
            for peer in peerStatus { menu.addItem(menuItem("\(peer.name): \(peer.state)")) }
            let selected = forwardingDestination
            let live = selected.flatMap { id in peerStatus.first { $0.id == id } }
            let note = live?.name ?? (selected == nil ? "Off" : "Selected Mac (unavailable)")
            let root = NSMenuItem(title: "Forward Gestures To: \(note)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(menuItem("Off", checked: selected == nil) { forwardingDestination = nil })
            for peer in peerStatus {
                if let id = peer.id {
                    sub.addItem(menuItem("\(peer.name): \(peer.state)", checked: selected == id) {
                        forwardingDestination = id
                    })
                } else {
                    sub.addItem(menuItem("\(peer.name): \(peer.state)"))
                }
            }
            if selected != nil, live == nil {
                sub.addItem(menuItem("Selected Mac (unavailable)", checked: true))
            }
            root.submenu = sub
            menu.addItem(root)
        }
        menu.addItem(menuItem(pairingKeyError == nil ? "Pairing Key…" : "Retry Pairing Key…", action: editPairingKey))

        menu.addItem(.separator())
        if tap == nil {
            menu.addItem(menuItem("Allow Accessibility…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
        }
        menu.addItem(menuItem("Start at Login", checked: SMAppService.mainApp.status == .enabled, action: toggleStartAtLogin))
        menu.addItem(menuItem("Quit uc-steer") { NSApp.terminate(nil) })
    }

    // "<mouse>: <SteerMouse device>", with a submenu to choose which SteerMouse device's settings it uses.
    func settingsItem(_ name: String, _ id: DeviceID) -> NSMenuItem {
        let chosen = settingsOverrides[id.key]
        let item = menuItem("\(name): \(settings(for: id)?.label ?? "none")")
        let submenu = NSMenu()
        let automatic = devices.first { $0.id == id }?.label ?? "none"
        submenu.addItem(menuItem("Automatic (\(automatic))", checked: chosen == nil) { settingsOverrides[id.key] = nil })
        submenu.addItem(.separator())
        for device in devices {
            submenu.addItem(menuItem(device.label, checked: chosen == device.profileID) { settingsOverrides[id.key] = device.profileID })
        }
        item.submenu = submenu
        return item
    }
}

// MARK: Main

setvbuf(stdout, nil, _IOLBF, 0)
if CommandLine.arguments.contains("--check") { check(); exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Without a main menu, the pairing key field gets no ⌘X/⌘C/⌘V/⌘A.
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
app.mainMenu = NSMenu()
app.mainMenu?.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu
let statusMenu = StatusMenu()

peers.onMessage = { replay($0, from: $1) }
peers.onDisconnect = disconnectPeer
reloadPairingKey()
let terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                 object: app, queue: .main) { _ in
    peers.start(key: nil) // Release replayed clicks before exiting; remote peers clean up on EOF.
}

let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
if AXIsProcessTrustedWithOptions(prompt) {
    startTap()
} else {
    log("waiting for Accessibility permission: System Settings > Privacy & Security > Accessibility > uc-steer")
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
        if AXIsProcessTrusted() { timer.invalidate(); startTap() }
    }
}
app.run()
