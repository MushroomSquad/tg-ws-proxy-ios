import Foundation
import Network

public final class ProxyServer: @unchecked Sendable {
    private var config: ProxyConfig
    private let log: (String) -> Void
    private let cachedCfDomains: [String]?

    private let lock = NSLock()
    private var running = false
    private var listener: NWListener?
    private var acceptTask: Task<Void, Never>?
    private var bgTask: Task<Void, Never>?

    public let stats = Stats()
    private let balancer = Balancer()
    private var wsPool: WsPool?
    private var cfWorkerPool: CfWorkerPool?
    private var cfDomainRefresh: CfDomainRefresh?

    private var wsBlacklist = Set<String>()
    private var dcFailUntil: [String: Date] = [:]
    private var ipFailUntil: [String: Date] = [:]

    private static let ipFailCooldown: TimeInterval = 3600
    private static let dcFailCooldown: TimeInterval = 60

    public init(config: ProxyConfig, log: @escaping (String) -> Void, cachedCfDomains: [String]? = nil) {
        self.config = config
        self.log = log
        self.cachedCfDomains = cachedCfDomains
    }

    public func updateConfig(_ newConfig: ProxyConfig) {
        lock.lock(); config = newConfig; lock.unlock()
    }

    public func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func refreshCfDomains() {
        if let cfDomainRefresh {
            cfDomainRefresh.refreshNow()
        } else {
            log("CF refresh unavailable (proxy stopped or custom domains set)")
        }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        guard config.secret.count == 32 else {
            throw ProxyConfigError.invalidSecret
        }

        stats.reset()
        wsBlacklist.removeAll()
        dcFailUntil.removeAll()
        ipFailUntil.removeAll()

        let cfg = config
        wsPool = WsPool(config: { [weak self] in
            self?.lock.lock(); defer { self?.lock.unlock() }
            return self?.config ?? cfg
        }, stats: stats, log: log)
        cfWorkerPool = CfWorkerPool(config: { [weak self] in
            self?.lock.lock(); defer { self?.lock.unlock() }
            return self?.config ?? cfg
        }, stats: stats, log: log)

        if config.fallbackCfproxy {
            let user = config.cfproxyUserDomains
            if !user.isEmpty {
                balancer.updateDomainsList(user)
            } else {
                let seed = (cachedCfDomains?.count ?? 0) >= 3 ? cachedCfDomains! : ProtocolConstants.cfproxyDefaultDomains
                balancer.updateDomainsList(seed)
                let refresh = CfDomainRefresh(
                    balancer: balancer,
                    hasUserDomains: { [weak self] in
                        self?.lock.lock(); defer { self?.lock.unlock() }
                        return !(self?.config.cfproxyUserDomains.isEmpty ?? true)
                    },
                    log: log
                )
                cfDomainRefresh = refresh
                refresh.start()
            }
        }

        let portValue = NWEndpoint.Port(rawValue: UInt16(config.port))!
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if config.host == "127.0.0.1" || config.host == "localhost" {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: portValue)
        }
        let listener = try NWListener(using: params, on: portValue)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleClient(connection) }
        }

        let host = config.host
        let port = config.port
        let secret = config.secret
        let redirects = config.dcRedirects
        let fallback = config.fallbackCfproxy
        let workers = config.cfproxyWorkerDomains
        let link = config.proxyLink()

        var startError: Error?
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let error):
                startError = error
                sem.signal()
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "tgws.listener"))
        _ = sem.wait(timeout: .now() + 5)
        if let startError { throw startError }

        self.listener = listener
        running = true

        if !CryptoSelfTest.run(log: log) {
            log("WARNING: crypto self-test failed — handshakes may fail on this device")
        }

        log(String(repeating: "=", count: 60))
        log("  Telegram MTProto WS Bridge Proxy (iOS)")
        log("  Listening on   \(host):\(port)")
        log("  Secret:        \(Self.maskSecret(secret))")
        log("  If bad handshake: Open in Telegram again (secret must match)")
        log("  Target DC IPs:")
        for dc in redirects.keys.sorted() {
            log("    DC\(dc): \(redirects[dc] ?? "")")
        }
        if fallback { log("  CF proxy:      enabled") }
        if !workers.isEmpty { log("  CF worker:     \(workers.joined(separator: " "))") }
        log(String(repeating: "=", count: 60))
        log("  Connect: \(link)")
        log(String(repeating: "=", count: 60))
        log("  Keep this app in the foreground — iOS may suspend the listener in background.")

        wsPool?.warmup()
        cfWorkerPool?.warmup()
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        listener?.cancel()
        listener = nil
        acceptTask?.cancel()
        acceptTask = nil
        cfDomainRefresh?.stop()
        cfDomainRefresh = nil
        wsPool?.reset()
        cfWorkerPool?.reset()
        let summary = stats.summary()
        lock.unlock()
        log("Proxy stopped. Final stats: \(summary)")
    }

    private func currentConfig() -> ProxyConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    private func handleClient(_ connection: NWConnection) async {
        stats.bumpConnectionsTotal()
        stats.bumpConnectionsActive(1)
        defer { stats.bumpConnectionsActive(-1) }

        let peer = "\(connection.endpoint)"
        let label = peer
        let client = TcpStream(connection: connection)
        do {
            try await TcpStream.startReady(connection: connection, timeoutMs: 10_000)
            let cfg = currentConfig()
            let secretBytes = try cfg.secretBytes()

            let handshake = try await client.readExact(ProtocolConstants.handshakeLen, timeoutMs: 10_000)
            guard let result = Handshake.tryHandshake(handshake: handshake, secret: secretBytes) else {
                stats.bumpConnectionsBad()
                let b0 = handshake.first.map { String(format: "0x%02X", $0) } ?? "?"
                log("[\(label)] bad handshake (wrong secret or proto) b0=\(b0) secret=\(Self.maskSecret(cfg.secret)) — re-open tg://proxy link from this app")
                client.close()
                return
            }

            var dc = result.dcId
            let isMedia = result.isMedia
            let protoTag = result.protoTag
            var isTestDc = cfg.forceTestDc || dc >= 10000
            if dc >= 10000 {
                log("[\(label)] test DC\(dc) -> DC\(dc - 10000)")
                dc -= 10000
                isTestDc = true
            }

            let protoInt: UInt32
            if protoTag == ProtocolConstants.protoTagAbridged {
                protoInt = ProtocolConstants.protoAbridgedInt
            } else if protoTag == ProtocolConstants.protoTagIntermediate {
                protoInt = ProtocolConstants.protoIntermediateInt
            } else {
                protoInt = ProtocolConstants.protoPaddedIntermediateInt
            }
            let dcIdx = isMedia ? -dc : dc
            let mediaTag = isMedia ? " media" : ""
            log("[\(label)] handshake ok: DC\(dc)\(mediaTag) proto=0x\(String(format: "%08X", protoInt))")

            let relayInit = try Handshake.generateRelayInit(protoTag: protoTag, dcIdx: dcIdx)
            let ctx = try Handshake.buildCryptoCtx(clientDecPrekeyIv: result.clientDecPrekeyIv, secret: secretBytes, relayInit: relayInit)
            let dcKey = "\(dc)\(isTestDc ? "t" : "")\(isMedia ? "m" : "")"
            let now = Date()
            let wsPath = isTestDc ? ProtocolConstants.wsPathTest : ProtocolConstants.wsPath
            let target = cfg.dcRedirects[dc]
            let isAnyCfFallback = cfg.fallbackCfproxy || !cfg.cfproxyWorkerDomains.isEmpty
            let splitter = try? MsgSplitter(relayInit: relayInit, proto: protoInt)

            lock.lock()
            let blacklisted = wsBlacklist.contains(dcKey)
            let ipCooling = target.map { now < (ipFailUntil[$0] ?? .distantPast) } ?? false
            lock.unlock()

            if cfg.dcRedirects[dc] == nil || blacklisted || (ipCooling && isAnyCfFallback) {
                if cfg.dcRedirects[dc] == nil {
                    log("[\(label)] DC\(dc) not in config -> fallback")
                } else if blacklisted {
                    log("[\(label)] DC\(dc)\(mediaTag) WS blacklisted -> fallback")
                } else {
                    log("[\(label)] DC\(dc)\(mediaTag) WS connect to \(target ?? "?") was timed out -> fallback")
                }
                let ok = await Fallback.doFallback(
                    client: client, relayInit: relayInit, label: label, dc: dc, isTestDc: isTestDc,
                    isMedia: isMedia, mediaTag: mediaTag, ctx: ctx, config: cfg, stats: stats,
                    balancer: balancer, cfWorkerPool: cfWorkerPool!, log: log, splitter: splitter
                )
                if !ok { log("[\(label)] DC\(dc)\(mediaTag) no fallback available") }
                return
            }

            lock.lock()
            let wsTimeout = now < (dcFailUntil[dcKey] ?? .distantPast) ? 2_000 : 5_000
            let allowPoolRefill = target.map { now >= (ipFailUntil[$0] ?? .distantPast) } ?? true
            lock.unlock()

            let domains = ProtocolConstants.wsDomains(dc: dc, isMedia: isMedia)
            var ws: RawWebSocket?
            var wsFailedRedirect = false
            var wsTimedOut = false
            var allRedirects = true

            if !isTestDc, let target {
                ws = await wsPool?.get(dc: dc, isMedia: isMedia, targetIp: target, domains: domains, allowRefill: allowPoolRefill)
                if ws != nil {
                    log("[\(label)] DC\(dc)\(mediaTag) -> pool hit via \(target)")
                }
            }

            if ws == nil, let target {
                for domain in domains {
                    let url = "wss://\(domain)\(wsPath)"
                    log("[\(label)] DC\(dc)\(mediaTag) -> \(url) via \(target)")
                    do {
                        ws = try await RawWebSocket.connect(
                            host: target, domain: domain, timeoutMs: wsTimeout,
                            path: wsPath, bufferSize: cfg.bufferSize
                        )
                        allRedirects = false
                        break
                    } catch let e as WsHandshakeError {
                        stats.bumpWsErrors()
                        if e.isRedirect {
                            wsFailedRedirect = true
                            log("[\(label)] DC\(dc)\(mediaTag) got \(e.statusCode) from \(domain) -> \(e.location ?? "?")")
                            continue
                        } else {
                            allRedirects = false
                            log("[\(label)] DC\(dc)\(mediaTag) WS handshake: \(e.statusLine)")
                        }
                    } catch is URLError {
                        stats.bumpWsErrors()
                        wsTimedOut = true
                        log("[\(label)] DC\(dc)\(mediaTag) WS connect timed out via \(domain)")
                        break
                    } catch {
                        stats.bumpWsErrors()
                        allRedirects = false
                        log("[\(label)] DC\(dc)\(mediaTag) WS connect failed: \(error.localizedDescription)")
                    }
                }
            }

            if ws == nil {
                lock.lock()
                if wsTimedOut, let target {
                    ipFailUntil[target] = now.addingTimeInterval(Self.ipFailCooldown)
                    log("[\(label)] DC\(dc)\(mediaTag) WS connect to \(target) timed out, cooldown for \(Int(Self.ipFailCooldown))s")
                }
                if wsFailedRedirect && allRedirects {
                    wsBlacklist.insert(dcKey)
                    log("[\(label)] DC\(dc)\(mediaTag) blacklisted for WS (all 302)")
                } else {
                    dcFailUntil[dcKey] = now.addingTimeInterval(Self.dcFailCooldown)
                }
                lock.unlock()
                let ok = await Fallback.doFallback(
                    client: client, relayInit: relayInit, label: label, dc: dc, isTestDc: isTestDc,
                    isMedia: isMedia, mediaTag: mediaTag, ctx: ctx, config: cfg, stats: stats,
                    balancer: balancer, cfWorkerPool: cfWorkerPool!, log: log, splitter: splitter
                )
                if ok { log("[\(label)] DC\(dc)\(mediaTag) fallback closed") }
                return
            }

            lock.lock()
            dcFailUntil[dcKey] = nil
            if let target { ipFailUntil[target] = nil }
            lock.unlock()
            wsPool?.reportSuccess(dc: dc, isMedia: isMedia)
            stats.bumpConnectionsWs()

            try await ws!.send(relayInit)
            await Bridge.bridgeWsReencrypt(
                client: client, ws: ws!, label: label, ctx: ctx, stats: stats, log: log,
                dc: dc, isMedia: isMedia, splitter: splitter
            )
        } catch {
            let cfg = currentConfig()
            if cfg.verbose {
                log("[\(label)] unexpected: \(error.localizedDescription)")
            }
            client.close()
        }
    }

    public static func maskSecret(_ secret: String) -> String {
        if secret.count < 8 { return "****" }
        return String(secret.prefix(4)) + "…" + String(secret.suffix(4))
    }
}
