import AppKit

@main
struct InputChecks {
    static func event(_ type: CGEventType, sender: Int64, button: UInt32 = 2, pid: Int64 = 123) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: button)!)!
        event.setIntegerValueField(senderField, value: sender)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        return event
    }

    static func main() {
        // No event tap, network discovery, live event posting, or settings writes in these checks.
        let remoteDown = event(.otherMouseDown, sender: 700)
        let remote = MouseButton(remoteDown)
        handledButtons.insert(remote)
        assert(!handle(.otherMouseUp, event(.otherMouseUp, sender: 0)))
        assert(!handle(.otherMouseDragged, event(.otherMouseDragged, sender: 701)))
        assert(handledButtons.contains(remote))
        assert(handle(.otherMouseDragged, event(.otherMouseDragged, sender: 700)))
        assert(handle(.otherMouseUp, event(.otherMouseUp, sender: 700)))
        assert(!handle(.otherMouseUp, event(.otherMouseUp, sender: 700)))

        // A disconnected route still owns its release; no ready peer is needed to consume it locally.
        forwardedButtons[remote] = ForwardedPress(pid: 123, device: DeviceID(vendor: 1, product: 2), recipients: [])
        assert(!forward(.otherMouseUp, event(.otherMouseUp, sender: 700, pid: 124)))
        assert(forwardedButtons[remote] != nil)
        assert(forward(.otherMouseDragged, event(.otherMouseDragged, sender: 700)))
        assert(forward(.otherMouseUp, event(.otherMouseUp, sender: 700)))
        assert(forwardedButtons[remote] == nil)
        assert(!forward(.otherMouseUp, event(.otherMouseUp, sender: 700)))

        // Equal sender IDs on different connections never share press ownership.
        let a = UUID(), b = UUID()
        let aButton = ReplayedButton(peer: a, mouse: remote)
        let bButton = ReplayedButton(peer: b, mouse: remote)
        replayedButtons[aButton] = .handled
        handledButtons.insert(remote)
        let upEvent = event(.otherMouseUp, sender: 700)
        let up = buttonMessage(upEvent, device: DeviceID(vendor: 1, product: 2))!
        replay(up, from: b)
        assert(replayedButtons[aButton] != nil)
        // Pre-cutover broadcasts must not release (or otherwise affect) an explicitly routed press.
        replay(Data([0, 1, 0, 2]) + (upEvent.data! as Data), from: a)
        assert(replayedButtons[aButton] != nil)
        replay(buttonMessage(event(.otherMouseUp, sender: 701), device: DeviceID(vendor: 1, product: 2))!, from: a)
        assert(replayedButtons[aButton] != nil) // different mouse on the same peer
        replay(up, from: a)
        assert(replayedButtons[aButton] == nil)
        assert(handledButtons.contains(remote))
        handledButtons.removeAll()

        // Disconnect cleanup creates releases only for posted clicks and drains each press once.
        replayedButtons[aButton] = .posted(remoteDown)
        replayedButtons[bButton] = .handled
        let release = takeReplayedRelease(aButton)
        assert(release?.type == .otherMouseUp)
        assert(release?.getIntegerValueField(.mouseEventButtonNumber) == 2)
        assert(takeReplayedRelease(aButton) == nil)
        assert(replayedButtons[bButton] != nil)
        disconnectPeer(b) // handled action: no event is posted
        assert(replayedButtons.isEmpty)

        // Reject malformed network payloads and unsupported button numbers before posting anything.
        replay(Data([0, 1, 0, 2]), from: a)
        assert(!supportedButton(-1) && !supportedButton(0) && !supportedButton(1))
        assert(supportedButton(2) && supportedButton(31) && !supportedButton(32))
        let keyboard = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        replay(buttonMessage(keyboard, device: DeviceID(vendor: 1, product: 2))!, from: a)
        assert(replayedButtons.isEmpty)

        // Valid replayed down: handled and posted states, duplicates ignored, release posts only for posted clicks.
        var posted: [CGEventType] = [], acted = 0
        var fx = ButtonEffects()
        fx.post = { posted.append($0.type) }
        fx.act = { _ in acted += 1; return true }
        fx.reload = {}
        let id12 = DeviceID(vendor: 1, product: 2)
        let device = Device(name: "M", id: id12, profileID: "x-coredata://a", label: "M", actions: [4: ["Selector": "X"]],
                            flipVertical: false, flipHorizontal: false)
        let downMessage = buttonMessage(event(.otherMouseDown, sender: 700), device: id12)!
        fx.lookup = { $0 == id12 ? device : nil }
        replay(downMessage, from: a, fx)
        replay(downMessage, from: a, fx)
        assert(acted == 1 && posted.isEmpty)
        if case .handled? = replayedButtons[aButton] {} else { assertionFailure("handled state") }
        replay(up, from: a, fx)
        assert(posted.isEmpty && replayedButtons.isEmpty)
        fx.lookup = { _ in nil }
        replay(downMessage, from: a, fx)
        replay(downMessage, from: a, fx)
        assert(posted == [.otherMouseDown])
        if case .posted? = replayedButtons[aButton] {} else { assertionFailure("posted state") }
        replay(up, from: a, fx)
        assert(posted == [.otherMouseDown, .otherMouseUp] && replayedButtons.isEmpty)

        // Forward: new route, then a stale press is released to its original recipients even from a new SteerMouse PID.
        let route1 = UUID(), route2 = UUID()
        var route = route1
        var sent: [(CGEventType, Set<UUID>)] = []
        var f = ButtonEffects()
        var destinationOn = true
        f.destination = { destinationOn ? "peer-id" : nil }
        f.connection = { $0 == "peer-id" ? route : nil }
        f.send = { data, to in
            sent.append((CGEvent(withDataAllocator: nil, data: Data(data.dropFirst(buttonMessageHeaderSize)) as CFData)!.type, to))
            return to
        }
        f.pointerHere = { false }
        f.steerMouse = { $0 > 0 }
        f.device = { _ in id12 }
        assert(forward(.otherMouseDown, event(.otherMouseDown, sender: 700, pid: 10), f))
        assert(forwardedButtons[remote]?.recipients == [route1] && sent.count == 1)
        route = route2
        assert(forward(.otherMouseDown, event(.otherMouseDown, sender: 700, pid: 11), f))
        assert(sent.map(\.0) == [.otherMouseDown, .otherMouseUp, .otherMouseDown])
        assert(sent[1].1 == [route1] && sent[2].1 == [route2])
        assert(forwardedButtons[remote]?.pid == 11 && forwardedButtons[remote]?.recipients == [route2])
        assert(!forward(.otherMouseUp, event(.otherMouseUp, sender: 700, pid: 10), f)) // mismatched release stays local
        assert(forwardedButtons[remote] != nil)
        assert(forward(.otherMouseUp, event(.otherMouseUp, sender: 700, pid: 11), f))
        assert(forwardedButtons.isEmpty && sent.count == 4)

        // Same PID, destination now off: the stale press is still released and the new down stays local.
        assert(forward(.otherMouseDown, event(.otherMouseDown, sender: 700, pid: 12), f))
        destinationOn = false
        assert(!forward(.otherMouseDown, event(.otherMouseDown, sender: 700, pid: 12), f))
        assert(sent.count == 6 && sent[5].0 == .otherMouseUp && forwardedButtons.isEmpty)

        // Same-named profiles get distinct labels, and overrides use the exact profile ID.
        func make(_ name: String, _ id: String) -> Device {
            Device(name: name, id: id12, profileID: id, label: name, actions: [:], flipVertical: true, flipHorizontal: false)
        }
        let twins = labeled([make("M", "x-coredata://2"), make("M", "x-coredata://1"), make("N", "x-coredata://3")])
        assert(Set(twins.map(\.label)).count == 3 && twins.last?.label == "N")
        assert(profile(for: id12, overrides: ["0001:0002": "x-coredata://2"], in: twins)?.profileID == "x-coredata://2")
        assert(migratedOverrides(["a": "N", "b": "M", "c": "x-coredata://9", "d": "gone"], twins)
               == ["a": "x-coredata://3", "c": "x-coredata://9"])

        // A failed load retries without an mtime change, but not within the retry interval; success caches the mtime.
        var mtime = Date(timeIntervalSince1970: 5)
        var clock: UInt64 = 1_000_000_000_000, loads = 0, fail = true
        devices = []; settingsDate = .distantPast; settingsRetryAt = 0
        func reload() {
            reloadSettingsIfChanged(modified: { mtime }, load: {
                loads += 1
                if fail { throw Failure(description: "busy") }
                return [twins[0]]
            }, migrate: { _ in }, now: { clock })
        }
        reload(); reload()
        assert(loads == 1 && settingsDate == .distantPast)
        clock += 10_000_000_000; reload()
        assert(loads == 2)
        fail = false; clock += 10_000_000_000; reload()
        assert(loads == 3 && settingsDate == mtime && devices.count == 1)
        reload()
        assert(loads == 3)
        // A failure after an mtime change still retries once the file returns to the last good mtime.
        let good = mtime
        mtime = Date(timeIntervalSince1970: 6); fail = true; reload()
        assert(loads == 4 && devices.isEmpty)
        mtime = good; fail = false; clock += 10_000_000_000; reload()
        assert(loads == 5 && devices.count == 1)

        // HID snapshots: deterministic clock and reads; no live IOKit.
        var hidNow: UInt64 = 5_000_000_000
        var hid: [HIDService]? = []
        inputNow = { hidNow }; inputRead = { hid }
        func mouse(_ id: UInt64, _ v: Int?, _ p: Int?, _ name: String?) -> HIDService {
            HIDService(registryID: id, vendor: v, product: p, name: name, transport: "USB", usagePage: Int(kHIDPage_GenericDesktop),
                       usage: Int(kHIDUsage_GD_Mouse), virtual: true)
        }
        // Missing IDs are never a 0000:0000 device; a later read recovers them.
        hid = [mouse(700, nil, nil, nil)]; invalidateInputDevices("check")
        assert(remoteDevice(sender: 700) == nil && deviceID(sender: 700) == nil && remoteMice().isEmpty)
        hid = [mouse(700, 1, nil, "V-M")]; hidNow += 2_000_000_000
        assert(remoteDevice(sender: 700) == nil && remoteMice().isEmpty)
        hid = [mouse(700, 1, 2, "V-M")]
        hidNow += 500_000_000
        assert(remoteDevice(sender: 700) == nil) // cached for under a second
        hidNow += 1_500_000_000
        assert(remoteDevice(sender: 700) == id12 && deviceID(sender: 700) == id12)
        // Removed senders disappear, then reconnect.
        hid = []; hidNow += 500_000_000
        assert(remoteDevice(sender: 700) == id12)
        hidNow += 1_000_000_000
        assert(remoteDevice(sender: 700) == nil && remoteMice().isEmpty)
        hid = [mouse(700, 1, 2, "V-M")]; hidNow += 2_000_000_000
        assert(remoteDevice(sender: 700) == id12)
        // A failed read fails closed (no stale identity); the next successful read recovers.
        hid = nil; hidNow += 2_000_000_000
        assert(remoteDevice(sender: 700) == nil && inputUnavailable)
        hid = [mouse(700, 1, 2, "V-M")]; hidNow += 500_000_000
        assert(remoteDevice(sender: 700) == nil) // retry throttled to one second
        hidNow += 1_000_000_000
        assert(remoteDevice(sender: 700) == id12 && !inputUnavailable)
        hid = []; invalidateInputDevices("check")
        assert(remoteDevice(sender: 700) == nil)
        // Duplicate VID/PID: a missing name never replaces a known one; no name at all is truthful.
        hid = [mouse(1, 1, 2, nil), mouse(2, 1, 2, "V-M"), mouse(3, 1, 2, nil), mouse(4, nil, 9, "X")]; hidNow += 2_000_000_000
        assert(remoteMice().map(\.name) == ["M"] && remoteMice()[0].id == id12)
        hid = [mouse(1, 1, 2, nil)]; hidNow += 2_000_000_000
        assert(remoteMice().map(\.name) == ["Unknown mouse (0001:0002)"])

        // Forwarding: an unresolved sender stays local; a resolved one sends the real VID/PID, and the route owns the release.
        var wire: [Data] = []
        var g = ButtonEffects()
        g.destination = { "peer-id" }
        g.connection = { _ in route2 }
        g.send = { data, to in wire.append(data); return to }
        g.pointerHere = { false }
        g.steerMouse = { $0 > 0 }
        g.device = { deviceID(sender: $0) }
        hid = [mouse(700, nil, nil, nil)]; invalidateInputDevices("check")
        assert(!forward(.otherMouseDown, event(.otherMouseDown, sender: 700, pid: 10), g))
        assert(wire.isEmpty && forwardedButtons.isEmpty)
        hid = [mouse(700, 0x046d, 0xb034, "V-M")]; hidNow += 2_000_000_000
        assert(forward(.otherMouseDown, event(.otherMouseDown, sender: 700, pid: 10), g))
        func wireID(_ d: Data) -> DeviceID { DeviceID(vendor: Int(d[4]) << 8 | Int(d[5]), product: Int(d[6]) << 8 | Int(d[7])) }
        let logi = DeviceID(vendor: 0x046d, product: 0xb034)
        assert(wire.count == 1 && wireID(wire[0]) == logi && forwardedButtons[remote]?.device == logi)
        hid = []; hidNow += 2_000_000_000 // sender gone: the release keeps its original route and device
        assert(forward(.otherMouseUp, event(.otherMouseUp, sender: 700, pid: 10), g))
        assert(wire.count == 2 && wireID(wire[1]) == logi && forwardedButtons.isEmpty)

        // Background refresh: lookups never read; stale or invalidated snapshots fail closed; pre-invalidation results are discarded.
        inputBackground = true; inputSchedule = { _ in }; inputReadInFlight = false
        hid = [mouse(700, 1, 2, "V-M")]
        finishInputRead(hid, generation: inputGeneration, started: hidNow)
        assert(remoteDevice(sender: 700) == id12)
        hidNow += 2_500_000_000
        assert(remoteDevice(sender: 700) == nil)
        finishInputRead(hid, generation: inputGeneration, started: hidNow)
        assert(remoteDevice(sender: 700) == id12)
        let before = inputGeneration
        invalidateInputDevices("check")
        assert(remoteDevice(sender: 700) == nil)
        finishInputRead(hid, generation: before, started: hidNow)
        assert(remoteDevice(sender: 700) == nil)
        inputReadInFlight = false
        finishInputRead(hid, generation: inputGeneration, started: hidNow)
        assert(remoteDevice(sender: 700) == id12)
        inputBackground = false
        print("Input ownership checks passed")
    }
}
