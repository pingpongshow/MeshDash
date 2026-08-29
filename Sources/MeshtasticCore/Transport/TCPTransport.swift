import Foundation
import Network
import Synchronization

/// Network link to a radio's TCP API (default port 4403), used by WiFi/Ethernet
/// capable boards and by the `meshtasticd` Linux daemon.
public final class TCPTransport: MeshTransport, @unchecked Sendable {
    public static let defaultPort: UInt16 = 4403

    public let address: DeviceAddress
    private let host: String
    private let port: UInt16

    private struct State {
        var continuation: AsyncStream<TransportEvent>.Continuation?
        var decoder = FrameDecoder()
        var isClosing = false
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "MeshDash.TCP")
    private var connection: NWConnection?
    private var connectDeadline: DispatchWorkItem?

    /// How long to wait for the link before giving up. NWConnection will sit in
    /// `.waiting` indefinitely on its own, so the deadline has to be ours.
    private let connectTimeout: TimeInterval = 10

    public init(host: String, port: UInt16 = TCPTransport.defaultPort) {
        self.host = host
        self.port = port
        self.address = .tcp(host: host, port: port)
    }

    public func events() -> AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            state.withLock { $0.continuation = continuation }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect() }
            }
        }
    }

    public func connect() async throws {
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: TCPTransport.defaultPort)
        let parameters = NWParameters.tcp
        // Radio traffic is small and latency-sensitive; don't sit in Nagle buffers.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        self.connection = connection

        state.withLock {
            $0.isClosing = false
            $0.decoder.reset()
        }

        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            let hasResumed = Mutex(false)
            /// Resumes the continuation exactly once, whichever path gets there first.
            @Sendable func settle(_ result: Result<Void, TransportError>) {
                let alreadyResumed = hasResumed.withLock { was -> Bool in
                    let old = was
                    was = true
                    return old
                }
                guard !alreadyResumed else {
                    if case .failure(let error) = result { self.finish(with: error) }
                    return
                }
                self.connectDeadline?.cancel()
                self.connectDeadline = nil
                switch result {
                case .success: resume.resume()
                case .failure(let error):
                    connection.cancel()
                    resume.resume(throwing: error)
                }
            }

            connection.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    settle(.success(()))
                    self.emit(.connected)
                    self.receiveLoop(on: connection)
                case .failed(let error):
                    settle(.failure(self.describe(error)))
                case .cancelled:
                    settle(.failure(.cancelled))
                case .waiting(let error):
                    // A refused connection means the host answered and nothing is
                    // on that port. NWConnection would keep retrying forever, so
                    // treat it as terminal rather than leaving the user waiting.
                    if case .posix(let code) = error, code == .ECONNREFUSED {
                        settle(.failure(self.describe(error)))
                    } else {
                        self.emit(.status("Waiting for \(self.host): \(error.localizedDescription)"))
                    }
                default:
                    break
                }
            }

            let deadline = DispatchWorkItem { settle(.failure(.timedOut)) }
            self.connectDeadline = deadline
            queue.asyncAfter(deadline: .now() + connectTimeout, execute: deadline)
            connection.start(queue: queue)
        }
    }

    /// Turns a Network.framework error into something that tells the user what
    /// to actually do about it.
    private func describe(_ error: NWError) -> TransportError {
        guard case .posix(let code) = error else {
            return .openFailed("\(host):\(port) — \(error.localizedDescription)")
        }
        switch code {
        case .ECONNREFUSED:
            let lines = [
                "\(host) refused the connection on port \(port). Nothing is listening there.",
                "A Meshtastic radio only opens this port when WiFi or Ethernet is enabled.",
                "A device that serves only a web dashboard — a Meshpoint gateway on port 8080, for instance — does not speak the Meshtastic network protocol.",
            ]
            return .openFailed(lines.joined(separator: "\n\n"))
        case .EHOSTUNREACH, .ENETUNREACH:
            return .openFailed("\(host) is not reachable from this Mac. Check that both are on the same network.")
        case .ETIMEDOUT:
            return .timedOut
        default:
            return .openFailed("\(host):\(port) — \(error.localizedDescription)")
        }
    }

    public func send(_ toRadio: Data) async throws {
        guard let connection, !state.withLock({ $0.isClosing }) else {
            throw TransportError.writeFailed("Network connection is closed.")
        }
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            connection.send(content: StreamFraming.frame(toRadio), completion: .contentProcessed { error in
                if let error {
                    resume.resume(throwing: TransportError.writeFailed(error.localizedDescription))
                } else {
                    resume.resume()
                }
            })
        }
    }

    public func disconnect() async {
        let stream: AsyncStream<TransportEvent>.Continuation? = state.withLock {
            guard !$0.isClosing else { return nil }
            $0.isClosing = true
            let stream = $0.continuation
            $0.continuation = nil
            return stream
        }
        guard stream != nil || connection != nil else { return }
        connectDeadline?.cancel()
        connectDeadline = nil
        connection?.cancel()
        connection = nil
        stream?.yield(.disconnected(nil))
        stream?.finish()
    }

    // MARK: - Receiving

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let output = self.state.withLock { $0.decoder.consume(data) }
                for payload in output.payloads { self.emit(.payload(payload)) }
                if !output.debugText.isEmpty { self.emit(.deviceLog(output.debugText)) }
            }
            if let error {
                self.finish(with: .readFailed(error.localizedDescription))
                return
            }
            if isComplete {
                self.finish(with: nil)
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    private func finish(with error: TransportError?) {
        let stream: AsyncStream<TransportEvent>.Continuation? = state.withLock {
            guard !$0.isClosing else { return nil }
            $0.isClosing = true
            let stream = $0.continuation
            $0.continuation = nil
            return stream
        }
        stream?.yield(.disconnected(error))
        stream?.finish()
    }

    private func emit(_ event: TransportEvent) {
        state.withLock { $0.continuation }?.yield(event)
    }
}
