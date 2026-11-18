import Foundation
import MyvuAI
import MyvuCore

/// P0 diagnostic capture, not a claim of continuous firmware support. It never
/// runs TTS, guesses keep-alive commands, ends a turn on ordinary spoken words,
/// or restarts the microphone behind the wearer's back.
public final class GlassesMicCapture: MyvuClientObserver {
    public struct Update: Sendable, Codable {
        public var stats: MicCaptureStats
        public var wallDuration: TimeInterval
        public var secondsSinceAudio: TimeInterval?
        public var triggerCount: Int
        public var launchRequests: Int
        public var status: String
        public var timeline: MicCaptureTimeline
        public var longestAudioGap: TimeInterval?
    }

    public var onUpdate: ((Update) -> Void)?
    public var onPCM: ((Data) -> Void)?
    public var onFinish: ((URL?, String?) -> Void)?
    private let client: MyvuClient
    private let queue = DispatchQueue(label: "dev.myvu.copilot.capture")
    private let processor: MicCaptureProcessor
    private var subscription: UUID?
    private var timer: DispatchSourceTimer?
    private var writer: WaveFileWriter?
    private var active = false
    private var startedAt = 0.0
    private var lastAudioAt: Double?
    private var lastTriggerAt = -Double.infinity
    private var triggerCount = 0
    private var launchRequests = 0
    private var lastLaunchAt = -Double.infinity
    private var sessionID = ""
    private var vad = VoiceActivity()
    private var vadSent = false
    private var timeline = MicCaptureTimeline()
    private var stalled = false
    private var status = "Waiting to request the glasses microphone"
    private let restorePreferences: AiProtocol.AssistantPreferences

    public init(client: MyvuClient, restorePreferences: AiProtocol.AssistantPreferences) throws {
        self.client = client
        self.restorePreferences = restorePreferences
        processor = MicCaptureProcessor(decoder: try LibOpusDecoder())
    }

    /// Call once per instance. Callback properties must be set before starting.
    /// A nil file URL means audio is decoded in memory without being saved.
    public func start(recordingTo url: URL?) throws {
        if let url { writer = try WaveFileWriter(url: url) }
        queue.sync {
            active = true
            startedAt = ProcessInfo.processInfo.systemUptime
        }
        client.addObserver(self, queue: queue)
        subscription = client.subscribeToAudioFrames(queue: queue) { [weak self] data in
            self?.receive(data)
        }
        // These are transient device settings. Restore the wearer's original
        // preferences at stop; do not overwrite persisted preferences.
        client.sendAssistantPreferences(.init(wakeWord: restorePreferences.wakeWord,
            wakeWordScreenOff: restorePreferences.wakeWordScreenOff,
            continuousDialogue: false, showWhatYouSaid: false,
            speakReplies: false, showReplyText: false))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        requestMicrophone()
    }

