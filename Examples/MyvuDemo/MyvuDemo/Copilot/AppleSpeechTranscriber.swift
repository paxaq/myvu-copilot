import AVFoundation
import Foundation
import Speech

@MainActor
protocol LocalTranscribing: AnyObject {
    var onText: ((String, Bool) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start() async throws
    func append(_ pcm: Data) throws
    func finish() async
    func cancel() async
}

/// Only SpeechAnalyzer is used. No fallback to a recognizer that might send
/// audio to a server, and no phone microphone or playback audio session.
@available(iOS 26.0, *)
@MainActor
final class AppleSpeechTranscriber: LocalTranscribing {
    var onText: ((String, Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
        sampleRate: 16_000, channels: 1, interleaved: false)!
    private var sampleOffset: Int64 = 0

    static func prepareEnglish(status: (String) -> Void) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw DemoError("Apple on-device transcription is unavailable on this device.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw DemoError("The English transcription model is not supported.")
        }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let state = await AssetInventory.status(forModules: [module])
        if state != .installed {
            status("Downloading the English model — audio stays on this iPhone")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw DemoError("The English model is not ready. Try preparing it again.")
        }
        status("English model ready — on-device")
        return locale
    }

    func start() async throws {
        let locale = try await Self.prepareEnglish { [weak self] in self?.onStatus?($0) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DemoError("Apple Speech did not provide a supported audio format.")
        }
        targetFormat = format
        if format != sourceFormat {
            guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                throw DemoError("Could not convert glasses audio for Apple Speech.")
            }
            converter.primeMethod = .none
            self.converter = converter
        }
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    self?.onText?(String(result.text.characters), result.isFinal)
                }
            } catch {
                if !Task.isCancelled { self?.onStatus?("Transcription stopped: \(error.localizedDescription)") }
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: input)
        onStatus?("On-device English transcription ready")
    }

    func append(_ pcm: Data) throws {
        guard let targetFormat, let continuation, pcm.count >= 2 else { return }
        let count = AVAudioFrameCount(pcm.count / 2)
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: count),
              let samples = input.int16ChannelData?[0] else {
            throw DemoError("Could not allocate an audio buffer.")
        }
        input.frameLength = count
        pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: Int(count) * 2))
        let output: AVAudioPCMBuffer
        if let converter {
            let capacity = AVAudioFrameCount(ceil(Double(count) * targetFormat.sampleRate / 16_000) + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw DemoError("Could not allocate a resampling buffer.")
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if let error { throw error }
            guard status != .error else { throw DemoError("Audio conversion failed.") }
            output = converted
        } else { output = input }
        guard output.frameLength > 0 else { return }
        let timestamp = CMTime(value: sampleOffset, timescale: CMTimeScale(targetFormat.sampleRate))
        sampleOffset += Int64(output.frameLength)
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: timestamp)) {
            throw DemoError("Transcription fell behind the audio stream. Recording continues; restart transcription after stopping.")
        }
    }

    func finish() async {
        continuation?.finish()
        continuation = nil
        guard let analyzer else { return }
        // Bound finalization so a stalled system service cannot trap the Stop UI.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            await analyzer.cancelAndFinishNow()
        }
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { onStatus?("Finalization: \(error.localizedDescription)") }
        timeout.cancel()
        await resultTask?.value
        resultTask = nil
        self.analyzer = nil
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
        resultTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        resultTask = nil
        analyzer = nil
    }
}
