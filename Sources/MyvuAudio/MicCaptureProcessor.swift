import Foundation
import MyvuAI
import MyvuCore

/// Streaming parser: never retains the utterance or a growing array of packets.
/// Reject the entire payload when a length is truncated, including a one-byte
/// tail. A damaged message must not partially advance the decoder state.
public enum GlassesAudioPacket {
    public static func frames(in relay: Data) throws -> [Data] {
        let payload = Pb.firstBytes(Pb.parse(relay), 5)
        guard !payload.isEmpty else { throw AudioCaptureError.invalidPacket }
        var frames: [Data] = []
        var offset = 0
        while offset < payload.count {
            guard offset + 2 <= payload.count else { throw AudioCaptureError.invalidPacket }
            let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2
            guard length > 0, offset + length <= payload.count else {
                throw AudioCaptureError.invalidPacket
            }
            frames.append(Data(payload[offset ..< offset + length]))
            offset += length
        }
        return frames
    }
}

public struct MicCaptureStats: Sendable, Codable {
    public var messages = 0
    public var frames = 0
    public var malformedMessages = 0
    public var decodeErrors = 0
    public var sampleCount = 0
    public var levelDB = -90.0
    public var peakDB = -90.0
    public var frameSizes: Set<Int> = []
    public var audioDuration: TimeInterval { Double(sampleCount) / 16_000 }
    public init() {}
}

/// Queue-confined decoding and counters, separate from BLE and UI for testing.
public final class MicCaptureProcessor {
    private let decoder: OpusDecoding
    public private(set) var stats = MicCaptureStats()

    public init(decoder: OpusDecoding) { self.decoder = decoder }

    public func resetDecoder() { decoder.reset() }

    public func consume(_ relay: Data, onPCM: (Data) throws -> Void) throws {
        stats.messages += 1
        let frames: [Data]
        do { frames = try GlassesAudioPacket.frames(in: relay) }
        catch { stats.malformedMessages += 1; return }
        for frame in frames {
            stats.frameSizes.insert(frame.count)
            let pcm: Data
            do { pcm = try decoder.decode(frame: frame) }
            catch { stats.decodeErrors += 1; continue }
            stats.frames += 1
            stats.sampleCount += pcm.count / 2
            var squareSum = 0.0
            pcm.withUnsafeBytes { bytes in
                for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                    let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                    let normalized = Double(value) / 32768
                    squareSum += normalized * normalized
                }
            }
            let rms = sqrt(squareSum / Double(max(1, pcm.count / 2)))
            stats.levelDB = max(-90, 20 * log10(max(0.000_001, rms)))
            stats.peakDB = max(stats.peakDB, stats.levelDB)
            try onPCM(pcm)
        }
    }
}
