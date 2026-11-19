import Foundation
import MyvuAI
import MyvuCore
import SwiftUI

/// The Copilot proper: conversation memory, gap analysis and silent hint
/// cards. Capture and transcription feed it; it never touches audio and never
/// speaks. Prefers on-device Apple Intelligence and falls back to rules.
@MainActor
final class CopilotAssistant: ObservableObject {
    enum EngineChoice: String, CaseIterable, Identifiable {
        case appleIntelligence, rules
        var id: String { rawValue }
        var title: String { self == .appleIntelligence ? "Apple Intelligence" : "Keyword rules" }
    }

    struct HintRecord: Identifiable {
        let id: UUID
        let question: String
        let reason: String
        let evidence: String
        let source: String
        let elapsed: TimeInterval
    }

    // Settings (edited before a session).
    @Published var goal = ""
    @Published var hintsEnabled = true
    @Published var engineChoice = EngineChoice.appleIntelligence
    /// Fixed cadence the user asked for: one hint round every 30 seconds.
    static let hintInterval: TimeInterval = 30

    // Live state.
    @Published private(set) var hints: [HintRecord] = []
    @Published private(set) var summary = MemorySummary()
    @Published private(set) var engineStatus = ""
    @Published private(set) var lastCheck = "No check yet" {
        didSet { checkHistory = Array((checkHistory + [lastCheck]).suffix(40)) }
    }
    /// Outcomes for the diagnostics report: status lines only, never transcript
    /// text or hint wording.
    private(set) var checkHistory: [String] = []
    @Published private(set) var isThinking = false

    static let hintCardID = 7_010_009
    private var memory = ConversationMemory()
    private var scheduler = HintScheduler()
    private var engine: HintEngine?
    private var summarizer: MemorySummarizer?
    private var fallback = RuleBasedHintEngine()
    private var sessionStart = Date()
    private var lastSpeechAt: TimeInterval?
    private var checkTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var cardShowing = false
    private var active = false
    private var send: ((String) -> Void)?
    private var onDisplay: ((Bool) -> Void)?

    init() { engineStatus = Self.describeAvailability() }

    static func describeAvailability() -> String {
        if #available(iOS 26.0, *) { return AppleIntelligenceCopilot.availabilityText }
        return "Apple Intelligence requires iOS 26 or later — keyword rules will be used"
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(sessionStart) }

