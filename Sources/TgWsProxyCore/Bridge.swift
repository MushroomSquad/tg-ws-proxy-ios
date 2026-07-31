import Foundation

public final class Stats: @unchecked Sendable {
    private let lock = NSLock()
    public var connectionsTotal: Int64 = 0
    public var connectionsActive: Int64 = 0
    public var connectionsWs: Int64 = 0
    public var connectionsTcpFallback: Int64 = 0
    public var connectionsCfproxy: Int64 = 0
    public var connectionsFronting: Int64 = 0
    public var connectionsBad: Int64 = 0
    public var wsErrors: Int64 = 0
    public var bytesUp: Int64 = 0
    public var bytesDown: Int64 = 0
    public var poolHits: Int64 = 0
    public var poolMisses: Int64 = 0
    public var cfPoolHits: Int64 = 0
    public var cfPoolMisses: Int64 = 0

    public init() {}

    public func addBytesUp(_ n: Int) { lock.lock(); bytesUp += Int64(n); lock.unlock() }
    public func addBytesDown(_ n: Int) { lock.lock(); bytesDown += Int64(n); lock.unlock() }
    public func inc(_ keyPath: WritableKeyPath<Stats, Int64>) {
        lock.lock(); self[keyPath: keyPath] += 1; lock.unlock()
    }

    public func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        let poolTotal = poolHits + poolMisses
        let poolS = poolTotal > 0 ? "\(poolHits)/\(poolTotal)" : "n/a"
        let cfTotal = cfPoolHits + cfPoolMisses
        let cfS = cfTotal > 0 ? "\(cfPoolHits)/\(cfTotal)" : "n/a"
        return "total=\(connectionsTotal) active=\(connectionsActive) ws=\(connectionsWs) " +
            "tcp_fb=\(connectionsTcpFallback) cf=\(connectionsCfproxy) front=\(connectionsFronting) " +
            "bad=\(connectionsBad) err=\(wsErrors) pool=\(poolS) cf_pool=\(cfS) " +
            "up=\(ProtocolConstants.humanBytes(bytesUp)) down=\(ProtocolConstants.humanBytes(bytesDown))"
    }

    public func reset() {
        lock.lock()
        connectionsTotal = 0
        connectionsActive = 0
        connectionsWs = 0
        connectionsTcpFallback = 0
        connectionsCfproxy = 0
        connectionsFronting = 0
        connectionsBad = 0
        wsErrors = 0
        bytesUp = 0
        bytesDown = 0
        poolHits = 0
        poolMisses = 0
        cfPoolHits = 0
        cfPoolMisses = 0
        lock.unlock()
    }
}

public final class Balancer: @unchecked Sendable {
    private let lock = NSLock()
    private var domains: [String] = []
    private var dcToDomain: [Int: String] = [:]

    public init() {}

    public func updateDomainsList(_ domainsList: [String]) {
        lock.lock(); defer { lock.unlock() }
        if Set(domains) == Set(domainsList), domains.count == domainsList.count { return }
        domains = domainsList
        dcToDomain.removeAll()
        if !domains.isEmpty {
            for dc in [1, 2, 3, 4, 5, 203] {
                dcToDomain[dc] = domains.randomElement()
            }
        }
    }

    @discardableResult
    public func updateDomainForDc(_ dcId: Int, domain: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if dcToDomain[dcId] == domain { return false }
        dcToDomain[dcId] = domain
        return true
    }

    public func getDomainsForDc(_ dcId: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let current = dcToDomain[dcId]
        let shuffled = domains.shuffled()
        var out: [String] = []
        if let current { out.append(current) }
        for d in shuffled where d != current {
            out.append(d)
        }
        return out
    }
}

