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
// those in its event tap, on the Mac the mouse is connected to, wherever the pointer is. While local pointer
// input is redirected, uc-steer sends those buttons to the Mac explicitly selected in its menu. There is no
// accessible authoritative API for automatically identifying the receiving Mac.

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
    let profileID: String  // SteerMouse's Core Data object URI: the one exact identity of this profile
    var label: String  // name, plus distinguishing details when profiles share a name
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
            devices.append(Device(name: name, id: DeviceID(vendor: vendor, product: product),
                                  profileID: device.objectID.uriRepresentation().absoluteString, label: name,
                                  actions: actions, flipVertical: flipVertical, flipHorizontal: flipHorizontal))
        }
    }
    return labeled(devices)
}

// Stable order, and labels that tell same-named profiles apart.
func labeled(_ devices: [Device]) -> [Device] {
    var sorted = devices.sorted { ($0.name, $0.profileID) < ($1.name, $1.profileID) }
    for (name, group) in Dictionary(grouping: sorted.indices, by: { sorted[$0].name }) where group.count > 1 {
        for (n, i) in group.enumerated() { sorted[i].label = "\(name) (\(sorted[i].id.key)) #\(n + 1)" }
    }
    return sorted
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
var settingsDate: Date? = .distantPast  // modification time of the last successful load
var settingsRetryAt: UInt64 = 0  // monotonic nanoseconds; nonzero while a load failure awaits retry

// A failed load retries at most once a second, even on an unchanged file, so the event tap never loops on I/O.
func reloadSettingsIfChanged(modified: () -> Date? = { (try? FileManager.default.attributesOfItem(atPath: store.path))?[.modificationDate] as? Date },
                             load: () throws -> [Device] = loadSettings,
                             migrate: ([Device]) -> Void = { devices in
                                 let migrated = migratedOverrides(settingsOverrides, devices)
                                 if migrated != settingsOverrides { settingsOverrides = migrated }
                             },
                             now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
    let time = now()
    guard time >= settingsRetryAt else { return }
    let date = modified()
    guard date != settingsDate || settingsRetryAt != 0 else { return }  // a pending failure retries even at the last good mtime
    do {
        devices = try load()
        settingsDate = date
        settingsRetryAt = 0
        migrate(devices)
        log("loaded SteerMouse settings for: " + devices.map(\.label).joined(separator: ", "))
    } catch {
        devices = []
        settingsRetryAt = time + 1_000_000_000
        log("can't read SteerMouse settings: \(error)")
    }
}

// The SteerMouse profile whose settings each Universal Control mouse uses, keyed by DeviceID.key. Chosen in the
// menu. Values are Device.profileID; mice without an entry use the SteerMouse device with the same vendor and product ID.
var settingsOverrides = UserDefaults.standard.dictionary(forKey: "settingsOverrides") as? [String: String] ?? [:] {
    didSet { UserDefaults.standard.set(settingsOverrides, forKey: "settingsOverrides") }
}

// Old overrides stored a profile name: keep it as a profile ID only if exactly one profile has that name.
func migratedOverrides(_ overrides: [String: String], _ devices: [Device]) -> [String: String] {
    overrides.compactMapValues { value in
        if value.hasPrefix("x-coredata://") { return value }
        let matches = devices.filter { $0.name == value }
        return matches.count == 1 ? matches[0].profileID : nil
    }
}

func profile(for id: DeviceID, overrides: [String: String], in devices: [Device]) -> Device? {
    if let chosen = overrides[id.key], let device = devices.first(where: { $0.profileID == chosen }) { return device }
    return devices.first { $0.id == id }
}

func settings(for id: DeviceID) -> Device? { profile(for: id, overrides: settingsOverrides, in: devices) }

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

// UniversalControl 199.0.4 publishes HID suppression flags: bit 0 = keyboard, bit 1 = pointer/scroll/digitizer.
// A clear pointer bit does NOT identify the receiving Mac: idle Macs also publish zero.
// ponytail: private notification, verified in macOS 27's binary; if unavailable, new presses stay local.
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

// Messages: UCS/version prefix, vendor/product (UInt16 big-endian), sender ID (UInt64 big-endian), CGEvent data.
// CGEvent serialization drops field 87, so the sender ID must travel separately. Connection IDs scope sessions.
let peers = Peers()
// Stable authenticated peer identity. The old name-based "forwardingDestination" preference is dropped.
var forwardingDestination: String? = {
    UserDefaults.standard.removeObject(forKey: "forwardingDestination")
    return UserDefaults.standard.string(forKey: "forwardingDestinationID")
}() {
    didSet { UserDefaults.standard.set(forwardingDestination, forKey: "forwardingDestinationID") }
}
// Explicit routing is a clean wire-format cutover: reject old peers' automatically broadcast events.
let buttonMessagePrefix = Data([0x55, 0x43, 0x53, 0x01]) // UCS, version 1
let buttonMessageHeaderSize = 16

struct MouseButton: Hashable {
    let sender: Int64
    let button: Int64

    init(_ event: CGEvent) {
        sender = event.getIntegerValueField(senderField)
        button = event.getIntegerValueField(.mouseEventButtonNumber)
    }
}

struct ForwardedPress {
    let pid: Int64
    let device: DeviceID
    let recipients: Set<UUID>
}
var forwardedButtons: [MouseButton: ForwardedPress] = [:]

struct ReplayedButton: Hashable {
    let peer: UUID
    let mouse: MouseButton
}
enum ReplayedPress {
    case handled
    case posted(CGEvent)
}
var replayedButtons: [ReplayedButton: ReplayedPress] = [:]

// CGEvent's other-button events cover buttons 3–32, never left/right clicks.
func supportedButton(_ button: Int64) -> Bool { (2..<32).contains(button) }

func buttonMessage(_ event: CGEvent, device: DeviceID) -> Data? {
    guard let data = event.data as Data? else { return nil }
    var message = buttonMessagePrefix
    for value in [device.vendor, device.product] {
        withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).bigEndian) { message.append(contentsOf: $0) }
    }
    let sender = UInt64(bitPattern: event.getIntegerValueField(senderField))
    withUnsafeBytes(of: sender.bigEndian) { message.append(contentsOf: $0) }
    message.append(data)
    return message
}

