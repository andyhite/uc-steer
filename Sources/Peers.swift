import AppKit
import Foundation
import Network
import CryptoKit
import Security

/// Finds other Macs on the local network running uc-steer and exchanges messages with the ones using the same pairing key.
/// Bonjour `_uc-steer._tcp`; TCP with TLS 1.2 using a pre-shared key derived from the pairing key; each message is a
/// 4-byte big-endian length, then the payload. A Mac sends only on connections it opened, so each pair has one path per
/// direction. Each side's first frame, inside TLS, is a versioned hello carrying its persisted per-install UUID; a
/// connection is routable and its frames accepted only after a valid hello from another identity. Bonjour names are
/// for display and discovery only.
final class Peers {
    /// Called with the sender connection's lifetime ID (incoming or outgoing).
    var onMessage: (Data, UUID) -> Void = { _, _ in }
    /// Called exactly once per connection, synchronously from stop/start or when it dies.
    var onDisconnect: (UUID) -> Void = { _ in }
    /// Other Macs found, sorted by name, with a short state for the menu. `id` is the peer's authenticated identity
    /// UUID string, nil until its hello is verified.
    var status: [(id: String?, name: String, state: String)] {
        found.keys.sorted().map { n in
            (id: outgoing[n].flatMap { ids[$0] }?.uuidString, name: n, state: states[n] ?? "connecting")
        }
    }

    /// UserDefaults key of this install's persisted identity UUID.
    static let identityKey = "peerIdentity"
    private static let type = "_uc-steer._tcp"
    private static let maxFrame = 65536
    private static let helloPrefix = Data("UCSH".utf8) + Data([1])  // magic, version 1
    private static let helloLength = 5 + 16

    /// Limits: live incoming connections; seconds from connect to verified hello (covers a silent peer); seconds from a
    /// frame's first byte to its last, fixed so trickling doesn't extend it. Verified idle connections never expire.
    var maxIncoming = 32
    var handshakeTimeout = 10.0
    var frameTimeout = 10.0

    /// Length-prefixed hello frame announcing `id`.
    static func helloFrame(_ id: UUID) -> Data {
        let hello = helloPrefix + withUnsafeBytes(of: id.uuid) { Data($0) }
        return withUnsafeBytes(of: UInt32(hello.count).bigEndian) { Data($0) } + hello
    }

