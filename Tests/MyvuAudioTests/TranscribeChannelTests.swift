import COpus
import Foundation
import MyvuAI
import MyvuCore
import XCTest
@testable import MyvuAudio

final class TranscribeChannelTests: XCTestCase {
    func testInterConnectMessageCarriesDataAsAString() throws {
        let start = try XCTUnwrap(JsonReader(parsing: GlassTranscribe.buildStart()))
        XCTAssertEqual(start.optInt("msgCmd", -1), 61)
        let data = try XCTUnwrap(start.opt("data") as? String, "data must be a JSON string, not an object")
        let inner = try XCTUnwrap(JsonReader(parsing: data))
        XCTAssertEqual(inner.optInt("transType", -1), GlassTranscribe.TranscribeType.transcribe)
        XCTAssertEqual(inner.optString("src"), "en")
        XCTAssertEqual(inner.optString("dst"), "en")
        XCTAssertTrue(inner.optBool("phoneInitFinish", false))
        XCTAssertTrue(inner.optBool("isNewSession", false))

        let record = try XCTUnwrap(JsonReader(parsing: GlassTranscribe.buildRecordState(2)))
        XCTAssertEqual(record.optInt("msgCmd", -1), 51)
        XCTAssertEqual(JsonReader(parsing: try XCTUnwrap(record.opt("data") as? String))?
            .optInt("recordState", -1), 2)

        // Gson omits a null data field.
        XCTAssertEqual(GlassTranscribe.buildExitAck(), #"{"msgCmd":68}"#)
    }

    func testSceneLaunchMatchesTheOpenAppEnvelope() throws {
        let json = try XCTUnwrap(JsonReader(parsing: GlassTranscribe.buildOpenScene()))
        XCTAssertEqual(json.optString("action"), "app")
        let data = try XCTUnwrap(json.optObject("data"))
        XCTAssertEqual(data.optString("action"), "open_app")
        XCTAssertEqual(data.optString("launchMode"), "scene")
        // XGA010C answered from the Translation app, not the Transcribe package.
        XCTAssertEqual(data.optString("pkg"), "com.upuphone.ar.translation.glasses")
        let ext = try XCTUnwrap(data.opt("ext") as? String, "ext must be a JSON string")
        let fields = try XCTUnwrap(JsonReader(parsing: ext))
        for key in ["dst", "saveResult", "src", "subtitleSetType",
                    "transType", "transVersionCode", "versionCode"] {
            XCTAssertTrue(fields.has(key), "missing InitPhone2GlassInfo.\(key)")
        }
        XCTAssertEqual(fields.optInt("transType", -1), 1, "transType 1 is transcription")
    }

    func testPhoneReportsStateMachineInsteadOfSilence() throws {
        XCTAssertEqual(GlassTranscribe.phonePackage, "com.upuphone.ar.translation.phone")
        let running = try XCTUnwrap(JsonReader(parsing: GlassTranscribe.buildTransState(
            GlassTranscribe.TransState.running)))
        XCTAssertEqual(running.optInt("msgCmd", -1), 52)
        let state = try XCTUnwrap(JsonReader(parsing: try XCTUnwrap(running.opt("data") as? String)))
        XCTAssertEqual(state.optInt("transState", -1), 4)
        XCTAssertEqual(state.optInt("extCode", 0), -1)
    }

    /// Shape read from the glasses firmware's PResultMsg parser: `src` (or
    /// `dst`) is an object with string `content` and number `type`, 0 = commit.
    func testSubtitleUsesTheFirmwareResultShape() throws {
        func line(_ json: String) throws -> (cmd: Int, src: JsonReader, hasDst: Bool) {
            let outer = try XCTUnwrap(JsonReader(parsing: json))
            let data = try XCTUnwrap(JsonReader(parsing: try XCTUnwrap(outer.opt("data") as? String)))
            return (outer.optInt("msgCmd", -1), try XCTUnwrap(data.optObject("src")), data.opt("dst") != nil)
        }
        let partial = try line(GlassTranscribe.buildSubtitle("Hello the", committed: false))
        XCTAssertEqual(partial.cmd, 53)
        XCTAssertEqual(partial.src.optString("content"), "Hello the")
        XCTAssertEqual(partial.src.optInt("type", -1), 1, "non-zero keeps the line open")
        XCTAssertFalse(partial.hasDst, "a dst object would make the glasses ignore src")

        let final = try line(GlassTranscribe.buildSubtitle("Hello there.", committed: true))
        XCTAssertEqual(final.src.optInt("type", -1), 0, "0 commits the line")
        XCTAssertEqual(final.src.optString("content"), "Hello there. ",
                       "the firmware joins committed lines with no separator")
        let padded = try line(GlassTranscribe.buildSubtitle("Next one \n ", committed: true))
        XCTAssertEqual(padded.src.optString("content"), "Next one ", "one trailing space, not more")
        let empty = try line(GlassTranscribe.buildSubtitle("", committed: true))
        XCTAssertEqual(empty.src.optString("content"), "")
        XCTAssertEqual(partial.src.optString("content").last, "e", "partials get no separator")

        let long = String(repeating: "word ", count: 400)
        let capped = try line(GlassTranscribe.buildSubtitle(long, committed: false))
        XCTAssertEqual(capped.src.optString("content").count, GlassTranscribe.subtitleCharacterLimit)
        XCTAssertTrue(long.hasSuffix(capped.src.optString("content")), "keeps the newest words")
    }

    func testPhoneStopUsesTransExit() throws {
        // Intl firmware 1.0.11.53: 68 reaches PStopMsg -> stopTrans; 65 is invalid.
        let stop = try XCTUnwrap(JsonReader(parsing: GlassTranscribe.buildExitAck()))
        XCTAssertEqual(stop.optInt("msgCmd", -1), 68)
        XCTAssertNil(stop.opt("data"))
    }

    func testEnvelopeParsingKeepsPackagesJsonAndBinary() throws {
        let audio = Data([1, 2, 3, 4])
        let body = Pb.string(2, GlassTranscribe.glassPackage) + Pb.string(3, AppLayer.pkgLauncher)
            + Pb.string(4, GlassTranscribe.message(3)) + Pb.bytes(5, audio) + Pb.varintField(6, 9)
        let message = try XCTUnwrap(AppChannelMessage.parse(body))
        XCTAssertEqual(message.sourcePackage, GlassTranscribe.glassPackage)
        XCTAssertEqual(message.targetPackage, AppLayer.pkgLauncher)
        XCTAssertEqual(message.msgCmd, GlassTranscribe.Glass2Phone.proximalAudio)
        XCTAssertEqual(message.binary, audio)
        XCTAssertTrue(message.involves("ar.translation"))

        let control = Pb.string(2, GlassTranscribe.glassPackage) + Pb.string(3, AppLayer.pkgLauncher)
            + Pb.string(4, GlassTranscribe.message(11, data: #"{"state":1}"#))
        let parsed = try XCTUnwrap(AppChannelMessage.parse(control))
        XCTAssertEqual(parsed.msgCmd, 11)
        XCTAssertEqual(parsed.dataString, #"{"state":1}"#)
        XCTAssertTrue(parsed.binary.isEmpty)

        let assistant = Pb.string(2, AppLayer.pkgAi) + Pb.string(3, AppLayer.pkgAi)
            + Pb.string(4, #"{"code":109}"#)
        XCTAssertNil(try XCTUnwrap(AppChannelMessage.parse(assistant)).msgCmd)
    }

    func testDetectsLengthPrefixedOpus() throws {
        let decoder = TranscribeAudioDecoder(decoder: try LibOpusDecoder())
        let packet = try encodedPacket()
        let pcm = decoder.consume(prefixed([packet, packet]))
        XCTAssertEqual(decoder.stats.format, .lengthPrefixedOpus)
        XCTAssertEqual(pcm.count, 2)
        XCTAssertEqual(pcm.first?.count, 640)
        XCTAssertEqual(decoder.stats.frames, 2)
        // A damaged message is counted, not partially decoded.
        XCTAssertTrue(decoder.consume(prefixed([packet]).dropLast()).isEmpty)
        XCTAssertEqual(decoder.stats.undecodedMessages, 1)
    }

    func testSinglePacketFormatNeedsRepeatedConfirmation() throws {
        let decoder = TranscribeAudioDecoder(decoder: try LibOpusDecoder())
        let packet = try encodedPacket()
        XCTAssertTrue(decoder.consume(packet).isEmpty)
        XCTAssertTrue(decoder.consume(packet).isEmpty)
        XCTAssertEqual(decoder.stats.format, .detecting)
        let released = decoder.consume(packet)
        XCTAssertEqual(decoder.stats.format, .singleOpus)
        XCTAssertEqual(released.count, TranscribeAudioDecoder.singlePacketConfirmations,
                       "audio held during detection is released, not dropped")
        XCTAssertEqual(decoder.consume(packet).count, 1)
    }

    func testUndecodablePayloadIsReportedNotGuessedAsPCM() throws {
        let decoder = TranscribeAudioDecoder(decoder: try LibOpusDecoder())
        for _ in 0 ..< TranscribeAudioDecoder.detectionLimit { XCTAssertTrue(decoder.consume(Data()).isEmpty) }
        XCTAssertEqual(decoder.stats.format, .undecodable)
        XCTAssertEqual(decoder.stats.frames, 0)
        XCTAssertEqual(decoder.stats.sampleCount, 0)
    }

    func testDetailIsBounded() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(TranscribeChannelCapture.safeDetail(long)?.count, 161)
        XCTAssertNil(TranscribeChannelCapture.safeDetail(""))
    }

    private func prefixed(_ packets: [Data]) -> Data {
        var payload = Data()
        for packet in packets {
            payload.append(contentsOf: [UInt8(packet.count >> 8), UInt8(packet.count & 255)])
            payload.append(packet)
        }
        return payload
    }

    private func encodedPacket() throws -> Data {
        var error: Int32 = 0
        let encoder = try XCTUnwrap(opus_encoder_create(16_000, 1, OPUS_APPLICATION_VOIP, &error))
        defer { opus_encoder_destroy(encoder) }
        let samples = (0 ..< 320).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 8_000) }
        var output = [UInt8](repeating: 0, count: 1_275)
        let count = samples.withUnsafeBufferPointer {
            opus_encode(encoder, $0.baseAddress!, 320, &output, 1_275)
        }
        XCTAssertGreaterThan(count, 0)
        return Data(output.prefix(Int(count)))
    }
}
