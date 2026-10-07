// uc-steer: applies SteerMouse settings (button actions, scroll direction) to mouse input that arrives
// through Universal Control.
//
// SteerMouse only applies settings to mice connected to this Mac. Its event tap matches each event's
// sender (undocumented CGEvent field 87: the registry ID of the HID service that sent it) against the
// devices it has opened. Universal Control delivers the other Mac's mouse as a virtual HID service that
// has no IORegistry entry, so SteerMouse lets that input through untouched. uc-steer catches it, finds the
// SteerMouse settings for the device with the same vendor and product ID, and applies them itself.

import AppKit
import CoreData
import IOKit.hid

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

// SteerMouse "Mission Control" actions, and the system shortcut (symbolic hotkey ID) each one presses.
let missionOps: [String: Int32] = [
    "Mission Control": 32, "Application Windows": 33, "Desktop": 36,
    "Move Left a Space": 79, "Move Right a Space": 81,
]

struct DeviceID: Hashable { let vendor: Int, product: Int }
struct Device {
    let name: String
    let actions: [Int: [String: Any]]  // button bit (1 << CGEvent button number) -> SteerMouse action
    let flipVertical: Bool, flipHorizontal: Bool  // SteerMouse reverses this scroll axis
}
struct Failure: Error, CustomStringConvertible { let description: String }

func log(_ message: String) { print("\(Date().formatted(.iso8601)) \(message)") }
var loggedOnce = Set<String>()
func logOnce(_ message: String) { if loggedOnce.insert(message).inserted { log(message) } }

// MARK: SteerMouse settings

func loadSettings() throws -> [DeviceID: Device] {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "jp.plentycom.app.SteerMouse"),
          let model = NSManagedObjectModel(contentsOf: app.appendingPathComponent("Contents/Resources/Device.momd"))
    else { throw Failure(description: "SteerMouse is not installed") }
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try coordinator.addPersistentStore(ofType: NSBinaryStoreType, configurationName: nil, at: store,
                                       options: [NSReadOnlyPersistentStoreOption: true])
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator

    var devices: [DeviceID: Device] = [:]
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
        // ponytail: two configured mice with the same vendor/product ID (same receiver model): the first wins
        let id = DeviceID(vendor: vendor, product: product)
        if devices[id] == nil, !actions.isEmpty || flipVertical || flipHorizontal {
            devices[id] = Device(name: name, actions: actions, flipVertical: flipVertical, flipHorizontal: flipHorizontal)
        }
    }
    return devices
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

var devices: [DeviceID: Device] = [:]
var settingsDate: Date? = .distantPast

func reloadSettingsIfChanged() {
    let date = (try? FileManager.default.attributesOfItem(atPath: store.path))?[.modificationDate] as? Date
    guard date != settingsDate else { return }
    settingsDate = date
    do {
        devices = try loadSettings()
        log("loaded SteerMouse settings for: " + devices.values.map(\.name).sorted().joined(separator: ", "))
    } catch {
        devices = [:]
        log("can't read SteerMouse settings: \(error)")
    }
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

func remoteDevice(sender: Int64) -> DeviceID? {
    if let known = senderDevices[sender] { return known }
    var id: DeviceID?
    if sender > 0, isVirtual(UInt64(sender)),
       let service = hidServices().first(where: { registryID($0) == UInt64(sender) }),
       let vendor: Int = property(service, kIOHIDVendorIDKey), let product: Int = property(service, kIOHIDProductIDKey) {
        id = DeviceID(vendor: vendor, product: product)
    }
    senderDevices[sender] = .some(id)
    return id
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

// MARK: Event tap

var tap: CFMachPort?
var handledButtons = Set<Int64>()  // presses uc-steer performed; their drags and release are dropped too

// SteerMouse settings for the Universal Control device that sent the event, if any.
func remoteSettings(_ event: CGEvent) -> Device? {
    guard let id = remoteDevice(sender: event.getIntegerValueField(senderField)) else { return nil }
    reloadSettingsIfChanged()
    return devices[id]
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
    default:
        return handledButtons.contains(button)
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
    guard let tap else { log("can't create the event tap"); exit(1) }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    reloadSettingsIfChanged()
    log("watching for Universal Control clicks and scrolling")
}

// MARK: Main

func check() {
    reloadSettingsIfChanged()
    for (id, device) in devices.sorted(by: { $0.value.name < $1.value.name }) {
        print("\(device.name) (\(String(format: "%04x:%04x", id.vendor, id.product)))")
        for (bit, action) in device.actions.sorted(by: { $0.key < $1.key }) {
            let (name, hotKey) = describe(action)
            print("  button \(bit.trailingZeroBitCount + 1): \(name)" + (hotKey == nil ? " (not supported; click passes through)" : ""))
        }
        let axes = [device.flipVertical ? "vertical" : nil, device.flipHorizontal ? "horizontal" : nil].compactMap { $0 }
        if !axes.isEmpty { print("  scroll: \(axes.joined(separator: " and ")) reversed") }
    }
    print("Universal Control pointing devices on this Mac now:")
    for service in hidServices() where property(service, kIOHIDPrimaryUsagePageKey) == kHIDPage_GenericDesktop
        && property(service, kIOHIDPrimaryUsageKey) == kHIDUsage_GD_Mouse && isVirtual(registryID(service)) {
        let id = DeviceID(vendor: property(service, kIOHIDVendorIDKey) ?? 0, product: property(service, kIOHIDProductIDKey) ?? 0)
        let product: String = property(service, kIOHIDProductKey) ?? "?"
        let settings = devices[id].map { "uses SteerMouse settings for \($0.name)" } ?? "no SteerMouse settings"
        print("  \(product) (\(String(format: "%04x:%04x", id.vendor, id.product))): \(settings)")
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
if CommandLine.arguments.contains("--check") { check(); exit(0) }

let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
if AXIsProcessTrustedWithOptions(prompt) {
    startTap()
} else {
    log("waiting for Accessibility permission: System Settings > Privacy & Security > Accessibility > uc-steer")
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
        if AXIsProcessTrusted() { timer.invalidate(); startTap() }
    }
}
RunLoop.main.run()
