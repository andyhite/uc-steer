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
        print("Input ownership checks passed")
    }
}
