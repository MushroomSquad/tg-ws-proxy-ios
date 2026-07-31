import Foundation

public struct ProxyConfig: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var secret: String
    public var dcRedirects: [Int: String]
    public var bufferSize: Int
    public var poolSize: Int
    public var fallbackCfproxy: Bool
    public var cfproxyUserDomains: [String]
    public var cfproxyWorkerDomains: [String]
    public var forceTestDc: Bool
    public var verbose: Bool
    public var checkUpdates: Bool

    public static let frontingDcIp = "149.154.167.220"
    public static let defaultDcRedirects: [Int: String] = [
        2: frontingDcIp,
        4: frontingDcIp,
    ]

    public init(
        host: String = "127.0.0.1",
        port: Int = 1443,
        secret: String = "",
        dcRedirects: [Int: String] = ProxyConfig.defaultDcRedirects,
        bufferSize: Int = 256 * 1024,
        poolSize: Int = 4,
        fallbackCfproxy: Bool = true,
        cfproxyUserDomains: [String] = [],
        cfproxyWorkerDomains: [String] = [],
        forceTestDc: Bool = false,
        verbose: Bool = false,
        checkUpdates: Bool = true
    ) {
        self.host = host
        self.port = port
        self.secret = secret
        self.dcRedirects = dcRedirects
        self.bufferSize = bufferSize
        self.poolSize = poolSize
        self.fallbackCfproxy = fallbackCfproxy
        self.cfproxyUserDomains = cfproxyUserDomains
        self.cfproxyWorkerDomains = cfproxyWorkerDomains
        self.forceTestDc = forceTestDc
        self.verbose = verbose
        self.checkUpdates = checkUpdates
    }

    public func secretBytes() throws -> Data {
        precondition(secret.count == 32, "Secret must be 32 hex chars")
        var out = Data(capacity: 16)
        var idx = secret.startIndex
        while idx < secret.endIndex {
            let next = secret.index(idx, offsetBy: 2)
            guard let b = UInt8(secret[idx..<next], radix: 16) else {
                throw ProxyConfigError.invalidSecret
            }
            out.append(b)
            idx = next
        }
        return out
    }

    public func proxyLink() -> String {
        "tg://proxy?server=\(host)&port=\(port)&secret=dd\(secret)"
    }

    public static func parseDcIpList(_ entries: [String]) throws -> [Int: String] {
        var out: [Int: String] = [:]
        for entry in entries {
            guard let idx = entry.firstIndex(of: ":"), idx > entry.startIndex else {
                throw ProxyConfigError.invalidDcIp(entry)
            }
            let dcStr = String(entry[..<idx])
            let ip = String(entry[entry.index(after: idx)...])
            guard let dc = Int(dcStr) else { throw ProxyConfigError.invalidDcIp(entry) }
            out[dc] = ip
        }
        return out
    }

    public static func coerceDomainList(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let parts = raw
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ";", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        for part in parts {
            let item = String(part).trimmingCharacters(in: .whitespaces)
            if !item.isEmpty, seen.insert(item).inserted {
                out.append(item)
            }
        }
        return out
    }

    public static func randomSecret() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public static func isDc4OnlyFronting(_ map: [Int: String]) -> Bool {
        map.count == 1 && map[4] == frontingDcIp
    }

    public var dcIpText: String {
        dcRedirects.keys.sorted().map { "\($0):\(dcRedirects[$0]!)" }.joined(separator: "\n")
    }
}

public enum ProxyConfigError: Error {
    case invalidSecret
    case invalidDcIp(String)
}
