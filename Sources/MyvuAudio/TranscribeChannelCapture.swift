import Foundation
import MyvuAI
import MyvuCore

/// Capture through the glasses' transcription feature instead of the assistant.
///
/// The assistant path (code 110 → 109) is a short-turn voice UI that the
/// firmware releases after ~30 s. Transcribe is the firmware's long-form
/// recording feature, so it is the candidate channel for a conversation that
/// must survive silence. The handshake below is reconstructed from static
/// evidence. Build 4 showed the glasses Translation app is the one that
/// answers, and that it exits after ~6 s if the phone stays silent:
///
/// 1. Optionally launch the glasses app (`open_app` scene). The wearer can
///    also open Transcribe from the glasses menu; both end in step 2.
/// 2. The glasses ask the phone to launch `…translation.phone.TranslationService`
///    (RunAsOne type 11, acked by the SDK) and then wait on "entering" until the
///    phone service speaks. 61 alone was not enough (build 6). The one start
///    seen so far (build 5) followed: TRANS_STATE 3/4, TRANS_START (61), then a
///    SECOND `open_app` carrying the init info, answered 0.08 s later by
///    TRANS_CLICK_START (1). That sequence is replayed once the service is
///    requested, and retried up to three times while the glasses stay silent.
/// 3. On TRANS_CLICK_START (1) or GLASS_SERVER_START_COMPLETE (11), report the
///    phone state machine as TRANS_STATE PREPARING then RUNNING (52), as the
///    official `handleStartTrans` path does once its recognizer is up. Every
///    such request is answered; build 5 lost one to a retry throttle.
/// 4. Decode TRANS_REMOTE_AUDIO (4), the stream the official app feeds to its
///    noise-reduction/ASR path; TRANS_PROXIMAL_AUDIO (3) is call-translation
///    only there, but is decoded too if it arrives.
/// 5. TRANS_EXIT (7) is acknowledged with 68 and ends the capture.
///
/// The official phone app reports mute after 2 s / 5 s / 5 min of silence and
/// may stop at 5 min. Those are phone-side choices; none is sent here.
///
/// Silence never ends the capture, and there is no automatic relaunch: a
/// stall is reported as a stall. Every control message in either direction is
/// kept in a bounded event log so the real handshake can be read back from a
/// diagnostic report; audio bytes and transcripts are never logged.
public final class TranscribeChannelCapture: MyvuClientObserver {
    public enum Stream: String, Sendable, Codable { case proximal, remote }

    public struct Event: Sendable, Codable {
        public enum Direction: String, Sendable, Codable { case sent, received, note }
        public let elapsed: TimeInterval
        public let direction: Direction
        public let msgCmd: Int?
        public let name: String
        /// Control JSON only (bounded); never audio, results or reply text.
        public let detail: String?
    }

    /// Every inbound payload during the session, grouped by routing facts.
    public struct InboundBucket: Sendable, Codable {
        public let key: String
        public var count: Int
        public var bytes: Int
        public var minSize: Int
        public var maxSize: Int
        public var firstAt: TimeInterval
        public var lastAt: TimeInterval
    }

    public struct Update: Sendable, Codable {
        public var wallDuration: TimeInterval
        public var status: String
        public var secondsSinceAudio: TimeInterval?
        public var firstAudioAt: TimeInterval?
        public var longestAudioGap: TimeInterval?
        public var proximal: TranscribeStreamStats
        public var remote: TranscribeStreamStats
        public var transcribedStream: Stream?
        public var sceneRequests: Int
        public var startRequests: Int
        public var glassesReady: Bool
        public var speechSegments: Int
        public var observedPackages: [String]
        public var events: [Event]
        public var omittedEvents: Int
        public var inbound: [InboundBucket]
        public var subtitlesSent: Int
    }

    public static let stallThreshold: TimeInterval = 3
    public static let maximumEvents = 160

    public var onUpdate: ((Update) -> Void)?
    public var onPCM: ((Data) -> Void)?
    public var onFinish: ((URL?, String?) -> Void)?

