import Foundation

/// Content-free timing evidence. Times are seconds since capture started;
/// markers describe requests/observations, not successful device actions.
public struct MicCaptureTimeline: Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case microphoneRequested, assistantTriggered, assistantReleased
        case firstAudio, speechDetected, audioStalled, audioResumed
        case cardShowRequested, cardDismissRequested, captureStopped
    }

    public struct Event: Sendable, Codable {
        public let kind: Kind
        public let elapsed: TimeInterval
        public let decodedFrames: Int
    }

    public private(set) var events: [Event] = []
    public private(set) var omittedEvents = 0
    public private(set) var firstAudioAt: TimeInterval?
    public private(set) var lastAudioAt: TimeInterval?
    private var longestCompletedGap: TimeInterval = 0

    public init() {}

    public mutating func record(_ kind: Kind, at elapsed: TimeInterval, frames: Int) {
        // A diagnostic session must remain bounded even with repeated controls.
        if events.count == 128 { events.removeFirst(); omittedEvents += 1 }
        events.append(Event(kind: kind, elapsed: elapsed, decodedFrames: frames))
    }

    public mutating func receivedAudio(at elapsed: TimeInterval, frames: Int) {
        if let lastAudioAt {
            longestCompletedGap = max(longestCompletedGap, elapsed - lastAudioAt)
            if elapsed - lastAudioAt > 3 { record(.audioResumed, at: elapsed, frames: frames) }
        } else {
            firstAudioAt = elapsed
            record(.firstAudio, at: elapsed, frames: frames)
        }
        lastAudioAt = elapsed
    }

    /// Includes the current trailing outage, but excludes waiting for first audio.
    public func longestGap(at elapsed: TimeInterval) -> TimeInterval? {
        lastAudioAt.map { max(longestCompletedGap, elapsed - $0) }
    }
}
