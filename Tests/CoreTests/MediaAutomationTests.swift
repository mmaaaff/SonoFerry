import XCTest
@testable import SonoFerryCore
final class MediaAutomationTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_000)
    var music: MediaSession { .init(application: "com.apple.Music", media: "track-1", output: "headset", playing: true) }
    func testDualEarPauseDebounceAndConfirmedResume() {
        var m = WearPlaybackMachine(), session = music; session.playing = true
        XCTAssertNil(m.update(wearing: 3, media: session, enabled: true, at: t))
        XCTAssertNil(m.update(wearing: 2, media: session, enabled: true, at: t.addingTimeInterval(1)))
        XCTAssertNil(m.update(wearing: 2, media: session, enabled: true, at: t.addingTimeInterval(1.29)))
        XCTAssertEqual(m.update(wearing: 2, media: session, enabled: true, at: t.addingTimeInterval(1.31)), .pause)
        session.playing = false; m.confirmPause(session)
        XCTAssertNil(m.update(wearing: 3, media: session, enabled: true, at: t.addingTimeInterval(2)))
        XCTAssertEqual(m.update(wearing: 3, media: session, enabled: true, at: t.addingTimeInterval(2.31)), .play)
        XCTAssertNil(m.update(wearing: 3, media: session, enabled: true, at: t.addingTimeInterval(3)))
    }
    func testSingleEarDoesNotRequireUnusedEarAndRejectsUnknown() {
        var m = WearPlaybackMachine(), session = music; session.playing = true
        _ = m.update(wearing: 1, media: session, enabled: true, at: t)
        _ = m.update(wearing: 0, media: session, enabled: true, at: t.addingTimeInterval(1))
        XCTAssertEqual(m.update(wearing: 0, media: session, enabled: true, at: t.addingTimeInterval(1.31)), .pause)
        session.playing = false; m.confirmPause(session)
        _ = m.update(wearing: nil, media: session, enabled: true, at: t.addingTimeInterval(2))
        _ = m.update(wearing: 1, media: session, enabled: true, at: t.addingTimeInterval(3))
        XCTAssertNil(m.update(wearing: 1, media: session, enabled: true, at: t.addingTimeInterval(3.31)))
    }
    func testTakeoverTrackAppOutputSleepAndDisconnectCancelResume() {
        for mutation in 0..<7 {
            var m = WearPlaybackMachine(), session = music; session.playing = true
            _ = m.update(wearing: 3, media: session, enabled: true, at: t)
            _ = m.update(wearing: 1, media: session, enabled: true, at: t.addingTimeInterval(1))
            _ = m.update(wearing: 1, media: session, enabled: true, at: t.addingTimeInterval(1.31))
            session.playing = false; m.confirmPause(session)
            switch mutation {
            case 0: session.controlRevision += 1
            case 1: session.media = "other"
            case 2: session.application = "browser"
            case 3: session.output = "speakers"
            case 4: m.cancel()
            case 5: _ = m.update(wearing: nil, media: session, enabled: true, at: t.addingTimeInterval(2))
            default: _ = m.update(wearing: 3, media: nil, enabled: true, at: t.addingTimeInterval(2))
            }
            _ = m.update(wearing: 3, media: session, enabled: true, at: t.addingTimeInterval(3))
            XCTAssertNil(m.update(wearing: 3, media: session, enabled: true, at: t.addingTimeInterval(3.31)))
        }
    }
    func testNoResumeForManualOrUnconfirmedPauseAndInitiallyUnworn() {
        for wearing: UInt8 in [0, 3] {
            var m = WearPlaybackMachine(), session = music; session.playing = true
            _ = m.update(wearing: wearing, media: session, enabled: true, at: t)
            session.playing = false
            _ = m.update(wearing: 3, media: session, enabled: true, at: t.addingTimeInterval(1))
            XCTAssertNil(m.update(wearing: 3, media: session, enabled: true, at: t.addingTimeInterval(1.31)))
        }
    }
    func testGestureOneSourceDeduplicationAndStaleSceneRejection() throws {
        var r = GestureRouter(), session = music; session.playing = true
        let event = try HeadsetGesture(payload: [1,1,1,1,0], sequence: 9, at: t)
        XCTAssertNil(r.action(for: event, from: .earphone, media: session, at: t))
        r.source = .earphone
        XCTAssertNil(r.action(for: event, from: .avrcp, media: session, at: t))
        XCTAssertEqual(r.action(for: event, from: .earphone, media: session, at: t), .pause)
        XCTAssertNil(r.action(for: event, from: .earphone, media: session, at: t.addingTimeInterval(0.1)))
        XCTAssertNil(r.action(for: event, from: .earphone, media: session, at: t.addingTimeInterval(3)))
        let call = try HeadsetGesture(payload: [1,1,1,1,1], sequence: 10, at: t)
        XCTAssertNil(r.action(for: call, from: .earphone, media: session, at: t))
    }
}