    private let client: MyvuClient
    private let options: GlassTranscribe.LaunchOptions
    private let preferredStream: Stream?
    private let maximumDuration: TimeInterval
    private let queue = DispatchQueue(label: "dev.myvu.copilot.transcribe")
    private let proximal: TranscribeAudioDecoder
    private let remote: TranscribeAudioDecoder
    private var subscription: UUID?
    private var inboundTap: UUID?
    private var inboundBuckets: [String: InboundBucket] = [:]
    private var inboundOverflow = 0
    private var subtitlesSent = 0
    private var timer: DispatchSourceTimer?
    private var writer: WaveFileWriter?
    private var rawDump: FileHandle?
    private var rawDumpURL: URL?
    private var rawDumpBytes = 0
    private var active = false
    private var startedAt = 0.0
    private var lastAudioAt: Double?
    private var firstAudioAt: Double?
    private var longestCompletedGap = 0.0
    private var stalled = false
    private var lockedStream: Stream?
    private var replyTarget = GlassTranscribe.glassPackage
    private var replySource = GlassTranscribe.phonePackage
    private var sceneRequests = 0
    private var startRequests = 0
    private var lastRunningAt = -Double.infinity
    private var announceScheduled = false
    private var serviceAttempts = 0
    public static let maximumServiceAttempts = 3
    private var lastSceneAt = -Double.infinity
    private var glassesReady = false
    private var vad = VoiceActivity()
    private var speechSegments = 0
    private var observedPackages: [String] = []
    private var events: [Event] = []
    private var omittedEvents = 0
    private var status = "Waiting for the glasses Transcribe app"

    public static let rawDumpLimit = 8 * 1024 * 1024

    public init(client: MyvuClient, options: GlassTranscribe.LaunchOptions = .init(),
                preferredStream: Stream? = nil, maximumDuration: TimeInterval = 30 * 60) throws {
        self.client = client
        self.options = options
        self.preferredStream = preferredStream
        self.maximumDuration = maximumDuration
        proximal = TranscribeAudioDecoder(decoder: try LibOpusDecoder())
        remote = TranscribeAudioDecoder(decoder: try LibOpusDecoder())
    }

