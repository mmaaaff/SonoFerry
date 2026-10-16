import XCTest
@testable import SonoFerryCore

final class HeadsetNoiseAndCallsTests: XCTestCase {
    func snapshot() throws -> HeadsetSnapshot {
        var s = HeadsetSnapshot(address: "fixture")
        s.connected = true; s.productID = 0x06ec10
        s.capabilities = try .init(reply: .init(command: 0x8100, payload: [0,255,0x77,0x5a,0xee,0xee,0x8f,0xa6,0x5f,0x17]))
        return s
    }
    func read(_ s: inout HeadsetSnapshot, _ q: HeadsetQuery, _ p: [UInt8]) throws {
        try s.consume(.init(command: q.command | 0x8000, payload: p), query: q)
    }
    func testX4FallbackRequiresFreshCurrentAndValidSupportIsAuthoritative() throws {
        var s = try snapshot()
        XCTAssertNotNil(s.restriction(for: .noise(4)))
        try read(&s, .noiseCurrent, [0,1,1,8])
        s.markStale(.noiseAvailable, reason: "unsupported envelope")
        XCTAssertEqual(s.noiseChoices, [4,5,6,7,12,13,14,8,3,11])
        for mode: UInt8 in [4,5,6,7,12,13,14,8,3,11] { XCTAssertNil(s.restriction(for: .noise(mode))) }
        try read(&s, .noiseAvailable, [0,3,3,16,16])
        XCTAssertEqual(s.noiseChoices, [4,12]); XCTAssertNotNil(s.restriction(for: .noise(7)))
        try read(&s, .noiseAvailable, [0,3,4,0])
        XCTAssertEqual(s.noiseChoices, []); XCTAssertNotNil(s.restriction(for: .noise(4)))
        s.markStale(.noiseAvailable, reason: "new connection")
        s.productID = 0xabcdef; XCTAssertTrue(s.noiseChoices.isEmpty)
        XCTAssertNotNil(s.restriction(for: .noise(4)))
        s.productID = 0x06ec10; s.markStale(.noiseCurrent, reason: "timeout")
        XCTAssertNotNil(s.restriction(for: .noise(4)))
    }
    func testManualNoiseUsesPhoneTypeAndUnknownEnvelopeDoesNotMutate() throws {
        var s = try snapshot()
        try read(&s, .noiseCurrent, [0,1,5,0,16])
        XCTAssertEqual(s.noise?.value, 12)
        XCTAssertEqual(try s.packet(for: .noise(14), sequence: 1).payload, [1,1,0,64])
        for payload: [UInt8] in [[0,1,2,4],[0,3,1,16],[0,1,1],[0,1,1,0],[0,1,1,48],[0,1,1,0,0,0,0,1]] {
            let before = s
            XCTAssertThrowsError(try read(&s, .noiseCurrent, payload)); XCTAssertEqual(s, before)
        }
        XCTAssertEqual(HeadsetSnapshot.noiseLabel(5), "中度降噪")
        XCTAssertEqual(HeadsetSnapshot.noiseLabel(13), "标准")
        XCTAssertEqual(HeadsetSnapshot.noiseLabel(31), "未识别的降噪模式")
    }
    func testAdaptiveParentPacketAndResolvedChildConfirmation() throws {
        var s = try snapshot()
        try read(&s, .noiseCurrent, [0,1,5,8])
        XCTAssertEqual(try s.packet(for: .noise(11), sequence: 1).payload, [1,1,0,8])
        for mode: UInt8 in [11,12,13,14] {
            s.noise = .init(mode)
            XCTAssertTrue(s.confirms(.noise(11)))
        }
        s.noise = .init(7); XCTAssertFalse(s.confirms(.noise(11)))
        s.noise = .init(13); s.markStale(.noiseCurrent, reason: "stale")
        XCTAssertFalse(s.confirms(.noise(11)))
    }
    func testPhoneNoiseNotificationsKeepSeparateMeanings() throws {
        var s = try snapshot(); s.notificationIDs = [3]
        try read(&s, .noiseCurrent, [0,1,1,8])
        let before = s
        for action: UInt8 in [2,99] {
            _ = try s.consumeNotification(.init(command: 0x0204, payload: [3,action,1,16]))
            XCTAssertEqual(s, before)
        }
        _ = try s.consumeNotification(.init(command: 0x0204, payload: [3,1,5,0,64]))
        XCTAssertEqual(s.noise?.value, 14)
        _ = try s.consumeNotification(.init(command: 0x0204, payload: [3,3,1,16]))
        XCTAssertEqual(s.noiseChoices, [4]); XCTAssertEqual(s.noise?.value, 14)
    }
    func testIntelligentDepthDoesNotChangeSelectedModeAndUsesPhoneLabels() throws {
        var s = try snapshot(); s.notificationIDs = [3]
        try read(&s, .noiseCurrent, [0,1,1,128])
        XCTAssertEqual(try HeadsetQuery.noiseIntelligent.packet(sequence: 1).payload, [4,1])
        for (depth, title): (UInt8, String) in [(4,"深度降噪"),(5,"中度降噪"),(6,"轻度降噪")] {
            _ = try s.consumeNotification(.init(command: 0x0204, payload: [3,4,1,1 << depth]))
            XCTAssertEqual(s.noise?.value, 7)
            XCTAssertEqual(s.intelligentNoiseTitle, "智能切换：" + title)
        }
        try read(&s, .noiseCurrent, [0,1,1,16]); XCTAssertNil(s.intelligentNoiseTitle)
        try read(&s, .noiseCurrent, [0,1,1,128]); XCTAssertNil(s.intelligentNoiseTitle, "a previous smart observation cannot survive mode changes")
        try read(&s, .noiseIntelligent, [0,4,1,16]); XCTAssertNotNil(s.intelligentNoiseTitle)
        s.markStale(); XCTAssertNil(s.intelligentNoiseTitle)
    }
    func testMalformedAndUnknownIntelligentDepth() throws {
        var s = try snapshot(); s.notificationIDs = [3]
        try read(&s, .noiseCurrent, [0,1,1,128])
        try read(&s, .noiseIntelligent, [0,4,1,16])
        for payload: [UInt8] in [[0,1,1,16], [0,4,5,16], [0,4,1], [0,4,1,0], [0,4,1,48], [0,4,1,0,0,0,0,1]] {
            let before = s; XCTAssertThrowsError(try read(&s, .noiseIntelligent, payload)); XCTAssertEqual(s, before)
        }
        try read(&s, .noiseIntelligent, [0,4,1,0,0,0,128])
        XCTAssertEqual(s.intelligentNoise?.value, 31); XCTAssertNil(s.intelligentNoiseTitle)
        s.markStale(.noiseIntelligent, reason: "timeout"); XCTAssertTrue(s.intelligentNoise!.stale)
        XCTAssertNotNil(s.issues[HeadsetQuery.noiseIntelligent.key])
        s.connected = false; XCTAssertNil(s.intelligentNoiseTitle)
    }
    func testCallChoicesAreGestureSpecificAndWritesDoNotTouchOtherMappings() throws {
        var s = try snapshot()
        let keys = [UInt8(1),2].flatMap { ear in (1...3).map { HeadsetKey(ear: ear, button: 6, action: UInt8($0), function: [29,28,25][$0-1]) } }
        try read(&s, .keys, [0,UInt8(keys.count)] + keys.flatMap(\.bytes))
        for var key in keys {
            XCTAssertEqual(key.allowedFunctions, [key.function,0]); XCTAssertTrue(key.isCall); XCTAssertTrue(key.isVisible)
            XCTAssertFalse(key.actionLabel.contains("6/"))
            key.function = 0
            XCTAssertEqual(try s.packet(for: .key(key), sequence: 9).payload, [1] + key.bytes)
            XCTAssertEqual(s.keys?.value, keys)
            key.function = 1; XCTAssertNotNil(s.restriction(for: .key(key)))
            key.function = key.action == 1 ? 28 : 29; XCTAssertNotNil(s.restriction(for: .key(key)))
        }
        XCTAssertFalse(HeadsetKey(ear: 1, action: 6, function: 18).isVisible)
        XCTAssertEqual(HeadsetKey.functions[25], "AI 摘要操控")
        s.markStale(.keys, reason: "disconnected"); XCTAssertNotNil(s.restriction(for: .key(keys[0])))
    }
    func testGoldenResultPresenceGatesOnlyEnableAndRejectsTruncationAtomically() throws {
        var s = try snapshot()
        try read(&s, .feature(.goldenSound), [0,1,11,1])
        XCTAssertNil(s.restriction(for: .feature(.goldenSound, false)))
        XCTAssertNotNil(s.restriction(for: .feature(.goldenSound, true)))
        let result: [UInt8] = [0,1,2,1,2,3,4,5,6,0,0,0,1] + Array("Private result name".utf8)
        try read(&s, .goldenResult, result)
        XCTAssertEqual(s.goldenResult?.value, true)
        XCTAssertEqual(try s.packet(for: .feature(.goldenSound, true), sequence: 4).payload, [11,1])
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(json.contains("Private result name"))
        for count in 0..<13 {
            let before = s
            XCTAssertThrowsError(try read(&s, .goldenResult, Array(result.prefix(count))))
            XCTAssertEqual(s, before)
        }
        XCTAssertThrowsError(try read(&s, .goldenResult, [0,1,0,0,0,0,0,255]))
        try read(&s, .goldenResult, [0,1,0,0,0,0,0])
        XCTAssertEqual(s.goldenResult?.value, false)
        XCTAssertNotNil(s.restriction(for: .feature(.goldenSound, true)))
        XCTAssertNil(s.restriction(for: .feature(.goldenSound, false)))
        s.goldenResult = .init(true); s.markStale(.noiseCurrent, reason: "noise failed")
        XCTAssertEqual(s.goldenResult?.stale, false)
        s.markStale(); XCTAssertEqual(s.goldenResult?.stale, true)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        object.removeValue(forKey: "goldenResult"); object.removeValue(forKey: "noiseType")
        let legacy = try JSONDecoder().decode(HeadsetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.goldenResult); XCTAssertNil(legacy.noiseType)
    }
}
