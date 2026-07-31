import Foundation
import Network
import Security

public final class WsHandshakeError: Error, LocalizedError {
    public let statusCode: Int
    public let statusLine: String
    public let location: String?

    public init(statusCode: Int, statusLine: String, location: String? = nil) {
        self.statusCode = statusCode
        self.statusLine = statusLine
        self.location = location
    }

    public var isRedirect: Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }

    public var errorDescription: String? {
        "HTTP \(statusCode): \(statusLine)"
    }
}

/// RFC6455 client over TLS (binary protocol), mirroring Android RawWebSocket.
public final class RawWebSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tgws.ws")
    private var recvBuffer = Data()
    private let stateLock = NSLock()
    private var _closed = false

    public var closed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _closed
    }

    public var isClosing: Bool {
        closed || connection.state == .cancelled || connection.state == .failed(NWError.posix(.ENOTCONN))
    }

    private init(connection: NWConnection) {
        self.connection = connection
    }

    public func send(_ data: Data) async throws {
        try await sendFrames([data])
    }

    public func sendBatch(_ parts: [Data]) async throws {
        try await sendFrames(parts)
    }

    private func sendFrames(_ parts: [Data]) async throws {
        if closed { throw URLError(.networkConnectionLost) }
        var payload = Data()
        for part in parts {
            payload.append(Self.buildFrame(opcode: Self.opBinary, data: part, mask: true))
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    public func recv() async throws -> Data? {
        while !closed {
            let (opcode, payload) = try await readFrame()
            switch opcode {
            case Self.opClose:
                markClosed()
                try? await sendRaw(Self.buildFrame(opcode: Self.opClose, data: Data(payload.prefix(min(2, payload.count))), mask: true))
                return nil
            case Self.opPing:
                try? await sendRaw(Self.buildFrame(opcode: Self.opPong, data: payload, mask: true))
            case Self.opPong:
                continue
            case Self.opText, Self.opBinary:
                return payload
            default:
                continue
            }
        }
        return nil
    }

    public func closeQuietly() async {
        if closed { return }
        markClosed()
        try? await sendRaw(Self.buildFrame(opcode: Self.opClose, data: Data(), mask: true))
        connection.cancel()
    }

    private func markClosed() {
        stateLock.lock()
        _closed = true
        stateLock.unlock()
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func readFrame() async throws -> (Int, Data) {
        let hdr = try await readExact(2)
        let opcode = Int(hdr[0] & 0x0F)
        var length = Int(hdr[1] & 0x7F)
        if length == 126 {
            let ext = try await readExact(2)
            length = (Int(ext[0]) << 8) | Int(ext[1])
        } else if length == 127 {
            let ext = try await readExact(8)
            length = Int(ext.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
        }
        let masked = (hdr[1] & 0x80) != 0
        if masked {
            let mask = try await readExact(4)
            let payload = try await readExact(length)
            return (opcode, Self.xorMask(payload, mask: mask))
        }
        let payload = try await readExact(length)
        return (opcode, payload)
    }

    private func readExact(_ n: Int) async throws -> Data {
        while true {
            stateLock.lock()
            if recvBuffer.count >= n {
                let out = recvBuffer.prefix(n)
                recvBuffer.removeFirst(n)
                stateLock.unlock()
                return Data(out)
            }
            stateLock.unlock()
            if closed { throw URLError(.networkConnectionLost) }
            try await receiveMore()
        }
    }

    private func receiveMore() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, isComplete, error in
                guard let self else {
                    cont.resume(throwing: URLError(.cancelled))
                    return
                }
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                self.stateLock.lock()
                if let content { self.recvBuffer.append(content) }
                if isComplete { self._closed = true }
                self.stateLock.unlock()
                cont.resume()
            }
        }
    }

    public static func connect(
        host: String,
        domain: String,
        timeoutMs: Int = 10_000,
        path: String = ProtocolConstants.wsPath,
        sni: String? = nil,
        bufferSize: Int = 256 * 1024
    ) async throws -> RawWebSocket {
        let sniHost = sni ?? domain
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 443)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, DispatchQueue.global())
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sniHost as CFString)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(to: endpoint, using: params)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let timeout = DispatchWorkItem {
                if !resumed {
                    resumed = true
                    connection.cancel()
                    cont.resume(throwing: URLError(.timedOut))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(min(timeoutMs, 10_000)), execute: timeout)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed {
                        resumed = true
                        timeout.cancel()
                        cont.resume()
                    }
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        timeout.cancel()
                        cont.resume(throwing: error)
                    }
                case .cancelled:
                    if !resumed {
                        resumed = true
                        timeout.cancel()
                        cont.resume(throwing: URLError(.cancelled))
                    }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "tgws.ws.connect"))
        }

        let ws = RawWebSocket(connection: connection)
        let wsKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let req = """
        GET \(path) HTTP/1.1\r
        Host: \(domain)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(wsKey)\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Protocol: binary\r
        \r

        """
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(req.utf8), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }

        // Read HTTP response headers
        var headerData = Data()
        while true {
            if let range = headerData.range(of: Data("\r\n\r\n".utf8)) {
                let headersBlob = headerData.subdata(in: 0..<range.lowerBound)
                let leftover = headerData.subdata(in: range.upperBound..<headerData.count)
                ws.stateLock.lock()
                ws.recvBuffer = leftover
                ws.stateLock.unlock()

                let text = String(data: headersBlob, encoding: .isoLatin1) ?? ""
                let lines = text.components(separatedBy: "\r\n")
                guard let first = lines.first else {
                    connection.cancel()
                    throw WsHandshakeError(statusCode: 0, statusLine: "empty response")
                }
                let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                if status == 101 {
                    return ws
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let c = line.firstIndex(of: ":") {
                        let k = String(line[..<c]).trimmingCharacters(in: .whitespaces).lowercased()
                        let v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                connection.cancel()
                throw WsHandshakeError(statusCode: status, statusLine: first, location: headers["location"])
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: bufferSize) { content, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    if let content { headerData.append(content) }
                    if isComplete && headerData.range(of: Data("\r\n\r\n".utf8)) == nil {
                        cont.resume(throwing: WsHandshakeError(statusCode: 0, statusLine: "incomplete headers"))
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Frame helpers

    private static let opText = 0x1
    private static let opBinary = 0x2
    private static let opClose = 0x8
    private static let opPing = 0x9
    private static let opPong = 0xA

    private static func buildFrame(opcode: Int, data: Data, mask: Bool) -> Data {
        let length = data.count
        var out = Data()
        out.append(UInt8(0x80 | opcode))
        if !mask {
            appendLength(&out, length: length, maskBit: false)
            out.append(data)
            return out
        }
        let maskKey = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        appendLength(&out, length: length, maskBit: true)
        out.append(maskKey)
        out.append(xorMask(data, mask: maskKey))
        return out
    }

    private static func appendLength(_ out: inout Data, length: Int, maskBit: Bool) {
        let m: UInt8 = maskBit ? 0x80 : 0
        if length < 126 {
            out.append(m | UInt8(length))
        } else if length < 65536 {
            out.append(m | 126)
            out.append(UInt8((length >> 8) & 0xff))
            out.append(UInt8(length & 0xff))
        } else {
            out.append(m | 127)
            var be = UInt64(length).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
    }

    private static func xorMask(_ data: Data, mask: Data) -> Data {
        if data.isEmpty { return data }
        var out = Data(count: data.count)
        for i in 0..<data.count {
            out[i] = data[i] ^ mask[i % 4]
        }
        return out
    }
}