    /// The official phone-side launch command. Wait for the glasses' code 3/7
    /// before acknowledging its recording session; do not fake an inbound event.
    public func requestMicrophone() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastLaunchAt >= 1.5 else { return }
            self.lastLaunchAt = now
            self.launchRequests += 1
            self.mark(.microphoneRequested)
            self.status = "Microphone requested — waiting for glasses response"
            self.send(AiProtocol.launchAssistant())
        }
    }

    public func stop() { queue.async { [weak self] in self?.finish(error: nil) } }

    /// Record only the display request, never its text or a claim it appeared.
    public func recordDisplayRequest(showing: Bool) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.mark(showing ? .cardShowRequested : .cardDismissRequested)
        }
    }

    public func myvuClient(_ client: MyvuClient, didChangeState state: ConnectionState) {
        if state != .ready { finish(error: "Glasses disconnected. Recording stopped.") }
    }

    public func myvuClient(_ client: MyvuClient, didReceive event: GlassesEvent) {
        guard active, case .aiTrigger(_, let payload) = event else { return }
        if payload?.optInt("control", 1) == 0 {
            mark(.assistantReleased)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerAt > 1.5 else { return }
        lastTriggerAt = now
        triggerCount += 1
        mark(.assistantTriggered)
        sessionID = UUID().uuidString
        processor.resetDecoder()
        vad = VoiceActivity()
        vadSent = false
        status = "Listening requested — waiting for audio"
        send(AiProtocol.sessionAck(sessionId: sessionID))
    }

    private func receive(_ body: Data) {
        guard active else { return }
        let framesBefore = processor.stats.frames
        do {
            try processor.consume(body) { [self] pcm in
                if !vadSent, !sessionID.isEmpty,
                   vad.consume(energy: VoiceActivity.energy(pcm),
                               now: ProcessInfo.processInfo.systemUptime) == .speechStarted {
                    vadSent = true
                    mark(.speechDetected)
                    send(AiProtocol.vadStart(sessionId: sessionID))
                }
                try writer?.append(pcm)
                onPCM?(pcm)
            }
            if processor.stats.frames > framesBefore {
                let now = ProcessInfo.processInfo.systemUptime
                lastAudioAt = now
                timeline.receivedAudio(at: now - startedAt, frames: processor.stats.frames)
                stalled = false
            }
        } catch { finish(error: error.localizedDescription) }
    }

    private func tick() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wall = now - startedAt
        if wall >= 600 { finish(error: "The 10-minute diagnostic session ended."); return }
        let age = lastAudioAt.map { now - $0 }
        if let age, age > 3, !stalled {
            mark(.audioStalled)
            stalled = true
        }
        var text = status
        if lastAudioAt == nil, launchRequests > 0, now - lastLaunchAt >= 5 {
            text = triggerCount == 0
                ? "No response yet — hold the right power button for 1 second"
                : "Assistant responded, but no microphone audio arrived"
        }
        if let age {
            if age > 3 { text = "Audio stream stalled — no automatic restart" }
            else if processor.stats.frames > 0 { text = "Receiving glasses microphone audio" }
            else { text = "Packets arrived, but no audio decoded" }
        }
        onUpdate?(Update(stats: processor.stats, wallDuration: wall,
            secondsSinceAudio: age, triggerCount: triggerCount,
            launchRequests: launchRequests, status: text, timeline: timeline,
            longestAudioGap: timeline.longestGap(at: wall)))
    }

    private func finish(error: String?) {
        guard active else { return }
        mark(.captureStopped)
        tickFinal()
        active = false
        timer?.cancel()
        timer = nil
        if let subscription { client.unsubscribeFromAudioFrames(subscription) }
        subscription = nil
        client.removeObserver(self)
        send(AiProtocol.vrState(AiProtocol.vrClose))
        send(AiProtocol.endTurn())
        client.sendAssistantPreferences(restorePreferences)
        var reason = error
        do { try writer?.finish() } catch { reason = error.localizedDescription }
        let url = writer?.url
        writer = nil
        onFinish?(url, reason)
    }

    private func send(_ json: String) {
        client.sendAction(json, targetPkg: AiProtocol.pkg, sourcePkg: AiProtocol.pkg)
    }

    private func tickFinal() {
        let now = ProcessInfo.processInfo.systemUptime
        onUpdate?(Update(stats: processor.stats, wallDuration: now - startedAt,
            secondsSinceAudio: lastAudioAt.map { now - $0 },
            triggerCount: triggerCount, launchRequests: launchRequests, status: "Capture stopped",
            timeline: timeline, longestAudioGap: timeline.longestGap(at: now - startedAt)))
    }

    private func mark(_ kind: MicCaptureTimeline.Kind) {
        timeline.record(kind, at: ProcessInfo.processInfo.systemUptime - startedAt,
                        frames: processor.stats.frames)
    }

    deinit {
        timer?.cancel()
        if let subscription { client.unsubscribeFromAudioFrames(subscription) }
    }
}
