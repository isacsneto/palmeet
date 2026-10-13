import Foundation

/// The 32-byte little-endian header that prefixes every binary WebSocket frame (extension → app).
///
/// ```
/// offset size field
///   0     1  kind          (1 = audio PCM Int16 interleaved, 2 = video JPEG)
///   1     1  reserved      (0)
///   2     2  channels      u16 (audio; 0 for video)
///   4     4  sampleRate    u32 (audio; 0 for video)
///   8    16  sessionId     UUID raw bytes, RFC 4122 order
///  24     8  captureTime   f64, Unix epoch milliseconds
///  32     …  payload
/// ```
public struct BinaryFrameHeader: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case audioPCM16 = 1
        case videoJPEG = 2
    }

    public static let size = 32

    public var kind: Kind
    public var channels: UInt16
    public var sampleRate: UInt32
    public var sessionID: UUID
    /// Unix epoch milliseconds.
    public var captureTimeMs: Double

    public init(kind: Kind, channels: UInt16, sampleRate: UInt32, sessionID: UUID, captureTimeMs: Double) {
        self.kind = kind
        self.channels = channels
        self.sampleRate = sampleRate
        self.sessionID = sessionID
        self.captureTimeMs = captureTimeMs
    }

    public var captureDate: Date { Date(timeIntervalSince1970: captureTimeMs / 1000) }

    public enum DecodingError: Error, Equatable {
        case tooShort(Int)
        case unknownKind(UInt8)
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.append(kind.rawValue)
        data.append(0)
        withUnsafeBytes(of: channels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sessionID.uuid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: captureTimeMs.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Parses a header from the start of `data` (payload follows at `size`).
    public static func decode(_ data: Data) throws -> BinaryFrameHeader {
        guard data.count >= size else { throw DecodingError.tooShort(data.count) }
        let bytes = [UInt8](data.prefix(size))
        guard let kind = Kind(rawValue: bytes[0]) else { throw DecodingError.unknownKind(bytes[0]) }
        func uint(_ offset: Int, _ count: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<count { value |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
            return value
        }
        let u = bytes[8..<24].map { $0 }
        let uuid = UUID(uuid: (
            u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
            u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]
        ))
        return BinaryFrameHeader(
            kind: kind,
            channels: UInt16(truncatingIfNeeded: uint(2, 2)),
            sampleRate: UInt32(truncatingIfNeeded: uint(4, 4)),
            sessionID: uuid,
            captureTimeMs: Double(bitPattern: uint(24, 8))
        )
    }
}

/// A decoded binary frame.
public enum BinaryFrame: Sendable {
    case audio(BridgeAudioChunk)
    case video(BridgeVideoFrame)

    public enum DecodingError: Error, Equatable {
        case invalidAudioFormat(channels: UInt16, sampleRate: UInt32)
    }

    public static func decode(_ data: Data) throws -> BinaryFrame {
        let header = try BinaryFrameHeader.decode(data)
        let payload = data.dropFirst(BinaryFrameHeader.size)
        switch header.kind {
        case .audioPCM16:
            guard header.channels > 0, header.sampleRate > 0 else {
                throw DecodingError.invalidAudioFormat(channels: header.channels, sampleRate: header.sampleRate)
            }
            let channels = Int(header.channels)
            return .audio(BridgeAudioChunk(
                sessionID: header.sessionID,
                captureTime: header.captureDate,
                sampleRate: Double(header.sampleRate),
                channels: channels,
                samples: PCMConversion.monoFloat(fromInterleavedInt16LE: payload, channels: channels)
            ))
        case .videoJPEG:
            return .video(BridgeVideoFrame(
                sessionID: header.sessionID, captureTime: header.captureDate, jpegData: Data(payload)
            ))
        }
    }

    /// Builds an audio frame (used by tests and tools; the extension builds these in JS).
    public static func encodeAudio(
        sessionID: UUID, captureTimeMs: Double, sampleRate: UInt32, channels: UInt16, interleaved: [Int16]
    ) -> Data {
        var data = BinaryFrameHeader(
            kind: .audioPCM16, channels: channels, sampleRate: sampleRate,
            sessionID: sessionID, captureTimeMs: captureTimeMs
        ).encoded()
        data.reserveCapacity(BinaryFrameHeader.size + interleaved.count * 2)
        for sample in interleaved {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func encodeVideo(sessionID: UUID, captureTimeMs: Double, jpeg: Data) -> Data {
        BinaryFrameHeader(
            kind: .videoJPEG, channels: 0, sampleRate: 0, sessionID: sessionID, captureTimeMs: captureTimeMs
        ).encoded() + jpeg
    }
}

public enum PCMConversion {
    /// Converts little-endian interleaved Int16 PCM to mono Float in -1...1 by averaging channels.
    /// A trailing partial frame (or odd byte) is ignored.
    public static func monoFloat(fromInterleavedInt16LE bytes: Data, channels: Int) -> [Float] {
        guard channels > 0 else { return [] }
        let sampleCount = bytes.count / 2
        let frameCount = sampleCount / channels
        guard frameCount > 0 else { return [] }
        let scale = 1.0 / (32768.0 * Float(channels))
        var output = [Float](repeating: 0, count: frameCount)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in 0..<frameCount {
                var sum: Int32 = 0
                let base = frame * channels * 2
                for ch in 0..<channels {
                    let offset = base + ch * 2
                    let value = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
                    sum += Int32(Int16(bitPattern: value))
                }
                output[frame] = Float(sum) * scale
            }
        }
        return output
    }
}
