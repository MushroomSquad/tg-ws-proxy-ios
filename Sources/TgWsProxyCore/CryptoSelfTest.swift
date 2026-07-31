import Foundation

public enum CryptoSelfTest {
    public static func run(log: (String) -> Void) -> Bool {
        do {
            let secret = hex("0123456789abcdef0123456789abcdef")
            let handshake = hex(
                "000d1a2734414e5b6875828f9ca9b6c3d0ddeaf704111e2b3845525f6c798693" +
                "a0adbac7d4e1eefb0815222f3c495663707d8a97a4b1becbb29ab919d970c664"
            )
            guard let parsed = Handshake.tryHandshake(handshake: handshake, secret: secret),
                  parsed.dcId == 2 else {
                log("Crypto self-test FAILED: fixed handshake not parsed")
                return false
            }

            let initData = try Handshake.generateRelayInit(protoTag: ProtocolConstants.protoTagSecure, dcIdx: 2)
            let key = Data((0..<32).map { UInt8($0) })
            let iv = Data((0..<16).map { UInt8($0) })
            let pt = Data("hello telegram ws proxy!!".utf8)
            let ct = try AesCtr.create(key: key, iv: iv).update(pt)
            let rt = try AesCtr.create(key: key, iv: iv).update(ct)
            guard rt == pt else {
                log("Crypto self-test FAILED: AES-CTR round-trip mismatch")
                return false
            }
            guard initData.count == 64 else {
                log("Crypto self-test FAILED: size check")
                return false
            }
            log("Crypto self-test OK")
            return true
        } catch {
            log("Crypto self-test FAILED: \(error)")
            return false
        }
    }

    private static func hex(_ s: String) -> Data {
        var data = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            if let b = UInt8(s[idx..<next], radix: 16) {
                data.append(b)
            }
            idx = next
        }
        return data
    }
}
