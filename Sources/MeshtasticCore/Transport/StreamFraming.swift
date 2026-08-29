import Foundation

/// The Meshtastic stream framing used on Serial and TCP links.
///
/// Every protobuf is prefixed with `0x94 0xC3` followed by a big-endian 16-bit
/// length. The receiver hunts for START1 and discards anything that does not
/// look like a valid header, which is what lets a client attach to a serial port
/// that is already mid-way through emitting debug logs.
public enum StreamFraming {
    public static let start1: UInt8 = 0x94
    public static let start2: UInt8 = 0xC3
    public static let maxPayload = 512
    public static let headerLength = 4

    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + headerLength)
        out.append(start1)
        out.append(start2)
        out.append(UInt8((payload.count >> 8) & 0xFF))
        out.append(UInt8(payload.count & 0xFF))
        out.append(payload)
        return out
    }
}

/// Incremental de-framer. Feed it arbitrary chunks of bytes; it hands back whole
/// protobuf payloads and surfaces any non-framed bytes as device log text.
public struct FrameDecoder: Sendable {
    public struct Output: Sendable {
        public var payloads: [Data] = []
        /// Bytes that were not part of a frame — on a serial link these are the
        /// device's own printf debug output, which is worth showing to the user.
        public var debugText: String = ""
    }

    private var buffer = Data()
    private var strayBytes = Data()

    public init() {}

    public mutating func consume(_ incoming: Data) -> Output {
        buffer.append(incoming)
        var result = Output()

        loop: while true {
            // Hunt for the start marker, treating everything before it as log text.
            guard let markerIndex = findStart(in: buffer) else {
                // Keep at most one trailing byte in case it is a split 0x94.
                if buffer.count > 1 {
                    strayBytes.append(buffer.prefix(buffer.count - 1))
                    buffer.removeFirst(buffer.count - 1)
                }
                break loop
            }
            if markerIndex > 0 {
                strayBytes.append(buffer.prefix(markerIndex))
                buffer.removeFirst(markerIndex)
            }

            guard buffer.count >= StreamFraming.headerLength else { break loop }

            let length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            guard length <= StreamFraming.maxPayload else {
                // Corrupt header — drop the marker and resume hunting.
                strayBytes.append(buffer[buffer.startIndex])
                buffer.removeFirst()
                continue loop
            }
            guard buffer.count >= StreamFraming.headerLength + length else { break loop }

            let start = buffer.index(buffer.startIndex, offsetBy: StreamFraming.headerLength)
            let end = buffer.index(start, offsetBy: length)
            result.payloads.append(Data(buffer[start..<end]))
            buffer.removeSubrange(buffer.startIndex..<end)
        }

        if !strayBytes.isEmpty {
            // Only flush complete lines so multi-chunk log lines stay intact.
            if let newlineIndex = strayBytes.lastIndex(of: 0x0A) {
                let chunk = strayBytes[strayBytes.startIndex...newlineIndex]
                result.debugText = String(decoding: chunk, as: UTF8.self)
                strayBytes.removeSubrange(strayBytes.startIndex...newlineIndex)
            } else if strayBytes.count > 4096 {
                result.debugText = String(decoding: strayBytes, as: UTF8.self)
                strayBytes.removeAll()
            }
        }
        return result
    }

    public mutating func reset() {
        buffer.removeAll()
        strayBytes.removeAll()
    }

    private func findStart(in data: Data) -> Int? {
        guard data.count >= 2 else {
            return data.first == StreamFraming.start1 ? 0 : nil
        }
        var index = data.startIndex
        let limit = data.index(data.endIndex, offsetBy: -1)
        while index < limit {
            if data[index] == StreamFraming.start1 && data[data.index(after: index)] == StreamFraming.start2 {
                return data.distance(from: data.startIndex, to: index)
            }
            index = data.index(after: index)
        }
        // A trailing lone START1 might be the first half of a split header.
        return data[limit] == StreamFraming.start1 ? data.count - 1 : nil
    }
}
