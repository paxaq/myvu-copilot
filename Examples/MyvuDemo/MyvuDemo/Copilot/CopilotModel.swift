import Foundation
import MyvuAI
import MyvuAudio
import MyvuCore
import SwiftUI

@MainActor
final class CopilotModel: ObservableObject {
    enum Phase { case idle, preparing, armed, recording, stopping }
    /// Which glasses feature delivers the audio. Transcribe is the firmware's
    /// long-form recorder and the candidate for silence-tolerant sessions; the
    /// assistant path is kept for comparison (it stops after ~30 s).
    enum Channel: String, CaseIterable, Identifiable {
        case transcribe, assistant
        var id: String { rawValue }
        var title: String { self == .transcribe ? "Glasses Transcribe app" : "Voice assistant (code 110)" }
    }
    /// Where recognized text is echoed on the glasses. The Transcribe scene's
    /// own subtitle format is not recovered, so both candidates are offered;
    /// the lens card always works but competes with hint cards.
    enum SubtitleMode: String, CaseIterable, Identifiable {
        case off, transcribeView, lensCard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .transcribeView: return "Transcribe view (streaming)"
            case .lensCard: return "Lens card"
            }
        }
    }
    private enum ActiveCapture {
        case assistant(GlassesMicCapture)
        case transcribe(TranscribeChannelCapture)
    }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "Ready for a microphone test"
    @Published private(set) var speechStatus = "English model not checked"
    @Published private(set) var update: GlassesMicCapture.Update?
    @Published private(set) var transcribeUpdate: TranscribeChannelCapture.Update?
    @Published private(set) var activeChannel: Channel?
    @Published var channel = Channel.transcribe
    @Published var openTranscribeFromPhone = true
    @Published private(set) var transcript = ""
    @Published private(set) var partial = ""
    @Published private(set) var recordingURL: URL?
    @Published private(set) var reportURL: URL?
    @Published private(set) var cardStatus = ""
    @Published private(set) var isPreparingModel = false
    @Published var transcribeLocally = true
    @Published var saveRecording = false
    @Published var subtitleMode = SubtitleMode.transcribeView
    let assistant = CopilotAssistant()
    private let client: MyvuClient
    private var capture: ActiveCapture?
    private var transcriber: (any LocalTranscribing)?
    private var startTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var cardTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var generation = UUID()
    private var startedAt = Date()
    private var speechResultCount = 0
    private var speechFinalResultCount = 0
    private var testCardOutstanding = false
    private static let cardID = 7_010_008
    private static let subtitleCardID = 7_010_010
    private var tickTask: Task<Void, Never>?
    private var lastPartialSentAt = Date.distantPast
    private var subtitleCardShown = false
    private var activeSubtitleMode = SubtitleMode.off

    var isBusy: Bool { phase != .idle || isPreparingModel }
    var isCapturing: Bool { phase == .armed || phase == .recording }

    init(client: MyvuClient) { self.client = client }

    func prepareModel() {
        guard !isBusy else { return }
        isPreparingModel = true
        modelTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparingModel = false; self.modelTask = nil }
            do {
                if #available(iOS 26.0, *) {
                    _ = try await AppleSpeechTranscriber.prepareEnglish { self.speechStatus = $0 }
                } else { self.speechStatus = "On-device transcription requires iOS 26 or later." }
            } catch { self.speechStatus = error.localizedDescription }
        }
    }

    func cancelModelPreparation() { modelTask?.cancel() }

    func start(preferences: AiProtocol.AssistantPreferences) {
        guard !isBusy else { return }
        phase = .preparing
        status = "Preparing capture"
        transcript = ""
        partial = ""
        update = nil
        transcribeUpdate = nil
        recordingURL = nil
        reportURL = nil
        cardStatus = ""
        speechResultCount = 0
        speechFinalResultCount = 0
        let token = UUID()
        generation = token
        startedAt = Date()
        let shouldTranscribe = transcribeLocally
        let shouldSave = saveRecording
        let selectedChannel = channel
        let openScene = openTranscribeFromPhone
        lastPartialSentAt = .distantPast
        activeSubtitleMode = shouldTranscribe ? subtitleMode : .off
        activeChannel = selectedChannel
        startTask = Task { [weak self] in
            guard let self else { return }
            var speech: (any LocalTranscribing)?
            do {
                if shouldTranscribe {
                    if #available(iOS 26.0, *) { speech = AppleSpeechTranscriber() }
                    else { throw DemoError("Turn off local transcription, or use iOS 26 or later.") }
                    self.transcriber = speech
                    speech?.onStatus = { [weak self] text in
                        guard self?.generation == token else { return }
                        self?.speechStatus = text
                    }
                    speech?.onText = { [weak self] text, final in
                        guard let self, self.generation == token else { return }
                        self.speechResultCount += 1
                        if final {
                            self.speechFinalResultCount += 1
                            self.transcript += (self.transcript.isEmpty ? "" : " ") + text
                            self.partial = ""
                            self.assistant.addFinal(text)
                        } else {
                            self.partial = text
                            self.assistant.heardSpeech()
                        }
                        self.forwardSubtitle(text, final: final)
                    }
                    try await speech?.start()
                } else { self.speechStatus = "Transcription off — audio diagnostics only" }
                try Task.checkCancellation()
                guard self.generation == token else { await speech?.cancel(); return }
                let (audio, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(128))
                let onPCM: (Data) -> Void = { [weak self] pcm in
                    if case .dropped = continuation.yield(pcm) {
                        Task { @MainActor [weak self] in
                            guard self?.generation == token else { return }
                            self?.speechStatus = "Audio processing fell behind; stop and restart the test."
                            self?.stop()
                        }
                    }
                }
                let onFinish: (URL?, String?) -> Void = { [weak self] url, reason in
                    continuation.finish()
                    Task { @MainActor [weak self] in
                        await self?.finished(url: url, reason: reason, token: token)
                    }
                }
                self.audioTask = Task { [weak self] in
                    for await pcm in audio {
                        guard let self, self.generation == token else { break }
                        do { try self.transcriber?.append(pcm) }
                        catch {
                            self.speechStatus = error.localizedDescription
                            await self.transcriber?.cancel()
                            self.transcriber = nil
                        }
                    }
                }
                let directory = try self.diagnosticsDirectory()
                let url = shouldSave ? directory.appendingPathComponent("\(token.uuidString).wav") : nil
                switch selectedChannel {
                case .assistant:
                    let session = try GlassesMicCapture(client: self.client, restorePreferences: preferences)
                    session.onPCM = onPCM
                    session.onFinish = onFinish
                    session.onUpdate = { [weak self] value in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            self.update = value
                            self.status = value.status
                            if self.phase != .stopping {
                                self.phase = value.stats.frames > 0 ? .recording : .armed
                            }
                        }
                    }
                    self.capture = .assistant(session)
                    try session.start(recordingTo: url)
                    self.status = "Microphone requested — waiting for glasses audio"
                case .transcribe:
                    let session = try TranscribeChannelCapture(client: self.client)
                    session.onPCM = onPCM
                    session.onFinish = onFinish
                    session.onUpdate = { [weak self] value in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            self.transcribeUpdate = value
                            self.status = value.status
                            if self.phase != .stopping {
                                self.phase = value.proximal.frames + value.remote.frames > 0 ? .recording : .armed
                            }
                        }
                    }
                    self.capture = .transcribe(session)
                    // Raw payloads are kept only with the WAV opt-in, for decoding
                    // a still-unknown packing offline.
                    let raw = shouldSave ? directory.appendingPathComponent("\(token.uuidString).transcribe.bin") : nil
                    try session.start(openScene: openScene, recordingTo: url, rawPayloadsTo: raw)
                    self.status = openScene ? "Asked the glasses to open Transcribe"
                        : "Open Transcribe on the glasses to begin"
                }
                self.phase = .armed
                self.startTask = nil
                self.beginCopilot(token: token)
            } catch {
                await speech?.cancel()
                guard self.generation == token else { return }
                self.audioTask?.cancel()
                self.audioTask = nil
                self.capture = nil
                self.transcriber = nil
                self.phase = .idle
                self.status = error is CancellationError ? "Preparation cancelled" : error.localizedDescription
                self.startTask = nil
            }
        }
    }

    func stop() {
        guard phase != .idle, phase != .stopping else { return }
        cardTask?.cancel()
        clearTestCard()
        endCopilot()
        if phase == .preparing {
            startTask?.cancel()
            status = "Cancelling preparation"
            return
        }
        phase = .stopping
        status = "Stopping capture and finalizing transcription"
        switch capture {
        case .assistant(let session): session.stop()
        case .transcribe(let session): session.stop()
        case nil: break
        }
    }

    func requestMicrophone() {
        guard isCapturing, case .assistant(let session) = capture else { return }
        session.requestMicrophone()
    }

    func openTranscribeOnGlasses() {
        guard isCapturing, case .transcribe(let session) = capture else { return }
        session.openScene()
    }

    func sendTranscribeStart() {
        guard isCapturing, case .transcribe(let session) = capture else { return }
        session.sendStart()
    }

    // MARK: - Copilot hints and subtitles

    private func beginCopilot(token: UUID) {
        assistant.begin(at: startedAt, send: { [weak self] json in
            self?.client.sendAction(json)
        }, onDisplay: { [weak self] showing in
            self?.recordDisplayRequest(showing: showing)
        })
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == token, self.isCapturing else { continue }
                self.assistant.tick(secondsSinceAudio: self.secondsSinceAudio)
            }
        }
    }

    private func endCopilot() {
        tickTask?.cancel()
        tickTask = nil
        assistant.end()
        if subtitleCardShown {
            subtitleCardShown = false
            client.sendAction(LensCards.buildDismiss(numericId: Self.subtitleCardID))
        }
    }

    private var secondsSinceAudio: TimeInterval? {
        switch activeChannel {
        case .transcribe: return transcribeUpdate?.secondsSinceAudio
        case .assistant: return update?.secondsSinceAudio
        case nil: return nil
        }
    }

    /// Partials at most ~3 per second; every final is sent.
    private func forwardSubtitle(_ text: String, final: Bool) {
        let mode = activeSubtitleMode
        guard mode != .off, !text.isEmpty, isCapturing else { return }
        let now = Date()
        if !final {
            guard now.timeIntervalSince(lastPartialSentAt) >= 0.35 else { return }
            lastPartialSentAt = now
        }
        switch mode {
        case .transcribeView:
            guard case .transcribe(let session) = capture else { break }
            session.sendSubtitle(text, committed: final)
        case .lensCard:
            subtitleCardShown = true
            let tail = text.count > 90 ? "…" + String(text.suffix(90)) : text
            client.sendAction(LensCards.buildShow(title: "Transcript", body: tail, numericId: Self.subtitleCardID))
        case .off:
            break
        }
    }

    private func recordDisplayRequest(showing: Bool) {
        switch capture {
        case .assistant(let session): session.recordDisplayRequest(showing: showing)
        case .transcribe(let session): session.recordDisplayRequest(showing: showing)
        case nil: break
        }
    }

    private func finished(url: URL?, reason: String?, token: UUID) async {
        guard generation == token else { return }
        phase = .stopping
        cardTask?.cancel()
        clearTestCard()
        endCopilot()
        await audioTask?.value
        audioTask = nil
        await transcriber?.finish()
        transcriber = nil
        capture = nil
        recordingURL = url
        partial = ""
        phase = .idle
        status = reason ?? "Capture stopped"
        do {
            let directory = try diagnosticsDirectory()
            let input = activeChannel == .transcribe
                ? "XGA010C glasses Transcribe app (msgCmd 3/4)" : "XGA010C glasses microphone (code 109)"
            let report = Report(startedAt: startedAt, finishedAt: Date(), input: input,
                savedAudio: url != nil, localTranscription: transcribeLocally,
                result: reason ?? "Stopped by user", update: update, transcribeUpdate: transcribeUpdate,
                speechResultCount: speechResultCount, speechFinalResultCount: speechFinalResultCount,
                subtitleMode: activeSubtitleMode.rawValue, hintsShown: assistant.hints.count,
                hintEngine: assistant.engineStatus, hintChecks: assistant.checkHistory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let reportURL = directory.appendingPathComponent("\(token.uuidString).json")
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            self.reportURL = reportURL
        } catch { status += " Report could not be saved: \(error.localizedDescription)" }
    }

    func showTestCard() {
        guard isCapturing else { return }
        cardTask?.cancel()
        recordDisplayRequest(showing: true)
        testCardOutstanding = true
        client.sendAction(LensCards.buildShow(title: "Copilot · Display test",
            body: "What is the deadline, and who owns the next step?", numericId: Self.cardID))
        cardStatus = "Test card sent. Check that audio keeps arriving."
        cardTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self else { return }
            self.clearTestCard()
            self.cardStatus = "Test card cleared."
        }
    }

    private func clearTestCard() {
        guard testCardOutstanding else { return }
        testCardOutstanding = false
        recordDisplayRequest(showing: false)
        client.sendAction(LensCards.buildDismiss(numericId: Self.cardID))
    }

    private func diagnosticsDirectory() throws -> URL {
        var directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CopilotDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try directory.setResourceValues(resource)
        return directory
    }

    private struct Report: Encodable {
        let startedAt: Date
        let finishedAt: Date
        let input: String
        let savedAudio: Bool
        let localTranscription: Bool
        let result: String
        let update: GlassesMicCapture.Update?
        let transcribeUpdate: TranscribeChannelCapture.Update?
        let speechResultCount: Int
        let speechFinalResultCount: Int
        /// Settings and counts only; subtitle and hint text are never saved.
        let subtitleMode: String
        let hintsShown: Int
        let hintEngine: String
        /// Check outcomes with session time; no transcript or hint text.
        let hintChecks: [String]
    }
}
