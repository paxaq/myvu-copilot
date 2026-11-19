import Foundation

/// One finalized line of transcript. `at` is seconds since the session began.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public let text: String
    public let at: TimeInterval
    public init(text: String, at: TimeInterval) {
        self.text = text
        self.at = at
    }
}

/// The structured part of the memory: what older conversation boiled down to.
/// Items are short English statements; content is never logged.
public struct MemorySummary: Sendable, Equatable, Codable {
    public var topic = ""
    public var facts: [String] = []
    public var decisions: [String] = []
    public var openQuestions: [String] = []
    public var actionItems: [String] = []

    public static let itemCap = 12

    public init(topic: String = "", facts: [String] = [], decisions: [String] = [],
                openQuestions: [String] = [], actionItems: [String] = []) {
        self.topic = topic
        self.facts = facts
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.actionItems = actionItems
    }

    public var isEmpty: Bool {
        topic.isEmpty && facts.isEmpty && decisions.isEmpty && openQuestions.isEmpty && actionItems.isEmpty
    }

    /// Adds newer items, drops near-duplicates and keeps the newest `itemCap`
    /// per list. An open question that reappears as a fact stays until the
    /// summarizer stops reporting it; the newer summary replaces the list.
    public mutating func merge(_ newer: MemorySummary) {
        if !newer.topic.isEmpty { topic = newer.topic }
        facts = Self.merged(facts, newer.facts)
        decisions = Self.merged(decisions, newer.decisions)
        actionItems = Self.merged(actionItems, newer.actionItems)
        // Open questions are a current view, not a history.
        openQuestions = Array(Self.merged([], newer.openQuestions).suffix(Self.itemCap))
    }

    public func rendered() -> String {
        var lines: [String] = []
        if !topic.isEmpty { lines.append("Topic: \(topic)") }
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("\(title):")
            lines.append(contentsOf: items.map { "- \($0)" })
        }
        section("Facts", facts)
        section("Decisions", decisions)
        section("Open questions", openQuestions)
        section("Action items", actionItems)
        return lines.joined(separator: "\n")
    }

    static func merged(_ older: [String], _ newer: [String]) -> [String] {
        var out: [String] = []
        for item in older + newer {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let index = out.firstIndex(where: { TextSimilarity.similarity($0, trimmed) >= 0.8 }) {
                out.remove(at: index)
            }
            out.append(trimmed)
        }
        return Array(out.suffix(itemCap))
    }
}

/// Rolling conversation memory: recent verbatim text plus a summary of what
/// has scrolled out of the window. Lives only in memory for the session.
public struct ConversationMemory: Sendable {
    public var goal: String
    public private(set) var segments: [TranscriptSegment] = []
    public var summary = MemorySummary()
    /// Segments before this index are folded into `summary`.
    public private(set) var summarizedCount = 0
    public let recentWindow: TimeInterval
    public static let segmentCap = 4_000

    public init(goal: String = "", recentWindow: TimeInterval = 180) {
        self.goal = goal
        self.recentWindow = recentWindow
    }

    public var totalWords: Int { segments.reduce(0) { $0 + TextSimilarity.words($1.text).count } }
    public var lastSegmentAt: TimeInterval? { segments.last?.at }

    public mutating func add(_ text: String, at time: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(TranscriptSegment(text: trimmed, at: time))
        if segments.count > Self.segmentCap {
            let drop = segments.count - Self.segmentCap
            segments.removeFirst(drop)
            summarizedCount = max(0, summarizedCount - drop)
        }
    }

    /// Verbatim text of the recent window, newest kept when over the limit.
    public func recentText(now: TimeInterval, maxCharacters: Int = 2_400) -> String {
        let recent = segments[summarizedCount...].filter { now - $0.at <= recentWindow }
        var lines: [String] = []
        var count = 0
        for segment in recent.reversed() {
            count += segment.text.count + 1
            if count > maxCharacters, !lines.isEmpty { break }
            lines.append(segment.text)
        }
        return lines.reversed().joined(separator: "\n")
    }

    /// Unsummarized segments that have left the recent window.
    public func pendingForSummary(now: TimeInterval) -> ArraySlice<TranscriptSegment> {
        let end = segments.firstIndex { now - $0.at <= recentWindow } ?? segments.count
        guard end > summarizedCount else { return [] }
        return segments[summarizedCount ..< end]
    }

    public mutating func fold(_ newer: MemorySummary, through count: Int) {
        summary.merge(newer)
        summarizedCount = min(max(summarizedCount, count), segments.count)
    }

    /// Without a summarizer, keep the recent window from growing unbounded by
    /// marking old text as dropped (it no longer reaches any prompt).
    public mutating func dropUnsummarized(now: TimeInterval) {
        let pending = pendingForSummary(now: now)
        if !pending.isEmpty { summarizedCount = pending.endIndex }
    }
}

public enum TextSimilarity {
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was", "be",
        "it", "that", "this", "what", "who", "how", "when", "which", "do", "does", "did", "you",
        "we", "they", "i", "by", "with", "at", "as", "will", "would", "can", "could", "there",
        "so", "here", "then", "now", "just", "really", "exactly", "actually", "please", "your", "our",
    ]

    public static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "$" }.map(String.init)
    }

    static func contentWords(_ text: String) -> Set<String> {
        Set(words(text).filter { !stopWords.contains($0) })
    }

    /// Jaccard overlap of content words, 0…1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = contentWords(a)
        let right = contentWords(b)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        let union = left.union(right).count
        return union == 0 ? 0 : Double(left.intersection(right).count) / Double(union)
    }
}
