import Foundation
import MyvuAI

/// How the Transcribe app packs audio in the StMessage binary field.
///
/// Not recovered statically (`BleAudioManager` is a protected stub), so the
/// first packets decide. The assistant's code 109 uses 2-byte big-endian
/// length-prefixed Opus; that is tried first, then one Opus packet per
/// message. Nothing is assumed to be raw PCM: an undecodable stream is
/// reported as such, and its bytes can be kept for offline analysis.
public enum TranscribePayloadFormat: String, Sendable, Codable {
    case detecting, lengthPrefixedOpus, singleOpus, undecodable
}

public struct TranscribeStreamStats: Sendable, Codable {
    public var messages = 0
    public var bytes = 0
    public var frames = 0
    public var undecodedMessages = 0
    public var decodeErrors = 0
    public var sampleCount = 0
    public var levelDB = -90.0
    public var peakDB = -90.0
    public var format = TranscribePayloadFormat.detecting
    /// Distinct payload sizes, bounded: a fingerprint of the packing.
    public var payloadSizes: [Int] = []
    public var audioDuration: TimeInterval { Double(sampleCount) / 16_000 }
    public init() {}
}

/// Queue-confined: one instance per stream, one decoder state per instance.
public final class TranscribeAudioDecoder {
    /// Messages tried before a stream is declared undecodable.
    public static let detectionLimit = 24
    /// Consecutive single-packet successes needed to accept that format; a
    /// lone success could be noise the Opus decoder happened to accept.
    public static let singlePacketConfirmations = 3

    private let decoder: OpusDecoding
    public private(set) var stats = TranscribeStreamStats()
    private var singleSuccesses = 0
    private var pendingSingle: [Data] = []

    public init(decoder: OpusDecoding) { self.decoder = decoder }

    /// Returns decoded 16 kHz mono PCM chunks for one message's binary field.
    public func consume(_ payload: Data) -> [Data] {
        stats.messages += 1
        stats.bytes += payload.count
        if stats.payloadSizes.count < 16, !stats.payloadSizes.contains(payload.count) {
            stats.payloadSizes.append(payload.count)
        }
        switch stats.format {
        case .lengthPrefixedOpus:
            guard let frames = Self.lengthPrefixedFrames(payload) else {
                stats.undecodedMessages += 1
                return []
            }
            return decode(frames)
        case .singleOpus:
            return decode([payload])
        case .undecodable:
            stats.undecodedMessages += 1
            return []
        case .detecting:
            return detect(payload)
        }
    }

    private func detect(_ payload: Data) -> [Data] {
        if let frames = Self.lengthPrefixedFrames(payload), !frames.isEmpty {
            decoder.reset()
            var pcm: [Data] = []
            for frame in frames {
                guard let chunk = try? decoder.decode(frame: frame), Self.plausible(chunk) else {
                    pcm = []
                    break
                }
                pcm.append(chunk)
            }
            if !pcm.isEmpty {
                stats.format = .lengthPrefixedOpus
                pendingSingle = []
                record(pcm)
                return pcm
            }
            // A failed attempt mutated the decoder; start the next one clean.
            decoder.reset()
        }
        if !payload.isEmpty, let chunk = try? decoder.decode(frame: payload), Self.plausible(chunk) {
            singleSuccesses += 1
            pendingSingle.append(chunk)
            if singleSuccesses >= Self.singlePacketConfirmations {
                stats.format = .singleOpus
                let accepted = pendingSingle
                pendingSingle = []
                record(accepted)
                return accepted
            }
            return []
        }
        singleSuccesses = 0
        pendingSingle = []
        decoder.reset()
        stats.undecodedMessages += 1
        if stats.messages >= Self.detectionLimit { stats.format = .undecodable }
        return []
    }

    private func decode(_ frames: [Data]) -> [Data] {
        var out: [Data] = []
        for frame in frames {
            do { out.append(try decoder.decode(frame: frame)) }
            catch { stats.decodeErrors += 1 }
        }
        record(out)
        return out
    }

    private func record(_ chunks: [Data]) {
        for pcm in chunks {
            stats.frames += 1
            stats.sampleCount += pcm.count / 2
            let level = Self.rmsDB(pcm)
            stats.levelDB = level
            stats.peakDB = max(stats.peakDB, level)
        }
    }

    /// Whole-payload 2-byte big-endian length framing, or nil if the lengths
    /// do not consume the payload exactly.
    public static func lengthPrefixedFrames(_ payload: Data) -> [Data]? {
        var frames: [Data] = []
        var offset = payload.startIndex
        while offset < payload.endIndex {
            guard offset + 2 <= payload.endIndex else { return nil }
            let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2
            guard length > 0, offset + length <= payload.endIndex else { return nil }
            frames.append(Data(payload[offset ..< offset + length]))
            offset += length
        }
        return frames
    }

    /// Opus packets are whole multiples of 2.5 ms; at 16 kHz that is 40 samples.
    static func plausible(_ pcm: Data) -> Bool {
        let samples = pcm.count / 2
        return samples >= 40 && samples % 40 == 0
    }

    static func rmsDB(_ pcm: Data) -> Double {
        var squareSum = 0.0
        let samples = max(1, pcm.count / 2)
        pcm.withUnsafeBytes { bytes in
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                let normalized = Double(value) / 32768
                squareSum += normalized * normalized
            }
        }
        return max(-90, 20 * log10(max(0.000_001, sqrt(squareSum / Double(samples)))))
    }
}
