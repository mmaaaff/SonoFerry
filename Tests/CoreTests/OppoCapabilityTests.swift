import XCTest
@testable import SonoFerryCore

final class OppoCapabilityTests: XCTestCase {
    func testLiveCodecBitmapRetainsUnknownAndSeparatesProtocolIDs() {
        XCTAssertEqual(OppoControlCodec.ids(in: 0x0146), [2,3,7,9])
        XCTAssertEqual(OppoControlCodec.label(2), "AAC")
        XCTAssertEqual(OppoControlCodec.label(9), "未知编码（控制编号 9）")
        XCTAssertEqual(OppoControlCodec.ids(in: 0), [])
        XCTAssertEqual(OppoControlCodec.ids(in: 0x8000), [16])
    }
    func testCommandBitmapIsNotAudioCapabilities() throws {
        let caps = try OppoControlCapabilities(reply: .init(command: 0x8100, payload: [0,0x80,0,2,0,0x20,0x80]))
        XCTAssertTrue(caps.supportsFeatureSetter)
        XCTAssertTrue(caps.supportsCurrentCodecQuery)
        XCTAssertTrue(caps.supportsCodecSelection)
        XCTAssertTrue(caps.hasBit(47)) // Unknown bits remain available as evidence.
        XCTAssertFalse(caps.hasBit(-1)); XCTAssertFalse(caps.hasBit(1000))
        let short = try OppoControlCapabilities(reply: .init(command: 0x8100, payload: [0,0]))
        XCTAssertFalse(short.supportsCodecSelection)
        for bytes: [UInt8] in [[], [0], [2,0xff]] {
            XCTAssertThrowsError(try OppoControlCapabilities(reply: .init(command: 0x8100, payload: bytes)))
        }
    }
    func testStrictExchangeCorrelationAndFormats() throws {
        let request = OppoControlPacket.controlMTUExchange
        XCTAssertEqual(request.payload, [0,2])
        let reply = try OppoControlPacket(command: 0x8101, sequence: request.sequence, payload: [0,0,2])
        XCTAssertEqual(try reply.successfulUInt16Reply(to: request), 512)
        XCTAssertThrowsError(try reply.successfulUInt16Reply(to: .controlVendorExchange))
        for bytes: [UInt8] in [[2,0,2],[0,2],[0,0,2,0]] {
            let malformed = try OppoControlPacket(command: 0x8101, sequence: request.sequence, payload: bytes)
            XCTAssertThrowsError(try malformed.successfulUInt16Reply(to: request))
        }
        XCTAssertEqual(OppoControlPacket.controlVendorExchange.payload, [0xff,0xff])
    }
    func testCodecSetterRequiresAdvertisedPathAndPreservesCodec() throws {
        let caps = try OppoControlCapabilities(reply: .init(command: 0x8100, payload: [0,0,0,2,0,0x20]))
        for codec: UInt8 in [3,8] {
            var transaction = try OppoHiResTransaction(capabilities: caps, currentCodec: codec, codecListMask: 0x84)
            let baseline = try OppoControlPacket(command: 0x810d, sequence: 0xf2, payload: [0,1,0x18,0])
            let request = try transaction.begin(after: baseline)
            XCTAssertEqual(request.command, 0x041a); XCTAssertEqual(request.payload, [codec,1,0])
            try transaction.markWriteAttempt(request)
            XCTAssertNil(transaction.receive(try .init(command: 0x8403, sequence: 0xf4, payload: [0])))
            XCTAssertEqual(transaction.receive(try .init(command: 0x841a, sequence: 0xf4, payload: [0])), .hiResQuery(sequence: 0xf5))
            XCTAssertEqual(transaction.report.preservedCodecID, codec)
            XCTAssertThrowsError(try transaction.markWriteAttempt(request))
        }
        for codec: UInt8? in [nil,0,1,2,7,9,255] {
            XCTAssertThrowsError(try OppoHiResTransaction(capabilities: caps, currentCodec: codec, codecListMask: 0xffff))
        }
        XCTAssertThrowsError(try OppoHiResTransaction(capabilities: caps, currentCodec: 8, codecListMask: 4))
        let noCaps = try OppoControlCapabilities(reply: .init(command: 0x8100, payload: [0,0]))
        XCTAssertThrowsError(try OppoHiResTransaction(capabilities: noCaps, currentCodec: 8, codecListMask: 0x80))
    }
    func testExplicitLHDCSelectionRequiresDeviceReportedCodec() throws {
        let caps = try OppoControlCapabilities(reply: .init(command: 0x8100, payload: [0,0,0,2,0,0x20]))
        let packet = try OppoControlPacket.codecHiResEnable(capabilities: caps, currentCodec: 2, codecListMask: 0x146, selectLHDC: true)
        XCTAssertEqual(packet.payload, [7,1,0])
        XCTAssertThrowsError(try OppoControlPacket.codecHiResEnable(capabilities: caps, currentCodec: 2, codecListMask: 6, selectLHDC: true))
        XCTAssertThrowsError(try OppoControlPacket.codecHiResEnable(capabilities: caps, currentCodec: 2, codecListMask: 0x146))
    }
}
