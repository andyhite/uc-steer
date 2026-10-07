// uc-steer's menu bar item and settings. Input.swift handles input; Peers.swift talks to your other Macs.

import AppKit
import ServiceManagement
import notify

// MARK: Pairing key

// The secret your Macs share before they forward input to each other. Kept in the login keychain.
enum PairingKey {
    static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "uc-steer", kSecAttrAccount as String: "pairing key"]

    static func read() -> String? {
        var query = item
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String?) {
        SecItemDelete(item as CFDictionary)
        guard let key else { return }
        var query = item
        query[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { log("can't save the pairing key: \(status)") }
    }

    // 4 groups of 5 characters from an alphabet without look-alikes: 100 random bits.
    static func generate() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return (0..<4).map { _ in String((0..<5).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
    }
}

var pairingKey = PairingKey.read()

func applyPairingKey() {
    peers.start(key: pairingKey)
    forwardsActions = pairingKey != nil
    if tap != nil { startTap() }  // adds or removes keyboard and click events
}

func editPairingKey() {
    let alert = NSAlert()
    alert.messageText = "Pairing Key"
    alert.informativeText = """
        uc-steer sends SteerMouse actions for buttons Universal Control doesn't forward, like the MX Master's \
        gesture button, to your other Macs that use this key. Copy it into uc-steer on each of them, or paste \
        the key from another Mac. Clear it to turn forwarding off.
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
    pairingKey = key.isEmpty ? nil : key
    PairingKey.save(pairingKey)
    applyPairingKey()
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
        if pairingKey == nil {
            menu.addItem(menuItem("Gesture button forwarding is off"))
        } else if peers.status.isEmpty {
            menu.addItem(menuItem("No other Macs with uc-steer found"))
        }
        for peer in peers.status { menu.addItem(menuItem("\(peer.name): \(peer.state)")) }
        menu.addItem(menuItem("Pairing Key…", action: editPairingKey))

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
        let item = menuItem("\(name): \(settings(for: id)?.name ?? "none")")
        let submenu = NSMenu()
        let automatic = devices.first { $0.id == id }?.name ?? "none"
        submenu.addItem(menuItem("Automatic (\(automatic))", checked: chosen == nil) { settingsOverrides[id.key] = nil })
        submenu.addItem(.separator())
        for device in devices {
            submenu.addItem(menuItem(device.name, checked: chosen == device.name) { settingsOverrides[id.key] = device.name })
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

peers.onMessage = replay
applyPairingKey()

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
