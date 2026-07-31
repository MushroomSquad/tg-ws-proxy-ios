import Foundation

public final class CfDomainRefresh: @unchecked Sendable {
    private let balancer: Balancer
    private let hasUserDomains: () -> Bool
    private let log: (String) -> Void
    private var task: Task<Void, Never>?
    private let started = LockedFlag()

    private static let refreshInterval: TimeInterval = 3600
    private static let minValidDomains = 3
    private static let domainsURL =
        "https://raw.githubusercontent.com/Flowseal/tg-ws-proxy/main/.github/cfproxy-domains.txt"
    private static let suffix = ".co.uk"

    public init(balancer: Balancer, hasUserDomains: @escaping () -> Bool, log: @escaping (String) -> Void) {
        self.balancer = balancer
        self.hasUserDomains = hasUserDomains
        self.log = log
    }

    public func start() {
        guard started.setTrueIfFalse() else { return }
        balancer.updateDomainsList(ProtocolConstants.cfproxyDefaultDomains)
        task = Task {
            await refreshOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                await refreshOnce()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        started.reset()
    }

    public func refreshNow() {
        Task { await refreshOnce() }
    }

    private func refreshOnce() async {
        if hasUserDomains() {
            log("CF domain refresh skipped (custom user domains set)")
            return
        }
        let fetched = await Self.fetchEncodedList()
        let pool = Self.normalize(fetched.map { Self.decodeDomain($0) })
        if pool.count >= Self.minValidDomains {
            balancer.updateDomainsList(pool)
            log("CF proxy domain pool updated from GitHub (\(pool.count) domains)")
            return
        }
        if !fetched.isEmpty {
            log("Ignoring fetched CF proxy domains due to low-quality payload " +
                "(total=\(fetched.count), valid=\(pool.count), required>=\(Self.minValidDomains))")
        } else {
            log("CF proxy domain refresh failed or empty; keeping current pool")
        }
    }

    public static func fetchEncodedList() async -> [String] {
        do {
            let nonce = String((0..<7).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
            guard let url = URL(string: "\(Self.domainsURL)?\(nonce)") else { return [] }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("tg-ws-proxy-ios", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        } catch {
            return []
        }
    }

    /// Same as Python `_dd` / Android decodeDomain
    public static func decodeDomain(_ encoded: String) -> String {
        guard encoded.hasSuffix(".com") else { return encoded }
        let p = String(encoded.dropLast(4))
        let n = p.filter(\.isLetter).count
        var decoded = ""
        for c in p {
            if c.isLetter {
                let base: Character = c.isLowercase ? "a" : "A"
                let baseCode = Int(base.asciiValue!)
                let code = Int(c.asciiValue!)
                let shifted = ((code - baseCode - n) % 26 + 26) % 26
                decoded.append(Character(UnicodeScalar(baseCode + shifted)!))
            } else {
                decoded.append(c)
            }
        }
        return decoded + suffix
    }

    public static func normalize(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for domain in domains {
            let item = domain.trimmingCharacters(in: .whitespaces).lowercased()
            guard isValidDomain(item), seen.insert(item).inserted else { continue }
            out.append(item)
        }
        return out
    }

    private static func isValidDomain(_ domain: String) -> Bool {
        if domain.isEmpty || domain.count > 253 { return false }
        if domain.hasPrefix(".") || domain.hasSuffix(".") { return false }
        let labels = domain.split(separator: ".")
        if labels.count < 2 { return false }
        for label in labels {
            if label.isEmpty || label.count > 63 { return false }
            if label.first == "-" || label.last == "-" { return false }
            if !label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) { return false }
        }
        let tld = labels.last!
        return tld.count >= 2 && tld.contains(where: \.isLetter)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func setTrueIfFalse() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
    func reset() { lock.lock(); value = false; lock.unlock() }
}
