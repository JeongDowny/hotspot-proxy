import Foundation
import Network
import os

/// Proxy serving HTTP (incl. CONNECT) and SOCKS5 on the same port.
final class ProxyServer {
    let queue = DispatchQueue(label: "proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var live: [ObjectIdentifier: Session] = [:]
    var onStats: ((Int, UInt64) -> Void)?
    var onState: ((String?) -> Void)?
    private let bytes = OSAllocatedUnfairLock(initialState: UInt64(0))
    private lazy var udp = UdpRelay(queue: queue)
    /// Each session gets a serial queue targeting this concurrent queue, so connections run in parallel across cores.
    private let work = DispatchQueue(label: "proxy.sessions", qos: .userInitiated, attributes: .concurrent)
    private var reaper: DispatchSourceTimer?
    private var ticks = 0

    func start(port: UInt16) {
        stop()
        Limits.raiseFileLimit()
        do {
            let params = Tcp.params()
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready: self?.onState?(nil)
                case .failed(let e): self?.onState?("Listener error: \(e)")
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
            queue.async { [self] in
                udp.onBytes = { [weak self] n in self?.bytes.withLock { $0 &+= UInt64(n) } }
                udp.start(port: port)
                startReaper()
            }
        } catch {
            onState?("Failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        queue.async { [weak self] in
            self?.reaper?.cancel(); self?.reaper = nil
            self?.udp.stop()
            self?.live.values.forEach { s in s.queue.async { s.close() } }
            self?.live.removeAll()
            self?.report()
        }
    }

    private func accept(_ c: NWConnection) {
        let s = Session(client: c, queue: DispatchQueue(label: "proxy.s", target: work))
        let id = ObjectIdentifier(s)
        live[id] = s
        s.onBytes = { [weak self] n in self?.bytes.withLock { $0 &+= UInt64(n) } }
        s.onClose = { [weak self] in self?.queue.async { self?.live[id] = nil } }
        s.queue.async { s.start() }
    }

    /// Closes sessions that will never finish on their own: a client that never sends its request,
    /// a half-closed pair whose other side never sends FIN, and pairs with no traffic for minutes.
    /// Without this, idle sessions pile up until the app hits its file limit; then iOS stops accepting
    /// on the listener (clients see a connect timeout) and upstream dials fail (SOCKS reply 5).
    private func startReaper() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            for s in self.live.values { s.queue.async { s.reapIfStale(now: now) } }
            self.ticks += 1
            if self.ticks % 6 == 0 { Diag.log("proxy: live=\(self.live.count) fds=\(Limits.openFiles())") }
        }
        t.resume()
        reaper = t
    }

    /// Called only while the UI is visible (never wakes the main thread in background).
    private func report() {
        let n = live.count, b = bytes.withLock { $0 }
        onStats?(n, b)
    }
    func pollStats() { queue.async { [weak self] in self?.report() } }
}

enum Tcp {
    static func params() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        return NWParameters(tls: nil, tcp: tcp)
    }
    /// Outbound legs leave through cellular only. With the phone on Wi-Fi the default route would
    /// exit through the Wi-Fi line (e.g. the office IP); without cellular the connect times out instead.
    static func upstreamParams() -> NWParameters {
        let p = params()
        p.requiredInterfaceType = .cellular
        return p
    }
    static let chunk = 128 * 1024
}

final class Session {
    let client: NWConnection
    var upstream: NWConnection?
    let queue: DispatchQueue
    var buf = Data()
    var closed = false
    private var piping = false
    private var holdsUdp = false
    private var lastActive = DispatchTime.now().uptimeNanoseconds
    private var finished = 0   // directions that hit EOF; session closes at 2
    var onBytes: ((Int) -> Void)?
    var onClose: (() -> Void)?

    init(client: NWConnection, queue: DispatchQueue) { self.client = client; self.queue = queue }

    func start() {
        client.stateUpdateHandler = { [weak self] s in
            if case .failed = s { self?.close() }
            if case .cancelled = s { self?.close() }
        }
        client.start(queue: queue)
        need(1) { [weak self] in
            guard let self else { return }
            if self.buf.first == 0x05 { self.socksGreeting() } else { self.readHttpHeader() }
        }
    }

    /// Limits in seconds: request handshake, one direction already closed, no traffic at all.
    static let handshakeLimit: UInt64 = 20, halfOpenLimit: UInt64 = 60, idleLimit: UInt64 = 600

