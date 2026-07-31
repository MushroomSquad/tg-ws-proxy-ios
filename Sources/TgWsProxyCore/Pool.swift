import Foundation

public final class WsPool: @unchecked Sendable {
    private struct Entry {
        let ws: RawWebSocket
        let created: Date
    }

    private let config: () -> ProxyConfig
    private let stats: Stats
    private let log: (String) -> Void
    private let lock = NSLock()
    private var idle: [String: [Entry]] = [:]
    private var refilling = Set<String>()
    private var refillFailures: [String: Int] = [:]
    private var refillAfter: [String: Date] = [:]
    public var tryFrontingFirst = false

    private static let maxAge: TimeInterval = 120
    private static let refillBackoffInitial: TimeInterval = 60
    private static let refillBackoffMax: TimeInterval = 3600

    public init(config: @escaping () -> ProxyConfig, stats: Stats, log: @escaping (String) -> Void) {
        self.config = config
        self.stats = stats
        self.log = log
    }

    private func key(_ dc: Int, _ isMedia: Bool) -> String { "\(dc):\(isMedia)" }

    public func get(dc: Int, isMedia: Bool, targetIp: String, domains: [String], allowRefill: Bool = true) async -> RawWebSocket? {
        let k = key(dc, isMedia)
        let now = Date()
        lock.lock()
        var bucket = idle[k] ?? []
        while !bucket.isEmpty {
            let entry = bucket.removeFirst()
            if now.timeIntervalSince(entry.created) > Self.maxAge || entry.ws.isClosing {
                Task { await entry.ws.closeQuietly() }
                continue
            }
            idle[k] = bucket
            lock.unlock()
            stats.bumpPoolHits()
            reportSuccess(dc: dc, isMedia: isMedia)
            if allowRefill { scheduleRefill(dc: dc, isMedia: isMedia, targetIp: targetIp, domains: domains) }
            return entry.ws
        }
        idle[k] = bucket
        lock.unlock()
        stats.bumpPoolMisses()
        if allowRefill { scheduleRefill(dc: dc, isMedia: isMedia, targetIp: targetIp, domains: domains) }
        return nil
    }

    public func reportSuccess(dc: Int, isMedia: Bool) {
        let k = key(dc, isMedia)
        lock.lock()
        refillFailures[k] = nil
        refillAfter[k] = nil
        lock.unlock()
    }

    public func scheduleRefill(dc: Int, isMedia: Bool, targetIp: String, domains: [String]) {
        let k = key(dc, isMedia)
        lock.lock()
        if refilling.contains(k) || (refillAfter[k].map { Date() < $0 } ?? false) {
            lock.unlock()
            return
        }
        refilling.insert(k)
        lock.unlock()
        Task {
            defer {
                lock.lock(); refilling.remove(k); lock.unlock()
            }
            await refill(dc: dc, isMedia: isMedia, targetIp: targetIp, domains: domains)
        }
    }

    private func refill(dc: Int, isMedia: Bool, targetIp: String, domains: [String]) async {
        let k = key(dc, isMedia)
        lock.lock()
        let needed = config().poolSize - (idle[k]?.count ?? 0)
        lock.unlock()
        if needed <= 0 { return }
        var connected = 0
        for _ in 0..<needed {
            guard let ws = await connectOne(targetIp: targetIp, domains: domains) else { continue }
            lock.lock()
            var bucket = idle[k] ?? []
            bucket.append(Entry(ws: ws, created: Date()))
            idle[k] = bucket
            lock.unlock()
            connected += 1
        }
        if connected > 0 {
            reportSuccess(dc: dc, isMedia: isMedia)
        } else {
            lock.lock()
            let failures = (refillFailures[k] ?? 0) + 1
            refillFailures[k] = failures
            let delay = min(Self.refillBackoffInitial * pow(2, Double(min(failures - 1, 6))), Self.refillBackoffMax)
            refillAfter[k] = Date().addingTimeInterval(delay)
            lock.unlock()
            log("WS pool refill failed for DC\(dc)\(isMedia ? "m" : ""), retry in \(Int(delay))s")
        }
    }