    /// Call once. `recordingTo` keeps decoded PCM of the transcribed stream;
    /// `rawPayloadsTo` keeps the binary fields (both streams) when the format
    /// is still unknown. Both are opt-in diagnostics.
    public func start(openScene: Bool, recordingTo url: URL?, rawPayloadsTo rawURL: URL?) throws {
        if let url { writer = try WaveFileWriter(url: url, maximumBytes: 16_000 * 2 * Int(maximumDuration)) }
        if let rawURL {
            FileManager.default.createFile(atPath: rawURL.path, contents: Data())
            rawDump = try FileHandle(forWritingTo: rawURL)
            rawDumpURL = rawURL
        }
        queue.sync {
            active = true
            startedAt = ProcessInfo.processInfo.systemUptime
        }
        client.addObserver(self, queue: queue)
        subscription = client.subscribeToAppMessages(queue: queue, matching: { message in
            message.involves("ar.transcribe") || message.involves("ar.translation")
        }, handler: { [weak self] message in self?.receive(message) })
        inboundTap = client.subscribeToInboundSummaries(queue: queue) { [weak self] summary in
            self?.countInbound(summary)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        if openScene { self.openScene() }
        else { queue.async { self.note("Waiting for Transcribe to be opened on the glasses") } }
    }

    /// Ask the glasses to open Transcribe. iOS cannot hold the classic-BT
    /// link some glasses scenes require, so this may be ignored; opening
    /// Transcribe from the glasses menu reaches the same handshake.
    public func openScene() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastSceneAt >= 1.5 else { return }
            self.sendScene(reason: nil)
            self.status = "Asked the glasses to open Transcribe"
        }
    }

    private func sendScene(reason: String?) {
        lastSceneAt = ProcessInfo.processInfo.systemUptime
        sceneRequests += 1
        record(.sent, cmd: nil, name: "open_app \(GlassTranscribe.glassPackage)", detail: reason)
        client.sendAction(GlassTranscribe.buildOpenScene(options), targetPkg: AppLayer.pkgLauncher,
                          sourcePkg: GlassTranscribe.phonePackage)
    }

    /// Manual retry: announce the phone service with TRANS_START (61). The
    /// glasses answer with TRANS_CLICK_START, which is then reported RUNNING.
    public func sendStart() { queue.async { [weak self] in self?.announcePhone(automatic: false) } }

    public func stop() { queue.async { [weak self] in self?.finish(error: nil) } }

    /// Echo a recognized line into the glasses' own Transcribe view
    /// (TRANS_REMOTE_RESULT, 53). Only counted, never logged: it is content.
    public func sendSubtitle(_ text: String, committed: Bool) {
        queue.async { [weak self] in
            guard let self, self.active, self.glassesReady else { return }
            if self.subtitlesSent == 0 {
                self.record(.sent, cmd: GlassTranscribe.Phone2Glass.remoteResult,
                            name: "TRANS_REMOTE_RESULT (first subtitle)", detail: nil)
            }
            self.subtitlesSent += 1
            self.client.sendAction(GlassTranscribe.buildSubtitle(text, committed: committed),
                                   targetPkg: self.replyTarget, sourcePkg: self.replySource)
        }
    }

    public func recordDisplayRequest(showing: Bool) {
        queue.async { [weak self] in
            self?.note(showing ? "Lens card show requested" : "Lens card dismiss requested")
        }
    }

    public func myvuClient(_ client: MyvuClient, didChangeState state: ConnectionState) {
        if state != .ready { finish(error: "Glasses disconnected. Transcription stopped.") }
    }

    /// The glasses ask the phone to "launch" a companion app with type 11
    /// before a scene starts; the SDK router acks it. Record which app asked.
    public func myvuClient(_ client: MyvuClient, didReceiveRawInbound body: String) {
        guard active else { return }
        for candidate in InboundRouter.findJsonObjects(body) {
            guard let json = JsonReader(parsing: candidate), json.optInt("type", -1) == 11,
                  let data = json.optObject("data") else { continue }
            let appId = data.optString("appId")
            record(.received, cmd: nil, name: "launch request (type 11, acked by SDK)",
                   detail: appId.isEmpty ? nil : "appId=\(appId)")
            // The glasses now wait for the phone translation service to speak.
            if appId.contains("ar.translation.phone"), !announceScheduled {
                announceScheduled = true
                queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    self.announceScheduled = false
                    if !self.glassesReady { self.announcePhone(automatic: true) }
                }
            }
        }
    }

    // MARK: - Inbound

    private func receive(_ message: AppChannelMessage) {
        guard active else { return }
        notePackage(message.sourcePackage)
        guard let cmd = message.msgCmd else {
            if !message.binary.isEmpty {
                record(.received, cmd: nil, name: "binary without msgCmd (\(message.binary.count) B)",
                       detail: nil)
            }
            return
        }
        // Answer on the reverse of whatever pair the glasses used.
        if message.sourcePackage.contains("transcribe") || message.sourcePackage.contains("translation") {
            replyTarget = message.sourcePackage
            if !message.targetPackage.isEmpty { replySource = message.targetPackage }
        }
        switch cmd {
        case GlassTranscribe.Glass2Phone.proximalAudio:
            audio(message.binary, stream: .proximal)
        case GlassTranscribe.Glass2Phone.remoteAudio:
            audio(message.binary, stream: .remote)
        case GlassTranscribe.Glass2Phone.serverStartComplete,
             GlassTranscribe.Glass2Phone.clickStart,
             GlassTranscribe.BaseState.connect:
            record(.received, cmd: cmd, name: GlassTranscribe.Glass2Phone.name(cmd),
                   detail: Self.safeDetail(message.dataString))
            glassesReady = true
            reportRunning()
        case GlassTranscribe.Glass2Phone.exit:
            record(.received, cmd: cmd, name: GlassTranscribe.Glass2Phone.name(cmd), detail: nil)
            send(GlassTranscribe.buildExitAck(), cmd: GlassTranscribe.Phone2Glass.exitAck, name: "TRANS_EXIT_ACK")
            finish(error: "Transcribe was closed on the glasses.", notifyGlasses: false)
        case GlassTranscribe.BaseState.glassServiceExit, GlassTranscribe.BaseState.disconnect:
            record(.received, cmd: cmd, name: GlassTranscribe.Glass2Phone.name(cmd), detail: nil)
            finish(error: "The glasses Transcribe service stopped.", notifyGlasses: false)
        case GlassTranscribe.Glass2Phone.wechatReply, GlassTranscribe.Glass2Phone.wechatReplyEnd:
            record(.received, cmd: cmd, name: GlassTranscribe.Glass2Phone.name(cmd), detail: nil)
        default:
            record(.received, cmd: cmd, name: GlassTranscribe.Glass2Phone.name(cmd),
                   detail: Self.safeDetail(message.dataString)
                       ?? (message.binary.isEmpty ? nil : "\(message.binary.count) B binary"))
        }
    }

    private func audio(_ payload: Data, stream: Stream) {
        dumpRaw(payload, stream: stream)
        let decoder = stream == .proximal ? proximal : remote
        let pcm = decoder.consume(payload)
        guard !pcm.isEmpty else { return }
        // Auto: take the first decodable stream, but move to remote (the
        // official transcription input) once, if it shows up later.
        let shouldLock: Bool
        if let preferredStream { shouldLock = lockedStream == nil && stream == preferredStream }
        else { shouldLock = lockedStream == nil || (lockedStream == .proximal && stream == .remote) }
        if shouldLock {
            lockedStream = stream
            vad = VoiceActivity()
            note("Transcribing the \(stream.rawValue) stream (\(decoder.stats.format.rawValue))")
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - startedAt
        if let lastAudioAt {
            let gap = now - lastAudioAt
            longestCompletedGap = max(longestCompletedGap, gap)
            if gap > Self.stallThreshold { note(String(format: "Audio resumed after %.1fs", gap)) }
        } else {
            firstAudioAt = elapsed
            note("First audio (\(stream.rawValue))")
        }
        lastAudioAt = now
        stalled = false
        guard stream == lockedStream else { return }
        for chunk in pcm {
            switch vad.consume(energy: VoiceActivity.energy(chunk), now: now) {
            case .speechStarted:
                speechSegments += 1
                if speechSegments <= 40 { note("Speech started") }
            case .speechEnded:
                if speechSegments <= 40 { note("Speech ended") }
                vad = VoiceActivity()
            default: break
            }
            do { try writer?.append(chunk) }
            catch {
                writer = nil
                note("WAV limit reached; recording file closed, capture continues")
            }
            onPCM?(chunk)
        }
    }

    // MARK: - Outbound

    /// Replays the build 5 sequence that made the glasses send their start.
    private func announcePhone(automatic: Bool) {
        guard active else { return }
        if automatic {
            guard serviceAttempts < Self.maximumServiceAttempts else {
                note("Phone service announced \(serviceAttempts) times without a start from the glasses")
                return
            }
            serviceAttempts += 1
        }
        startRequests += 1
        status = "Phone transcription service announced — waiting for the glasses"
        send(GlassTranscribe.buildTransState(GlassTranscribe.TransState.preparing),
             cmd: GlassTranscribe.Phone2Glass.transState, name: "TRANS_STATE preparing")
        send(GlassTranscribe.buildTransState(GlassTranscribe.TransState.running),
             cmd: GlassTranscribe.Phone2Glass.transState, name: "TRANS_STATE running")
        send(GlassTranscribe.buildStart(options), cmd: GlassTranscribe.Phone2Glass.start, name: "TRANS_START")
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.active, !self.glassesReady else { return }
            self.sendScene(reason: "init info")
        }
        guard automatic else { return }
        queue.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.active, !self.glassesReady else { return }
            self.announcePhone(automatic: true)
        }
    }

    /// Answer every start request from the glasses; only exact duplicates
    /// arriving within 250 ms share one answer.
    private func reportRunning() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRunningAt >= 0.25 else { return }
        lastRunningAt = now
        status = "Transcribe is open — phone reported running"
        send(GlassTranscribe.buildTransState(GlassTranscribe.TransState.preparing),
             cmd: GlassTranscribe.Phone2Glass.transState, name: "TRANS_STATE preparing")
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.active else { return }
            self.send(GlassTranscribe.buildTransState(GlassTranscribe.TransState.running),
                      cmd: GlassTranscribe.Phone2Glass.transState, name: "TRANS_STATE running")
            // The glasses entered Transcribe on RUNNING alone but sent no audio
            // (build 7). The phone module also reports its recording state.
            self.send(GlassTranscribe.buildRecordState(GlassTranscribe.RecordState.start),
                      cmd: GlassTranscribe.Phone2Glass.recordState, name: "RECORD_STATE start")
        }
    }

    private func send(_ json: String, cmd: Int, name: String) {
        record(.sent, cmd: cmd, name: name, detail: Self.safeDetail(JsonReader(parsing: json)?.opt("data") as? String))
        client.sendAction(json, targetPkg: replyTarget, sourcePkg: replySource)
    }

    // MARK: - Timer and finish

    private func tick() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wall = now - startedAt
        if wall >= maximumDuration {
            finish(error: "The \(Int(maximumDuration / 60))-minute session limit was reached.")
            return
        }
        let age = lastAudioAt.map { now - $0 }
        if let age, age > Self.stallThreshold, !stalled {
            stalled = true
            note("Audio stalled")
        }
        var text = status
        if let age {
            text = age > Self.stallThreshold
                ? "No audio for \(Int(age))s — session kept open, no automatic restart"
                : "Receiving Transcribe audio"
        } else if proximal.stats.messages + remote.stats.messages > 0 {
            text = "Transcribe audio arrived, but the format is not decoded yet"
        } else if !glassesReady, wall > 6 {
            text = "No reply yet — open Transcribe from the glasses menu"
        }
        onUpdate?(snapshot(wall: wall, now: now, status: text))
    }

    private func snapshot(wall: TimeInterval, now: TimeInterval, status: String) -> Update {
        Update(wallDuration: wall, status: status,
               secondsSinceAudio: lastAudioAt.map { now - $0 }, firstAudioAt: firstAudioAt,
               longestAudioGap: lastAudioAt.map { max(longestCompletedGap, now - $0) },
               proximal: proximal.stats, remote: remote.stats, transcribedStream: lockedStream,
               sceneRequests: sceneRequests, startRequests: startRequests, glassesReady: glassesReady,
               speechSegments: speechSegments, observedPackages: observedPackages,
               events: events, omittedEvents: omittedEvents,
               inbound: inboundBuckets.values.sorted { $0.firstAt < $1.firstAt }
                   + (inboundOverflow > 0 ? [InboundBucket(key: "other kinds (not grouped)",
                        count: inboundOverflow, bytes: 0, minSize: 0, maxSize: 0, firstAt: 0, lastAt: 0)] : []),
               subtitlesSent: subtitlesSent)
    }

    private func finish(error: String?, notifyGlasses: Bool = true) {
        guard active else { return }
        note("Capture stopped")
        if notifyGlasses {
            send(GlassTranscribe.buildTransState(GlassTranscribe.TransState.end),
                 cmd: GlassTranscribe.Phone2Glass.transState, name: "TRANS_STATE end")
            // 68 is what actually stops the glasses view (firmware PStopMsg).
            send(GlassTranscribe.buildExitAck(), cmd: GlassTranscribe.Phone2Glass.exitAck, name: "TRANS_EXIT (stop)")
            send(GlassTranscribe.buildPhoneServerExit(), cmd: GlassTranscribe.Phone2Glass.phoneServerExit,
                 name: "PHONE_TRANS_SERVER_EXIT")
        }
        let now = ProcessInfo.processInfo.systemUptime
        onUpdate?(snapshot(wall: now - startedAt, now: now, status: "Capture stopped"))
        active = false
        timer?.cancel()
        timer = nil
        if let subscription { client.unsubscribeFromAppMessages(subscription) }
        subscription = nil
        if let inboundTap { client.unsubscribeFromInboundSummaries(inboundTap) }
        inboundTap = nil
        client.removeObserver(self)
        var reason = error
        do { try writer?.finish() } catch { reason = error.localizedDescription }
        try? rawDump?.close()
        rawDump = nil
        let url = writer?.url
        writer = nil
        onFinish?(url, reason)
    }

    // MARK: - Diagnostics

    /// Record format: 1 byte stream (3/4), 4 bytes big-endian length, payload.
    private func dumpRaw(_ payload: Data, stream: Stream) {
        guard let rawDump, rawDumpBytes + payload.count + 5 <= Self.rawDumpLimit else { return }
        var header = Data([stream == .proximal ? 3 : 4])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { header.append(contentsOf: $0) }
        rawDump.write(header + payload)
        rawDumpBytes += payload.count + 5
    }

    private func countInbound(_ summary: InboundFrameSummary) {
        guard active else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let key = summary.groupKey
        if var bucket = inboundBuckets[key] {
            bucket.count += 1
            bucket.bytes += summary.size
            bucket.minSize = min(bucket.minSize, summary.size)
            bucket.maxSize = max(bucket.maxSize, summary.size)
            bucket.lastAt = elapsed
            inboundBuckets[key] = bucket
        } else if inboundBuckets.count < 32 {
            inboundBuckets[key] = InboundBucket(key: key, count: 1, bytes: summary.size,
                minSize: summary.size, maxSize: summary.size, firstAt: elapsed, lastAt: elapsed)
        } else {
            inboundOverflow += 1
        }
    }

    private func notePackage(_ package: String) {
        guard !package.isEmpty, !observedPackages.contains(package), observedPackages.count < 8 else { return }
        observedPackages.append(package)
    }

    private func note(_ text: String) { record(.note, cmd: nil, name: text, detail: nil) }

    private func record(_ direction: Event.Direction, cmd: Int?, name: String, detail: String?) {
        if events.count == Self.maximumEvents { events.removeFirst(); omittedEvents += 1 }
        events.append(Event(elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                            direction: direction, msgCmd: cmd, name: name, detail: detail))
    }

    /// Control payloads are short JSON; cap them so a report cannot grow
    /// with content the glasses might put there.
    static func safeDetail(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    deinit {
        timer?.cancel()
        if let subscription { client.unsubscribeFromAppMessages(subscription) }
        if let inboundTap { client.unsubscribeFromInboundSummaries(inboundTap) }
        try? rawDump?.close()
    }
}
