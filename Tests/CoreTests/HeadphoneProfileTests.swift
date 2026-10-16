import XCTest
@testable import SonoFerryCore

final class HeadphoneProfileTests: XCTestCase {
    func state(_ id: UInt32) throws -> HeadsetSnapshot {
        var s = HeadsetSnapshot(address: "00:11:22:33:44:55")
        s.productID = id; s.connected = true
        s.capabilities = try .init(reply: .init(command: 0x8100, payload: [0] + Array(repeating: 255, count: 9)))
        s.serviceUUID = HeadphoneProfile.find(id)?.serviceUUID
        return s
    }
    func testCatalogueHasExactOPPOScopeAndUnsupportedTransportRemainsClosed() throws {
        XCTAssertEqual(HeadphoneProfile.all.count, 58)
        XCTAssertEqual(HeadphoneProfile.all.filter { $0.dialect == nil }.count, 5)
        XCTAssertEqual(HeadphoneProfile.all.filter { $0.dialect == .elnk1107 }.count, 6)
        for p in HeadphoneProfile.all {
            let s = try state(p.productID)
            XCTAssertFalse(s.supports(.spatial)); XCTAssertFalse(s.supports(.personalResult))
            XCTAssertNotNil(s.restriction(for: .spatial(1)))
            if p.dialect == nil { XCTAssertNil(s.profile); XCTAssertFalse(s.supports(.battery)) }
            XCTAssertEqual(Set(p.presets.map(\.id)).count, p.presets.count)
        }
        XCTAssertNil(HeadphoneProfile.find(0xffffff))
        XCTAssertNil(HeadphoneProfile.hint(name: "OnePlus Buds Pro"))
    }
    func testNoiseIdentifiersDoNotCrossProducts() throws {
        let x = try XCTUnwrap(HeadphoneProfile.find(0x061410)), x4 = try XCTUnwrap(HeadphoneProfile.find(0x06ec10))
        XCTAssertEqual(x.noiseLabel(3), "深度降噪"); XCTAssertEqual(x4.noiseLabel(3), "关闭")
        XCTAssertEqual(x.noiseLabel(1), "通透"); XCTAssertEqual(x4.noiseLabel(1), "降噪")
        var s = try state(x.productID); s.noise = .init(0); s.noiseType = .init(1)
        XCTAssertNil(s.restriction(for: .noise(3)))
        XCTAssertEqual(try s.packet(for: .noise(3), sequence: 1).payload, [1,1,8])
        XCTAssertNotNil(s.restriction(for: .noise(14)))
        s.noiseAvailable = .init([]); XCTAssertTrue(s.noiseChoices.isEmpty)
        s.noiseAvailable?.stale = true; XCTAssertFalse(s.noiseChoices.isEmpty)
        XCTAssertFalse(try state(0x06b450).supports(.noiseCurrent))
    }
    func testConditionalNoiseOptionRequiresReportedSupport() throws {
        var s = try state(0x062010); s.noise = .init(0); s.noiseType = .init(1)
        XCTAssertFalse(s.noiseChoices.contains(3)) // Enhanced transparency is decideByEarDevice.
        s.noiseAvailable = .init([0,1,2,3]); XCTAssertTrue(s.noiseChoices.contains(3))
        s.noiseAvailable?.stale = true; XCTAssertFalse(s.noiseChoices.contains(3))
    }
    func testPresetsDoNotRequireAnAbsentEqualizerInterface() throws {
        var s = try state(0x06f010); s.preset = .init(0)
        XCTAssertTrue(s.supports(.preset)); XCTAssertFalse(s.supports(.equalizers))
        XCTAssertEqual(s.prerequisiteQueries(for: .preset(1)), [.preset])
        XCTAssertNil(s.restriction(for: .preset(1)))
        let before = s; s.preset = .init(1)
        XCTAssertTrue(s.confirmsSound(.preset(1), before: before))
        XCTAssertNil(s.newEqualizer)
        XCTAssertNotNil(s.restriction(for: .createEqualizer(.init(id: 0, name: "test", minimum: -6, maximum: 6, frequencies: [100], gains: [0]))))
    }
    func testEQUsesReportedBandsAndModelCapacityAndExplicitEmptyDefaults() throws {
        for p in HeadphoneProfile.all where p.supports(.equalizers) {
            var s = try state(p.productID); s.equalizers = .init([]); s.preset = .init(0)
            XCTAssertEqual(s.customEQLimit, p.eqLimit)
            XCTAssertEqual(s.newEqualizer?.frequencies, p.eqFrequencies.isEmpty ? nil : p.eqFrequencies)
            let curve = HeadsetEQ(id: 1, name: "reported", minimum: -3, maximum: 8, frequencies: [100,1000], gains: [2,4])
            s.equalizers = .init([curve])
            XCTAssertEqual(s.newEqualizer?.frequencies, [100,1000]); XCTAssertEqual(s.newEqualizer?.minimum, -3)
            s.equalizers = .init((1...p.eqLimit).map { i in var c = curve; c.id = UInt8(i); return c })
            XCTAssertNil(s.newEqualizer)
        }
    }
    func testGesturesArePerModelAndReportedKeyAndNoTranslationFunctions() throws {
        var s = try state(0x06f010)
        let key = HeadsetKey(ear: 1, action: 1, function: 1)
        s.keys = .init([key])
        XCTAssertEqual(s.profile?.keyLabel(key), "单击")
        XCTAssertEqual(s.profile?.allowedFunctions(key), [0,1])
        XCTAssertNil(s.restriction(for: .key(key)))
        var other = key; other.function = 13; XCTAssertNotNil(s.restriction(for: .key(other)))
        other = key; other.ear = 2; XCTAssertNotNil(s.restriction(for: .key(other)))
        for p in HeadphoneProfile.all { for rule in p.keys { XCTAssertFalse(rule.functions.contains(26)); XCTAssertFalse(rule.functions.contains(27)) } }
        s.productID = 0xffffff; XCTAssertNotNil(s.restriction(for: .key(key)))
    }
    func testIdentityAndFreshCapabilityRequiredForWrite() throws {
        var s = try state(0x06ec10); s.features[17] = .init(false)
        XCTAssertNil(s.restriction(for: .feature(.multipoint, true)))
        s.serviceUUID = HeadsetDialect.elnk1107.rawValue
        XCTAssertNil(s.profile); XCTAssertNotNil(s.restriction(for: .feature(.multipoint, true)))
        let mismatch = RegisteredHeadphone(address: s.address, model: .encoX4, identity: s.identity)
        XCTAssertNil(mismatch.profile)
        s.serviceUUID = HeadsetDialect.elnk079A.rawValue; s.markStale()
        XCTAssertNotNil(s.restriction(for: .feature(.multipoint, true)))
    }
    func testLibraryV1AndCodecEmptyCompleteRoundTrip() throws {
        let old = Data(#"[{"address":"00:11:22:33:44:55","model":"encoX4"},{"address":"00:11:22:33:44:66","model":"wh1000xm5"}]"#.utf8)
        let saved = try JSONDecoder().decode([RegisteredHeadphone].self, from: old)
        XCTAssertEqual(saved.map(\.model), [.encoX4,.wh1000xm5]); XCTAssertNil(saved[0].identity)
        var generic = RegisteredHeadphone(address: "00:11:22:33:44:77", name: "Renamed audio")
        generic.identity = .init(address: generic.address, productID: 0xffffff, serviceUUID: HeadsetDialect.elnk079A.rawValue, generation: UUID())
        XCTAssertNil(generic.profile)
        XCTAssertEqual(try JSONDecoder().decode(RegisteredHeadphone.self, from: JSONEncoder().encode(generic)), generic)
        for status in [CodecProbeState.Status.complete, .failed, .notProbed] {
            let state = CodecProbeState(status, date: Date(timeIntervalSince1970: 100))
            XCTAssertEqual(try JSONDecoder().decode(CodecProbeState.self, from: JSONEncoder().encode(state)), state)
        }
    }
}