    private func connectOne(targetIp: String, domains: [String]) async -> RawWebSocket? {
        for domain in domains {
            if tryFrontingFirst, let ws = await connectFronted(targetIp: targetIp, domain: domain) {
                return ws
            }
            do {
                let ws = try await RawWebSocket.connect(
                    host: targetIp, domain: domain, timeoutMs: 8_000, bufferSize: config().bufferSize
                )
                tryFrontingFirst = false
                return ws
            } catch let e as WsHandshakeError {
                if e.isRedirect { continue }
                return nil
            } catch is URLError {
                if tryFrontingFirst { return nil }
                return await connectFronted(targetIp: targetIp, domain: domain)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func connectFronted(targetIp: String, domain: String) async -> RawWebSocket? {
        do {
            let ws = try await RawWebSocket.connect(
                host: targetIp, domain: domain, timeoutMs: 7_000, sni: "sprinthost.ru",
                bufferSize: config().bufferSize
            )
            stats.bumpConnectionsFronting()
            tryFrontingFirst = true
            return ws
        } catch {
            return nil
        }
    }

    public func warmup() {
        for (dc, targetIp) in config().dcRedirects {
            for isMedia in [false, true] {
                let domains = ProtocolConstants.wsDomains(dc: dc, isMedia: isMedia)
                scheduleRefill(dc: dc, isMedia: isMedia, targetIp: targetIp, domains: domains)
            }
        }
        log("WS pool warmup started for \(config().dcRedirects.count) DC(s)")
    }

    public func reset() {
        lock.lock()
        idle.removeAll()
        refilling.removeAll()
        refillFailures.removeAll()
        refillAfter.removeAll()
        tryFrontingFirst = false
        lock.unlock()
    }
}

public final class CfWorkerPool: @unchecked Sendable {
    private struct Entry {
        let ws: RawWebSocket
        let created: Date
    }

    private let config: () -> ProxyConfig
    private let stats: Stats
    private let log: (String) -> Void
    private let lock = NSLock()
    private var idle: [String: [Entry]] = [:]
    private var refilling = Set<String>()
    private static let maxAge: TimeInterval = 100

    public init(config: @escaping () -> ProxyConfig, stats: Stats, log: @escaping (String) -> Void) {
        self.config = config
        self.stats = stats
        self.log = log
    }

    private func key(_ dc: Int, _ worker: String) -> String { "\(dc):\(worker)" }

    public func get(dc: Int, workerDomain: String, fallbackDst: String) async -> RawWebSocket? {
        let k = key(dc, workerDomain)
        let now = Date()
        lock.lock()
        var bucket = idle[k] ?? []
        while !bucket.isEmpty {
            let entry = bucket.removeFirst()
            if now.timeIntervalSince(entry.created) > Self.maxAge || entry.ws.isClosing {
                Task { await entry.ws.closeQuietly() }
                continue
            }
            idle[k] = bucket
            lock.unlock()
            stats.bumpCfPoolHits()
            scheduleRefill(dc: dc, workerDomain: workerDomain, fallbackDst: fallbackDst)
            return entry.ws
        }
        idle[k] = bucket
        lock.unlock()
        stats.bumpCfPoolMisses()
        scheduleRefill(dc: dc, workerDomain: workerDomain, fallbackDst: fallbackDst)
        return nil
    }

    private func scheduleRefill(dc: Int, workerDomain: String, fallbackDst: String) {
        let k = key(dc, workerDomain)
        lock.lock()
        if refilling.contains(k) { lock.unlock(); return }
        refilling.insert(k)
        lock.unlock()
        Task {
            defer { lock.lock(); refilling.remove(k); lock.unlock() }
            lock.lock()
            let needed = config().poolSize - (idle[k]?.count ?? 0)
            lock.unlock()
            if needed <= 0 { return }
            for _ in 0..<needed {
                guard let ws = await connectOne(workerDomain: workerDomain, fallbackDst: fallbackDst, dc: dc) else { continue }
                lock.lock()
                var bucket = idle[k] ?? []
                bucket.append(Entry(ws: ws, created: Date()))
                idle[k] = bucket
                lock.unlock()
            }
        }
    }

    private func connectOne(workerDomain: String, fallbackDst: String, dc: Int) async -> RawWebSocket? {
        let encoded = fallbackDst.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fallbackDst
        let path = "/apiws?dst=\(encoded)&dc=\(dc)"
        do {
            return try await RawWebSocket.connect(
                host: workerDomain, domain: workerDomain, timeoutMs: 8_000,
                path: path, bufferSize: config().bufferSize
            )
        } catch {
            return nil
        }
    }

    public func warmup() {
        let cfFallbacks = ProtocolConstants.dcDefaultIps.filter { config().dcRedirects[$0.key] == nil }
        if cfFallbacks.isEmpty || config().cfproxyWorkerDomains.isEmpty { return }
        for worker in config().cfproxyWorkerDomains {
            for (dc, dst) in cfFallbacks {
                scheduleRefill(dc: dc, workerDomain: worker, fallbackDst: dst)
            }
        }
        log("CF worker pool warmup started for \(cfFallbacks.count) DC(s)")
    }

    public func reset() {
        lock.lock()
        idle.removeAll()
        refilling.removeAll()
        lock.unlock()
    }
}
