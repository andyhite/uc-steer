// uc-steer makes SteerMouse settings work for a mouse used through Universal Control.
//
// Clicks and scrolling: SteerMouse only applies settings to mice connected to this Mac. Its event tap matches
// each event's sender (undocumented CGEvent field 87: the registry ID of the HID service that sent it) against
// the devices it has opened. Universal Control delivers the other Mac's mouse as a virtual HID service that has
// no IORegistry entry, so SteerMouse lets that input through untouched. uc-steer catches it, finds the
// SteerMouse settings for that device, and applies them itself.
//
// Buttons Universal Control never sees: SteerMouse reads some buttons from the mouse itself (the MX Master's
// gesture button, over Logitech's HID++ protocol), posts them as ordinary button events for that mouse, and maps
// those in its event tap, on the Mac the mouse is connected to, wherever the pointer is. While the pointer is on
// another Mac, uc-steer takes those button events before SteerMouse maps them and sends them to uc-steer on your
// other Macs (Peers.swift). The Mac with the pointer applies its own SteerMouse settings to them.

import AppKit
import CoreData
import IOKit.hid
import notify
import os

// Private SkyLight functions. SteerMouse uses the same ones to trigger Mission Control shortcuts.
@_silgen_name("CGSGetSymbolicHotKeyValue")
func CGSGetSymbolicHotKeyValue(_ hotKey: Int32, _ character: UnsafeMutablePointer<UInt16>,
                               _ keyCode: UnsafeMutablePointer<UInt16>, _ modifiers: UnsafeMutablePointer<UInt64>) -> Int32
@_silgen_name("CGSIsSymbolicHotKeyEnabled")
func CGSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32

let senderField = CGEventField(rawValue: 87)!
let store = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/SteerMouse & CursorSense/Device.smsetting")
let steerMouseManager = "jp.plentycom.boa.SteerMouse"  // bundle ID of the SteerMouse process that performs actions

// SteerMouse "Mission Control" actions, and the system shortcut (symbolic hotkey ID) each one presses.
let missionOps: [String: Int32] = [
    "Mission Control": 32, "Application Windows": 33, "Desktop": 36,
    "Move Left a Space": 79, "Move Right a Space": 81,
]

struct DeviceID: Hashable {
    let vendor: Int, product: Int
    var key: String { String(format: "%04x:%04x", vendor, product) }
}
struct Device {
    let name: String
    let id: DeviceID
    let actions: [Int: [String: Any]]  // button bit (1 << CGEvent button number) -> SteerMouse action
    let flipVertical: Bool, flipHorizontal: Bool  // SteerMouse reverses this scroll axis
}
struct Failure: Error, CustomStringConvertible { let description: String }

let logger = Logger(subsystem: "com.andyhite.uc-steer", category: "uc-steer")
// To the unified log (`log stream --predicate 'subsystem == "com.andyhite.uc-steer"'`), and stdout for --check.
func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    print(message)
}
var loggedOnce = Set<String>()
func logOnce(_ message: String) { if loggedOnce.insert(message).inserted { log(message) } }

// MARK: SteerMouse settings

func loadSettings() throws -> [Device] {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "jp.plentycom.app.SteerMouse"),
          let model = NSManagedObjectModel(contentsOf: app.appendingPathComponent("Contents/Resources/Device.momd"))
    else { throw Failure(description: "SteerMouse is not installed") }
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try coordinator.addPersistentStore(ofType: NSBinaryStoreType, configurationName: nil, at: store,
                                       options: [NSReadOnlyPersistentStoreOption: true])
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator

    var devices: [Device] = []
    for device in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Device")) {
        guard let vendor = device.value(forKey: "vid") as? Int, let product = device.value(forKey: "pid") as? Int,
              device.value(forKey: "actionDisabled") as? Bool != true else { continue }
        // ponytail: default settings only; per-app settings and modifier+button combos are skipped
        let apps = device.value(forKey: "applications") as? Set<NSManagedObject> ?? []
        guard let defaults = apps.first(where: { $0.value(forKey: "bundleID") == nil }) else { continue }
        var actions: [Int: [String: Any]] = [:]
        var wheelDirections: [String: String] = [:]  // e.g. "Roll Up" -> "Down"
        for action in defaults.value(forKey: "actions") as? Set<NSManagedObject> ?? [] {
            guard ((action.value(forKey: "modkeys") as? Int) ?? 0) == 0,
                  let function = action.value(forKey: "func") as? [String: Any] else { continue }
            if let wheel = action.value(forKey: "scroll") as? String {
                if function["Selector"] as? String != "Scroll" {
                    logOnce("SteerMouse wheel action \"\(wheel)\" isn't supported; scrolling passes through")
                } else if let direction = function["Scroll Direction"] as? String {
                    wheelDirections[wheel] = direction
                }
            } else if let bit = action.value(forKey: "button") as? Int, bit > 0 {
                actions[bit] = function
            }
        }
        let name = device.value(forKey: "registryName") as? String ?? "?"
        let horizontal = device.value(forKey: "hScrollOp") as? String == "Roll" ? "Roll" : "Tilt"
        let flipVertical = reversesAxis(wheelDirections, "Roll Up", "Up", "Roll Down", "Down", device: name)
        let flipHorizontal = reversesAxis(wheelDirections, "\(horizontal) Left", "Left", "\(horizontal) Right", "Right", device: name)
        if !actions.isEmpty || flipVertical || flipHorizontal {
            devices.append(Device(name: name, id: DeviceID(vendor: vendor, product: product), actions: actions,
                                  flipVertical: flipVertical, flipHorizontal: flipHorizontal))
        }
    }
    return devices.sorted { $0.name < $1.name }
}

