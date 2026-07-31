import Foundation

/// Splits TCP stream into MTProto transport packets for one-WS-frame-per-packet sends.
public final class MsgSplitter {
    private let dec: AesCtr
    private var cipherBuf = Data()
    private var plainBuf = Data()
    private var disabled = false
    private let proto: UInt32

    public init(relayInit: Data, proto: UInt32) throws {
        self.proto = proto
        let key = relayInit.subdata(in: 8..<40)
        let iv = relayInit.subdata(in: 40..<56)
        self.dec = try AesCtr.create(key: key, iv: iv)
        _ = try self.dec.update(ProtocolConstants.zero64)
    }

    public func split(_ chunk: Data) throws -> [Data] {
        if chunk.isEmpty { return [] }
        if disabled { return [chunk] }

        cipherBuf.append(chunk)
        let plain = try dec.update(chunk)
        plainBuf.append(plain)

        var parts: [Data] = []
        var offset = 0
        let size = cipherBuf.count
        while offset < size {
            guard let packetLen = nextPacketLen(offset: offset, avail: size - offset) else { break }
            if packetLen <= 0 {
                parts.append(cipherBuf.subdata(in: offset..<size))
                offset = size
                disabled = true
                break
            }
            parts.append(cipherBuf.subdata(in: offset..<(offset + packetLen)))
            offset += packetLen
        }

        if offset > 0 {
            cipherBuf = Data(cipherBuf.suffix(from: offset))
            plainBuf = Data(plainBuf.suffix(from: offset))
        }
        return parts
    }

    public func flush() -> [Data] {
        if cipherBuf.isEmpty { return [] }
        let tail = cipherBuf
        cipherBuf = Data()
        plainBuf = Data()
        return [tail]
    }

    private func nextPacketLen(offset: Int, avail: Int) -> Int? {
        if avail <= 0 { return nil }
        switch proto {
        case ProtocolConstants.protoAbridgedInt:
            return nextAbridged(offset: offset, avail: avail)
        case ProtocolConstants.protoIntermediateInt, ProtocolConstants.protoPaddedIntermediateInt:
            return nextIntermediate(offset: offset, avail: avail)
        default:
            return 0
        }
    }

    private func nextAbridged(offset: Int, avail: Int) -> Int? {
        let first = Int(plainBuf[offset])
        let headerLen: Int
        let payloadLen: Int
        if first == 0x7F || first == 0xFF {
            if avail < 4 { return nil }
            payloadLen = (
                Int(plainBuf[offset + 1]) |
                (Int(plainBuf[offset + 2]) << 8) |
                (Int(plainBuf[offset + 3]) << 16)
            ) * 4
            headerLen = 4
        } else {
            payloadLen = (first & 0x7F) * 4
            headerLen = 1
        }
        if payloadLen <= 0 { return 0 }
        let packetLen = headerLen + payloadLen
        if avail < packetLen { return nil }
        return packetLen
    }

    private func nextIntermediate(offset: Int, avail: Int) -> Int? {
        if avail < 4 { return nil }
        let payloadLen = Int(UInt32(littleEndian: plainBuf.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }) & 0x7FFF_FFFF)
        if payloadLen <= 0 { return 0 }
        if payloadLen > 16 * 1024 * 1024 { return 0 }
        let packetLen = 4 + payloadLen
        if avail < packetLen { return nil }
        return packetLen
    }
}
