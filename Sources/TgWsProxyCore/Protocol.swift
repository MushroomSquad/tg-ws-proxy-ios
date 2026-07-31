import Foundation

public enum ProtocolConstants {
    public static let zero64 = Data(count: 64)
    public static let handshakeLen = 64
    public static let skipLen = 8
    public static let prekeyLen = 32
    public static let keyLen = 32
    public static let ivLen = 16
    public static let protoTagPos = 56
    public static let dcIdxPos = 60

    public static let protoTagAbridged = Data([0xEF, 0xEF, 0xEF, 0xEF])
    public static let protoTagIntermediate = Data([0xEE, 0xEE, 0xEE, 0xEE])
    public static let protoTagSecure = Data([0xDD, 0xDD, 0xDD, 0xDD])

    public static let protoAbridgedInt: UInt32 = 0xEFEFEFEF
    public static let protoIntermediateInt: UInt32 = 0xEEEEEEEE
    public static let protoPaddedIntermediateInt: UInt32 = 0xDDDDDDDD

    public static let reservedFirstBytes: Set<UInt8> = [0xEF]
    public static let reservedStarts: Set<[UInt8]> = [
        [0x48, 0x45, 0x41, 0x44],
        [0x50, 0x4F, 0x53, 0x54],
        [0x47, 0x45, 0x54, 0x20],
        [0xEE, 0xEE, 0xEE, 0xEE],
        [0xDD, 0xDD, 0xDD, 0xDD],
        [0x16, 0x03, 0x01, 0x02],
    ]
    public static let reservedContinue = Data([0, 0, 0, 0])

    public static let dcDefaultIps: [Int: String] = [
        1: "149.154.175.50",
        2: "149.154.167.51",
        3: "149.154.175.100",
        4: "149.154.167.91",
        5: "149.154.171.5",
        203: "91.105.192.100",
    ]

    public static let dcTestIps: [Int: String] = [
        1: "149.154.175.10",
        2: "149.154.167.40",
        3: "149.154.175.117",
    ]

    public static let wsPath = "/apiws"
    public static let wsPathTest = "/apiws_test"

    public static let cfproxyDefaultDomains: [String] = [
        "pclead.co.uk", "offshor.co.uk", "cakeisalie.co.uk", "noskomnadzor.co.uk",
        "lovetrue.co.uk", "sorokdva.co.uk", "pyatdesyatdva.co.uk", "kartoshka.co.uk",
        "sorokodin.co.uk", "pyatdesyatodin.co.uk", "notelega.co.uk", "ebally.co.uk",
        "nebally.co.uk", "havegreatday.co.uk", "pomogite.co.uk", "fixtelega.co.uk",
        "sadnews.co.uk", "onedaychamp.co.uk", "stopblocking.co.uk", "nothingthere.co.uk",
    ]

    public static func wsDomains(dc: Int, isMedia: Bool?) -> [String] {
        var d = dc
        if d == 203 { d = 2 }
        if isMedia == nil || isMedia == true {
            return ["kws\(d)-1.web.telegram.org", "kws\(d).web.telegram.org"]
        }
        return ["kws\(d).web.telegram.org", "kws\(d)-1.web.telegram.org"]
    }

    public static func humanBytes(_ n: Int64) -> String {
        var v = Double(n)
        for unit in ["B", "KB", "MB", "GB"] {
            if abs(v) < 1024 {
                return String(format: "%.1f%@", v, unit)
            }
            v /= 1024
        }
        return String(format: "%.1fTB", v)
    }
}
