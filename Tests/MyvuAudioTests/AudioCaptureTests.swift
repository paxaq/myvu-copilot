import COpus
import Foundation
import MyvuCore
import MyvuAI
import XCTest
@testable import MyvuAudio

final class AudioCaptureTests: XCTestCase {
    func testTimelineDistinguishesDisplayFromAudioOutageAndIncludesTrailingGap() {
        var timeline = MicCaptureTimeline()
        XCTAssertNil(timeline.longestGap(at: 10), "Initial waiting is not a stream outage")
        timeline.receivedAudio(at: 10, frames: 1)
        timeline.receivedAudio(at: 10.06, frames: 2)
        timeline.record(.cardShowRequested, at: 20, frames: 2)
        timeline.receivedAudio(at: 21, frames: 3)
        timeline.record(.cardDismissRequested, at: 30, frames: 3)
        XCTAssertEqual(timeline.longestGap(at: 40)!, 19, accuracy: 0.001)
        XCTAssertEqual(timeline.events.map(\.kind), [.firstAudio, .cardShowRequested,
                                                    .audioResumed, .cardDismissRequested])
        XCTAssertEqual(timeline.firstAudioAt, 10)
        for i in 0..<200 { timeline.record(.microphoneRequested, at: Double(i + 40), frames: 3) }
        XCTAssertEqual(timeline.events.count, 128)
        XCTAssertEqual(timeline.omittedEvents, 76)
    }
    func testPhoneLaunchCommandIsNotAForgedTriggerOrAck() throws {
        let bytes = try XCTUnwrap(AiProtocol.launchAssistant().data(using: .utf8))
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(message["code"] as? Int, 110)
        XCTAssertEqual(message.count, 1, "Official launch sends a null/omitted payload, not a fake recording session")
    }
    private func encodedPacket() throws -> Data {
        var error: Int32 = 0
        let encoder = try XCTUnwrap(opus_encoder_create(16_000, 1, OPUS_APPLICATION_VOIP, &error))
        defer { opus_encoder_destroy(encoder) }
        XCTAssertEqual(error, OPUS_OK)
        let samples = (0 ..< 320).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 8_000) }
        var output = [UInt8](repeating: 0, count: 1_275)
        let count = samples.withUnsafeBufferPointer {
            opus_encode(encoder, $0.baseAddress!, 320, &output, 1_275)
        }
        XCTAssertGreaterThan(count, 0)
        return Data(output.prefix(Int(count)))
    }

    private func relay(_ packets: [Data]) -> Data {
        var payload = Data()
        for packet in packets {
            payload.append(contentsOf: [UInt8(packet.count >> 8), UInt8(packet.count & 255)])
            payload.append(packet)
        }
        return Pb.bytes(5, payload)
    }

    func testRealOpusRoundTripAndReset() throws {
        let packet = try encodedPacket()
        let decoder = try LibOpusDecoder()
        let first = try decoder.decode(frame: packet)
        XCTAssertEqual(first.count, 640, "20ms at 16kHz mono Int16")
        XCTAssertTrue(first.contains { $0 != 0 })
        _ = try decoder.decode(frame: packet)
        decoder.reset()
        XCTAssertEqual(try decoder.decode(frame: packet), first)
        XCTAssertThrowsError(try decoder.decode(frame: Data()))
    }

    func testMultiPacketAndTruncatedTail() throws {
        let packet = try encodedPacket()
        XCTAssertEqual(try GlassesAudioPacket.frames(in: relay([packet, packet])), [packet, packet])
        let bad = Pb.bytes(5, Data([0, 1, 0xF8, 0]))
        XCTAssertThrowsError(try GlassesAudioPacket.frames(in: bad))
        XCTAssertThrowsError(try GlassesAudioPacket.frames(in: Pb.bytes(5, Data([0, 5, 0xF8]))))
        XCTAssertThrowsError(try GlassesAudioPacket.frames(in: Pb.bytes(5, Data([0, 0]))))
        XCTAssertThrowsError(try GlassesAudioPacket.frames(in: Data()))
    }

    func testStreamingBeyondOldTwoThousandFrameLimit() throws {
        let processor = MicCaptureProcessor(decoder: try LibOpusDecoder())
        let body = relay([try encodedPacket()])
        var bytes = 0
        for _ in 0 ..< 2_501 { try processor.consume(body) { bytes += $0.count } }
        XCTAssertEqual(processor.stats.frames, 2_501)
        XCTAssertEqual(bytes, 2_501 * 640)
        XCTAssertEqual(processor.stats.audioDuration, 50.02, accuracy: 0.0001)
        XCTAssertEqual(processor.stats.decodeErrors, 0)
        XCTAssertGreaterThan(processor.stats.peakDB, -60)
        try processor.consume(Pb.bytes(5, Data([0, 1, 0xF8, 0]))) { _ in
            XCTFail("Malformed messages must not emit partial audio")
        }
        XCTAssertEqual(processor.stats.malformedMessages, 1)
        XCTAssertEqual(processor.stats.frames, 2_501)
    }

    func testIncrementalWaveHeaderAndSizeLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WaveFileWriter(url: url, maximumBytes: 640)
        try writer.append(Data(repeating: 1, count: 320))
        try writer.append(Data(repeating: 2, count: 320))
        XCTAssertThrowsError(try writer.append(Data([0, 0])))
        try writer.finish()
        try writer.finish()
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 684)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(Array(bytes[40 ..< 44]), [0x80, 0x02, 0, 0])
        XCTAssertEqual(Array(bytes[4 ..< 8]), [0xA4, 0x02, 0, 0])
        XCTAssertEqual(Array(bytes[24 ..< 28]), [0x80, 0x3E, 0, 0])
        XCTAssertThrowsError(try writer.append(Data([0, 0])))
    }
}
