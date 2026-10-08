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

// Opt-in detail for the Debug Logging menu item. Never log key content, pointer coordinates or serial numbers.
var debugLogging = UserDefaults.standard.bool(forKey: "debugLogging") {
    didSet {
        UserDefaults.standard.set(debugLogging, forKey: "debugLogging")
        log("debug logging \(debugLogging ? "enabled" : "disabled")")
    }
}
func debugLog(_ message: @autoclosure () -> String) {
    if debugLogging { log("debug: " + message()) }
}

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
        guard let vendor = device.value(forKey: "vid") as? Int, let product = device.value(forKey: "pid") as? Int else {
            debugLog("settings: skipped a profile without vid/pid")
            continue
        }
        guard device.value(forKey: "actionDisabled") as? Bool != true else {
            debugLog("settings: skipped \(DeviceID(vendor: vendor, product: product).key): actions disabled")
            continue
        }
        // ponytail: default settings only; per-app settings and modifier+button combos are skipped
        let apps = device.value(forKey: "applications") as? Set<NSManagedObject> ?? []
        guard let defaults = apps.first(where: { $0.value(forKey: "bundleID") == nil }) else {
            debugLog("settings: skipped \(DeviceID(vendor: vendor, product: product).key): no default-app settings")
            continue
        }
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
        let registryName = device.value(forKey: "registryName") as? String
        let name = registryName.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Unnamed profile (\(DeviceID(vendor: vendor, product: product).key))"
        if registryName?.isEmpty ?? true { log("SteerMouse profile \(vendor):\(product) has no registryName; calling it \"\(name)\"") }
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

