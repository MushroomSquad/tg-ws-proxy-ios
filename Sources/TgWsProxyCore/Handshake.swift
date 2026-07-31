import Foundation
import CryptoKit

public struct HandshakeResult {
    public let dcId: Int
    public let isMedia: Bool
    public let protoTag: Data
    public let clientDecPrekeyIv: Data
}

public final class CryptoCtx {
    public let cltDec: AesCtr
    public let cltEnc: AesCtr
    public let tgEnc: AesCtr
    public let tgDec: AesCtr

    public init(cltDec: AesCtr, cltEnc: AesCtr, tgEnc: AesCtr, tgDec: AesCtr) {
        self.cltDec = cltDec
        self.cltEnc = cltEnc
        self.tgEnc = tgEnc
        self.tgDec = tgDec
    }
}

public enum Handshake {
    public static func tryHandshake(handshake: Data, secret: Data) -> HandshakeResult? {
        guard handshake.count == ProtocolConstants.handshakeLen else { return nil }

        let start = ProtocolConstants.skipLen
        let prekeyIvLen = ProtocolConstants.prekeyLen + ProtocolConstants.ivLen
        let decPrekeyAndIv = handshake.subdata(in: start..<(start + prekeyIvLen))
        let decPrekey = decPrekeyAndIv.prefix(ProtocolConstants.prekeyLen)
        let decIv = decPrekeyAndIv.suffix(ProtocolConstants.ivLen)
        let decKey = sha256(Data(decPrekey) + secret)

        guard let decryptor = try? AesCtr.create(key: decKey, iv: Data(decIv)),
              let decrypted = try? decryptor.update(handshake) else {
            return nil
        }

        let protoTag = decrypted.subdata(in: ProtocolConstants.protoTagPos..<(ProtocolConstants.protoTagPos + 4))
        guard protoTag == ProtocolConstants.protoTagAbridged
            || protoTag == ProtocolConstants.protoTagIntermediate
            || protoTag == ProtocolConstants.protoTagSecure else {
            return nil
        }

        let dcBytes = decrypted.subdata(in: ProtocolConstants.dcIdxPos..<(ProtocolConstants.dcIdxPos + 2))
        let dcIdx = Int(Int16(littleEndian: dcBytes.withUnsafeBytes { $0.load(as: Int16.self) }))
        let dcId = abs(dcIdx)
        let isMedia = dcIdx < 0
        return HandshakeResult(dcId: dcId, isMedia: isMedia, protoTag: protoTag, clientDecPrekeyIv: decPrekeyAndIv)
    }

    public static func generateRelayInit(protoTag: Data, dcIdx: Int) throws -> Data {
        while true {
            var rnd = Data((0..<ProtocolConstants.handshakeLen).map { _ in UInt8.random(in: 0...255) })
            if ProtocolConstants.reservedFirstBytes.contains(rnd[0]) { continue }
            let start4 = Array(rnd.prefix(4))
            if ProtocolConstants.reservedStarts.contains(start4) { continue }
            if rnd.subdata(in: 4..<8) == ProtocolConstants.reservedContinue { continue }

            let encKey = rnd.subdata(in: ProtocolConstants.skipLen..<(ProtocolConstants.skipLen + ProtocolConstants.prekeyLen))
            let encIv = rnd.subdata(in: (ProtocolConstants.skipLen + ProtocolConstants.prekeyLen)..<(ProtocolConstants.skipLen + ProtocolConstants.prekeyLen + ProtocolConstants.ivLen))
            let encryptor = try AesCtr.create(key: encKey, iv: encIv)
            let encryptedFull = try encryptor.update(rnd)

            var keystreamTail = Data(count: 8)
            for i in 0..<8 {
                keystreamTail[i] = encryptedFull[56 + i] ^ rnd[56 + i]
            }

            var dcBytes = Data(count: 2)
            var le = Int16(clamping: dcIdx).littleEndian
            withUnsafeBytes(of: &le) { dcBytes.replaceSubrange(0..<2, with: $0) }
            let pad = Data((0..<2).map { _ in UInt8.random(in: 0...255) })
            let tailPlain = protoTag + dcBytes + pad
            var encryptedTail = Data(count: 8)
            for i in 0..<8 {
                encryptedTail[i] = tailPlain[i] ^ keystreamTail[i]
            }

            rnd.replaceSubrange(ProtocolConstants.protoTagPos..<(ProtocolConstants.protoTagPos + 8), with: encryptedTail)
            return rnd
        }
    }

    public static func buildCryptoCtx(clientDecPrekeyIv: Data, secret: Data, relayInit: Data) throws -> CryptoCtx {
        let cltDecPrekey = clientDecPrekeyIv.prefix(ProtocolConstants.prekeyLen)
        let cltDecIv = clientDecPrekeyIv.suffix(ProtocolConstants.ivLen)
        let cltDecKey = sha256(Data(cltDecPrekey) + secret)

        let cltEncPrekeyIv = Data(clientDecPrekeyIv.reversed())
        let cltEncKey = sha256(cltEncPrekeyIv.prefix(ProtocolConstants.prekeyLen) + secret)
        let cltEncIv = Data(cltEncPrekeyIv.suffix(ProtocolConstants.ivLen))

        let cltDecryptor = try AesCtr.create(key: cltDecKey, iv: Data(cltDecIv))
        let cltEncryptor = try AesCtr.create(key: cltEncKey, iv: cltEncIv)
        _ = try cltDecryptor.update(ProtocolConstants.zero64)

        let relayEncKey = relayInit.subdata(in: ProtocolConstants.skipLen..<(ProtocolConstants.skipLen + ProtocolConstants.prekeyLen))
        let relayEncIv = relayInit.subdata(in: (ProtocolConstants.skipLen + ProtocolConstants.prekeyLen)..<(ProtocolConstants.skipLen + ProtocolConstants.prekeyLen + ProtocolConstants.ivLen))
        let relayDecPrekeyIv = Data(relayInit.subdata(in: ProtocolConstants.skipLen..<(ProtocolConstants.skipLen + ProtocolConstants.prekeyLen + ProtocolConstants.ivLen)).reversed())
        let relayDecKey = Data(relayDecPrekeyIv.prefix(ProtocolConstants.keyLen))
        let relayDecIv = Data(relayDecPrekeyIv.suffix(ProtocolConstants.ivLen))

        let tgEncryptor = try AesCtr.create(key: relayEncKey, iv: relayEncIv)
        let tgDecryptor = try AesCtr.create(key: relayDecKey, iv: relayDecIv)
        _ = try tgEncryptor.update(ProtocolConstants.zero64)

        return CryptoCtx(cltDec: cltDecryptor, cltEnc: cltEncryptor, tgEnc: tgEncryptor, tgDec: tgDecryptor)
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