public enum Bridge {
    public static func bridgeWsReencrypt(
        client: TcpStream,
        ws: RawWebSocket,
        label: String,
        ctx: CryptoCtx,
        stats: Stats,
        log: @escaping (String) -> Void,
        dc: Int? = nil,
        isMedia: Bool = false,
        splitter: MsgSplitter? = nil
    ) async {
        let dcTag = dc.map { "DC\($0)\(isMedia ? "m" : "")" } ?? "DC?"
        var upBytes: Int64 = 0
        var downBytes: Int64 = 0
        var upPackets = 0
        var downPackets = 0
        let start = Date()
        let closeReason = LockedBox("normal")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    while true {
                        guard let chunk = try await client.read(maxLength: 256 * 1024), !chunk.isEmpty else {
                            let tail = splitter?.flush() ?? []
                            if let first = tail.first { try await ws.send(first) }
                            break
                        }
                        stats.addBytesUp(chunk.count)
                        upBytes += Int64(chunk.count)
                        upPackets += 1
                        let plain = try ctx.cltDec.update(chunk)
                        let out = try ctx.tgEnc.update(plain)
                        if let splitter {
                            let parts = try splitter.split(out)
                            if parts.isEmpty { continue }
                            if parts.count > 1 { try await ws.sendBatch(parts) }
                            else { try await ws.send(parts[0]) }
                        } else {
                            try await ws.send(out)
                        }
                    }
                } catch {
                    closeReason.value = "client: \(type(of: error))"
                }
            }
            group.addTask {
                do {
                    while true {
                        guard let data = try await ws.recv() else {
                            if closeReason.value == "normal" { closeReason.value = "upstream: ws_close" }
                            break
                        }
                        stats.addBytesDown(data.count)
                        downBytes += Int64(data.count)
                        downPackets += 1
                        let plain = try ctx.tgDec.update(data)
                        let out = try ctx.cltEnc.update(plain)
                        try await client.write(out)
                    }
                } catch {
                    closeReason.value = "upstream: \(type(of: error))"
                }
            }
            await group.next()
            group.cancelAll()
        }

        let elapsed = Date().timeIntervalSince(start)
        log("[\(label)] \(dcTag) WS session closed (\(closeReason.value)): " +
            "^\(ProtocolConstants.humanBytes(upBytes)) (\(upPackets) pkts) " +
            "v\(ProtocolConstants.humanBytes(downBytes)) (\(downPackets) pkts) in \(String(format: "%.1f", elapsed))s")
        await ws.closeQuietly()
        client.close()
    }

    public static func bridgeTcpReencrypt(
        client: TcpStream,
        remote: TcpStream,
        label: String,
        ctx: CryptoCtx,
        stats: Stats,
        log: @escaping (String) -> Void
    ) async {
        var upBytes: Int64 = 0
        var downBytes: Int64 = 0
        var upPackets = 0
        var downPackets = 0
        let start = Date()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await forward(src: client, dst: remote, isUp: true, ctx: ctx, stats: stats) { n in
                    upBytes += Int64(n); upPackets += 1
                }
            }
            group.addTask {
                try? await forward(src: remote, dst: client, isUp: false, ctx: ctx, stats: stats) { n in
                    downBytes += Int64(n); downPackets += 1
                }
            }
            await group.next()
            group.cancelAll()
        }
        client.close()
        remote.close()
        let elapsed = Date().timeIntervalSince(start)
        log("[\(label)] TCP bridge closed: " +
            "^\(ProtocolConstants.humanBytes(upBytes)) (\(upPackets) pkts) " +
            "v\(ProtocolConstants.humanBytes(downBytes)) (\(downPackets) pkts) in \(String(format: "%.1f", elapsed))s")
    }

    private static func forward(
        src: TcpStream,
        dst: TcpStream,
        isUp: Bool,
        ctx: CryptoCtx,
        stats: Stats,
        onChunk: (Int) -> Void
    ) async throws {
        while true {
            guard let chunk = try await src.read(), !chunk.isEmpty else { break }
            let out: Data
            if isUp {
                stats.addBytesUp(chunk.count)
                out = try ctx.tgEnc.update(try ctx.cltDec.update(chunk))
            } else {
                stats.addBytesDown(chunk.count)
                out = try ctx.cltEnc.update(try ctx.tgDec.update(chunk))
            }
            onChunk(chunk.count)
            try await dst.write(out)
        }
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    init(_ value: T) { _value = value }
}

public enum Fallback {
    private static let maxCfDomainTries = 3
    private static let tcpFirstByteMs = 4_000
    private static let frontingIp = "149.154.167.220"

