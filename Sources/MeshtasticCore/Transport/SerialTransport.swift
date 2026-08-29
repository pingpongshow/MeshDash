import Foundation
import Synchronization

/// USB serial link to a radio, speaking the 0x94/0xC3 framed stream protocol.
public final class SerialTransport: MeshTransport, @unchecked Sendable {
    public let address: DeviceAddress
    private let path: String
    private let baudRate: speed_t

    private struct State {
        var fileDescriptor: Int32 = -1
        var continuation: AsyncStream<TransportEvent>.Continuation?
        var decoder = FrameDecoder()
        var isClosing = false
    }

    private let state = Mutex(State())
    private var readerThread: Thread?

    public init(path: String, baudRate: Int = 115_200) {
        self.path = path
        self.baudRate = speed_t(baudRate)
        self.address = .serial(path: path)
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
        let descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw TransportError.openFailed("\(path): \(String(cString: strerror(errno)))")
        }

        // Claim the port so a stray `screen` session can't steal bytes from us.
        if ioctl(descriptor, TIOCEXCL) == -1 {
            close(descriptor)
            throw TransportError.openFailed("\(path) is already in use by another program.")
        }
        // Back to blocking reads now that the port is ours.
        if fcntl(descriptor, F_SETFL, 0) == -1 {
            close(descriptor)
            throw TransportError.openFailed("Could not configure \(path): \(String(cString: strerror(errno)))")
        }

        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            close(descriptor)
            throw TransportError.openFailed("Could not read terminal settings for \(path).")
        }
        cfmakeraw(&settings)
        cfsetispeed(&settings, baudRate)
        cfsetospeed(&settings, baudRate)
        settings.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        settings.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        // Block until at least one byte arrives, with a 0.5s idle timeout so the
        // reader thread can notice a disconnect request.
        withUnsafeMutablePointer(to: &settings.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 5
            }
        }
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            close(descriptor)
            throw TransportError.openFailed("Could not apply terminal settings for \(path).")
        }

        // Assert DTR and RTS together. On the ESP32 auto-reset circuit driving
        // both at once is a no-op, whereas toggling one alone reboots the board.
        var modemBits: Int32 = 0
        if ioctl(descriptor, TIOCMGET, &modemBits) == 0 {
            modemBits |= (TIOCM_DTR | TIOCM_RTS)
            _ = ioctl(descriptor, TIOCMSET, &modemBits)
        }
        tcflush(descriptor, TCIOFLUSH)

        state.withLock {
            $0.fileDescriptor = descriptor
            $0.isClosing = false
            $0.decoder.reset()
        }

        startReader()
        emit(.connected)
    }

    public func send(_ toRadio: Data) async throws {
        let framed = StreamFraming.frame(toRadio)
        let descriptor = state.withLock { $0.fileDescriptor }
        guard descriptor >= 0 else { throw TransportError.writeFailed("Serial port is closed.") }

        try framed.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw TransportError.writeFailed(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    public func disconnect() async {
        let teardown: (Int32, AsyncStream<TransportEvent>.Continuation?)? = state.withLock {
            guard !$0.isClosing, $0.fileDescriptor >= 0 else { return nil }
            $0.isClosing = true
            let descriptor = $0.fileDescriptor
            $0.fileDescriptor = -1
            let stream = $0.continuation
            $0.continuation = nil
            return (descriptor, stream)
        }
        guard let (descriptor, stream) = teardown else { return }

        close(descriptor)
        stream?.yield(.disconnected(nil))
        stream?.finish()
    }

    // MARK: - Reader

    private func startReader() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "MeshDash.Serial"
        thread.qualityOfService = .userInitiated
        readerThread = thread
        thread.start()
    }

    private func readLoop() {
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let (descriptor, closing) = state.withLock { ($0.fileDescriptor, $0.isClosing) }
            guard descriptor >= 0, !closing else { return }

            let count = read(descriptor, &scratch, scratch.count)
            if count > 0 {
                let output = state.withLock { $0.decoder.consume(Data(scratch[0..<count])) }
                for payload in output.payloads { emit(.payload(payload)) }
                if !output.debugText.isEmpty { emit(.deviceLog(output.debugText)) }
            } else if count == 0 {
                continue // VTIME idle timeout; loop so we can observe `isClosing`.
            } else {
                if errno == EINTR || errno == EAGAIN { continue }
                let message = String(cString: strerror(errno))
                let (wasClosing, stream) = state.withLock { s -> (Bool, AsyncStream<TransportEvent>.Continuation?) in
                    let wasClosing = s.isClosing
                    s.isClosing = true
                    let stream = s.continuation
                    s.continuation = nil
                    if s.fileDescriptor >= 0 { close(s.fileDescriptor); s.fileDescriptor = -1 }
                    return (wasClosing, stream)
                }
                if !wasClosing {
                    stream?.yield(.disconnected(.readFailed(message)))
                    stream?.finish()
                }
                return
            }
        }
    }

    private func emit(_ event: TransportEvent) {
        state.withLock { $0.continuation }?.yield(event)
    }
}
