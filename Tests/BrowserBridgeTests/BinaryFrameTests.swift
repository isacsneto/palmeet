import Foundation
import Testing
@testable import BrowserBridge

@Suite("Binary frames")
struct BinaryFrameTests {
    let sessionID = UUID(uuidString: "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b")!

    @Test func headerMatchesReferenceBytes() {
        // Reference produced with Python: struct.pack('<BBHI16sd', 1, 0, 2, 48000, uuid.bytes, 1700000000123.5)
        let header = BinaryFrameHeader(
            kind: .audioPCM16, channels: 2, sampleRate: 48000, sessionID: sessionID, captureTimeMs: 1_700_000_000_123.5
        )
        let encoded = header.encoded()
        #expect(encoded.count == BinaryFrameHeader.size)
        #expect(hex(encoded) == "0100020080bb00006f1c2a3b4d5e4f608a7b9c0d1e2f3a4b00b88756febc7842")
    }

    @Test func headerRoundTrip() throws {
        let header = BinaryFrameHeader(
            kind: .videoJPEG, channels: 0, sampleRate: 0, sessionID: UUID(), captureTimeMs: 1_234_567.25
        )
        let decoded = try BinaryFrameHeader.decode(header.encoded() + Data([1, 2, 3]))
        #expect(decoded == header)
        #expect(abs(decoded.captureDate.timeIntervalSince1970 - 1_234.56725) < 1e-6)
    }

    @Test func headerRejectsShortAndUnknownKind() {
        #expect(throws: BinaryFrameHeader.DecodingError.tooShort(10)) {
            try BinaryFrameHeader.decode(Data(count: 10))
        }
        var bytes = BinaryFrameHeader(
            kind: .audioPCM16, channels: 1, sampleRate: 16000, sessionID: sessionID, captureTimeMs: 0
        ).encoded()
        bytes[0] = 9
        #expect(throws: BinaryFrameHeader.DecodingError.unknownKind(9)) {
            try BinaryFrameHeader.decode(bytes)
        }
    }

    @Test func int16ToMonoFloat() {
        // Stereo frames: (32767, -32768), (16384, 16384), (0, -16384)
        let samples: [Int16] = [32767, -32768, 16384, 16384, 0, -16384]
        var bytes = Data()
        for s in samples { withUnsafeBytes(of: s.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(0x7F)  // stray odd byte is ignored
        let mono = PCMConversion.monoFloat(fromInterleavedInt16LE: bytes, channels: 2)
        #expect(mono.count == 3)
        #expect(abs(mono[0] - (-1.0 / 65536)) < 1e-7)
        #expect(mono[1] == 0.5)
        #expect(mono[2] == -0.25)
        #expect(PCMConversion.monoFloat(fromInterleavedInt16LE: bytes, channels: 0).isEmpty)
    }

    @Test func monoFullScale() {
        var bytes = Data()
        for s: Int16 in [Int16.min, Int16.max, 0] { withUnsafeBytes(of: s.littleEndian) { bytes.append(contentsOf: $0) } }
        let mono = PCMConversion.monoFloat(fromInterleavedInt16LE: bytes, channels: 1)
        #expect(mono == [-1.0, Float(32767) / 32768, 0])
    }

    @Test func audioFrameRoundTrip() throws {
        let data = BinaryFrame.encodeAudio(
            sessionID: sessionID, captureTimeMs: 5000, sampleRate: 48000, channels: 2,
            interleaved: [16384, -16384, 8192, 8192]
        )
        guard case .audio(let chunk) = try BinaryFrame.decode(data) else {
            Issue.record("expected audio")
            return
        }
        #expect(chunk.sessionID == sessionID)
        #expect(chunk.sampleRate == 48000)
        #expect(chunk.channels == 2)
        #expect(chunk.samples == [0, 0.25])
        #expect(chunk.captureTime == Date(timeIntervalSince1970: 5))
    }

    @Test func videoFrameRoundTrip() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0xFF, 0xD9])
        let data = BinaryFrame.encodeVideo(sessionID: sessionID, captureTimeMs: 42, jpeg: jpeg)
        guard case .video(let frame) = try BinaryFrame.decode(data) else {
            Issue.record("expected video")
            return
        }
        #expect(frame.jpegData == jpeg)
        #expect(frame.sessionID == sessionID)
    }

    @Test func audioWithZeroChannelsIsRejected() {
        let data = BinaryFrame.encodeAudio(sessionID: sessionID, captureTimeMs: 0, sampleRate: 48000, channels: 0, interleaved: [1])
        #expect(throws: BinaryFrame.DecodingError.self) { try BinaryFrame.decode(data) }
    }
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
