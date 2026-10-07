import Foundation
import Network
import CryptoKit
import Security

/// Finds other Macs on the local network running uc-steer and exchanges messages with the ones using the same pairing key.
/// Bonjour `_uc-steer._tcp`; TCP with TLS 1.2 using a pre-shared key derived from the pairing key; each message is a
/// 4-byte big-endian length, then the payload. A Mac sends only on connections it opened, so each pair has one path per
/// direction.
final class Peers {
    var onMessage: (Data) -> Void = { _ in }
    /// Other Macs found, sorted by name, with a short state for the menu.
    var status: [(name: String, state: String)] { found.keys.sorted().map { (name: $0, state: states[$0] ?? "connecting") } }
    var isConnected: Bool { outgoing.values.contains { $0.state == .ready } }

    private static let type = "_uc-steer._tcp"
    private static let maxFrame = 65536

    private let name: String?
    private var ownName: String?
    private var key: String?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var timer: Timer?
    private var found: [String: NWEndpoint] = [:]
    private var outgoing: [String: NWConnection] = [:]
    private var incoming: [NWConnection] = []
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
            l.serviceRegistrationUpdateHandler = { [weak self] change in
                guard case .add(let ep) = change, case .service(let n, _, _, _) = ep else { return }
                self?.ownName = n
                self?.refresh()
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { s in
                if case .failed(let e) = s { log("peers: listener failed: \(e)") }
            }
            l.start(queue: .main)
            listener = l
        } catch { log("peers: listener error: \(error)") }

        let b = NWBrowser(for: .bonjour(type: Peers.type, domain: nil), using: parameters(key))
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var f: [String: NWEndpoint] = [:]
            for r in results { if case .service(let n, _, _, _) = r.endpoint { f[n] = r.endpoint } }
            self?.found = f
            self?.refresh()
        }
        b.stateUpdateHandler = { s in
            if case .failed(let e) = s { log("peers: browser failed: \(e)") }
        }
        b.start(queue: .main)
        browser = b
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    @discardableResult func send(_ message: Data) -> Bool {
        var frame = Data(withUnsafeBytes(of: UInt32(message.count).bigEndian) { Array($0) })
        frame.append(message)
        let ready = outgoing.values.filter { $0.state == .ready }
        for c in ready { c.send(content: frame, completion: .contentProcessed { _ in }) }
        return !ready.isEmpty
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        outgoing.values.forEach { $0.cancel() }
        incoming.forEach { $0.cancel() }
        outgoing = [:]; incoming = []; pending = []; found = [:]; states = [:]; ownName = nil; key = nil
    }

    /// The server drops a wrong-key handshake without telling the client, so the client just hangs in
    /// "preparing"; a connection still not ready one tick later is most likely a key mismatch.
    private func tick() {
        // Restart if the listener or browser failed, e.g. local network access was denied, then allowed.
        var failed = listener == nil
        if case .failed = listener?.state { failed = true }
        if case .failed = browser?.state { failed = true }
        if failed, let key { log("peers: restarting"); start(key: key); return }

        for n in pending { if let c = outgoing[n], c.state != .ready {
            setState(n, "can't connect; check the pairing key"); c.cancel()
        } }
        pending = Set(outgoing.filter { $0.value.state != .ready }.keys)
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
        for n in outgoing.keys where found[n] == nil { outgoing.removeValue(forKey: n)?.cancel() }
        for n in states.keys where found[n] == nil { states[n] = nil }
        for (n, ep) in found where outgoing[n] == nil {
            let c = NWConnection(to: ep, using: parameters(key))
            outgoing[n] = c
            states[n] = states[n] ?? "connecting"
            c.stateUpdateHandler = { [weak self, weak c] s in
                guard let self, let c, self.outgoing[n] === c else { return }
                switch s {
                case .ready: self.setState(n, "connected")
                case .failed(let e), .waiting(let e):
                    if case .tls = e { self.setState(n, "pairing key doesn't match", e) }
                    else { self.setState(n, "disconnected", e) }
                    self.outgoing[n] = nil
                    c.cancel()
                case .cancelled: self.outgoing[n] = nil
                default: break
                }
            }
            c.start(queue: .main)
            receive(c)
        }
    }

    private func accept(_ c: NWConnection) {
        incoming.append(c)
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c else { return }
            switch s {
            case .failed(let e): log("peers: incoming failed: \(e)"); c.cancel()
            case .cancelled: self.incoming.removeAll { $0 === c }
            default: break
            }
        }
        c.start(queue: .main)
        receive(c)
    }

    /// Reads 4-byte big-endian length, then payload, forever.
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak c] d, _, _, err in
            guard let self, let c else { return }
            guard err == nil, let d, d.count == 4 else { return }
            let len = d.reduce(0) { $0 << 8 | Int($1) }
            guard len <= Peers.maxFrame else { log("peers: oversized frame, dropping connection"); c.cancel(); return }
            guard len > 0 else { self.receive(c); return }
            c.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self, weak c] body, _, _, err in
                guard let self, let c, err == nil, let body, body.count == len else { return }
                self.onMessage(body)
                self.receive(c)
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