// True when SteerMouse reverses both directions of one wheel axis. Other remaps (one direction only, or onto
// the other axis) aren't supported.
func reversesAxis(_ directions: [String: String], _ wheelA: String, _ a: String, _ wheelB: String, _ b: String,
                  device: String) -> Bool {
    let (toA, toB) = (directions[wheelA] ?? a, directions[wheelB] ?? b)
    if toA == b && toB == a { return true }
    if toA != a || toB != b {
        logOnce("\(device): SteerMouse scroll setting \(wheelA) -> \(toA), \(wheelB) -> \(toB) isn't supported")
    }
    return false
}

var devices: [Device] = []
var settingsDate: Date? = .distantPast

func reloadSettingsIfChanged() {
    let date = (try? FileManager.default.attributesOfItem(atPath: store.path))?[.modificationDate] as? Date
    guard date != settingsDate else { return }
    settingsDate = date
    do {
        devices = try loadSettings()
        log("loaded SteerMouse settings for: " + devices.map(\.name).joined(separator: ", "))
    } catch {
        devices = []
        log("can't read SteerMouse settings: \(error)")
    }
}

// The SteerMouse device whose settings each Universal Control mouse uses, keyed by DeviceID.key. Chosen in the
// menu. Mice without an entry use the SteerMouse device with the same vendor and product ID.
var settingsOverrides = UserDefaults.standard.dictionary(forKey: "settingsOverrides") as? [String: String] ?? [:] {
    didSet { UserDefaults.standard.set(settingsOverrides, forKey: "settingsOverrides") }
}

func settings(for id: DeviceID) -> Device? {
    if let name = settingsOverrides[id.key], let device = devices.first(where: { $0.name == name }) { return device }
    return devices.first { $0.id == id }
}

// The action's name, and the symbolic hotkey for it if uc-steer supports the action.
func describe(_ action: [String: Any]) -> (name: String, hotKey: Int32?) {
    let selector = action["Selector"] as? String ?? "?"
    let name = action["Mission Op"] as? String ?? selector
    return (name, selector == "Mission Control" ? missionOps[name] : nil)
}

// MARK: Universal Control devices

let hidClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
var senderDevices: [Int64: DeviceID?] = [:]  // nil: a device connected to this Mac, or unknown

// Universal Control's virtual devices exist only in the HID event system, not in the IORegistry.
func isVirtual(_ registryID: UInt64) -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
    if service != 0 { IOObjectRelease(service) }
    return service == 0
}

