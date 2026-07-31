import Foundation
import UIKit
import TgWsProxyCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var running = false
    @Published var showSettings = false
    @Published var showFirstRun = false
    @Published var statusLine = "Stopped"
    @Published var cfStatus = ""
    @Published var draftPort: String = "1443"
    @Published var draftSecret: String = ""
    @Published var draftDcIp: String = ""
    @Published var draftWorkers: String = ""
    @Published var draftUserDomains: String = ""
    @Published var draftPoolSize: String = "4"
    @Published var draftCfproxy = true
    @Published var draftVerbose = false
    @Published var shareURL: URL?

    let store: ConfigStore
    private var server: ProxyServer?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    init(store: ConfigStore = ConfigStore()) {
        self.store = store
        syncDraftFromStore()
        showFirstRun = !store.firstRunDone
        AppLog.shared.verbose = store.config.verbose
    }

    func syncDraftFromStore() {
        let c = store.config
        draftPort = String(c.port)
        draftSecret = c.secret
        draftDcIp = c.dcIpText
        draftWorkers = c.cfproxyWorkerDomains.joined(separator: " ")
        draftUserDomains = c.cfproxyUserDomains.joined(separator: " ")
        draftPoolSize = String(c.poolSize)
        draftCfproxy = c.fallbackCfproxy
        draftVerbose = c.verbose
    }

    func applyDraftIfStopped() {
        guard !running else { return }
        var c = store.config
        c.port = Int(draftPort) ?? c.port
        if draftSecret.count == 32 { c.secret = draftSecret.lowercased() }
        let dcLines = draftDcIp.split(whereSeparator: \.isNewline).map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if dcLines.isEmpty {
            c.dcRedirects = [:]
        } else if let parsed = try? ProxyConfig.parseDcIpList(dcLines) {
            c.dcRedirects = parsed
        }
        c.cfproxyWorkerDomains = ProxyConfig.coerceDomainList(draftWorkers)
        c.cfproxyUserDomains = ProxyConfig.coerceDomainList(draftUserDomains)
        c.poolSize = Int(draftPoolSize) ?? 4
        c.fallbackCfproxy = draftCfproxy
        c.verbose = draftVerbose
        store.config = c
        store.save()
        AppLog.shared.verbose = c.verbose
    }

    func start() {
        applyDraftIfStopped()
        let config = store.config
        let log: (String) -> Void = { msg in
            Task { @MainActor in AppLog.shared.i(msg) }
        }
        let server = ProxyServer(config: config, log: log, cachedCfDomains: store.cachedCfDomains)
        do {
            try server.start()
            self.server = server
            running = true
            statusLine = "Running on \(config.host):\(config.port)"
            beginBackgroundTask()
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            AppLog.shared.e("Start failed: \(error.localizedDescription)")
            statusLine = "Start failed"
        }
    }

    func stop() {
        server?.stop()
        server = nil
        running = false
        statusLine = "Stopped"
        endBackgroundTask()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func toggle() {
        if running { stop() } else { start() }
    }

    func copyLink() {
        UIPasteboard.general.string = store.config.proxyLink()
        AppLog.shared.i("Proxy link copied")
    }

    func openTelegram() {
        guard let url = URL(string: store.config.proxyLink()) else { return }
        UIApplication.shared.open(url)
    }

    func refreshCF() async {
        cfStatus = "Refreshing…"
        let fetched = await CfDomainRefresh.fetchEncodedList()
        let pool = CfDomainRefresh.normalize(fetched.map { CfDomainRefresh.decodeDomain($0) })
        if pool.count >= 3 {
            store.cachedCfDomains = pool
            server?.refreshCfDomains()
            cfStatus = "CF domains: \(pool.count)"
            AppLog.shared.i("CF domains refreshed (\(pool.count))")
        } else {
            cfStatus = "Refresh failed / low quality"
            AppLog.shared.w("CF refresh failed (valid=\(pool.count))")
        }
    }

    func clearLogs() { AppLog.shared.clear() }

    func prepareShare() {
        shareURL = AppLog.shared.snapshotForExport()
    }

    func dismissFirstRun() {
        store.setFirstRunDone()
        showFirstRun = false
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "TgWsProxy") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }
}