// One short-lived HID read backs every lookup. Snapshots hold plain values only: no service or client reference
// outlives the read, so a handle gone stale can never poison later lookups.
struct HIDService: Equatable {
    let registryID: UInt64
    var vendor: Int?, product: Int?, name: String?, transport: String?, usagePage: Int?, usage: Int?
    var virtual: Bool  // no IORegistry entry: Universal Control's devices exist only in the HID event system
    var deviceID: DeviceID? { vendor.flatMap { v in product.map { DeviceID(vendor: v, product: $0) } } }
    var isMouse: Bool { usagePage == Int(kHIDPage_GenericDesktop) && usage == Int(kHIDUsage_GD_Mouse) }
    var isRemoteMouse: Bool { isMouse && virtual && transport != "UniversalControl" }  // not Universal Control's own pointer
    var missing: String {
        [vendor == nil ? "vendor ID" : nil, product == nil ? "product ID" : nil, name == nil ? "name" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
struct HIDSnapshot { var at: UInt64; var services: [UInt64: HIDService]; var valid: Bool }

// Test seams: monotonic clock, the HID read (nil = unavailable), and where background reads run.
var inputNow: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
var inputRead: () -> [HIDService]? = readHIDServices
let inputQueue = DispatchQueue(label: "com.andyhite.uc-steer.hid", qos: .utility)
var inputSchedule: (@escaping () -> Void) -> Void = { inputQueue.async(execute: $0) }
var inputSnapshot = HIDSnapshot(at: 0, services: [:], valid: false)
var inputUnavailable = false
var inputBackground = false  // set by startInputDevices
var inputReadInFlight = false
var inputGeneration = 0
let inputMaxAge: UInt64 = 1_000_000_000
let inputStaleAfter: UInt64 = 2_000_000_000

func isVirtual(_ registryID: UInt64) -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
    if service != 0 { IOObjectRelease(service) }
    return service == 0
}

func readHIDServices() -> [HIDService]? {
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    return withExtendedLifetime(client) {  // the client must outlive every property read
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return nil }
        func property<T>(_ service: IOHIDServiceClient, _ key: String) -> T? { IOHIDServiceClientCopyProperty(service, key as CFString) as? T }
        return services.compactMap { service in
            let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
            guard id > 0 else { return nil }
            let name: String? = property(service, kIOHIDProductKey)
            return HIDService(registryID: id, vendor: property(service, kIOHIDVendorIDKey), product: property(service, kIOHIDProductIDKey),
                              name: name?.isEmpty == true ? nil : name, transport: property(service, kIOHIDTransportKey),
                              usagePage: property(service, kIOHIDPrimaryUsagePageKey), usage: property(service, kIOHIDPrimaryUsageKey),
                              virtual: isVirtual(id))
        }
    }
}

func applyInput(_ list: [HIDService]?, at time: UInt64) {
    if let list {
        if inputUnavailable { log("HID services available again"); inputUnavailable = false }
        let services = Dictionary(list.map { ($0.registryID, $0) }, uniquingKeysWith: { first, _ in first })
        logInputChanges(from: inputSnapshot.services, to: services)
        inputSnapshot = HIDSnapshot(at: time, services: services, valid: true)
    } else {
        // Fail closed: no stale identities. Retries are throttled by the same maxAge.
        if !inputUnavailable { log("HID services unavailable; no input devices resolve until a read succeeds"); inputUnavailable = true }
        inputSnapshot = HIDSnapshot(at: time, services: [:], valid: true)
    }
}

// At most one HID read per maxAge. A removed device disappears and a device whose IDs were missing recovers on the next read.
// With background refresh on, only maxAge 0 (the check) reads here; everything else uses the last result, or
// nothing once it is older than inputStaleAfter, so the event tap never scans (a scan takes ~50 ms).
func currentInput(maxAge: UInt64 = inputMaxAge) -> HIDSnapshot {
    let time = inputNow()
    if inputBackground && maxAge != 0 {
        if inputSnapshot.valid, time &- inputSnapshot.at < inputStaleAfter { return inputSnapshot }
        logLimited("input-stale", "HID snapshot is missing or stale; no input devices resolve until the next read completes")
        return HIDSnapshot(at: 0, services: [:], valid: false)
    }
    if inputSnapshot.valid, time &- inputSnapshot.at < maxAge { return inputSnapshot }
    if inputBackground { inputGeneration += 1 }  // an in-flight read predates this one
    applyInput(inputRead(), at: time)
    return inputSnapshot
}

// Production lifecycle: the parent calls this before creating the event tap. One synchronous read, then a
// background read about every second (one in flight; value-only results applied on main).
func startInputDevices() {
    inputBackground = true
    applyInput(inputRead(), at: inputNow())
    let timer = Timer(timeInterval: 1, repeats: true) { _ in requestInputRead() }
    RunLoop.main.add(timer, forMode: .common)
}

func requestInputRead() {
    guard inputBackground, !inputReadInFlight else { return }
    inputReadInFlight = true
    let (generation, started, read) = (inputGeneration, inputNow(), inputRead)
    inputSchedule {
        let list = read()
        DispatchQueue.main.async { inputReadInFlight = false; finishInputRead(list, generation: generation, started: started) }
    }
}

// A result from before an invalidation is discarded and a new read requested.
func finishInputRead(_ list: [HIDService]?, generation: Int, started: UInt64) {
    guard generation == inputGeneration else { requestInputRead(); return }
    applyInput(list, at: started)
}

// Parent calls this on wake: lookups fail closed until a new read completes.
func invalidateInputDevices(_ reason: String) {
    inputSnapshot.valid = false
    inputGeneration += 1
    missingSenders.removeAll()
    limitedLogs.removeAll()
    log("input devices invalidated: \(reason)")
    requestInputRead()
}

func describe(_ s: HIDService) -> String {
    "\(s.name ?? "unnamed") (\(s.deviceID?.key ?? "missing \(s.missing)"), registry \(s.registryID))"
}

func logInputChanges(from old: [UInt64: HIDService], to new: [UInt64: HIDService]) {
    for (id, s) in new where s.isRemoteMouse {
        guard let before = old[id], before.isRemoteMouse else {
            log("Universal Control mouse added: \(describe(s))" + (s.deviceID == nil ? "; ignored until its vendor/product ID is available" : ""))
            continue
        }
        if before != s {
            log("Universal Control mouse \(before.deviceID == nil && s.deviceID != nil ? "metadata recovered" : "metadata changed"): \(describe(before)) -> \(describe(s))")
        }
    }
    for (id, s) in old where s.isRemoteMouse && new[id]?.isRemoteMouse != true {
        log("Universal Control mouse removed: \(describe(s))")
    }
}

// Rate-limited default log with a bounded key table.
var limitedLogs: [String: UInt64] = [:]
func logLimited(_ key: String, _ message: @autoclosure () -> String, every: UInt64 = 30_000_000_000) {
    let time = inputNow()
    if let last = limitedLogs[key], time &- last < every { return }
    if limitedLogs.count >= 64 { limitedLogs.removeAll() }
    limitedLogs[key] = time
    log(message())
}

var missingSenders = Set<Int64>()  // senders reported unresolved; bounded
func noteMiss(_ sender: Int64, _ reason: String) {
    if missingSenders.count >= 32 { missingSenders.removeAll() }
    missingSenders.insert(sender)
    logLimited("miss \(sender)", "can't resolve input sender \(sender): \(reason); passing through")
}
func noteResolved(_ sender: Int64) {
    if missingSenders.remove(sender) != nil { log("input sender \(sender) resolved") }
}

// Vendor and product ID of the HID service with this registry ID, the sender CGEvent field 87 holds.
func deviceID(sender: Int64) -> DeviceID? {
    guard sender > 0 else { return nil }
    guard let service = currentInput().services[UInt64(sender)] else { noteMiss(sender, "no such HID service"); return nil }
    guard let id = service.deviceID else { noteMiss(sender, "missing \(service.missing)"); return nil }
    noteResolved(sender)
    return id
}

// The Universal Control device that sent an event, if one did.
func remoteDevice(sender: Int64) -> DeviceID? {
    guard sender > 0 else { return nil }
    // Absent from the snapshot: a device connected to this Mac, or one that appears within a second.
    guard let service = currentInput().services[UInt64(sender)], service.virtual else { return nil }
    guard let id = service.deviceID else { noteMiss(sender, "missing \(service.missing)"); return nil }
    noteResolved(sender)
    return id
}

// Universal Control's copies of your other Macs' mice, one per vendor and product ID. Mice without both IDs are
// omitted (logged when they appear); a missing product name never replaces a known one.
func remoteMice(_ snapshot: HIDSnapshot = currentInput()) -> [(name: String, id: DeviceID)] {
    var names: [DeviceID: [String]] = [:]
    for service in snapshot.services.values where service.isRemoteMouse {
        guard let id = service.deviceID else { continue }
        var known = names[id, default: []]
        if let product = service.name { known.append(product.hasPrefix("V-") ? String(product.dropFirst(2)) : product) }  // Universal Control adds "V-"
        names[id] = known
    }
    return names.map { (name: $0.value.min() ?? "Unknown mouse (\($0.key.key))", id: $0.key) }
        .sorted { ($0.name, $0.id.key) < ($1.name, $1.id.key) }
}

// MARK: Where the pointer is

// UniversalControl 199.0.4 publishes HID suppression flags: bit 0 = keyboard, bit 1 = pointer/scroll/digitizer.
// A clear pointer bit does NOT identify the receiving Mac: idle Macs also publish zero.
// ponytail: private notification, verified in macOS 27's binary; if unavailable, new presses stay local.
let inputStateName = "user.uid.\(getuid()).com.apple.universalcontrol.inputstate"
let inputStateToken: Int32 = {
    var token: Int32 = 0
    let status = notify_register_check(inputStateName, &token)
    if status != UInt32(NOTIFY_STATUS_OK) { log("can't register for Universal Control input state (status \(status))") }
    return token
}()

var lastInputState: UInt64?
func pointerIsHere() -> Bool {
    var state: UInt64 = 0
    let status = notify_get_state(inputStateToken, &state)
    if status != UInt32(NOTIFY_STATUS_OK) {
        logLimited("notify", "can't read Universal Control input state (status \(status)); treating the pointer as here")
    }
    if state != lastInputState { debugLog("Universal Control input state \(lastInputState.map(String.init) ?? "none") -> \(state)") }
    lastInputState = state
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

func isSteerMouse(_ pid: Int64) -> Bool {
    // Not cached: PIDs are reused, and this runs only for a new other-button press.
    NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == steerMouseManager
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
    guard type == .otherMouseDown, supportedButton(mouse.button) else { return false }
    let tag = "button \(mouse.button + 1) sender \(mouse.sender) pid \(pid)"
    guard pid > 0, fx.steerMouse(pid) else { debugLog("\(tag): not from SteerMouse; local"); return false }
    guard let destination = fx.destination() else { debugLog("\(tag): forwarding disabled; local"); return false }
    guard let recipient = fx.connection(destination) else { debugLog("\(tag): selected Mac has no connection; local"); return false }
    guard !fx.pointerHere() else { debugLog("\(tag): pointer is on this Mac; local"); return false }
    // The wire carries only a resolved source device; an unresolved press stays local and retries on the next press.
    guard let id = fx.device(mouse.sender) else {
        logLimited("press-unresolved", "\(tag): source device has no vendor/product ID; staying local")
        return false
    }
    guard let message = buttonMessage(event, device: id) else { return false }
    let recipients = fx.send(message, [recipient])
    guard !recipients.isEmpty else { debugLog("\(tag): send failed; local"); return false }
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
        debugLog("replayed button \(mouse.button + 1) of \(id.key): handled")
        replayedButtons[button] = .handled
    } else {
        debugLog("replayed button \(mouse.button + 1) of \(id.key): passed through")
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
        guard supportedButton(mouse.button) else { return false }
        guard let id = remoteDevice(sender: mouse.sender) else {
            debugLog("button \(mouse.button + 1) from sender \(mouse.sender): not a resolved Universal Control device; passing through")
            return false
        }
        reloadSettingsIfChanged()
        guard let device = settings(for: id), let action = device.actions[1 << Int(mouse.button)] else {
            debugLog("button \(mouse.button + 1) of \(id.key): no SteerMouse action; passing through")
            return false
        }
        guard perform(action) else {
            debugLog("button \(mouse.button + 1) of \(id.key) (\(device.label)): action not performed; passing through")
            return false
        }
        debugLog("button \(mouse.button + 1) of \(id.key) handled with settings for \(device.label)")
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
            logLimited("tap-disabled", "event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"); re-enabling", every: 1_000_000_000)
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
    // Everything goes through log(): unified log (visible from the menu app) and stdout (--check).
    let isCheckProcess = CommandLine.arguments.contains("--check")
    let out: (String) -> Void = { log($0) }
    let info = Bundle.main.infoDictionary
    out("macOS \(ProcessInfo.processInfo.operatingSystemVersionString); uc-steer \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")); pid \(getpid()); \(Bundle.main.executablePath ?? "?")")
    out(isCheckProcess ? "mode: separate --check process (no live event tap, snapshot cache or press state; run Log Diagnostics in the menu app for those)"
                       : "mode: running menu app (live state)")
    out("permissions: accessibility \(AXIsProcessTrusted()), input monitoring \(CGPreflightListenEventAccess()), post events \(CGPreflightPostEventAccess())")
    out("event tap: " + (tap.map { "created, enabled \(CGEvent.tapIsEnabled(tap: $0))" } ?? "not created"))
    var state: UInt64 = 0
    let status = notify_get_state(inputStateToken, &state)
    out("pointer input state: status \(status), raw \(state), pointer here \(state & 2 == 0); token \(inputStateToken)")
    out("Gesture forwarding destination: \(forwardingDestination ?? "Off") (selected manually); debug logging \(debugLogging)")
    if inputSnapshot.valid {
        out("cached HID snapshot: \((inputNow() &- inputSnapshot.at) / 1_000_000) ms old, unavailable \(inputUnavailable), \(inputSnapshot.services.count) services, remote mice: "
            + (inputSnapshot.services.values.filter(\.isRemoteMouse).map(describe).sorted().joined(separator: "; ")))
    } else {
        out("cached HID snapshot: none (unavailable \(inputUnavailable))")
    }
    out("owned presses: forwarded \(forwardedButtons.count), replayed \(replayedButtons.count), handled \(handledButtons.count)")
    reloadSettingsIfChanged()
    out("settings: \(devices.count) profiles, loaded \(settingsDate.map { "\($0)" } ?? "never"), retry pending \(settingsRetryAt != 0)")
    for device in devices {
        out("\(device.name) (\(device.id.key))")
        for (bit, action) in device.actions.sorted(by: { $0.key < $1.key }) {
            let (name, hotKey) = describe(action)
            let supported = supportedButton(Int64(bit.trailingZeroBitCount)) && hotKey != nil
            out("  button \(bit.trailingZeroBitCount + 1): \(name)" + (supported ? "" : " (not supported; click passes through)"))
        }
        let axes = [device.flipVertical ? "vertical" : nil, device.flipHorizontal ? "horizontal" : nil].compactMap { $0 }
        if !axes.isEmpty { out("  scroll: \(axes.joined(separator: " and ")) reversed") }
    }
    out("raw HID mice now (forced read):")
    let fresh = currentInput(maxAge: 0)
    out("HID read " + (inputUnavailable ? "UNAVAILABLE" : "ok") + ", \(fresh.services.count) services")
    for s in fresh.services.values.filter({ $0.isMouse || $0.virtual }).sorted(by: { $0.registryID < $1.registryID }) {
        out("  registry \(s.registryID) \(s.virtual ? "virtual" : "local") \(s.transport ?? "transport missing") usage \(s.usagePage.map(String.init) ?? "missing")/\(s.usage.map(String.init) ?? "missing") "
            + "product \(s.name.map { "\"\($0)\"" } ?? "missing") ids \(s.deviceID?.key ?? "missing \(s.missing)")" + (s.isRemoteMouse ? " [remote]" : ""))
    }
    out("Universal Control mice on this Mac now:")
    for mouse in remoteMice(fresh) {
        let source = settings(for: mouse.id).map { "uses SteerMouse settings for \($0.label)" } ?? "no SteerMouse settings"
        out("  \(mouse.name) (\(mouse.id.key)): \(source)")
    }
}
