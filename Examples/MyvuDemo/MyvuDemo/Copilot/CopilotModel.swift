import Foundation
import MyvuAI
import MyvuAudio
import MyvuCore
import SwiftUI

@MainActor
final class CopilotModel: ObservableObject {
    enum Phase { case idle, preparing, armed, recording, stopping }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "Ready for a microphone test"
    @Published private(set) var speechStatus = "English model not checked"
    @Published private(set) var update: GlassesMicCapture.Update?
    @Published private(set) var transcript = ""
    @Published private(set) var partial = ""
    @Published private(set) var recordingURL: URL?
    @Published private(set) var reportURL: URL?
    @Published private(set) var cardStatus = ""
    @Published private(set) var isPreparingModel = false
    @Published var transcribeLocally = true
    @Published var saveRecording = false
    private let client: MyvuClient
    private var capture: GlassesMicCapture?
    private var transcriber: (any LocalTranscribing)?
    private var startTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var cardTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var generation = UUID()
    private var startedAt = Date()
    private static let cardID = 7_010_008

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
        recordingURL = nil
        reportURL = nil
        cardStatus = ""
        let token = UUID()
        generation = token
        startedAt = Date()
        let shouldTranscribe = transcribeLocally
        let shouldSave = saveRecording
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
                        if final {
                            self.transcript += (self.transcript.isEmpty ? "" : " ") + text
                            self.partial = ""
                        } else { self.partial = text }
                    }
                    try await speech?.start()
                } else { self.speechStatus = "Transcription off — audio diagnostics only" }
                try Task.checkCancellation()
                guard self.generation == token else { await speech?.cancel(); return }
                let session = try GlassesMicCapture(client: self.client, restorePreferences: preferences)
                let (audio, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(128))
                session.onPCM = { [weak self] pcm in
                    if case .dropped = continuation.yield(pcm) {
                        Task { @MainActor [weak self] in
                            guard self?.generation == token else { return }
                            self?.speechStatus = "Audio processing fell behind; stop and restart the test."
                            self?.stop()
                        }
                    }
                }
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
                session.onFinish = { [weak self] url, reason in
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
                let url = shouldSave ? try self.diagnosticsDirectory()
                    .appendingPathComponent("\(token.uuidString).wav") : nil
                self.capture = session
                try session.start(recordingTo: url)
                self.phase = .armed
                self.status = "Armed — trigger the assistant on the glasses, then speak"
                self.startTask = nil
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
        client.sendAction(LensCards.buildDismiss(numericId: Self.cardID))
        if phase == .preparing {
            startTask?.cancel()
            status = "Cancelling preparation"
            return
        }
        phase = .stopping
        status = "Stopping capture and finalizing transcription"
        capture?.stop()
    }

    private func finished(url: URL?, reason: String?, token: UUID) async {
        guard generation == token else { return }
        phase = .stopping
        cardTask?.cancel()
        client.sendAction(LensCards.buildDismiss(numericId: Self.cardID))
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
            let report = Report(startedAt: startedAt, finishedAt: Date(),
                input: "XGA010C glasses microphone (code 109)",
                savedAudio: url != nil, localTranscription: transcribeLocally,
                result: reason ?? "Stopped by user", update: update)
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
        client.sendAction(LensCards.buildShow(title: "Copilot · Display test",
            body: "What is the deadline, and who owns the next step?", numericId: Self.cardID))
        cardStatus = "Test card sent. Check that audio keeps arriving."
        cardTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self else { return }
            self.client.sendAction(LensCards.buildDismiss(numericId: Self.cardID))
            self.cardStatus = "Test card cleared."
        }
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
    }
}