func hidServices() -> [IOHIDServiceClient] { (IOHIDEventSystemClientCopyServices(hidClient) as? [IOHIDServiceClient]) ?? [] }
func registryID(_ service: IOHIDServiceClient) -> UInt64 { (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0 }
func property<T>(_ service: IOHIDServiceClient, _ key: String) -> T? { IOHIDServiceClientCopyProperty(service, key as CFString) as? T }

// Vendor and product ID of the HID service with this registry ID, the sender CGEvent field 87 holds.
func deviceID(sender: Int64) -> DeviceID? {
    guard sender > 0, let service = hidServices().first(where: { registryID($0) == UInt64(sender) }),
          let vendor: Int = property(service, kIOHIDVendorIDKey), let product: Int = property(service, kIOHIDProductIDKey)
    else { return nil }
    return DeviceID(vendor: vendor, product: product)
}

// The Universal Control device that sent an event, if one did.
func remoteDevice(sender: Int64) -> DeviceID? {
    if let known = senderDevices[sender] { return known }
    let id = sender > 0 && isVirtual(UInt64(sender)) ? deviceID(sender: sender) : nil
    senderDevices[sender] = .some(id)
    return id
}

// Universal Control's copies of your other Macs' mice, one per vendor and product ID.
func remoteMice() -> [(name: String, id: DeviceID)] {
    var mice: [DeviceID: String] = [:]
    for service in hidServices() where property(service, kIOHIDPrimaryUsagePageKey) == kHIDPage_GenericDesktop
        && property(service, kIOHIDPrimaryUsageKey) == kHIDUsage_GD_Mouse
        && property(service, kIOHIDTransportKey) != "UniversalControl"  // Universal Control's own pointer
        && isVirtual(registryID(service)) {
        let id = DeviceID(vendor: property(service, kIOHIDVendorIDKey) ?? 0, product: property(service, kIOHIDProductIDKey) ?? 0)
        let product: String = property(service, kIOHIDProductKey) ?? "?"
        mice[id] = product.hasPrefix("V-") ? String(product.dropFirst(2)) : product  // Universal Control adds "V-"
    }
    return mice.map { (name: $0.value, id: $0.key) }.sorted { $0.name < $1.name }
}

// MARK: Where the pointer is

// Universal Control publishes where this Mac's input goes; bit 1 is set while the pointer is on another device.
// ponytail: undocumented, observed on macOS 27. If it goes away, the pointer always reads as here: forwarding
// stops, and SteerMouse actions run on the Mac the mouse is connected to, as without uc-steer.
let inputStateName = "user.uid.\(getuid()).com.apple.universalcontrol.inputstate"
let inputStateToken: Int32 = {
    var token: Int32 = 0
    notify_register_check(inputStateName, &token)
    return token
}()

func pointerIsHere() -> Bool {
    var state: UInt64 = 0
    notify_get_state(inputStateToken, &state)
    return state & 2 == 0
}

// MARK: Actions

func perform(_ action: [String: Any]) -> Bool {
    let (name, hotKey) = describe(action)
    guard let hotKey else {
        logOnce("SteerMouse action \"\(name)\" isn't supported; passing the click through")
        return false
    }
    var character: UInt16 = 0, keyCode: UInt16 = 0
    var modifiers: UInt64 = 0  // 64-bit and zeroed: reads right whether SkyLight writes 32 or 64 bits
    guard CGSGetSymbolicHotKeyValue(hotKey, &character, &keyCode, &modifiers) == 0, keyCode != 0xFFFF else {
        logOnce("\"\(name)\" has no shortcut in System Settings > Keyboard > Keyboard Shortcuts > Mission Control")
        return false
    }
    let enabled = CGSIsSymbolicHotKeyEnabled(hotKey)
    if !enabled { _ = CGSSetSymbolicHotKeyEnabled(hotKey, true) }
    for down in [true, false] {
        let key = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
        key?.flags = CGEventFlags(rawValue: modifiers)
        key?.post(tap: .cghidEventTap)
    }
    if !enabled { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = CGSSetSymbolicHotKeyEnabled(hotKey, false) } }
    log(name)
    return true
}

// MARK: Forwarding SteerMouse's buttons

// Each message to another Mac: the mouse's vendor and product ID (big-endian UInt16 each), then a serialized
// button event.
let peers = Peers()

var steerMouseProcesses: [Int64: Bool] = [:]
func isSteerMouse(_ pid: Int64) -> Bool {
    if let known = steerMouseProcesses[pid] { return known }
    let result = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == steerMouseManager
    steerMouseProcesses[pid] = result
    return result
}

// Sends a button event SteerMouse posted to the other Macs, while the pointer is on one of them. True: drop it.
func forward(_ type: CGEventType, _ event: CGEvent) -> Bool {
    let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
    guard type == .otherMouseDown || type == .otherMouseUp, pid > 0, peers.isConnected, !pointerIsHere(),
          isSteerMouse(pid), let data = event.data as Data? else { return false }
    let id = deviceID(sender: event.getIntegerValueField(senderField))  // the mouse SteerMouse posted it for
    var message = Data()
    for value in [id?.vendor ?? 0, id?.product ?? 0] {
        message += withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).bigEndian) { Data($0) }
    }
    peers.send(message + data)
    if type == .otherMouseDown {
        let button = event.getIntegerValueField(.mouseEventButtonNumber) + 1
        log("sent button \(button) of \(id?.key ?? "an unknown mouse") to the Mac with the pointer")
    }
    return true
}

