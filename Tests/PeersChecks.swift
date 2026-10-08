// Appended to Sources/Peers.swift by test.sh so `extension Peers` can reach private state. No imports here: the
// concatenated file already has Peers' imports. Loopback-only TLS NWListeners; no Bonjour, no app.

func peersFail(_ what: String) -> Never { print("FAIL: \(what)"); exit(1) }
func peersCheck(_ ok: Bool, _ what: String) { if !ok { peersFail(what) } }

/// Runs the main run loop (where Peers' connections live) until `cond` holds or `secs` pass.
@discardableResult func peersWait(_ secs: Double = 5, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(secs)
    while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return cond()
}
func peersSpin(_ secs: Double) { peersWait(secs) { false } }

func peersFrame(_ d: Data) -> Data {
    withUnsafeBytes(of: UInt32(d.count).bigEndian) { Data($0) } + d
}

/// Test-side TLS listener using Peers' real parameters; scripted peer for Peers' outgoing connections.
final class PeersServer {
    let listener: NWListener
    var conns: [NWConnection] = []
    var received: [Data] = []  // bytes read from each accepted connection, same index as `conns`
    var script: (NWConnection) -> Void = { _ in }
    var id = UUID()      // identity announced in the hello
    var hello = true     // send a valid hello before `script` runs
    var port: NWEndpoint.Port { listener.port! }

    init(_ params: NWParameters) {
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try! NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { c.cancel(); return }
            conns.append(c); received.append(Data())
            let i = conns.count - 1
            c.start(queue: .main)
            drain(c, i)
            if hello { c.send(content: Peers.helloFrame(id), completion: .idempotent) }
            script(c)
        }
        listener.start(queue: .main)
        peersCheck(peersWait { listener.state == .ready && listener.port != nil }, "test listener ready")
    }

    private func drain(_ c: NWConnection, _ i: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
            guard let self else { return }
            if let d { received[i].append(d) }
            if err == nil && !done { drain(c, i) }
        }
    }

    /// Sends chunks one at a time with a gap (so they arrive fragmented), then optionally closes cleanly.
    static func play(_ c: NWConnection, _ chunks: [Data], close: Bool) {
        guard let first = chunks.first else {
            if close {
                c.send(content: nil, contentContext: .finalMessage, isComplete: true,
                       completion: .contentProcessed { _ in c.cancel() })
            }
            return
        }
        c.send(content: first, completion: .contentProcessed { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { play(c, Array(chunks.dropFirst()), close: close) }
        })
    }

    func stop() { listener.cancel(); conns.forEach { $0.cancel() } }
}

final class PeersRecorder {
    var events: [String] = []
    var messages: [(Data, UUID)] = []
    var disconnects: [UUID] = []
    init(_ p: Peers) {
        p.onMessage = { [weak self] d, id in guard let self else { return }; messages.append((d, id)); events.append("message") }
        p.onDisconnect = { [weak self] id in guard let self else { return }; disconnects.append(id); events.append("disconnect") }
    }
}

extension Peers {
    static let testKey = "peers-checks-key"

    func connect(to s: PeersServer, as n: String = "srv") {
        key = Peers.testKey
        found[n] = .hostPort(host: .ipv4(.loopback), port: s.port)
        refresh()
    }

    /// Plays `chunks` from a scripted peer to a Peers outgoing connection and returns what Peers reported.
    static func scenario(_ what: String, chunks: [Data], close: Bool = true, settle: Double = 0.4, hello: Bool = true,
                         me: UUID = UUID(), peer: UUID = UUID(), configure: (Peers) -> Void = { _ in }) -> (Peers, PeersRecorder, PeersServer) {
        let p = Peers(identity: me)
        configure(p)
        let r = PeersRecorder(p)
        let s = PeersServer(p.parameters(testKey))
        s.hello = hello; s.id = peer
        s.script = { c in PeersServer.play(c, chunks, close: close) }
        p.connect(to: s)
        peersCheck(peersWait { !r.disconnects.isEmpty }, "\(what): connection was dropped")
        peersSpin(settle)  // any duplicate disconnect would show up here
        peersCheck(r.disconnects.count == 1, "\(what): disconnect exactly once (got \(r.disconnects.count))")
        peersCheck(p.conns.isEmpty && p.outgoing.isEmpty, "\(what): tables cleared")
        return (p, r, s)
    }

