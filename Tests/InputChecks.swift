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
        print("Input ownership checks passed")
    }
}
