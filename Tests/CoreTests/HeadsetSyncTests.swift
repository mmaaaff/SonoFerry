import XCTest
@testable import SonoFerryCore

final class HeadsetSyncTests: XCTestCase {
    func fixture() throws -> HeadsetSnapshot {
        var s = HeadsetSnapshot(address: "fixture"); s.connected = true; s.productID = 0x06ec10
        s.capabilities = try .init(reply: .init(command: 0x8100, payload: [0,255,0x77,0x5a,0xee,0xee,0x8f,0xa6,0x5f,0x17]))
        s.preset = .init(0)
        s.equalizers = .init([.init(id: 32, name: "Phone EQ", minimum: -6, maximum: 6, frequencies: [100,1000], gains: [1,2])])
        return s
    }
    func testUnwornIsFreshBilateralEvidenceAndGuardsEveryNoiseMode() throws {
        var s = try fixture()
        try s.consume(.init(command: 0x810c, payload: [0,1,1,16]), query: .noiseCurrent)
        XCTAssertFalse(s.bothEarsUnworn)
        s.ears[1] = .init(.init(raw: 1)); XCTAssertFalse(s.bothEarsUnworn)
        s.ears[2] = .init(.init(raw: 1)); XCTAssertTrue(s.bothEarsUnworn)
        for mode: UInt8 in [4,5,6,7,12,13,14,8,3] {
            XCTAssertEqual(s.restriction(for: .noise(mode)), "佩戴耳机以启用降噪")
            XCTAssertThrowsError(try s.packet(for: .noise(mode), sequence: 1))
        }
        s.ears[2]?.stale = true; XCTAssertFalse(s.bothEarsUnworn)
        s.notificationIDs = [2]
        try s.consumeNotification(.init(command: 0x0204, payload: [2,1,2,3]))
        XCTAssertFalse(s.bothEarsUnworn); XCTAssertNil(s.restriction(for: .noise(4)))
        s.markStale(); XCTAssertFalse(s.bothEarsUnworn)
    }
    func testPhonePresetCustomAndBassSyncWithoutNotificationRegistration() throws {
        var s = try fixture()
        try s.consumeSync(.init(command: 0x0504, sequence: 244, payload: [32]))
        XCTAssertEqual(s.soundSelection, .equalizer(32))
        try s.consumeSync(.init(command: 0x0504, payload: [7]))
        XCTAssertEqual(s.soundSelection, .preset(7))
        var curve = s.equalizers!.value[0]; curve.selected = true; curve.gains = [-3,5]
        try s.consumeSync(.init(command: 0x0506, payload: [1,1] + Array(try curve.settingPayload().dropFirst())))
        XCTAssertEqual(s.soundSelection, .equalizer(32)); XCTAssertEqual(s.equalizers?.value.first?.gains, [-3,5])
        try s.consumeSync(.init(command: 0x0503, payload: [3,29,1,17,1,11,0]))
        XCTAssertEqual(s.features[29]?.value, true); XCTAssertEqual(s.features[17]?.value, true)
        try s.consumeSync(.init(command: 0x0508, payload: [251,5,3]))
        XCTAssertEqual(s.bassWave?.value.current, 3)
        try s.consumeSync(.init(command: 0x0506, payload: [0]))
        XCTAssertEqual(s.equalizers?.value, []); XCTAssertNil(s.soundSelection)
    }
    func testMalformedSyncAtomicAndDisconnectedOrUnknownIgnored() throws {
        var s = try fixture()
        for (command, payload): (UInt16, [UInt8]) in [(0x0503,[2,29,1,17]), (0x0503,[2,29,1,29,0]), (0x0503,[2,29,1,17,7]), (0x0504,[7,0]), (0x0506,[1]), (0x0508,[251,5,6]), (0x0508,[251,5])] {
            let before = s
            XCTAssertThrowsError(try s.consumeSync(.init(command: command, payload: payload)))
            XCTAssertEqual(s, before)
        }
        let before = s; XCTAssertEqual(try s.consumeSync(.init(command: 0x0509, payload: [1])), []); XCTAssertEqual(s, before)
        s.connected = false; let offline = s
        try s.consumeSync(.init(command: 0x0504, payload: [7])); XCTAssertEqual(s, offline)
    }
}
