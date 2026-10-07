import Foundation
import Network
import CryptoKit
import Security

/// Finds other Macs on the local network running uc-steer and exchanges messages with the ones using the same pairing key.
/// Bonjour `_uc-steer._tcp`; TCP with TLS 1.2 using a pre-shared key derived from the pairing key; each message is a
/// 4-byte big-endian length, then the payload. A Mac sends only on connections it opened, so each pair has one path per
/// direction.
final class Peers {
    /// Called with the sender connection's lifetime ID (incoming or outgoing).
    var onMessage: (Data, UUID) -> Void = { _, _ in }
    /// Called exactly once per connection, synchronously from stop/start or when it dies.
    var onDisconnect: (UUID) -> Void = { _ in }
    /// Other Macs found, sorted by name, with a short state for the menu.
    var status: [(name: String, state: String)] { found.keys.sorted().map { (name: $0, state: states[$0] ?? "connecting") } }

    private static let type = "_uc-steer._tcp"
    private static let maxFrame = 65536

    private let name: String?
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

    init(name: String? = nil) { self.name = name }

    func start(key: String?) {
        stop()
        guard let key, !key.isEmpty else { return }
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

    /// Ready outgoing connection ID for `name`, nil if absent or not ready. The ID is that connection's lifetime.
    func connection(to name: String) -> UUID? {
        guard let id = outgoing[name], conns[id]?.state == .ready else { return nil }
        return id
    }

    /// Queues one frame on ready outgoing connections whose exact ID is in `recipients` and returns those IDs,
    /// so a replacement connection never receives it. Oversized frames are not sent.
    @discardableResult func send(_ message: Data, to recipients: Set<UUID>) -> Set<UUID> {
        guard message.count <= Peers.maxFrame else { log("peers: refusing oversized frame"); return [] }
        var frame = withUnsafeBytes(of: UInt32(message.count).bigEndian) { Data($0) }
        frame.append(message)
        var sent: Set<UUID> = []
        for id in outgoing.values where recipients.contains(id) {
            guard let c = conns[id], c.state == .ready else { continue }
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
            c.stateUpdateHandler = { [weak self, weak c] s in
                guard let self, let c, self.conns[id] === c else { return }
                switch s {
                case .ready: self.setState(n, "connected")
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
        let id = UUID()
        conns[id] = c
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, self.conns[id] === c else { return }
            switch s {
            case .failed(let e): log("peers: incoming failed: \(e)"); self.drop(id)
            case .waiting(let e): log("peers: incoming waiting: \(e)"); self.drop(id)
            case .cancelled: self.drop(id)
            default: break
            }
        }
        c.start(queue: .main)
        receive(c, id)
    }

    /// Removes and cancels the connection, then reports it. The table removal is the once-only gate, so every
    /// path (EOF, error, cancel, stop, vanished peer) can call this; stale callbacks of replaced connections no-op.
    private func drop(_ id: UUID) {
        guard let c = conns.removeValue(forKey: id) else { return }
        for (n, o) in outgoing where o == id {
            outgoing[n] = nil
            if states[n] == "connected" { setState(n, "disconnected") }
        }
        c.cancel()
        onDisconnect(id)
    }

    /// Reads 4-byte big-endian length, then payload, until EOF or error; any of those drops the connection.
    private func receive(_ c: NWConnection, _ id: UUID) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak c] d, _, done, err in
            guard let self, let c, self.conns[id] === c else { return }
            guard err == nil, let d, d.count == 4 else { self.drop(id); return }
            let len = d.reduce(0) { $0 << 8 | Int($1) }
            guard len <= Peers.maxFrame else { log("peers: oversized frame, dropping connection"); self.drop(id); return }
            guard len > 0 else { if done { self.drop(id) } else { self.receive(c, id) }; return }
            guard !done else { self.drop(id); return }  // EOF after a header: the body can never arrive
            c.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self, weak c] body, _, done, err in
                guard let self, let c, self.conns[id] === c else { return }
                guard err == nil, let body, body.count == len else { self.drop(id); return }
                self.onMessage(body, id)
                if done { self.drop(id) } else if self.conns[id] === c { self.receive(c, id) }
            }
        }
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
