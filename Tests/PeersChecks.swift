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
    static func scenario(_ what: String, chunks: [Data], close: Bool = true, settle: Double = 0.4) -> (Peers, PeersRecorder, PeersServer) {
        let p = Peers()
        let r = PeersRecorder(p)
        let s = PeersServer(p.parameters(testKey))
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
            let p = Peers(), r = PeersRecorder(p)
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
            let p = Peers(), r = PeersRecorder(p)
            p.key = testKey
            let lp = p.parameters(testKey)
            lp.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let l = try! NWListener(using: lp)
            l.newConnectionHandler = { p.accept($0) }
            l.start(queue: .main)
            peersCheck(peersWait { l.state == .ready && l.port != nil }, "accept: listener ready")
            let c = NWConnection(to: .hostPort(host: .ipv4(.loopback), port: l.port!), using: p.parameters(testKey))
            c.start(queue: .main)
            PeersServer.play(c, [peersFrame(body)], close: false)
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
            let p = Peers(), r = PeersRecorder(p)
            let s = PeersServer(p.parameters(testKey))
            p.connect(to: s)
            peersCheck(peersWait { p.conns.values.allSatisfy { $0.state == .ready } && s.conns.count == 1 }, "reconnect: first connected")
            let a = p.outgoing["srv"]!
            peersCheck(p.connection(to: "srv") == a && p.send(body, to: [a]) == [a], "reconnect: explicit send reaches A")
            peersCheck(peersWait { s.received[0] == peersFrame(body) }, "reconnect: A's peer got exactly one frame")

            s.conns[0].cancel()
            peersCheck(peersWait { r.disconnects == [a] }, "reconnect: A dropped")
            peersCheck(p.send(body, to: [a]).isEmpty && p.connection(to: "srv") == nil, "reconnect: nothing to send to while down")
            p.refresh()
            peersCheck(peersWait { s.conns.count == 2 && p.conns.values.allSatisfy { $0.state == .ready } }, "reconnect: second connected")
            let b = p.outgoing["srv"]!
            peersCheck(a != b, "reconnect: new connection has a new ID")
            peersCheck(p.send(body, to: [a]).isEmpty, "reconnect: stale recipient A is not served by B")
            peersCheck(p.send(body, to: []).isEmpty, "reconnect: empty recipient set sends nothing")
            peersSpin(0.3)
            peersCheck(s.received[1].isEmpty, "reconnect: B's peer got nothing for A")
            peersCheck(p.connection(to: "srv") == b, "reconnect: name resolves to B")
            peersCheck(p.send(body, to: [a, b]) == [b] && p.send(body, to: [b]) == [b], "reconnect: B receives when named")
            peersCheck(peersWait { s.received[1] == peersFrame(body) + peersFrame(body) }, "reconnect: B's peer got exactly two frames")
            peersCheck(p.send(Data(count: 65537), to: [b]).isEmpty, "oversized send refused")

            let before = r.disconnects.count
            p.stop()  // synchronous: one disconnect for B, tables empty
            peersCheck(r.disconnects.count == before + 1 && r.disconnects.last == b, "stop: B reported synchronously, once")
            peersCheck(p.conns.isEmpty && p.outgoing.isEmpty && p.found.isEmpty && p.key == nil, "stop: state cleared")
            peersCheck(p.send(body, to: [b]).isEmpty && p.connection(to: "srv") == nil, "stop: B invalidated")
            p.refresh()
            peersCheck(p.conns.isEmpty, "stop: refresh without a key connects nothing")
            peersSpin(0.3)
            peersCheck(r.disconnects.count == before + 1, "stop: no duplicate disconnect")

            p.connect(to: s)  // same peer after restart gets a fresh ID that old recipients can't reach
            peersCheck(peersWait { s.conns.count == 3 && p.conns.values.allSatisfy { $0.state == .ready } }, "restart: connected")
            let c = p.outgoing["srv"]!
            peersCheck(c != a && c != b, "restart: fresh ID")
            peersCheck(p.send(body, to: [a, b]).isEmpty && p.send(body, to: [c]) == [c], "restart: only C is served")
            p.stop(); s.stop()
        }
        do { // explicit routing: two ready destinations, only the named ID receives; reconnect never retargets
            let p = Peers(), r = PeersRecorder(p)
            let s1 = PeersServer(p.parameters(testKey)), s2 = PeersServer(p.parameters(testKey))
            peersCheck(p.connection(to: "one") == nil, "route: unknown name has no connection")
            p.connect(to: s1, as: "one")
            p.connect(to: s2, as: "two")
            peersCheck(peersWait { s1.conns.count == 1 && s2.conns.count == 1 && p.conns.values.allSatisfy { $0.state == .ready } }, "route: both connected")
            let one = p.connection(to: "one"), two = p.connection(to: "two")
            peersCheck(one != nil && two != nil && one != two, "route: ready names have distinct IDs")
            peersCheck(p.connection(to: "missing") == nil, "route: missing name has no connection")
            peersCheck(p.send(body, to: [two!]) == [two!], "route: explicit ID is served")
            peersCheck(peersWait { s2.received[0] == peersFrame(body) }, "route: chosen peer got the frame")
            peersSpin(0.3)
            peersCheck(s1.received[0].isEmpty, "route: unchosen peer got nothing")
            peersCheck(p.send(body, to: []).isEmpty, "route: empty set sends nothing")
            s2.conns[0].cancel()
            peersCheck(peersWait { r.disconnects == [two!] }, "route: chosen connection dropped")
            peersCheck(p.connection(to: "two") == nil, "route: dropped name has no connection")
            p.refresh()
            peersCheck(peersWait { s2.conns.count == 2 && p.connection(to: "two") != nil }, "route: reconnected")
            let two2 = p.connection(to: "two")!
            peersCheck(two2 != two!, "route: replacement has a new ID")
            peersCheck(p.send(body, to: [two!]).isEmpty, "route: old ID never retargets replacement")
            peersSpin(0.3)
            peersCheck(s2.received[1].isEmpty && s1.received[0].isEmpty, "route: nobody received old-ID send")
            peersCheck(p.send(body, to: [two2]) == [two2], "route: new ID reaches replacement")
            peersCheck(peersWait { s2.received[1] == peersFrame(body) }, "route: replacement got the frame")
            peersCheck(s1.received[0].isEmpty, "route: first peer still untouched")
            p.stop(); s1.stop(); s2.stop()
        }
        print("Peers transport checks passed")
    }
}

@main struct PeersChecks {
    static func main() { Peers.runChecks() }
}
