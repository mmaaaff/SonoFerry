import Foundation

public enum MediaAction: String, Codable, Sendable { case play, pause, next, previous }
public struct MediaSession: Equatable, Sendable {
    public var application: String
    public var media: String
    public var output: String
    public var playing: Bool
    public var controlRevision: UInt64
    public init(application: String, media: String, output: String, playing: Bool, controlRevision: UInt64 = 0) {
        self.application = application; self.media = media; self.output = output; self.playing = playing; self.controlRevision = controlRevision
    }
    public func sameIdentity(as other: Self) -> Bool { application == other.application && media == other.media && output == other.output }
}
/// Pure state machine. Its adapter must supply reliable identity, route and user-command revisions.
public struct WearPlaybackMachine: Sendable {
    private var baseline: UInt8?
    private var last: MediaSession?
    private var candidate: UInt8?
    private var changedAt = Date.distantPast
    private var pendingPause: MediaSession?
    private var resume: MediaSession?
    private var previousPlaying = false
    public init() {}
    public mutating func cancel() { self = .init() }
    public mutating func update(wearing: UInt8?, media: MediaSession?, enabled: Bool, at date: Date) -> MediaAction? {
        guard enabled, let wearing, wearing <= 3, let media, !media.application.isEmpty, !media.media.isEmpty, !media.output.isEmpty else { cancel(); return nil }
        if let last, !last.sameIdentity(as: media) || last.controlRevision != media.controlRevision { cancel() }
        last = media
        if media.playing && !previousPlaying {
            baseline = wearing == 0 ? nil : wearing
            resume = nil; pendingPause = nil
        }
        previousPlaying = media.playing
        if candidate != wearing { candidate = wearing; changedAt = date; return nil }
        guard date.timeIntervalSince(changedAt) >= 0.3, let baseline else { return nil }
        if media.playing, wearing & baseline != baseline, pendingPause == nil {
            pendingPause = media; return .pause
        }
        if !media.playing, wearing & baseline == baseline, let resume, resume.sameIdentity(as: media), resume.controlRevision == media.controlRevision {
            self.resume = nil; self.baseline = nil; return .play
        }
        return nil
    }
    public mutating func confirmPause(_ media: MediaSession?) {
        guard let pendingPause, let media, !media.playing, pendingPause.sameIdentity(as: media), pendingPause.controlRevision == media.controlRevision else { cancel(); return }
        resume = media; self.pendingPause = nil; last = media; previousPlaying = false
    }
}
public enum GestureExecutionSource: String, Codable, Sendable { case native, earphone, avrcp }
public struct GestureRouter: Sendable {
    public var source: GestureExecutionSource = .native
    private var recent: [String: Date] = [:]
    public init() {}
    public mutating func reset() { recent.removeAll(); source = .native }
    public mutating func action(for event: HeadsetGesture, from: GestureExecutionSource, media: MediaSession?, at now: Date) -> MediaAction? {
        guard from == source, source != .native, let media, now.timeIntervalSince(event.receivedAt) < 1,
              now >= event.receivedAt, event.scene == 0 else { return nil }
        recent = recent.filter { now.timeIntervalSince($0.value) < 2 }
        let id = "\(event.sequence):\(event.key.id):\(event.key.function)"
        guard recent[id] == nil else { return nil }; recent[id] = now
        switch event.key.function {
        case 1: return media.playing ? .pause : .play
        case 5: return .previous
        case 6: return .next
        default: return nil
        }
    }
}
