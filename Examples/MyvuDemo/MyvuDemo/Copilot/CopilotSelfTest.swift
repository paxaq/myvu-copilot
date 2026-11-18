#if DEBUG
import Foundation
import MyvuAudio
import MyvuCore

/// Explicit developer launch argument only. Uses bundled synthetic speech;
/// never accesses a microphone or sends conversation data to any service.
@MainActor
enum CopilotSelfTest {
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--copilot-self-test") else { return }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CopilotDiagnostics", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return }
        let output = directory.appendingPathComponent("self-test.json")
        func write(_ value: [String: Any]) {
            if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: output, options: .atomic)
            }
        }
        write(["status": "preparing", "input": "bundled synthetic English speech"])
        guard #available(iOS 26.0, *) else { write(["status": "failed", "error": "iOS 26 required"]); return }
        let speech = AppleSpeechTranscriber()
        var text = ""
        var lastPartial = ""
        speech.onText = { value, final in
            if final { text += " " + value; lastPartial = "" }
            else { lastPartial = value }
        }
        speech.onStatus = { value in write(["status": "preparing", "detail": value]) }
        do {
            try await speech.start()
            guard let fixture = Bundle.main.url(forResource: "english-test", withExtension: "opusframes") else {
                throw DemoError("Missing synthetic speech fixture")
            }
            let payload = try Data(contentsOf: fixture)
            let packets = try GlassesAudioPacket.frames(in: Pb.bytes(5, payload))
            let decoder = try LibOpusDecoder()
            var samples = 0
            write(["status": "transcribing", "packets": packets.count])
            for packet in packets {
                let pcm = try decoder.decode(frame: packet)
                samples += pcm.count / 2
                try speech.append(pcm)
                try await Task.sleep(for: .milliseconds(20))
            }
            await speech.finish()
            let recognized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let anchors = ["deadline", "friday", "budget", "support"]
            let missing = anchors.filter { !recognized.lowercased().contains($0) }
            write(["status": missing.isEmpty ? "passed" : "failed", "transcript": recognized,
                   "unfinalized": lastPartial, "missingWords": missing, "audioSeconds": Double(samples) / 16_000,
                   "input": "bundled synthetic English speech", "recognizer": "Apple SpeechAnalyzer on-device"])
        } catch {
            await speech.cancel()
            write(["status": "failed", "error": error.localizedDescription])
        }
    }
}
#endif
