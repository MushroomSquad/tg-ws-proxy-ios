import Foundation
import Network

/// Bidirectional TCP byte stream over NWConnection (client side or accepted).
public final class TcpStream: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private let queue: DispatchQueue

    public init(connection: NWConnection, queue: DispatchQueue = .global(qos: .userInitiated)) {
        self.connection = connection
        self.queue = queue
    }

    public static func connect(host: String, port: UInt16, timeoutMs: Int = 10_000) async throws -> TcpStream {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(to: endpoint, using: params)
        try await startReady(connection: connection, timeoutMs: timeoutMs)
        return TcpStream(connection: connection)
    }

    public static func startReady(connection: NWConnection, timeoutMs: Int) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let timeout = DispatchWorkItem {
                if !resumed {
                    resumed = true
                    connection.cancel()
                    cont.resume(throwing: URLError(.timedOut))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; timeout.cancel(); cont.resume() }
                case .failed(let err):
                    if !resumed { resumed = true; timeout.cancel(); cont.resume(throwing: err) }
                case .cancelled:
                    if !resumed { resumed = true; timeout.cancel(); cont.resume(throwing: URLError(.cancelled)) }
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "tgws.tcp"))
        }
    }

    public func read(maxLength: Int = 65536) async throws -> Data? {
        lock.lock()
        if !buffer.isEmpty {
            let n = min(maxLength, buffer.count)
            let out = buffer.prefix(n)
            buffer.removeFirst(n)
            lock.unlock()
            return Data(out)
        }
        if closed {
            lock.unlock()
            return nil
        }
        lock.unlock()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { [weak self] content, _, isComplete, error in
                guard let self else {
                    cont.resume(returning: nil)
                    return
                }
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                self.lock.lock()
                if isComplete { self.closed = true }
                self.lock.unlock()
                if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    public func readExact(_ n: Int, timeoutMs: Int = 10_000) async throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while out.count < n {
            if Date() > deadline { throw URLError(.timedOut) }
            guard let chunk = try await read(maxLength: n - out.count) else {
                throw URLError(.networkConnectionLost)
            }
            if chunk.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            out.append(chunk)
        }
        return out
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    public func close() {
        lock.lock(); closed = true; lock.unlock()
        connection.cancel()
    }
}
