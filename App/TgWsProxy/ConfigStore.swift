import Foundation
import TgWsProxyCore

@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: ProxyConfig
    @Published var firstRunDone: Bool

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let host = "host"
        static let port = "port"
        static let secret = "secret"
        static let dcIp = "dc_ip"
        static let cfproxy = "cfproxy"
        static let workerDomains = "cfproxy_worker_domain"
        static let userDomains = "cfproxy_user_domain"
        static let verbose = "verbose"
        static let firstRunDone = "first_run_done"
        static let poolSize = "pool_size"
        static let checkUpdates = "check_updates"
        static let cfDomainsCache = "cf_domains_cache"
    }

    init() {
        firstRunDone = defaults.bool(forKey: Keys.firstRunDone)
        config = Self.load(from: defaults)
        if ProxyConfig.isDc4OnlyFronting(config.dcRedirects) {
            config.dcRedirects = ProxyConfig.defaultDcRedirects
            save()
        }
        if config.secret.count != 32 {
            config.secret = ProxyConfig.randomSecret()
            save()
        }
    }

    func save() {
        defaults.set(config.host, forKey: Keys.host)
        defaults.set(config.port, forKey: Keys.port)
        defaults.set(config.secret, forKey: Keys.secret)
        defaults.set(config.dcIpText, forKey: Keys.dcIp)
        defaults.set(config.fallbackCfproxy, forKey: Keys.cfproxy)
        defaults.set(config.cfproxyWorkerDomains.joined(separator: " "), forKey: Keys.workerDomains)
        defaults.set(config.cfproxyUserDomains.joined(separator: " "), forKey: Keys.userDomains)
        defaults.set(config.verbose, forKey: Keys.verbose)
        defaults.set(config.poolSize, forKey: Keys.poolSize)
        defaults.set(config.checkUpdates, forKey: Keys.checkUpdates)
    }

    func setFirstRunDone() {
        firstRunDone = true
        defaults.set(true, forKey: Keys.firstRunDone)
    }

    var cachedCfDomains: [String]? {
        get { defaults.stringArray(forKey: Keys.cfDomainsCache) }
        set { defaults.set(newValue, forKey: Keys.cfDomainsCache) }
    }

    private static func load(from defaults: UserDefaults) -> ProxyConfig {
        let dcRaw = defaults.string(forKey: Keys.dcIp)
        let dcMap: [Int: String]
        if let dcRaw {
            let lines = dcRaw.split(whereSeparator: \.isNewline).map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.isEmpty {
                dcMap = [:]
            } else if let parsed = try? ProxyConfig.parseDcIpList(lines) {
                dcMap = ProxyConfig.isDc4OnlyFronting(parsed) ? ProxyConfig.defaultDcRedirects : parsed
            } else {
                dcMap = ProxyConfig.defaultDcRedirects
            }
        } else {
            dcMap = ProxyConfig.defaultDcRedirects
        }

        return ProxyConfig(
            host: defaults.string(forKey: Keys.host) ?? "127.0.0.1",
            port: defaults.object(forKey: Keys.port) as? Int ?? 1443,
            secret: defaults.string(forKey: Keys.secret) ?? "",
            dcRedirects: dcMap,
            poolSize: defaults.object(forKey: Keys.poolSize) as? Int ?? 4,
            fallbackCfproxy: defaults.object(forKey: Keys.cfproxy) as? Bool ?? true,
            cfproxyUserDomains: ProxyConfig.coerceDomainList(defaults.string(forKey: Keys.userDomains) ?? ""),
            cfproxyWorkerDomains: ProxyConfig.coerceDomainList(defaults.string(forKey: Keys.workerDomains) ?? ""),
            verbose: defaults.bool(forKey: Keys.verbose),
            checkUpdates: defaults.object(forKey: Keys.checkUpdates) as? Bool ?? true
        )
    }
}