// Applies a button another Mac forwarded, if the pointer is on this Mac: this Mac's SteerMouse settings for that
// mouse, as for clicks from Universal Control, or a plain click when it has no supported action.
func replay(_ message: Data) {
    guard pointerIsHere(), message.count > 4,
          let event = CGEvent(withDataAllocator: nil, data: Data(message.dropFirst(4)) as CFData),
          event.type == .otherMouseDown || event.type == .otherMouseUp, let now = CGEvent(source: nil) else { return }
    let b = Array(message.prefix(4))
    let id = DeviceID(vendor: Int(b[0]) << 8 | Int(b[1]), product: Int(b[2]) << 8 | Int(b[3]))
    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    if event.type == .otherMouseDown {
        reloadSettingsIfChanged()
        if let action = settings(for: id)?.actions[1 << Int(button)], perform(action) {
            handledButtons.insert(button)
            return
        }
        logOnce("button \(button + 1) of \(id.key) from another Mac has no supported SteerMouse action here; passing it through")
    } else if handledButtons.remove(button) != nil {
        return
    }
    event.location = now.location  // the other Mac's pointer position means nothing here
    event.timestamp = now.timestamp
    event.setIntegerValueField(senderField, value: 0)  // a registry ID on the other Mac; must not match a device here
    event.post(tap: .cghidEventTap)
}

// MARK: Event tap

var tap: CFMachPort?
var handledButtons = Set<Int64>()  // presses uc-steer performed; their drags and release are dropped too

// SteerMouse settings for the Universal Control device that sent the event, if any.
func remoteSettings(_ event: CGEvent) -> Device? {
    guard let id = remoteDevice(sender: event.getIntegerValueField(senderField)) else { return nil }
    reloadSettingsIfChanged()
    return settings(for: id)
}

// Negates one scroll axis. The line delta goes first, in case CoreGraphics derives the other two from it.
func flip(_ event: CGEvent, _ line: CGEventField, _ fixed: CGEventField, _ point: CGEventField) {
    let (l, f, p) = (event.getIntegerValueField(line), event.getDoubleValueField(fixed), event.getIntegerValueField(point))
    event.setIntegerValueField(line, value: -l)
    event.setDoubleValueField(fixed, value: -f)
    event.setIntegerValueField(point, value: -p)
}

// Returns true to drop the event.
func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    if forward(type, event) { return true }
    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    switch type {
    case .scrollWheel:
        guard let device = remoteSettings(event) else { return false }
        if device.flipVertical {
            flip(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        }
        if device.flipHorizontal {
            flip(event, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        }
        return false
    case .otherMouseDown:
        guard let action = remoteSettings(event)?.actions[1 << Int(button)], perform(action) else { return false }
        handledButtons.insert(button)
        return true
    case .otherMouseUp:
        return handledButtons.remove(button) != nil
    case .otherMouseDragged:
        return handledButtons.contains(button)
    default:
        return false
    }
}

func startTap() {
    let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
    let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return handle(type, event) ? nil : Unmanaged.passUnretained(event)
    }, userInfo: nil)
    guard let tap else { log("can't create the event tap"); return }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    reloadSettingsIfChanged()
    log("watching Universal Control input and SteerMouse's buttons")
}

// MARK: Check

func check() {
    reloadSettingsIfChanged()
    for device in devices {
        print("\(device.name) (\(device.id.key))")
        for (bit, action) in device.actions.sorted(by: { $0.key < $1.key }) {
            let (name, hotKey) = describe(action)
            print("  button \(bit.trailingZeroBitCount + 1): \(name)" + (hotKey == nil ? " (not supported; click passes through)" : ""))
        }
        let axes = [device.flipVertical ? "vertical" : nil, device.flipHorizontal ? "horizontal" : nil].compactMap { $0 }
        if !axes.isEmpty { print("  scroll: \(axes.joined(separator: " and ")) reversed") }
    }
    print("Universal Control mice on this Mac now:")
    for mouse in remoteMice() {
        let source = settings(for: mouse.id).map { "uses SteerMouse settings for \($0.name)" } ?? "no SteerMouse settings"
        print("  \(mouse.name) (\(mouse.id.key)): \(source)")
    }
}