var steerMouseProcesses: [Int64: Bool] = [:]
func isSteerMouse(_ pid: Int64) -> Bool {
    if let known = steerMouseProcesses[pid] { return known }
    let result = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == steerMouseManager
    steerMouseProcesses[pid] = result
    return result
}

// Real effects of forwarding and replaying; checks substitute their own.
struct ButtonEffects {
    var post: (CGEvent) -> Void = { postReplayedButton($0) }
    var act: ([String: Any]) -> Bool = { perform($0) }
    var reload: () -> Void = { reloadSettingsIfChanged() }
    var lookup: (DeviceID) -> Device? = { settings(for: $0) }
    var destination: () -> String? = { forwardingDestination }
    var connection: (String) -> UUID? = { peers.connection(to: $0) }
    var send: (Data, Set<UUID>) -> Set<UUID> = { peers.send($0, to: $1) }
    var pointerHere: () -> Bool = { pointerIsHere() }
    var steerMouse: (Int64) -> Bool = { isSteerMouse($0) }
    var device: (Int64) -> DeviceID? = { deviceID(sender: $0) }
}

// The press owns its route until release, even if the pointer moves or the connections disappear.
func forward(_ type: CGEventType, _ event: CGEvent, _ fx: ButtonEffects = ButtonEffects()) -> Bool {
    guard type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged else { return false }
    let mouse = MouseButton(event)
    let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
    if let press = forwardedButtons[mouse] {
        if type != .otherMouseDown {
            if press.pid == pid {
                if type == .otherMouseUp {
                    forwardedButtons[mouse] = nil
                    if !press.recipients.isEmpty, let message = buttonMessage(event, device: press.device) { _ = fx.send(message, press.recipients) }
                }
                return true
            }
        } else if supportedButton(mouse.button), pid > 0, fx.steerMouse(pid) {
            // A valid new press means the old release was lost: release the old route first, even if the PID changed.
            forwardedButtons[mouse] = nil
            if let up = event.copy() {
                up.type = .otherMouseUp
                if !press.recipients.isEmpty, let message = buttonMessage(up, device: press.device) { _ = fx.send(message, press.recipients) }
            }
        }
    }
    // Never forward an orphan release or a press which began on this Mac.
    guard type == .otherMouseDown, supportedButton(mouse.button), pid > 0,
          let destination = fx.destination(), let recipient = fx.connection(destination),
          !fx.pointerHere(), fx.steerMouse(pid) else { return false }
    let id = fx.device(mouse.sender) ?? DeviceID(vendor: 0, product: 0)
    guard let message = buttonMessage(event, device: id) else { return false }
    let recipients = fx.send(message, [recipient])
    guard !recipients.isEmpty else { return false }
    forwardedButtons[mouse] = ForwardedPress(pid: pid, device: id, recipients: recipients)
    log("sent button \(mouse.button + 1) of \(id.key) to the selected Mac: \(destination)")
    return true
}

