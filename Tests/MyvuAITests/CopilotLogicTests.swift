import XCTest
@testable import MyvuAI

final class CopilotLogicTests: XCTestCase {
    // MARK: Memory

    func testRecentWindowAndSummaryHandOff() {
        var memory = ConversationMemory(goal: "Scope the project", recentWindow: 180)
        memory.add("The budget is twenty thousand dollars.", at: 10)
        memory.add("  ", at: 11)
        memory.add("We need it soon.", at: 200)
        XCTAssertEqual(memory.segments.count, 2, "blank lines are not memory")
        XCTAssertEqual(memory.recentText(now: 220), "We need it soon.")
        XCTAssertEqual(memory.pendingForSummary(now: 220).map(\.text), ["The budget is twenty thousand dollars."])

        memory.fold(MemorySummary(facts: ["Budget: $20,000"]), through: 1)
        XCTAssertTrue(memory.pendingForSummary(now: 220).isEmpty)
        XCTAssertEqual(memory.summary.facts, ["Budget: $20,000"])
        // Twenty minutes later the summary still carries the early fact.
        XCTAssertTrue(memory.summary.rendered().contains("$20,000"))
    }

    func testRecentTextKeepsNewestWhenOverLimit() {
        var memory = ConversationMemory()
        for index in 0 ..< 50 { memory.add("Sentence number \(index) about the plan.", at: Double(index)) }
        let text = memory.recentText(now: 60, maxCharacters: 120)
        XCTAssertTrue(text.hasSuffix("Sentence number 49 about the plan."))
        XCTAssertFalse(text.contains("number 0 "))
        XCTAssertLessThanOrEqual(text.count, 160)
    }

    func testSummaryMergeDeduplicatesAndReplacesOpenQuestions() {
        var summary = MemorySummary(facts: ["Launch is in March"], openQuestions: ["Who owns QA?"])
        summary.merge(MemorySummary(facts: ["launch is in March", "Team of five"], openQuestions: []))
        XCTAssertEqual(summary.facts, ["launch is in March", "Team of five"])
        XCTAssertTrue(summary.openQuestions.isEmpty, "answered questions drop out with the newer view")
    }

    // MARK: Scheduler

    func testRoundsComeEveryThirtySecondsOnAFixedGrid() {
        var scheduler = HintScheduler()
        XCTAssertEqual(scheduler.round(now: 10, totalWords: 40, secondsSinceAudio: 0.1), .notDue, "too early")
        XCTAssertEqual(scheduler.round(now: 30.4, totalWords: 40, secondsSinceAudio: 0.1), .check)
        XCTAssertEqual(scheduler.round(now: 45, totalWords: 80, secondsSinceAudio: 0.1), .notDue)
        // Ticks are about a second apart; the grid does not drift with them.
        XCTAssertEqual(scheduler.round(now: 60.9, totalWords: 80, secondsSinceAudio: 0.1), .check)
        XCTAssertEqual(scheduler.lastCheckAt ?? 0, 60.4, accuracy: 0.001)
        XCTAssertEqual(scheduler.round(now: 90.5, totalWords: 81, secondsSinceAudio: 0.1),
                       .skipped(.noNewSpeech), "a silent round shows nothing")
        XCTAssertEqual(scheduler.round(now: 100, totalWords: 120, secondsSinceAudio: 0.1), .notDue,
                       "a skipped round still uses its slot")
        XCTAssertEqual(scheduler.round(now: 120.5, totalWords: 120, secondsSinceAudio: 30), .skipped(.noAudio))
        XCTAssertEqual(scheduler.round(now: 150.5, totalWords: 120, secondsSinceAudio: 0.1), .check)
    }

    func testSilenceAloneNeverProducesAHint() {
        var scheduler = HintScheduler()
        XCTAssertEqual(scheduler.round(now: 30, totalWords: 100, secondsSinceAudio: 0.06), .check)
        // Ten minutes of healthy but silent audio: rounds pass, none checks.
        for minute in 1 ... 20 {
            XCTAssertNotEqual(scheduler.round(now: 30 + Double(minute) * 30, totalWords: 100,
                                              secondsSinceAudio: 0.06), .check)
        }
    }

    func testANewRoundDropsAnUnshownHint() {
        var scheduler = HintScheduler()
        _ = scheduler.round(now: 30, totalWords: 40, secondsSinceAudio: 0)
        scheduler.offer(HintCandidate(question: "Who owns the next step, and by when?", reason: "r", source: "t"),
                        now: 31, secondsSinceAudio: 0)
        _ = scheduler.round(now: 60, totalWords: 80, secondsSinceAudio: 0)
        XCTAssertNil(scheduler.pending)
    }

