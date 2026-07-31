import Foundation
import CommonCrypto

/// AES-CTR stream cipher (AES/CTR/NoPadding equivalent).
public final class AesCtr {
    private var cryptor: CCCryptorRef?

    public init(key: Data, iv: Data) throws {
        precondition(key.count == 16 || key.count == 24 || key.count == 32, "AES key must be 16/24/32")
        precondition(iv.count == 16, "CTR IV must be 16 bytes")

        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBuf in
            iv.withUnsafeBytes { ivBuf in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBuf.baseAddress,
                    keyBuf.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else {
            throw AesCtrError.createFailed(status)
        }
        self.cryptor = cryptor
    }

    deinit {
        if let cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    public func update(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        guard let cryptor else { throw AesCtrError.notInitialized }
        var out = Data(count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { inBuf in
            out.withUnsafeMutableBytes { outBuf in
                CCCryptorUpdate(
                    cryptor,
                    inBuf.baseAddress,
                    data.count,
                    outBuf.baseAddress,
                    data.count,
                    &moved
                )
            }
        }
        guard status == kCCSuccess, moved == data.count else {
            throw AesCtrError.updateFailed(status, moved)
        }
        return out
    }

    public static func create(key: Data, iv: Data) throws -> AesCtr {
        try AesCtr(key: key, iv: iv)
    }
}

public enum AesCtrError: Error, CustomStringConvertible {
    case createFailed(CCCryptorStatus)
    case updateFailed(CCCryptorStatus, Int)
    case notInitialized

    public var description: String {
        switch self {
        case .createFailed(let s): return "AES-CTR create failed: \(s)"
        case .updateFailed(let s, let n): return "AES-CTR update failed: \(s) moved=\(n)"
        case .notInitialized: return "AES-CTR not initialized"
        }
    }
}