func postReplayedButton(_ event: CGEvent) {
    guard let now = CGEvent(source: nil) else { return }
    event.location = now.location
    event.timestamp = now.timestamp
    event.setIntegerValueField(senderField, value: 0)
    event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
    event.post(tap: .cghidEventTap)
}

// Return a release only for a click we actually posted, not for a handled action or an orphan release.
func takeReplayedRelease(_ button: ReplayedButton) -> CGEvent? {
    guard let press = replayedButtons.removeValue(forKey: button), case .posted(let event) = press else { return nil }
    event.type = .otherMouseUp
    return event
}

func disconnectPeer(_ peer: UUID) {
    for button in replayedButtons.keys.filter({ $0.peer == peer }) {
        if let release = takeReplayedRelease(button) { postReplayedButton(release) }
    }
}

// The sender explicitly selected this Mac. Its connection owns the press, independently of pointer movement.
func replay(_ message: Data, from peer: UUID, _ fx: ButtonEffects = ButtonEffects()) {
    guard message.count > buttonMessageHeaderSize, message.starts(with: buttonMessagePrefix),
          let event = CGEvent(withDataAllocator: nil, data: Data(message.dropFirst(buttonMessageHeaderSize)) as CFData),
          event.type == .otherMouseDown || event.type == .otherMouseUp else { return }
    let b = message.startIndex + 4
    let sender = message[(b + 4)..<(b + 12)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    event.setIntegerValueField(senderField, value: Int64(bitPattern: sender))
    let mouse = MouseButton(event)
    guard supportedButton(mouse.button) else { return }
    let button = ReplayedButton(peer: peer, mouse: mouse)
    if event.type == .otherMouseUp {
        if let release = takeReplayedRelease(button) {
            release.flags = event.flags
            fx.post(release)
        }
        return
    }
    guard replayedButtons[button] == nil else { return }
    let id = DeviceID(vendor: Int(message[b]) << 8 | Int(message[b + 1]),
                      product: Int(message[b + 2]) << 8 | Int(message[b + 3]))
    fx.reload()
    if let action = fx.lookup(id)?.actions[1 << Int(mouse.button)], fx.act(action) {
        replayedButtons[button] = .handled
    } else {
        logOnce("button \(mouse.button + 1) of \(id.key) from another Mac has no supported SteerMouse action here; passing it through")
        replayedButtons[button] = .posted(event)
        fx.post(event)
    }
}

// MARK: Event tap

var tap: CFMachPort?
var handledButtons = Set<MouseButton>()  // Only the originating HID service owns its handled press.

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
    let mouse = MouseButton(event)
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
        handledButtons.remove(mouse)  // A new press supersedes an interrupted press from this device.
        guard supportedButton(mouse.button),
              let action = remoteSettings(event)?.actions[1 << Int(mouse.button)], perform(action) else { return false }
        handledButtons.insert(mouse)
        return true
    case .otherMouseUp:
        return handledButtons.remove(mouse) != nil
    case .otherMouseDragged:
        return handledButtons.contains(mouse)
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
    print("Gesture forwarding destination: \(forwardingDestination ?? "Off") (selected manually)")
    reloadSettingsIfChanged()
    for device in devices {
        print("\(device.name) (\(device.id.key))")
        for (bit, action) in device.actions.sorted(by: { $0.key < $1.key }) {
            let (name, hotKey) = describe(action)
            let supported = supportedButton(Int64(bit.trailingZeroBitCount)) && hotKey != nil
            print("  button \(bit.trailingZeroBitCount + 1): \(name)" + (supported ? "" : " (not supported; click passes through)"))
        }
        let axes = [device.flipVertical ? "vertical" : nil, device.flipHorizontal ? "horizontal" : nil].compactMap { $0 }
        if !axes.isEmpty { print("  scroll: \(axes.joined(separator: " and ")) reversed") }
    }
    print("Universal Control mice on this Mac now:")
    for mouse in remoteMice() {
        let source = settings(for: mouse.id).map { "uses SteerMouse settings for \($0.label)" } ?? "no SteerMouse settings"
        print("  \(mouse.name) (\(mouse.id.key)): \(source)")
    }
}