    func reapIfStale(now: UInt64) {
        guard !closed, !holdsUdp else { return }
        let idle = (now &- lastActive) / 1_000_000_000
        let limit = !piping ? Self.handshakeLimit : finished > 0 ? Self.halfOpenLimit : Self.idleLimit
        if idle > limit { close() }
    }

    // MARK: buffered reading
    private func need(_ n: Int, _ then: @escaping () -> Void) {
        if buf.count >= n { then(); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.buf.append(data) }
            if err != nil || (done && self.buf.count < n) { self.close(); return }
            self.need(n, then)
        }
    }

    private func take(_ n: Int) -> Data {
        let d = buf.prefix(n); buf.removeFirst(n); return Data(d)
    }

    // MARK: SOCKS5
    private func socksGreeting() {
        need(2) { [self] in
            let nm = Int(buf[buf.startIndex + 1])
            need(2 + nm) { [self] in
                _ = take(2 + nm)
                client.send(content: Data([5, 0]), completion: .contentProcessed { _ in })
                socksRequest()
            }
        }
    }

    private func socksRequest() {
        need(5) { [self] in
            let b = Array(buf.prefix(5))
            guard b[0] == 5, b[1] == 1 || b[1] == 3 else { reply(7); close(); return }
            let cmd = b[1]
            let atyp = b[3]
            let addrLen: Int
            switch atyp {
            case 1: addrLen = 4
            case 3: addrLen = 1 + Int(b[4])
            case 4: addrLen = 16
            default: reply(8); close(); return
            }
            need(4 + addrLen + 2) { [self] in
                let r = Array(take(4 + addrLen + 2))
                let a = Array(r[4..<(4 + addrLen)])
                let host: String
                switch atyp {
                case 1: host = a.map(String.init).joined(separator: ".")
                case 3: host = String(decoding: a[1...], as: UTF8.self)
                default: host = stride(from: 0, to: 16, by: 2).map { String(format: "%x", (UInt16(a[$0]) << 8) | UInt16(a[$0 + 1])) }.joined(separator: ":")
                }
                let port = (UInt16(r[4 + addrLen]) << 8) | UInt16(r[5 + addrLen])
                if cmd == 3 { udpAssociate(); return }
                connect(host: host, port: port) { [self] ok in
                    if ok { reply(0); pipe() }
                    else {  // flush the failure reply before closing, otherwise the client just sees EOF
                        client.send(content: Data([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [weak self] _ in self?.close() })
                    }
                }
            }
        }
    }

    /// UDP ASSOCIATE: reply with the UDP relay on the same IP/port and hold until the TCP control connection closes.
    private func udpAssociate() {
        var resp = Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        if case .hostPort(let h, let p)? = client.currentPath?.localEndpoint, case .ipv4(let v4) = h {
            resp = Data([5, 0, 0, 1]) + v4.rawValue + Data([UInt8(p.rawValue >> 8), UInt8(p.rawValue & 0xff)])
        }
        client.send(content: resp, completion: .contentProcessed { _ in })
        holdsUdp = true   // lives as long as the client keeps the control connection
        holdOpen()
    }

    private func holdOpen() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
            if done || err != nil { self?.close() } else { self?.holdOpen() }
        }
    }

    private func reply(_ code: UInt8) {
        client.send(content: Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in })
    }

    // MARK: HTTP
    private func readHttpHeader() {
        if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
            buf.removeSubrange(buf.startIndex..<r.upperBound)
            handleHttp(head)
            return
        }
        if buf.count > 64 * 1024 { close(); return }
        need(buf.count + 1) { [weak self] in self?.readHttpHeader() }
    }

    private func handleHttp(_ head: String) {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { close(); return }
        let method = parts[0], target = parts[1], version = parts[2]

        if method.uppercased() == "CONNECT" {
            let (h, p) = splitHostPort(target, defaultPort: 443)
            connect(host: h, port: p) { [self] ok in
                if ok {
                    client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    pipe()
                } else {
                    client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
                }
            }
            return
        }

        guard let url = URL(string: target), let host = url.host else {
            client.send(content: Data("HTTP/1.1 400 Bad Request\r\nX-Proxy: hotspot\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }
        let port = UInt16(url.port ?? 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        lines[0] = "\(method) \(path) \(version)"
        lines = lines.filter {
            let k = $0.lowercased()
            return !(k.hasPrefix("proxy-connection:") || k.hasPrefix("connection:") || k.hasPrefix("keep-alive:") || k.hasPrefix("proxy-authorization:"))
        }
        lines.append("Connection: close")
        let newHead = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connect(host: host, port: port) { [self] ok in
            guard ok else {
                client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
                return
            }
            upstream?.send(content: newHead, completion: .contentProcessed { _ in })
            pipe()
        }
    }

    private func splitHostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16) {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            let h = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            return (h, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        if let i = s.lastIndex(of: ":"), let p = UInt16(s[s.index(after: i)...]) { return (String(s[..<i]), p) }
        return (s, defaultPort)
    }

    // MARK: upstream + relay
    private func connect(host: String, port: UInt16, _ done: @escaping (Bool) -> Void) {
        guard let p = NWEndpoint.Port(rawValue: port) else { done(false); return }
        let up = NWConnection(host: NWEndpoint.Host(host), port: p, using: Tcp.upstreamParams())
        upstream = up
        var fired = false
        up.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready: if !fired { fired = true; done(true) }
            case .failed:
                if !fired { fired = true; done(false) } else { self?.close() }
            case .waiting:
                // Transient on cellular (radio wake-up, path flap). Keep waiting; the timer below bounds it.
                break
            case .cancelled: self?.close()
            default: break
            }
        }
        up.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak up] in
            guard !fired, let up else { return }
            fired = true; up.cancel(); done(false)
        }
    }

    private func pipe() {
        guard let up = upstream else { close(); return }
        piping = true; lastActive = DispatchTime.now().uptimeNanoseconds
        if !buf.isEmpty { let d = buf; buf = Data(); up.send(content: d, completion: .contentProcessed { _ in }) }
        relay(from: client, to: up)
        relay(from: up, to: client)
    }

    /// On EOF in one direction, forward only a FIN (half-close) and keep relaying the other direction.
    private func relay(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: Tcp.chunk) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if err != nil { self.close(); return }
            let payload = (data?.isEmpty == false) ? data : nil
            if let payload { self.onBytes?(payload.count); self.lastActive = DispatchTime.now().uptimeNanoseconds }
            if payload == nil && !done { self.relay(from: from, to: to); return }
            // Data and EOF can arrive in one callback (small response + FIN). Send the data as a normal
            // message first; sending it together with .finalMessage lost it on the client side.
            if done, let payload {
                to.send(content: payload, completion: .contentProcessed { [weak self] e in
                    guard let self, !self.closed else { return }
                    if e != nil { self.close(); return }
                    self.finish(to)
                })
                return
            }
            if done { self.finish(to); return }
            to.send(content: payload, completion: .contentProcessed { [weak self] e in
                guard let self, !self.closed else { return }
                if e != nil { self.close(); return }
                self.relay(from: from, to: to)
            })
        }
    }

    /// Forward only a FIN (half-close); the session closes once both directions finished.
    private func finish(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self, !self.closed else { return }
            self.finished += 1
            if self.finished == 2 { self.close() }
        })
    }

    func close() {
        if closed { return }
        closed = true
        client.cancel(); upstream?.cancel()
        onClose?()
    }
}

enum Limits {
    /// iOS starts apps with a soft limit of 256 descriptors. Every proxied TCP pair holds 2,
    /// so ~120 concurrent Mac connections (browser + Claude + KakaoTalk) exhaust it.
    static func raiseFileLimit() {
        var r = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &r) == 0 else { return }
        let before = r.rlim_cur
        r.rlim_cur = min(r.rlim_max, rlim_t(OPEN_MAX))
        let ok = setrlimit(RLIMIT_NOFILE, &r) == 0
        var after = rlimit(); getrlimit(RLIMIT_NOFILE, &after)
        Diag.log("limits: nofile \(before) -> \(after.rlim_cur) (max \(r.rlim_max), ok=\(ok))")
    }

    static func openFiles() -> Int {
        var r = rlimit(); getrlimit(RLIMIT_NOFILE, &r)
        let top = Int32(min(r.rlim_cur, 16384))
        return (0..<top).reduce(0) { $0 + (fcntl($1, F_GETFD) != -1 ? 1 : 0) }
    }
}
