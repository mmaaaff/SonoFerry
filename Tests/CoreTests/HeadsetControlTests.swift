import XCTest
@testable import SonoFerryCore

final class HeadsetControlTests: XCTestCase {
    let time = Date(timeIntervalSince1970: 1234)
    func snapshot() throws -> HeadsetSnapshot {
        var s = HeadsetSnapshot(address: "00:11:22:33:44:55")
        s.connected = true; s.productID = 0x06ec10
        s.capabilities = try .init(reply: .init(command: 0x8100, payload: [0,255,0x77,0x5a,0xee,0xee,0x8f,0xa6,0x5f,0x17]))
        return s
    }
    func packet(_ query: HeadsetQuery, _ payload: [UInt8]) throws -> OppoControlPacket { try .init(command: query.command | 0x8000, payload: payload) }
    func testBatteryUnknownOfflineBoxAndAtomicParsing() throws {
        var s = try snapshot()
        try s.consume(packet(.battery, [0,3,1,88,2,0xe4,3,40]), query: .battery, at: time)
        XCTAssertEqual(s.battery[2]?.value, .init(percent: 100, charging: true))
        try s.consume(packet(.battery, [0,2,1,127,2,50]), query: .battery, at: time.addingTimeInterval(5))
        XCTAssertNil(s.battery[1]?.value.percent); XCTAssertNil(s.battery[1]?.value.charging)
        XCTAssertEqual(s.battery[3]?.value.percent, 40); XCTAssertEqual(s.battery[3]?.updatedAt, time); XCTAssertEqual(s.battery[3]?.stale, true)
        let before = s
        for payload: [UInt8] in [[0,2,1,55], [0,2,1,55,1,99], [0,1,1,60,7]] {
            XCTAssertThrowsError(try s.consume(packet(.battery, payload), query: .battery)); XCTAssertEqual(s, before)
        }
    }
    func testPartialNotificationsDoNotEraseOtherEarAndRequireSubscription() throws {
        var s = try snapshot(); s.notificationIDs = [1,2,3]
        try s.consume(packet(.ears, [0,2,1,3,2,3]), query: .ears, at: time)
        let notification = try OppoControlPacket(command: 0x0204, payload: [2,1,1,1])
        _ = try s.consumeNotification(notification, at: time.addingTimeInterval(1))
        XCTAssertEqual(s.wearMask, 2); XCTAssertEqual(s.ears[2]?.updatedAt, time)
        s.notificationIDs = []; let old = s
        _ = try s.consumeNotification(notification); XCTAssertEqual(s, old); XCTAssertNil(s.wearMask)
    }
    func testLeftRightKeyWriteIsOneDeltaAndRejectsPhoneFunction() throws {
        var s = try snapshot()
        try s.consume(packet(.keys, [0,2,1,1,2,6,2,1,2,5]), query: .keys)
        let updated = HeadsetKey(ear: 1, action: 2, function: 5)
        XCTAssertEqual(try s.packet(for: .key(updated), sequence: 7).payload, [1,1,1,2,5])
        XCTAssertEqual(s.keys?.value[1].function, 5)
        XCTAssertThrowsError(try s.packet(for: .key(.init(ear: 1, action: 2, function: 18)), sequence: 8))
        XCTAssertThrowsError(try s.packet(for: .key(.init(ear: 1, action: 3, function: 1)), sequence: 9))
    }
    func testDynamicEQSignedBoundsAndExactReadback() throws {
        var s = try snapshot()
        let curve = HeadsetEQ(id: 7, name: "三段", selected: true, minimum: -6, maximum: 6, frequencies: [80,900,12000], gains: [-6,0,6])
        let payload = try curve.settingPayload()
        s.preset = .init(255)
        try s.consume(packet(.equalizers, [0,1,1] + Array(payload.dropFirst())), query: .equalizers)
        XCTAssertEqual(s.equalizers?.value, [curve]); XCTAssertTrue(s.confirms(.equalizer(curve)))
        var changed = curve; changed.gains[0] = 7
        XCTAssertThrowsError(try changed.validate()); XCTAssertNotNil(s.restriction(for: .equalizer(changed)))
        changed = curve; changed.frequencies[0] = 90
        XCTAssertNotNil(s.restriction(for: .equalizer(changed)))
        changed = curve; changed.gains[1] = 2
        XCTAssertFalse(s.confirms(.equalizer(changed))); XCTAssertNil(s.restriction(for: .equalizer(changed)))
        let original = s
        XCTAssertThrowsError(try s.consume(packet(.equalizers, [0,1,0] + Array(payload.dropFirst().dropLast())), query: .equalizers))
        XCTAssertEqual(s, original)
    }
    func testUnknownNoiseIsPreservedNotMadeSelectable() throws {
        var s = try snapshot()
        try s.consume(packet(.noiseAvailable, [0,3,1,8,1,128]), query: .noiseAvailable)
        try s.consume(packet(.noiseCurrent, [0,1,1,0,0,128]), query: .noiseCurrent)
        XCTAssertEqual(s.noise?.value, 23); XCTAssertEqual(s.noiseChoices, [8,3])
        XCTAssertNotNil(s.restriction(for: .noise(23)))
        XCTAssertThrowsError(try s.consume(packet(.noiseCurrent, [0,1,1,9]), query: .noiseCurrent))
    }
    func testFeaturePrerequisitesAndStaleGeneration() throws {
        var s = try snapshot()
        try s.consume(packet(.feature(.wearDetection), [0,1,4,1]), query: .feature(.wearDetection))
        XCTAssertEqual(try s.packet(for: .feature(.wearDetection, false), sequence: 9).payload, [4,0])
        try s.consume(packet(.feature(.goldenSound), [0,1,11,1]), query: .feature(.goldenSound))
        XCTAssertNil(s.restriction(for: .feature(.goldenSound, false)))
        s.markStale(.feature(.wearDetection), reason: "timeout")
        XCTAssertNotNil(s.restriction(for: .feature(.wearDetection, false)))
        s.markStale(); XCTAssertFalse(s.connected)
    }
    func testLongFramesEverySplitAndProtocolFragments() throws {
        let original = try OppoControlPacket(command: 0x8122, sequence: 4, payload: (0..<1024).map { UInt8($0 % 256) })
        XCTAssertEqual(Array(original.bytes.prefix(3)), [0xaa,0x87,8])
        for offset in 0...original.bytes.count {
            var framer = OppoControlFramer()
            XCTAssertEqual(try framer.accept(Array(original.bytes.prefix(offset))) + framer.accept(Array(original.bytes.dropFirst(offset))), [original])
            try framer.finish()
        }
        let inner = Array(original.bytes.dropFirst(5))
        var fragments: [UInt8] = []
        let pieces = stride(from: 0, to: inner.count, by: 60).map { Array(inner[$0..<min($0+60,inner.count)]) }
        for (i,piece) in pieces.enumerated() {
            fragments += [0xaa,UInt8(piece.count+3),i == 0 ? 1 : i == pieces.count-1 ? 3 : 2,0,UInt8(i)] + piece
        }
        var framer = OppoControlFramer(); XCTAssertEqual(try framer.accept(fragments), [original]); try framer.finish()
        var invalid = OppoControlFramer(); XCTAssertThrowsError(try invalid.accept([0xaa,4,2,0,1,0]))
        var unfinished = OppoControlFramer(); _ = try unfinished.accept([0xaa,4,1,0,0,0]); XCTAssertThrowsError(try unfinished.finish())
        var oversized = OppoControlFramer(); XCTAssertThrowsError(try oversized.accept([0xaa,0xff,0x7f]))
    }
    func testWireBackwardCompatibilityAndNewRequest() throws {
        let old = try JSONDecoder().decode(WireMessage.self, from: Data(#"{"version":1,"kind":"devices"}"#.utf8))
        XCTAssertNil(old.headset); XCTAssertEqual(old.version, 1)
        var message = WireMessage("headsetSet", requestID: UUID(), sessionID: UUID())
        message.headsetSetting = .noise(3); message.controlGeneration = UUID(); message.headset = try snapshot()
        let decoded = try JSONDecoder().decode(WireMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.headset, message.headset); XCTAssertEqual(decoded.headsetSetting, message.headsetSetting)
    }
}
