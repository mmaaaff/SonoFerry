import XCTest
@testable import SonoFerryCore

final class HeadsetSoundTests: XCTestCase {
    func state() throws -> HeadsetSnapshot {
        var s = try HeadsetControlTests().snapshot()
        s.preset = .init(0); s.equalizers = .init([])
        return s
    }
    let curve = HeadsetEQ(id: 10, name: "Balance", minimum: -6, maximum: 6, frequencies: [80,900,12000], gains: [-6,0,6])
    func testEQWriteReplyHasStatusAndSlotID() throws {
        let ack = try HeadsetWriteReply(.init(command: 0x8418, payload: [0,6]), command: 0x0418)
        XCTAssertTrue(ack.accepted); XCTAssertEqual(ack.equalizerID, 6)
        XCTAssertFalse(try HeadsetWriteReply(.init(command: 0x8418, payload: [3,6]), command: 0x0418).accepted)
        for bytes: [UInt8] in [[], [0], [0,6,0]] {
            XCTAssertThrowsError(try HeadsetWriteReply(.init(command: 0x8418, payload: bytes), command: 0x0418))
        }
        XCTAssertThrowsError(try HeadsetWriteReply(.init(command: 0x841b, payload: [0,6]), command: 0x0418))
        XCTAssertTrue(try HeadsetWriteReply(.init(command: 0x841b, payload: [0]), command: 0x041b).accepted)
        XCTAssertThrowsError(try HeadsetWriteReply(.init(command: 0x841b, payload: [0,0]), command: 0x041b))
        var before = try state(); before.equalizers = .init([curve])
        var after = before; after.preset = .init(curve.id); after.equalizers?.value[0].selected = true
        XCTAssertTrue(after.confirmsSound(.selectEqualizer(curve.id), before: before, acknowledgedEQID: curve.id))
        XCTAssertFalse(after.confirmsSound(.selectEqualizer(curve.id), before: before, acknowledgedEQID: curve.id + 1))
        let draft = try XCTUnwrap(before.newEqualizer)
        var added = draft; added.id = 6; added.selected = true
        after = before; after.equalizers?.value.append(added); after.preset = .init(6)
        XCTAssertTrue(after.confirmsSound(.createEqualizer(draft), before: before, acknowledgedEQID: 6))
        XCTAssertFalse(after.confirmsSound(.createEqualizer(draft), before: before, acknowledgedEQID: 5))
    }
    func testCatalogAndSingleSelectionRequireCoherentFreshSources() throws {
        var s = try state()
        XCTAssertEqual(HeadsetSoundPreset.x4.map(\.id), [0,7,2,1,3])
        XCTAssertEqual(HeadsetSoundPreset.x4.map(\.name), ["丹拿原声","丹拿高解析","纯享人声","清亮高音","澎湃低音"])
        XCTAssertEqual(s.soundSelection, .preset(0))
        var selected = curve; selected.selected = true; s.equalizers = .init([selected])
        XCTAssertNil(s.soundSelection) // Phone changed one source before the other.
        s.preset = .init(255); XCTAssertEqual(s.soundSelection, .equalizer(10))
        var duplicate = selected; duplicate.id = 11; s.equalizers?.value.append(duplicate)
        XCTAssertNil(s.soundSelection)
        s.equalizers = .init([selected]); s.preset?.stale = true; XCTAssertNil(s.soundSelection)
    }
    func testEQCRUDUsesFullCurveActionsAndLatestSelection() throws {
        var s = try state(); s.equalizers = .init([curve])
        var changed = curve; changed.gains[1] = 3; s.equalizers = .init([changed])
        XCTAssertEqual(try s.packet(for: .selectEqualizer(10), sequence: 1).payload, try changed.settingPayload())
        XCTAssertNotNil(s.restriction(for: .equalizer(curve, replacing: curve)))
        XCTAssertNotNil(s.restriction(for: .deleteEqualizer(curve)))
        XCTAssertEqual(try s.packet(for: .deleteEqualizer(changed), sequence: 2).payload, [3] + Array(try changed.settingPayload().dropFirst()))
        let draft = try XCTUnwrap(s.newEqualizer)
        XCTAssertEqual(draft.frequencies, curve.frequencies); XCTAssertEqual(draft.id, 0)
        XCTAssertEqual(try s.packet(for: .createEqualizer(draft), sequence: 3).payload.first, 1)
        s.equalizers = .init((10...12).map { var c = curve; c.id = UInt8($0); return c })
        XCTAssertNil(s.newEqualizer); XCTAssertNotNil(s.restriction(for: .createEqualizer(draft)))
        s.equalizers = .init([])
        XCTAssertEqual(s.newEqualizer?.frequencies, [31,62,125,250,500,1000,2000,4000,8000,16000])
        s.productID = 0; XCTAssertNil(s.newEqualizer)
    }
    func testReadbackMustConfirmSelectionAndPreserveOtherSlots() throws {
        var before = try state(); before.equalizers = .init([curve])
        var after = before
        XCTAssertFalse(after.confirmsSound(.selectEqualizer(10), before: before))
        after.preset = .init(255); after.equalizers?.value[0].selected = true
        XCTAssertTrue(after.confirmsSound(.selectEqualizer(10), before: before))
        after.equalizers?.value[0].gains[0] = 0
        XCTAssertFalse(after.confirmsSound(.selectEqualizer(10), before: before))
        let draft = try XCTUnwrap(before.newEqualizer)
        var added = draft; added.id = 73 // Firmware owns allocation, not the host.
        after = before; after.equalizers?.value.append(added)
        XCTAssertTrue(after.confirmsSound(.createEqualizer(draft), before: before))
        after.equalizers?.value[0].name = "Phone edited"
        XCTAssertFalse(after.confirmsSound(.createEqualizer(draft), before: before))
        after = before; after.equalizers = .init([])
        XCTAssertTrue(after.confirmsSound(.deleteEqualizer(curve), before: before))
        after.preset?.stale = true
        XCTAssertFalse(after.confirmsSound(.deleteEqualizer(curve), before: before))
    }
    func testBassWaveSignedBoundsAndMalformedRepliesAreAtomic() throws {
        var s = try state(); s.features[29] = .init(true)
        func response(_ bytes: [UInt8]) throws -> OppoControlPacket { try .init(command: 0x8124, payload: bytes) }
        try s.consume(response([0,251,5,254]), query: .bassWave)
        XCTAssertEqual(s.bassWave?.value, .init(minimum: -5, maximum: 5, current: -2))
        XCTAssertEqual(try s.packet(for: .bassWave(4), sequence: 1).payload, [251,5,4])
        XCTAssertEqual(try s.packet(for: .feature(.bassWave, false), sequence: 2).payload, [29,0])
        XCTAssertNotNil(s.restriction(for: .bassWave(6)))
        let before = s
        for bytes: [UInt8] in [[0,251,5], [0,5,251,0], [0,251,5,6], [0,251,5,0,0]] {
            XCTAssertThrowsError(try s.consume(response(bytes), query: .bassWave)); XCTAssertEqual(s, before)
        }
        s.features[29] = .init(false); XCTAssertNotNil(s.restriction(for: .bassWave(0)))
        s.markStale(); XCTAssertEqual(s.bassWave?.stale, true)
    }
    func testPhoneShareCodeVectorsChecksumAliasesAndLargeCurves() throws {
        // Independent Python integer conversion of the APK's documented algorithm.
        XCTAssertEqual(try HeadsetEQShareCode.encode(Array(repeating: 0, count: 10)), "20681MQ4J")
        for gains in [Array(repeating: -6, count: 10), Array(repeating: 6, count: 10), [-6,-3,0,3,6,5,2,-1,-4,-6], (0..<32).map { $0 % 13 - 6 }] {
            let code = try HeadsetEQShareCode.encode(gains)
            XCTAssertEqual(try HeadsetEQShareCode.decode(code.lowercased(), bands: gains.count), gains)
            XCTAssertThrowsError(try HeadsetEQShareCode.decode(String(code.dropLast()) + (code.last == "0" ? "1" : "0"), bands: gains.count))
        }
        XCTAssertEqual(try HeadsetEQShareCode.decode("OOOOOOOOO", bands: 10), Array(repeating: -6, count: 10))
        XCTAssertThrowsError(try HeadsetEQShareCode.decode("ZZZZZZZZ0", bands: 10))
        XCTAssertThrowsError(try HeadsetEQShareCode.decode("000", bands: 10))
        XCTAssertThrowsError(try HeadsetEQShareCode.encode([7]))
    }
    func testNewSettingsAndOldCachedSnapshotDecode() throws {
        var s = try state(); s.bassWave = .init(.init(minimum: -5, maximum: 5, current: 0))
        for setting: HeadsetSetting in [.selectEqualizer(10), .createEqualizer(curve), .deleteEqualizer(curve), .equalizer(curve, replacing: curve), .bassWave(-2)] {
            XCTAssertEqual(try JSONDecoder().decode(HeadsetSetting.self, from: JSONEncoder().encode(setting)), setting)
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]); json.removeValue(forKey: "bassWave")
        XCTAssertNil(try JSONDecoder().decode(HeadsetSnapshot.self, from: JSONSerialization.data(withJSONObject: json)).bassWave)
    }
}
