import COpus
import Foundation
import MyvuAI

/// Raw Opus packets -> signed little-endian 16-bit PCM. Confine each decoder
/// to one audio queue; reset only at a real device recording boundary.
public final class LibOpusDecoder: OpusDecoding {
    public let sampleRate = 16_000
    public let channels = 1
    private let state: OpaquePointer

    public init() throws {
        var error: Int32 = 0
        guard let decoder = opus_decoder_create(16_000, 1, &error), error == OPUS_OK else {
            throw AudioCaptureError.codec(error)
        }
        state = decoder
    }

    deinit { opus_decoder_destroy(state) }

    public func reset() { _ = opus_decoder_init(state, 16_000, 1) }

    public func decode(frame: Data) throws -> Data {
        guard !frame.isEmpty else { throw AudioCaptureError.invalidPacket }
        // Opus packets can contain up to 120 ms, not just a single 20 ms frame.
        var pcm = [Int16](repeating: 0, count: 1_920)
        let count = frame.withUnsafeBytes { raw in
            opus_decode(state, raw.bindMemory(to: UInt8.self).baseAddress,
                        Int32(frame.count), &pcm, 1_920, 0)
        }
        guard count > 0 else { throw AudioCaptureError.codec(count) }
        return pcm.withUnsafeBytes { Data($0.prefix(Int(count) * 2)) }
    }
}

public enum AudioCaptureError: LocalizedError {
    case invalidPacket
    case codec(Int32)
    case recordingTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidPacket: return "Malformed glasses audio packet."
        case .codec(let code): return "Opus decoder error (\(code))."
        case .recordingTooLarge: return "The diagnostic recording reached its size limit."
        }
    }
}