    func testOfferRejectsBadOrRepeatedQuestions() {
        var scheduler = HintScheduler()
        func candidate(_ question: String, priority: Int = 3) -> HintCandidate {
            HintCandidate(question: question, reason: "r", priority: priority, source: "t")
        }
        XCTAssertEqual(scheduler.offer(candidate(""), now: 0, secondsSinceAudio: 0), .empty)
        XCTAssertEqual(scheduler.offer(candidate("Deadline?"), now: 0, secondsSinceAudio: 0), .tooShort)
        XCTAssertEqual(scheduler.offer(candidate("Tell me the deadline"), now: 0, secondsSinceAudio: 0), .notAQuestion)
        XCTAssertEqual(scheduler.offer(candidate(String(repeating: "word ", count: 25) + "?"), now: 0,
                                       secondsSinceAudio: 0), .tooLong)
        XCTAssertEqual(scheduler.offer(candidate("What is the actual deadline here?", priority: 0), now: 0,
                                       secondsSinceAudio: 0), .lowPriority)
        XCTAssertEqual(scheduler.offer(candidate("What is the actual deadline here?"), now: 0,
                                       secondsSinceAudio: 20), .audioStale)
        XCTAssertNil(scheduler.offer(candidate("“What is the actual deadline here?”"), now: 0, secondsSinceAudio: 0))
        XCTAssertEqual(scheduler.pending?.candidate.question, "What is the actual deadline here?")
        XCTAssertNotNil(scheduler.takeReady(now: 2, lastSpeechAt: 0, secondsSinceAudio: 0))
        XCTAssertEqual(scheduler.offer(candidate("So what is the actual deadline?"), now: 100,
                                       secondsSinceAudio: 0), .duplicate)
    }

    func testShowsAtAPauseRespectsTheGapAndExpires() {
        var scheduler = HintScheduler()
        let hint = HintCandidate(question: "Who owns the next step, and by when?", reason: "r", source: "t")
        scheduler.offer(hint, now: 100, secondsSinceAudio: 0)
        XCTAssertNil(scheduler.takeReady(now: 100.5, lastSpeechAt: 100.2, secondsSinceAudio: 0), "still talking")
        XCTAssertNil(scheduler.takeReady(now: 102, lastSpeechAt: 101, secondsSinceAudio: 30), "audio stale")
        XCTAssertEqual(scheduler.takeReady(now: 103, lastSpeechAt: 101, secondsSinceAudio: 0), hint)

        let next = HintCandidate(question: "What does the budget cover exactly?", reason: "r", source: "t")
        scheduler.offer(next, now: 110, secondsSinceAudio: 0)
        XCTAssertNil(scheduler.takeReady(now: 115, lastSpeechAt: 100, secondsSinceAudio: 0), "minimum gap")
        XCTAssertNil(scheduler.takeReady(now: 140, lastSpeechAt: 100, secondsSinceAudio: 0), "expired")
        XCTAssertNil(scheduler.pending)
    }

    func testContinuousTalkHoldsAHintOnlyBriefly() {
        var scheduler = HintScheduler()
        let hint = HintCandidate(question: "What would a successful outcome look like?", reason: "r", source: "t")
        scheduler.offer(hint, now: 30, secondsSinceAudio: 0)
        XCTAssertNil(scheduler.takeReady(now: 32, lastSpeechAt: 31.9, secondsSinceAudio: 0))
        XCTAssertEqual(scheduler.takeReady(now: 34, lastSpeechAt: 33.9, secondsSinceAudio: 0), hint)
    }

    // MARK: Rules

    func testRulesFindGapsAndStayQuietWhenCovered() async throws {
        let engine = RuleBasedHintEngine()
        func context(_ text: String, asked: [String] = []) -> HintContext {
            HintContext(goal: "", summary: MemorySummary(), recentTranscript: text, previousQuestions: asked)
        }
        let urgent = try await engine.suggest(context("We need this done soon."))
        XCTAssertEqual(urgent?.question, "What is the deadline, and what makes it time-sensitive?")
        XCTAssertNil(RuleBasedHintEngine.firstGap(in: context("We need this soon, by next Friday.")))
        let budget = try await engine.suggest(context("The budget is $20,000."))
        XCTAssertEqual(budget?.question, "Does that budget include implementation and ongoing support?")
        XCTAssertNil(RuleBasedHintEngine.firstGap(in: context("The budget is $20,000 and covers support.")))
        XCTAssertNil(RuleBasedHintEngine.firstGap(in: context("We need this done soon.",
            asked: ["What is the deadline, and what makes it time-sensitive?"])), "never asks the same thing twice")
        XCTAssertNil(RuleBasedHintEngine.firstGap(in: context("Nice weather today.")))
    }

    func testRulesAlwaysHaveAStandingQuestionUntilAllAreAsked() async throws {
        let engine = RuleBasedHintEngine()
        var asked: [String] = []
        for _ in RuleBasedHintEngine.standing {
            let hint = try await engine.suggest(HintContext(goal: "", summary: MemorySummary(),
                recentTranscript: "Nice weather today.", previousQuestions: asked))
            let question = try XCTUnwrap(hint?.question)
            XCTAssertFalse(asked.contains(question), "never the same standing question twice")
            var scheduler = HintScheduler()
            XCTAssertNil(scheduler.offer(try XCTUnwrap(hint), now: 0, secondsSinceAudio: 0),
                         "standing questions pass the scheduler's checks")
            asked.append(question)
        }
        let done = try await engine.suggest(HintContext(goal: "", summary: MemorySummary(),
            recentTranscript: "Nice weather today.", previousQuestions: asked))
        XCTAssertNil(done)
    }
}