    private static func parseHello(_ d: Data) -> UUID? {
        guard d.count == helloLength, d.prefix(helloPrefix.count) == helloPrefix else { return nil }
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: d.suffix(16)) }
        return UUID(uuid: bytes)
    }

    private let name: String?
    private let injectedID: UUID?
    private lazy var ownID: UUID = {
        if let injectedID { return injectedID }
        let d = UserDefaults.standard
        if let s = d.string(forKey: Peers.identityKey), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        d.set(u.uuidString, forKey: Peers.identityKey)
        return u
    }()
    private var ownName: String?
    private var key: String?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var timer: Timer?
    private var found: [String: NWEndpoint] = [:]
    private var conns: [UUID: NWConnection] = [:]  // every live connection, in or out, by lifetime ID
    private var outgoing: [String: UUID] = [:]     // peer name -> ID of the connection we opened
    private var states: [String: String] = [:]
    private var pending: Set<String> = []
    private var ids: [UUID: UUID] = [:]            // connection ID -> peer identity, only once its hello verified
    private var incoming: Set<UUID> = []
    private var buffers: [UUID: Data] = [:]        // received bytes not yet forming a whole frame
    private var handshakes: [UUID: DispatchWorkItem] = [:]
    private var frameDeadlines: [UUID: DispatchWorkItem] = [:]

    private let monitor = NWPathMonitor()
    private var observing = false
    private var lastPath: String?
    private var restartWork: DispatchWorkItem?

    init(name: String? = nil, identity: UUID? = nil) {
        self.name = name
        injectedID = identity
    }

    /// Started by the first `start(key:)`, so an instance that never starts ignores wake and path events.
    private func observe() {
        guard !observing else { return }
        observing = true
        // After sleep, Bonjour registration, browse results and sockets are stale; rebuild once the network settles.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRestart("wake")
        }
        monitor.pathUpdateHandler = { [weak self] p in
            let sig = "\(p.status) \(p.availableInterfaces.map(\.name).sorted())"
            guard let self, sig != self.lastPath else { return }
            let first = self.lastPath == nil
            self.lastPath = sig
            if !first { self.scheduleRestart("network change") }
        }
        monitor.start(queue: .main)
    }

    /// Debounced: wake and path events arrive in bursts while Wi-Fi reassociates.
    private func scheduleRestart(_ why: String) {
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let key = self.key else { return }
            log("peers: restarting after \(why)")
            self.start(key: key)
        }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    func start(key: String?) {
        stop()
        guard let key, !key.isEmpty else { return }
        observe()
        self.key = key
        ownName = name
        do {
            let l = try NWListener(using: parameters(key))
            l.service = name.map { NWListener.Service(name: $0, type: Peers.type) } ?? NWListener.Service(type: Peers.type)
            // Bonjour may rename us on conflict; the registered name is the one to exclude from browsing.
            l.serviceRegistrationUpdateHandler = { [weak self, weak l] change in
                guard let self, let l, self.listener === l,
                      case .add(let ep) = change, case .service(let n, _, _, _) = ep else { return }
                self.ownName = n
                self.refresh()
            }
            l.newConnectionHandler = { [weak self, weak l] c in
                guard let self, let l, self.listener === l else { c.cancel(); return }
                self.accept(c)
            }
            l.stateUpdateHandler = { s in
                if case .failed(let e) = s { log("peers: listener failed: \(e)") }
            }
            l.start(queue: .main)
            listener = l
        } catch { log("peers: listener error: \(error)") }

        let b = NWBrowser(for: .bonjour(type: Peers.type, domain: nil), using: parameters(key))
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            guard let self, let b, self.browser === b else { return }
            var f: [String: NWEndpoint] = [:]
            for r in results { if case .service(let n, _, _, _) = r.endpoint { f[n] = r.endpoint } }
            self.found = f
            self.refresh()
        }
        b.stateUpdateHandler = { s in
            if case .failed(let e) = s { log("peers: browser failed: \(e)") }
        }
        b.start(queue: .main)
        browser = b
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Ready outgoing connection ID whose verified identity is `identity`, nil if absent or not ready. The ID is that
    /// connection's lifetime.
    func connection(to identity: String) -> UUID? {
        guard let u = UUID(uuidString: identity) else { return nil }
        return outgoing.values.first { ids[$0] == u && conns[$0]?.state == .ready }
    }

    /// Queues one frame on ready outgoing connections whose exact ID is in `recipients` and returns those IDs,
    /// so a replacement connection never receives it. Oversized frames are not sent.
    @discardableResult func send(_ message: Data, to recipients: Set<UUID>) -> Set<UUID> {
        guard message.count <= Peers.maxFrame else { log("peers: refusing oversized frame"); return [] }
        var frame = withUnsafeBytes(of: UInt32(message.count).bigEndian) { Data($0) }
        frame.append(message)
        var sent: Set<UUID> = []
        for id in outgoing.values where recipients.contains(id) {
            guard let c = conns[id], c.state == .ready, ids[id] != nil else { continue }
            c.send(content: frame, completion: .contentProcessed { [weak self, weak c] err in
                guard let self, let c, self.conns[id] === c, err != nil else { return }
                self.drop(id)
            })
            sent.insert(id)
        }
        return sent
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        let old = conns.keys
        outgoing = [:]; pending = []; found = [:]; states = [:]; ownName = nil; key = nil
        old.forEach(drop)
    }

    /// The server drops a wrong-key handshake without telling the client, so the client just hangs in
    /// "preparing"; a connection still not ready one tick later is most likely a key mismatch.
    private func tick() {
        // Restart if the listener or browser failed, e.g. local network access was denied, then allowed.
        var failed = listener == nil
        if case .failed = listener?.state { failed = true }
        if case .failed = browser?.state { failed = true }
        if failed, let key { log("peers: restarting"); start(key: key); return }

        for n in pending { if let id = outgoing[n], let c = conns[id], c.state != .ready {
            setState(n, "can't connect; check the pairing key"); drop(id)
        } }
        pending = Set(outgoing.filter { conns[$0.value]?.state != .ready }.keys)
        refresh()
    }

    /// Logs only changes, so a peer that stays unreachable doesn't log every retry.
    private func setState(_ n: String, _ state: String, _ error: NWError? = nil) {
        if states[n] != state { log("peers: \(n): \(state)" + (error.map { " (\($0))" } ?? "")) }
        states[n] = state
    }

    /// Drops vanished peers and connects to any without a live outgoing connection.
    private func refresh() {
        guard let key else { return }
        found[ownName ?? ""] = nil
        for (n, id) in outgoing where found[n] == nil { drop(id) }
        for n in states.keys where found[n] == nil { states[n] = nil }
        for (n, ep) in found where outgoing[n] == nil {
            let c = NWConnection(to: ep, using: parameters(key))
            let id = UUID()
            conns[id] = c
            outgoing[n] = id
            states[n] = states[n] ?? "connecting"
            handshakes[id] = expire(id, after: handshakeTimeout, "no valid hello")
            c.stateUpdateHandler = { [weak self, weak c] s in
                guard let self, let c, self.conns[id] === c else { return }
                switch s {
                case .ready: self.sendHello(c, id)
                case .failed(let e), .waiting(let e):
                    if case .tls = e { self.setState(n, "pairing key doesn't match", e) }
                    else { self.setState(n, "disconnected", e) }
                    self.drop(id)
                case .cancelled: self.drop(id)
                default: break
                }
            }
            c.start(queue: .main)
            receive(c, id)
        }
    }

    private func accept(_ c: NWConnection) {
        guard incoming.count < maxIncoming else { log("peers: too many incoming connections"); c.cancel(); return }
        let id = UUID()
        conns[id] = c
        incoming.insert(id)
        handshakes[id] = expire(id, after: handshakeTimeout, "no valid hello")
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, self.conns[id] === c else { return }
            switch s {
            case .ready: self.sendHello(c, id)
            case .failed(let e): log("peers: incoming failed: \(e)"); self.drop(id)
            case .waiting(let e): log("peers: incoming waiting: \(e)"); self.drop(id)
            case .cancelled: self.drop(id)
            default: break
            }
        }
        c.start(queue: .main)
        receive(c, id)
    }

    private func sendHello(_ c: NWConnection, _ id: UUID) {
        c.send(content: Peers.helloFrame(ownID), completion: .contentProcessed { [weak self, weak c] err in
            guard let self, let c, self.conns[id] === c, err != nil else { return }
            self.drop(id)
        })
    }

    /// Drops `id` after `secs` unless the returned item is cancelled first (by `drop`, or on success).
    private func expire(_ id: UUID, after secs: Double, _ why: String) -> DispatchWorkItem {
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.conns[id] != nil else { return }
            log("peers: dropping connection: \(why)")
            self.drop(id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: w)
        return w
    }

    /// Removes and cancels the connection, then reports it. The table removal is the once-only gate, so every
    /// path (EOF, error, cancel, stop, vanished peer) can call this; stale callbacks of replaced connections no-op.
    private func drop(_ id: UUID) {
        guard let c = conns.removeValue(forKey: id) else { return }
        for (n, o) in outgoing where o == id {
            outgoing[n] = nil
            if states[n] == "connected" { setState(n, "disconnected") }
        }
        ids[id] = nil; incoming.remove(id); buffers[id] = nil
        handshakes.removeValue(forKey: id)?.cancel()
        frameDeadlines.removeValue(forKey: id)?.cancel()
        c.cancel()
        onDisconnect(id)
    }

    /// Accumulates bytes and parses whole frames; any protocol violation, error or EOF drops the connection.
    private func receive(_ c: NWConnection, _ id: UUID) {
        c.receive(minimumIncompleteLength: 1, maximumLength: Peers.maxFrame) { [weak self] d, _, done, err in
            guard let self, self.conns[id] === c else { return }
            if let d { self.buffers[id, default: Data()].append(d) }
            guard self.consume(id) else { self.drop(id); return }
            guard self.conns[id] === c else { return }
            if err != nil || done { self.drop(id) } else { self.receive(c, id) }
        }
    }

    /// Handles every complete frame in the buffer; false on a protocol violation. The first frame must be a valid
    /// hello from another identity. A partial frame left over arms a fixed deadline for the rest of it.
    private func consume(_ id: UUID) -> Bool {
        var consumed = false
        guard let buf = buffers[id] else { return true }
        var off = 0  // parsed prefix; trimmed once so coalesced frames aren't recopied
        while buf.count - off >= 4 {
            let len = buf.dropFirst(off).prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard len <= Peers.maxFrame, ids[id] != nil || len == Peers.helloLength else {
                log("peers: bad frame length, dropping connection"); return false
            }
            guard buf.count - off >= 4 + len else { break }
            let payload = Data(buf.dropFirst(off + 4).prefix(len))
            off += 4 + len
            consumed = true
            if ids[id] == nil {
                guard let peer = Peers.parseHello(payload), peer != ownID else { log("peers: invalid hello, dropping connection"); return false }
                ids[id] = peer
                handshakes.removeValue(forKey: id)?.cancel()
                for (n, o) in outgoing where o == id { setState(n, "connected") }
            } else if len > 0 {
                onMessage(payload, id)
                if conns[id] == nil { return true }
            }
        }
        if off > 0 { buffers[id] = Data(buf.dropFirst(off)) }
        if consumed { frameDeadlines.removeValue(forKey: id)?.cancel() }
        if buffers[id]?.isEmpty == false, frameDeadlines[id] == nil {
            frameDeadlines[id] = expire(id, after: frameTimeout, "incomplete frame")
        }
        return true
    }

    private func parameters(_ key: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let o = tls.securityProtocolOptions
        let psk = Data(HMAC<SHA256>.authenticationCode(for: Data("uc-steer".utf8), using: SymmetricKey(data: Data(key.utf8))))
        sec_protocol_options_add_pre_shared_key(o,
            psk.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
            Data("uc-steer".utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(o, tls_ciphersuite_t(rawValue: 0x00A8)!)
        sec_protocol_options_set_min_tls_protocol_version(o, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(o, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }
}