    /// - Parameters:
    ///   - send: delivers a lens-card action JSON to the glasses.
    ///   - onDisplay: diagnostics hook, true for show and false for dismiss.
    func begin(at start: Date, send: @escaping (String) -> Void, onDisplay: @escaping (Bool) -> Void) {
        end()
        sessionStart = start
        memory = ConversationMemory(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines))
        scheduler = HintScheduler()
        hints = []
        checkHistory = []
        summary = MemorySummary()
        lastSpeechAt = nil
        lastCheck = hintsEnabled ? "Listening — a hint every \(Int(Self.hintInterval))s while people talk"
            : "Hints are off"
        self.send = send
        self.onDisplay = onDisplay
        engine = nil
        summarizer = nil
        if engineChoice == .appleIntelligence, #available(iOS 26.0, *), AppleIntelligenceCopilot.isAvailable {
            let apple = AppleIntelligenceCopilot()
            engine = apple
            summarizer = apple
        } else {
            engine = fallback
        }
        engineStatus = engine === fallback
            ? (engineChoice == .rules ? "Keyword rules (offline)" : Self.describeAvailability() + " — using keyword rules")
            : (Self.describeAvailability())
        active = true
    }

    func end() {
        active = false
        checkTask?.cancel()
        summaryTask?.cancel()
        dismissTask?.cancel()
        checkTask = nil
        summaryTask = nil
        isThinking = false
        dismissCard()
        send = nil
        onDisplay = nil
    }

    /// Any recognized speech, partial or final, marks "someone is talking".
    func heardSpeech() {
        guard active else { return }
        lastSpeechAt = elapsed
    }

    func addFinal(_ text: String) {
        guard active else { return }
        let now = elapsed
        lastSpeechAt = now
        memory.add(text, at: now)
    }

    /// Call about once a second while capturing.
    func tick(secondsSinceAudio: TimeInterval?) {
        guard active, hintsEnabled else { return }
        let now = elapsed
        foldSummaryIfNeeded(now: now)
        if checkTask == nil {
            switch scheduler.round(now: now, totalWords: memory.totalWords, secondsSinceAudio: secondsSinceAudio) {
            case .notDue: break
            case .check: check(now: now)
            case .skipped(let why): lastCheck = "\(Self.clock(now)) No hint this round (\(why.rawValue))"
            }
        }
        if let ready = scheduler.takeReady(now: now, lastSpeechAt: lastSpeechAt,
                                           secondsSinceAudio: secondsSinceAudio) {
            present(ready, at: now)
        }
    }

    private func check(now: TimeInterval) {
        let context = HintContext(goal: memory.goal, summary: memory.summary,
                                  recentTranscript: memory.recentText(now: now),
                                  previousQuestions: scheduler.shown.map(\.candidate.question))
        guard let engine else { return }
        isThinking = true
        lastCheck = "Checking the conversation…"
        checkTask = Task { [weak self] in
            let result: Result<HintCandidate?, Error>
            do { result = .success(try await engine.suggest(context)) }
            catch { result = .failure(error) }
            guard let self, self.active, !Task.isCancelled else { return }
            self.isThinking = false
            self.checkTask = nil
            let stamp = Self.clock(now)
            // Fixed cadence: if the engine has nothing usable, the rules
            // (keyword gaps, then standing questions) still fill the round.
            let note: String
            switch result {
            case .failure(let error):
                note = "\(engine.name) failed: \(error.localizedDescription)"
            case .success(nil):
                note = "\(engine.name) had nothing"
            case .success(let candidate?):
                guard let rejection = self.offer(candidate) else {
                    self.lastCheck = "\(stamp) Hint ready — waiting for a pause"
                    return
                }
                note = "\(engine.name) suggestion skipped (\(rejection.rawValue))"
            }
            if engine !== self.fallback, let backup = RuleBasedHintEngine.hint(for: context),
               self.offer(backup) == nil {
                self.lastCheck = "\(stamp) \(note); rules hint ready"
            } else {
                self.lastCheck = "\(stamp) \(note); no hint this round"
            }
        }
    }

    /// Audio health is re-read at show time; offer with a fresh reading.
    private func offer(_ candidate: HintCandidate) -> HintRejection? {
        scheduler.offer(candidate, now: elapsed, secondsSinceAudio: 0)
    }

    private func present(_ hint: HintCandidate, at now: TimeInterval) {
        hints.insert(HintRecord(id: UUID(), question: hint.question, reason: hint.reason,
                                evidence: hint.evidence, source: hint.source, elapsed: now), at: 0)
        lastCheck = "\(Self.clock(now)) Hint shown on the glasses"
        dismissTask?.cancel()
        cardShowing = true
        onDisplay?(true)
        // Same id every time: a new hint replaces the old card, never stacks.
        send?(LensCards.buildShow(title: "Copilot", body: hint.question, numericId: Self.hintCardID))
        let duration = scheduler.config.displayDuration
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.dismissCard()
        }
    }

    private func dismissCard() {
        guard cardShowing else { return }
        cardShowing = false
        onDisplay?(false)
        send?(LensCards.buildDismiss(numericId: Self.hintCardID))
    }

    private func foldSummaryIfNeeded(now: TimeInterval) {
        guard summaryTask == nil else { return }
        let pending = memory.pendingForSummary(now: now)
        guard !pending.isEmpty else { return }
        guard let summarizer else {
            memory.dropUnsummarized(now: now)
            return
        }
        let segments = Array(pending)
        let through = pending.endIndex
        let previous = memory.summary
        let goal = memory.goal
        summaryTask = Task { [weak self] in
            let notes = try? await summarizer.summarize(segments, previous: previous, goal: goal)
            guard let self, self.active else { return }
            self.summaryTask = nil
            if let notes {
                self.memory.fold(notes, through: through)
                self.summary = self.memory.summary
            } else {
                // Keep the session going; older verbatim text just drops out.
                self.memory.dropUnsummarized(now: self.elapsed)
            }
        }
    }

    static func clock(_ value: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
