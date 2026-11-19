import Foundation

/// Offline fallback when Apple Intelligence is unavailable: four common
/// information gaps from the Copilot plan, matched by keywords, then a short
/// list of standing questions so a fixed-cadence round still has a hint.
public final class RuleBasedHintEngine: HintEngine {
    public let name = "Rules"

    struct Rule {
        let id: String
        let question: String
        let reason: String
        let triggers: [String]
        let covered: [String]
        let priority: Int
    }

    static let rules: [Rule] = [
        Rule(id: "deadline",
             question: "What is the deadline, and what makes it time-sensitive?",
             reason: "Urgency was mentioned without a date.",
             triggers: ["soon", "asap", "urgent", "quickly", "deadline", "timeline", "as fast as"],
             covered: ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                       "tomorrow", "next week", "next month", "end of", "january", "february", "march",
                       "april", "may ", "june", "july", "august", "september", "october", "november",
                       "december", "q1", "q2", "q3", "q4", "by the"],
             priority: 4),
        Rule(id: "budget",
             question: "Does that budget include implementation and ongoing support?",
             reason: "A budget was given without its scope.",
             triggers: ["budget", "cost", "price", "$", "dollars", "spend"],
             covered: ["include", "covers", "covered", "support", "maintenance", "excluding", "scope"],
             priority: 3),
        Rule(id: "success",
             question: "What would a successful outcome look like for you?",
             reason: "A plan was discussed without success criteria.",
             triggers: ["proposal", "solution", "approach", "we want to", "the plan", "our goal", "we need to"],
             covered: ["success", "successful", "metric", "measure", "kpi", "outcome", "target"],
             priority: 3),
        Rule(id: "owner",
             question: "Who owns the next step, and by when?",
             reason: "A decision or next step has no owner.",
             triggers: ["decided", "agreed", "let's", "next step", "we will", "we'll", "going to"],
             covered: ["owner", "responsible", "i'll", "i will", "assigned", "will own", "will take"],
             priority: 4),
    ]

    public init() {}

    /// General questions that fit most work conversations, used in order when
    /// no keyword gap is found. Each is asked at most once per session.
    static let standing: [(question: String, reason: String)] = [
        ("What is the most important outcome you want from this?", "Clarifies the goal."),
        ("What is the next step, and who owns it?", "Turns talk into action."),
        ("Is there a deadline we should plan around?", "Checks timing."),
        ("What is the biggest risk you see right now?", "Surfaces risks early."),
        ("What would make this a clear success for you?", "Sets success criteria."),
        ("Is anything still unclear or undecided?", "Catches open questions."),
        ("Who else needs to be involved in this decision?", "Checks stakeholders."),
        ("What constraints should we keep in mind?", "Checks limits and scope."),
    ]

    public func suggest(_ context: HintContext) async throws -> HintCandidate? {
        Self.hint(for: context)
    }

    /// A keyword gap if there is one, otherwise the next unasked standing question.
    public static func hint(for context: HintContext) -> HintCandidate? {
        firstGap(in: context) ?? standingQuestion(in: context)
    }

    public static func standingQuestion(in context: HintContext) -> HintCandidate? {
        for item in standing where !context.previousQuestions.contains(where: {
            TextSimilarity.similarity($0, item.question) >= 0.55
        }) {
            return HintCandidate(question: item.question, reason: item.reason, priority: 2,
                                 source: "Rules")
        }
        return nil
    }

    public static func firstGap(in context: HintContext) -> HintCandidate? {
        let recent = " " + context.recentTranscript.lowercased() + " "
        let everything = recent + " " + context.summary.rendered().lowercased()
        for rule in rules {
            guard let trigger = rule.triggers.first(where: { recent.contains($0) }) else { continue }
            guard !rule.covered.contains(where: { everything.contains($0) }) else { continue }
            guard !context.previousQuestions.contains(where: {
                TextSimilarity.similarity($0, rule.question) >= 0.55
            }) else { continue }
            return HintCandidate(question: rule.question, reason: rule.reason,
                                 evidence: "mentioned “\(trigger.trimmingCharacters(in: .whitespaces))”",
                                 priority: rule.priority, source: "Rules")
        }
        return nil
    }
}