    private static func formatErr(_ error: Error) -> String {
        if let e = error as? WsHandshakeError {
            return "WsHandshakeError \(e.statusCode) \(e.statusLine)"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    private static func alternateTcpIp(dc: Int, primary: String, config: ProxyConfig) -> String? {
        let fromConfig = config.dcRedirects[dc]
        let candidates = [fromConfig, frontingIp].compactMap { $0 }
        return candidates.first { $0 != primary }
    }

    public static func doFallback(
        client: TcpStream,
        relayInit: Data,
        label: String,
        dc: Int,
        isTestDc: Bool,
        isMedia: Bool,
        mediaTag: String,
        ctx: CryptoCtx,
        config: ProxyConfig,
        stats: Stats,
        balancer: Balancer,
        cfWorkerPool: CfWorkerPool,
        log: @escaping (String) -> Void,
        splitter: MsgSplitter?
    ) async -> Bool {
        let ipTable = isTestDc ? ProtocolConstants.dcTestIps : ProtocolConstants.dcDefaultIps
        let fallbackDst = ipTable[dc]
        let useCf = config.fallbackCfproxy && !isTestDc
        let workerDomains = config.cfproxyWorkerDomains

        var methods: [String] = []
        if !workerDomains.isEmpty, fallbackDst != nil { methods.append("cf_worker") }
        if isMedia {
            if fallbackDst != nil { methods.append("tcp") }
            if useCf { methods.append("cf") }
        } else {
            if useCf { methods.append("cf") }
            if fallbackDst != nil { methods.append("tcp") }
        }

        for method in methods {
            switch method {
            case "cf_worker":
                if await cfWorkerFallback(
                    client: client, relayInit: relayInit, label: label, ctx: ctx, dc: dc,
                    isTestDc: isTestDc, isMedia: isMedia, fallbackDst: fallbackDst!,
                    config: config, stats: stats, cfWorkerPool: cfWorkerPool, log: log, splitter: splitter
                ) { return true }
            case "cf":
                if await cfProxyFallback(
                    client: client, relayInit: relayInit, label: label, ctx: ctx, dc: dc,
                    isMedia: isMedia, config: config, stats: stats, balancer: balancer, log: log, splitter: splitter
                ) { return true }
            case "tcp":
                let primary = fallbackDst!
                log("[\(label)] DC\(dc)\(mediaTag) -> TCP fallback to \(primary):443")
                if await tcpFallback(client: client, dst: primary, relayInit: relayInit, label: label, ctx: ctx, config: config, stats: stats, log: log) {
                    return true
                }
                if let alt = alternateTcpIp(dc: dc, primary: primary, config: config) {
                    log("[\(label)] DC\(dc)\(mediaTag) -> TCP fallback retry \(alt):443")
                    if await tcpFallback(client: client, dst: alt, relayInit: relayInit, label: label, ctx: ctx, config: config, stats: stats, log: log) {
                        return true
                    }
                }
            default:
                break
            }
        }
        return false
    }

    private static func cfWorkerFallback(
        client: TcpStream,
        relayInit: Data,
        label: String,
        ctx: CryptoCtx,
        dc: Int,
        isTestDc: Bool,
        isMedia: Bool,
        fallbackDst: String,
        config: ProxyConfig,
        stats: Stats,
        cfWorkerPool: CfWorkerPool,
        log: @escaping (String) -> Void,
        splitter: MsgSplitter?
    ) async -> Bool {
        let mediaTag = isMedia ? " media" : ""
        for workerDomain in config.cfproxyWorkerDomains.shuffled() {
            var ws: RawWebSocket?
            if !isTestDc {
                ws = await cfWorkerPool.get(dc: dc, workerDomain: workerDomain, fallbackDst: fallbackDst)
                if ws != nil {
                    log("[\(label)] DC\(dc)\(mediaTag) -> CF worker pool hit for \(fallbackDst)")
                }
            }
            if ws == nil {
                let encoded = fallbackDst.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fallbackDst
                let path = "/apiws?dst=\(encoded)&dc=\(dc)"
                log("[\(label)] DC\(dc)\(mediaTag) -> trying CF worker \(workerDomain) for \(fallbackDst)")
                do {
                    ws = try await RawWebSocket.connect(
                        host: workerDomain, domain: workerDomain, timeoutMs: 10_000,
                        path: path, bufferSize: config.bufferSize
                    )
                } catch {
                    log("[\(label)] DC\(dc)\(mediaTag) CF worker \(workerDomain) failed: \(formatErr(error))")
                }
            }
            guard let ws else { continue }
            stats.inc(\.connectionsCfproxy)
            try? await ws.send(relayInit)
            await Bridge.bridgeWsReencrypt(
                client: client, ws: ws, label: label, ctx: ctx, stats: stats, log: log,
                dc: dc, isMedia: isMedia, splitter: splitter
            )
            return true
        }
        return false
    }

    private static func cfProxyFallback(
        client: TcpStream,
        relayInit: Data,
        label: String,
        ctx: CryptoCtx,
        dc: Int,
        isMedia: Bool,
        config: ProxyConfig,
        stats: Stats,
        balancer: Balancer,
        log: @escaping (String) -> Void,
        splitter: MsgSplitter?
    ) async -> Bool {
        let mediaTag = isMedia ? " media" : ""
        log("[\(label)] DC\(dc)\(mediaTag) -> trying CF proxy")
        var ws: RawWebSocket?
        var chosen: String?
        let candidates = Array(balancer.getDomainsForDc(dc).prefix(maxCfDomainTries))
        for base in candidates {
            let domain = "kws\(dc).\(base)"
            do {
                ws = try await RawWebSocket.connect(host: domain, domain: domain, timeoutMs: 10_000, bufferSize: config.bufferSize)
                chosen = base
                break
            } catch {
                log("[\(label)] DC\(dc)\(mediaTag) CF proxy failed: \(formatErr(error))")
                if let e = error as? WsHandshakeError, [502, 503].contains(e.statusCode) {
                    return false
                }
            }
        }
        guard let connected = ws else { return false }
        if let chosen, balancer.updateDomainForDc(dc, domain: chosen) {
            log("[\(label)] Switched active CF domain")
        }
        stats.inc(\.connectionsCfproxy)
        try? await connected.send(relayInit)
        await Bridge.bridgeWsReencrypt(
            client: client, ws: connected, label: label, ctx: ctx, stats: stats, log: log,
            dc: dc, isMedia: isMedia, splitter: splitter
        )
        return true
    }

    private static func tcpFallback(
        client: TcpStream,
        dst: String,
        relayInit: Data,
        label: String,
        ctx: CryptoCtx,
        config: ProxyConfig,
        stats: Stats,
        log: @escaping (String) -> Void
    ) async -> Bool {
        let remote: TcpStream
        do {
            remote = try await TcpStream.connect(host: dst, port: 443, timeoutMs: 10_000)
            try await remote.write(relayInit)
        } catch {
            log("[\(label)] TCP fallback to \(dst):443 failed: \(formatErr(error))")
            return false
        }

        do {
            // Require first reply within tcpFirstByteMs
            let first = try await withThrowingTaskGroup(of: Data?.self) { group -> Data? in
                group.addTask { try await remote.read(maxLength: 65536) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(tcpFirstByteMs) * 1_000_000)
                    return nil
                }
                let result = try await group.next() ?? nil
                group.cancelAll()
                return result ?? nil
            }
            guard let first, !first.isEmpty else {
                log("[\(label)] TCP fallback dead (no reply) from \(dst):443")
                remote.close()
                return false
            }
            let out = try ctx.cltEnc.update(try ctx.tgDec.update(first))
            try await client.write(out)
            stats.addBytesDown(first.count)
            stats.inc(\.connectionsTcpFallback)
            await Bridge.bridgeTcpReencrypt(client: client, remote: remote, label: label, ctx: ctx, stats: stats, log: log)
            return true
        } catch {
            log("[\(label)] TCP fallback to \(dst):443 failed: \(formatErr(error))")
            remote.close()
            return false
        }
    }
}
