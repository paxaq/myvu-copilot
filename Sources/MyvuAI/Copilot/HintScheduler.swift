import Foundation

/// A follow-up question proposed by an engine, before scheduling rules.
public struct HintCandidate: Sendable, Equatable {
    public var question: String
    public var reason: String
    public var evidence: String
    /// 1 (nice to know) … 5 (critical gap).
    public var priority: Int
    public var source: String

    public init(question: String, reason: String, evidence: String = "", priority: Int = 3,
                source: String) {
        self.question = question
        self.reason = reason
        self.evidence = evidence
        self.priority = priority
        self.source = source
    }
}

public struct ShownHint: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let candidate: HintCandidate
    public let shownAt: TimeInterval
}

public struct HintSchedulerConfig: Sendable, Equatable {
    /// Fixed cadence: one hint round every this many seconds of session time.
    public var checkInterval: TimeInterval = 30
    public var firstCheckAfter: TimeInterval = 30
    /// Two cards never appear closer than this (a slow round can show late).
    public var minimumGap: TimeInterval = 20
    public var displayDuration: TimeInterval = 10
    /// Prefer a natural pause in speech before showing…
    public var pauseBeforeShowing: TimeInterval = 1.5
    /// …but never hold a ready hint longer than this, to keep the rhythm.
    public var maximumPauseWait: TimeInterval = 4
    /// A pending hint older than this belongs to the previous round.
    public var pendingLifetime: TimeInterval = 25
    /// New transcript words needed since the previous round; a silent round
    /// shows nothing rather than repeating itself.
    public var minimumNewWords = 3
    /// Hints are not shown when audio has been missing this long.
    public var staleAudioLimit: TimeInterval = 8
    public var minimumWords = 4
    public var maximumWords = 18
    public var minimumPriority = 1
    public var duplicateSimilarity = 0.55

    public init() {}
}

public enum HintRejection: String, Sendable, Equatable {
    case empty, tooShort, tooLong, lowPriority, duplicate, audioStale, notAQuestion
}

/// What `round` decided for this tick.
public enum HintRound: Sendable, Equatable {
    case notDue
    /// Ask an engine now.
    case check
    /// The round's time came but there is nothing to hint about.
    case skipped(HintRoundSkip)
}

public enum HintRoundSkip: String, Sendable, Equatable {
    case noAudio = "no audio from the glasses"
    case noNewSpeech = "no new speech"
}

/// Pure scheduling: when to ask an engine, which answers to keep, when a kept
/// one may appear. No timers, no I/O; the caller passes the clock.
public struct HintScheduler: Sendable {
    public var config: HintSchedulerConfig
    public private(set) var shown: [ShownHint] = []
    public private(set) var pending: (candidate: HintCandidate, at: TimeInterval)?
    public private(set) var lastCheckAt: TimeInterval?
    private var wordsAtLastCheck = 0

    public init(config: HintSchedulerConfig = HintSchedulerConfig()) { self.config = config }

    /// One fixed-cadence round. When a round is due its slot is used up
    /// whatever happens, so the next one comes `checkInterval` later.
    public mutating func round(now: TimeInterval, totalWords: Int,
                               secondsSinceAudio: TimeInterval?) -> HintRound {
        let due = lastCheckAt.map { now - $0 >= config.checkInterval } ?? (now >= config.firstCheckAfter)
        guard due else { return .notDue }
        // Stay on the grid: the slot that just came due, not this tick.
        if let last = lastCheckAt, now - last < config.checkInterval * 2 {
            lastCheckAt = last + config.checkInterval
        } else {
            lastCheckAt = now
        }
        pending = nil
        guard let age = secondsSinceAudio, age <= config.staleAudioLimit else { return .skipped(.noAudio) }
        guard totalWords - wordsAtLastCheck >= config.minimumNewWords else { return .skipped(.noNewSpeech) }
        wordsAtLastCheck = totalWords
        return .check
    }

    /// Cleans and validates a candidate; on success it becomes pending.
    @discardableResult
    public mutating func offer(_ candidate: HintCandidate, now: TimeInterval,
                               secondsSinceAudio: TimeInterval?) -> HintRejection? {
        var cleaned = candidate
        cleaned.question = Self.clean(candidate.question)
        let words = TextSimilarity.words(cleaned.question).count
        if cleaned.question.isEmpty { return .empty }
        if !cleaned.question.hasSuffix("?") { return .notAQuestion }
        if words < config.minimumWords { return .tooShort }
        if words > config.maximumWords { return .tooLong }
        if cleaned.priority < config.minimumPriority { return .lowPriority }
        if shown.contains(where: {
            TextSimilarity.similarity($0.candidate.question, cleaned.question) >= config.duplicateSimilarity
        }) { return .duplicate }
        guard let age = secondsSinceAudio, age <= config.staleAudioLimit else { return .audioStale }
        pending = (cleaned, now)
        return nil
    }

    /// The pending hint, if it may be shown now. Expired ones are dropped.
    public mutating func takeReady(now: TimeInterval, lastSpeechAt: TimeInterval?,
                                   secondsSinceAudio: TimeInterval?) -> HintCandidate? {
        guard let pending else { return nil }
        if now - pending.at > config.pendingLifetime {
            self.pending = nil
            return nil
        }
        guard let age = secondsSinceAudio, age <= config.staleAudioLimit else { return nil }
        if let last = shown.last, now - last.shownAt < config.minimumGap { return nil }
        let paused = lastSpeechAt.map { now - $0 >= config.pauseBeforeShowing } ?? true
        // Talk without pauses must not break the rhythm.
        let waitedLongEnough = now - pending.at >= config.maximumPauseWait
        guard paused || waitedLongEnough else { return nil }
        self.pending = nil
        shown.append(ShownHint(id: UUID(), candidate: pending.candidate, shownAt: now))
        return pending.candidate
    }

    public mutating func discardPending() { pending = nil }

    static func clean(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }
}

/// What an engine sees. The transcript is conversation content: engines must
/// treat it as data, never as instructions.
public struct HintContext: Sendable, Equatable {
    public var goal: String
    public var summary: MemorySummary
    public var recentTranscript: String
    public var previousQuestions: [String]

    public init(goal: String, summary: MemorySummary, recentTranscript: String,
                previousQuestions: [String]) {
        self.goal = goal
        self.summary = summary
        self.recentTranscript = recentTranscript
        self.previousQuestions = previousQuestions
    }
}

public protocol HintEngine: AnyObject {
    var name: String { get }
    func suggest(_ context: HintContext) async throws -> HintCandidate?
}

public protocol MemorySummarizer: AnyObject {
    func summarize(_ segments: [TranscriptSegment], previous: MemorySummary, goal: String) async throws -> MemorySummary
}