    static func runChecks() {
        // Watchdog: no scenario may hang the run.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { peersFail("timed out") }

        let body = Data("hello".utf8)

        do { // EOF with nothing sent
            let (_, r, s) = scenario("empty EOF", chunks: [])
            peersCheck(r.messages.isEmpty, "empty EOF: no message"); s.stop()
        }
        do { // EOF inside the 4-byte header
            let (_, r, s) = scenario("truncated header", chunks: [Data([0, 0])])
            peersCheck(r.messages.isEmpty, "truncated header: no message"); s.stop()
        }
        do { // EOF inside the body
            let (_, r, s) = scenario("truncated body", chunks: [peersFrame(Data(repeating: 7, count: 10)).prefix(7)].map { Data($0) })
            peersCheck(r.messages.isEmpty, "truncated body: no message"); s.stop()
        }
        do { // EOF after header only
            let (_, r, s) = scenario("header only", chunks: [Data([0, 0, 0, 5])])
            peersCheck(r.messages.isEmpty, "header only: no message"); s.stop()
        }
        do { // a complete frame immediately followed by EOF: delivered, then one disconnect
            let (_, r, s) = scenario("final frame", chunks: [peersFrame(body)])
            peersCheck(r.messages.count == 1 && r.messages[0].0 == body, "final frame: delivered")
            peersCheck(r.events == ["message", "disconnect"], "final frame: message before disconnect, got \(r.events)")
            peersCheck(r.messages[0].1 == r.disconnects[0], "final frame: same connection ID"); s.stop()
        }
        do { // oversized length: dropped while the peer keeps the connection open
            let (_, r, s) = scenario("oversized", chunks: [Data([0, 1, 0, 1])], close: false)
            peersCheck(r.messages.isEmpty, "oversized: no message"); s.stop()
        }
        do { // fragmented stream: byte-at-a-time header+body, a zero-length frame, then a second frame
            let bytes = peersFrame(body) + Data([0, 0, 0, 0]) + peersFrame(Data("ab".utf8))
            let p = Peers(identity: UUID()), r = PeersRecorder(p)
            let s = PeersServer(p.parameters(testKey))
            s.script = { c in PeersServer.play(c, bytes.map { Data([$0]) }, close: false) }
            p.connect(to: s)
            peersCheck(peersWait { r.messages.count == 2 }, "fragmented: both frames delivered")
            peersCheck(r.messages.map { $0.0 } == [body, Data("ab".utf8)], "fragmented: payloads intact and ordered")
            peersCheck(r.disconnects.isEmpty && p.conns.count == 1, "fragmented: connection still live")
            s.conns.forEach { $0.cancel() }
            peersCheck(peersWait { r.disconnects.count == 1 }, "fragmented: disconnect after peer closes")
            peersSpin(0.3)
            peersCheck(r.disconnects.count == 1, "fragmented: disconnect once")
            s.stop()
        }
        do { // incoming (accepted) connections use the same receive/teardown path
            let p = Peers(identity: UUID()), r = PeersRecorder(p)
            p.key = testKey
            let lp = p.parameters(testKey)
            lp.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let l = try! NWListener(using: lp)
            l.newConnectionHandler = { p.accept($0) }
            l.start(queue: .main)
            peersCheck(peersWait { l.state == .ready && l.port != nil }, "accept: listener ready")
            let c = NWConnection(to: .hostPort(host: .ipv4(.loopback), port: l.port!), using: p.parameters(testKey))
            c.start(queue: .main)
            PeersServer.play(c, [Peers.helloFrame(UUID()), peersFrame(body)], close: false)
            peersCheck(peersWait { r.messages.count == 1 }, "accept: message delivered")
            peersCheck(r.messages[0].0 == body && p.conns[r.messages[0].1] != nil, "accept: ID owns a live connection")
            peersCheck(p.send(body, to: [r.messages[0].1]).isEmpty, "accept: incoming connections are never send targets")
            c.cancel()
            peersCheck(peersWait { r.disconnects == [r.messages[0].1] }, "accept: disconnect reports same ID")
            peersSpin(0.3)
            peersCheck(r.disconnects.count == 1 && p.conns.isEmpty, "accept: disconnect once")
            l.cancel()
        }
        do { // recipient scoping across reconnect, then stop invalidation
            let me = UUID(), hf = Peers.helloFrame(me)
            let p = Peers(identity: me), r = PeersRecorder(p)
            let s = PeersServer(p.parameters(testKey))
            let sid = s.id.uuidString
            p.connect(to: s)
            peersCheck(peersWait { p.connection(to: sid) != nil && s.conns.count == 1 }, "reconnect: first connected")
            let a = p.outgoing["srv"]!
            peersCheck(p.connection(to: sid) == a && p.send(body, to: [a]) == [a], "reconnect: explicit send reaches A")
            peersCheck(peersWait { s.received[0] == hf + peersFrame(body) }, "reconnect: A's peer got hello + one frame")

            s.conns[0].cancel()
            peersCheck(peersWait { r.disconnects == [a] }, "reconnect: A dropped")
            peersCheck(p.send(body, to: [a]).isEmpty && p.connection(to: sid) == nil, "reconnect: nothing to send to while down")
            p.refresh()
            peersCheck(peersWait { s.conns.count == 2 && p.connection(to: sid) != nil }, "reconnect: second connected")
            let b = p.outgoing["srv"]!
            peersCheck(a != b, "reconnect: new connection has a new ID")
            peersCheck(p.send(body, to: [a]).isEmpty, "reconnect: stale recipient A is not served by B")
            peersCheck(p.send(body, to: []).isEmpty, "reconnect: empty recipient set sends nothing")
            peersSpin(0.3)
            peersCheck(s.received[1] == hf, "reconnect: B's peer got nothing for A")
            peersCheck(p.connection(to: sid) == b, "reconnect: identity resolves to B")
            peersCheck(p.send(body, to: [a, b]) == [b] && p.send(body, to: [b]) == [b], "reconnect: B receives when named")
            peersCheck(peersWait { s.received[1] == hf + peersFrame(body) + peersFrame(body) }, "reconnect: B's peer got exactly two frames")
            peersCheck(p.send(Data(count: 65537), to: [b]).isEmpty, "oversized send refused")

            let before = r.disconnects.count
            p.stop()  // synchronous: one disconnect for B, tables empty
            peersCheck(r.disconnects.count == before + 1 && r.disconnects.last == b, "stop: B reported synchronously, once")
            peersCheck(p.conns.isEmpty && p.outgoing.isEmpty && p.found.isEmpty && p.key == nil && p.ids.isEmpty, "stop: state cleared")
            peersCheck(p.send(body, to: [b]).isEmpty && p.connection(to: sid) == nil, "stop: B invalidated")
            p.refresh()
            peersCheck(p.conns.isEmpty, "stop: refresh without a key connects nothing")
            peersSpin(0.3)
            peersCheck(r.disconnects.count == before + 1, "stop: no duplicate disconnect")

            p.connect(to: s)  // same peer after restart gets a fresh ID that old recipients can't reach
            peersCheck(peersWait { s.conns.count == 3 && p.connection(to: sid) != nil }, "restart: connected")
            let c = p.outgoing["srv"]!
            peersCheck(c != a && c != b, "restart: fresh ID")
            peersCheck(p.send(body, to: [a, b]).isEmpty && p.send(body, to: [c]) == [c], "restart: only C is served")
            p.stop(); s.stop()
        }
        do { // explicit routing by identity; reconnect never retargets
            let p = Peers(identity: UUID()), r = PeersRecorder(p)
            let s1 = PeersServer(p.parameters(testKey)), s2 = PeersServer(p.parameters(testKey))
            let hf = Peers.helloFrame(p.ownID)
            peersCheck(p.connection(to: s1.id.uuidString) == nil && p.connection(to: "not a uuid") == nil, "route: unknown identity has no connection")
            p.connect(to: s1, as: "one")
            p.connect(to: s2, as: "two")
            peersCheck(peersWait { p.connection(to: s1.id.uuidString) != nil && p.connection(to: s2.id.uuidString) != nil }, "route: both connected")
            let one = p.connection(to: s1.id.uuidString)!, two = p.connection(to: s2.id.uuidString)!
            peersCheck(one != two, "route: ready identities have distinct IDs")
            peersCheck(p.status.map { $0.id } == [s1.id.uuidString, s2.id.uuidString], "route: status carries identities")
            peersCheck(p.connection(to: UUID().uuidString) == nil, "route: missing identity has no connection")
            peersCheck(p.send(body, to: [two]) == [two], "route: explicit ID is served")
            peersCheck(peersWait { s2.received[0] == hf + peersFrame(body) }, "route: chosen peer got the frame")
            peersSpin(0.3)
            peersCheck(s1.received[0] == hf, "route: unchosen peer got nothing")
            peersCheck(p.send(body, to: []).isEmpty, "route: empty set sends nothing")
            s2.conns[0].cancel()
            peersCheck(peersWait { r.disconnects == [two] }, "route: chosen connection dropped")
            peersCheck(p.connection(to: s2.id.uuidString) == nil, "route: dropped identity has no connection")
            p.refresh()
            peersCheck(peersWait { s2.conns.count == 2 && p.connection(to: s2.id.uuidString) != nil }, "route: reconnected")
            let two2 = p.connection(to: s2.id.uuidString)!
            peersCheck(two2 != two, "route: replacement has a new ID")
            peersCheck(p.send(body, to: [two]).isEmpty, "route: old ID never retargets replacement")
            peersSpin(0.3)
            peersCheck(s2.received[1] == hf && s1.received[0] == hf, "route: nobody received old-ID send")
            peersCheck(p.send(body, to: [two2]) == [two2], "route: new ID reaches replacement")
            peersCheck(peersWait { s2.received[1] == hf + peersFrame(body) }, "route: replacement got the frame")
            peersCheck(s1.received[0] == hf, "route: first peer still untouched")
            p.stop(); s1.stop(); s2.stop()
        }
        do { // same name, new identity: the old selection is not silently switched
            let p = Peers(identity: UUID())
            let s1 = PeersServer(p.parameters(testKey)), s2 = PeersServer(p.parameters(testKey))
            p.connect(to: s1)
            peersCheck(peersWait { p.connection(to: s1.id.uuidString) != nil }, "name reuse: first connected")
            s1.stop()
            peersCheck(peersWait { p.outgoing.isEmpty }, "name reuse: first dropped")
            p.connect(to: s2)
            peersCheck(peersWait { p.connection(to: s2.id.uuidString) != nil }, "name reuse: second connected")
            peersCheck(p.connection(to: s1.id.uuidString) == nil, "name reuse: old identity not routed to new peer")
            peersCheck(p.status.map { $0.id } == [s2.id.uuidString] && p.status.map { $0.name } == ["srv"], "name reuse: status shows new identity")
            p.stop(); s2.stop()
        }
        do { // same identity under a new name: reconnects, same identity routes
            let p = Peers(identity: UUID())
            let s = PeersServer(p.parameters(testKey))
            p.connect(to: s, as: "old")
            peersCheck(peersWait { p.connection(to: s.id.uuidString) != nil }, "rename: connected as old")
            p.found = [:]
            p.connect(to: s, as: "new")
            peersCheck(peersWait { p.status.map { $0.name } == ["new"] && p.connection(to: s.id.uuidString) != nil }, "rename: reconnected as new")
            peersCheck(p.status.map { $0.id } == [s.id.uuidString], "rename: same identity")
            p.stop(); s.stop()
        }
        do { // hello must be first, well-formed, current, and not our own identity
            func hello(_ version: UInt8, magic: String = "UCSH", _ id: UUID = UUID()) -> Data {
                peersFrame(Data(magic.utf8) + Data([version]) + withUnsafeBytes(of: id.uuid) { Data($0) })
            }
            let me = UUID()
            let bad: [(String, Data)] = [
                ("old version", hello(0)),
                ("future version", hello(2)),
                ("bad magic", hello(1, magic: "XXXX")),
                ("short hello", peersFrame(Data("UCSH".utf8) + Data([1, 2, 3]))),
                ("application frame first", peersFrame(body)),
                ("empty frame first", Data([0, 0, 0, 0])),
                ("own identity", hello(1, me)),
            ]
            for (what, first) in bad {
                let (_, r, s) = scenario("hello: \(what)", chunks: [first, peersFrame(body)], close: false, hello: false, me: me)
                peersCheck(r.messages.isEmpty, "hello: \(what): nothing delivered"); s.stop()
            }
            let (_, r, s) = scenario("self hello", chunks: [peersFrame(body)], close: false, me: me, peer: me)
            peersCheck(r.messages.isEmpty, "self hello: nothing delivered"); s.stop()
        }
        do { // handshake deadline runs from connect, before any header byte
            let t = Date()
            let (_, r, s) = scenario("handshake expiry", chunks: [], close: false, hello: false) { $0.handshakeTimeout = 0.4 }
            peersCheck(Date().timeIntervalSince(t) >= 0.35 && r.messages.isEmpty, "handshake expiry: not before deadline"); s.stop()
        }
        do { // partial header, partial body, and trickle all expire from the first byte
            let (_, r1, s1) = scenario("partial header", chunks: [Data([0, 0])], close: false) { $0.frameTimeout = 0.4 }
            peersCheck(r1.messages.isEmpty, "partial header: nothing delivered"); s1.stop()
            let (_, r2, s2) = scenario("partial body", chunks: [peersFrame(body).prefix(6).map { $0 }].map { Data($0) }, close: false) { $0.frameTimeout = 0.4 }
            peersCheck(r2.messages.isEmpty, "partial body: nothing delivered"); s2.stop()
            let slow = peersFrame(Data(repeating: 1, count: 100)).map { Data([$0]) }  // ~1s of trickle
            let (_, r3, s3) = scenario("trickle", chunks: slow, close: false) { $0.frameTimeout = 0.4 }
            peersCheck(r3.messages.isEmpty, "trickle: deadline not extended by arriving bytes"); s3.stop()
        }
        do { // authenticated idle sockets live on, with no deadline armed
            let p = Peers(identity: UUID()), r = PeersRecorder(p)
            p.handshakeTimeout = 0.3; p.frameTimeout = 0.3
            let s = PeersServer(p.parameters(testKey))
            p.connect(to: s)
            peersCheck(peersWait { p.connection(to: s.id.uuidString) != nil }, "idle: connected")
            PeersServer.play(s.conns[0], [peersFrame(body)], close: false)
            peersCheck(peersWait { r.messages.count == 1 }, "idle: frame delivered")
            peersSpin(1.0)
            peersCheck(r.disconnects.isEmpty && p.connection(to: s.id.uuidString) != nil, "idle: still connected")
            peersCheck(p.handshakes.isEmpty && p.frameDeadlines.isEmpty, "idle: no deadlines pending")
            p.stop(); s.stop()
            peersCheck(p.handshakes.isEmpty && p.frameDeadlines.isEmpty && p.buffers.isEmpty, "idle: stop cleans deadlines")
        }
        do { // incoming cap applies before retention and releases on close
            let p = Peers(identity: UUID())
            p.key = testKey; p.maxIncoming = 2; p.handshakeTimeout = 60
            let lp = p.parameters(testKey)
            lp.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let l = try! NWListener(using: lp)
            l.newConnectionHandler = { p.accept($0) }
            l.start(queue: .main)
            peersCheck(peersWait { l.state == .ready && l.port != nil }, "cap: listener ready")
            func dial() -> NWConnection {
                let c = NWConnection(to: .hostPort(host: .ipv4(.loopback), port: l.port!), using: p.parameters(testKey))
                c.start(queue: .main); return c
            }
            let c1 = dial(), c2 = dial()
            peersCheck(peersWait { p.conns.count == 2 }, "cap: two accepted")
            let c3 = dial()
            peersSpin(0.6)
            peersCheck(p.conns.count == 2 && p.incoming.count == 2, "cap: third not retained")
            c3.cancel()
            c1.cancel()
            peersCheck(peersWait { p.conns.count == 1 }, "cap: closing releases a slot")
            let c4 = dial()
            peersCheck(peersWait { p.conns.count == 2 }, "cap: slot reused")
            c2.cancel(); c4.cancel(); p.stop(); l.cancel()
        }
        do { // wrong key: TLS never completes, no hello, nothing routable
            let p = Peers(identity: UUID()), r = PeersRecorder(p)
            let s = PeersServer(p.parameters("wrong-key"))
            p.connect(to: s)
            peersSpin(1.0)
            peersCheck(p.connection(to: s.id.uuidString) == nil && p.status.allSatisfy { $0.id == nil }, "wrong key: not routable")
            peersCheck(r.messages.isEmpty && s.received.allSatisfy { $0.isEmpty }, "wrong key: no frames either way")
            p.stop(); s.stop()
        }
        print("Peers transport checks passed")
    }
}

@main struct PeersChecks {
    static func main() { Peers.runChecks() }
}
