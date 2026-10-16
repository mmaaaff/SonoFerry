import XCTest
@testable import SonoFerryCore

final class OppoControlTests: XCTestCase {
    func testPublicCommandVectors() {
        XCTAssertEqual(OppoControlPacket.hiResSet(true).bytes, [0xaa,9,0,0,3,4,0xf0,2,0,0x18,1])
        XCTAssertEqual(OppoControlPacket.hiResSet(false).bytes, [0xaa,9,0,0,3,4,0xf0,2,0,0x18,0])
        XCTAssertEqual(OppoControlPacket.hiResQuery().bytes, [0xaa,9,0,0,0x0d,1,0xf0,2,0,1,0x18])
        XCTAssertEqual(OppoControlPacket.referenceBatchQuery().bytes,
            [0xaa,0x13,0,0,0x0d,1,0xf3,0x0c,0,0x0b,5,4,0x0b,0x11,0x13,0x18,6,0x1b,0x1c,0x27,0x28])
    }
    func testEverySplitAndCoalescedFrames() throws {
        let a = try OppoControlPacket(command: 0x810d, payload: [0,1,0x18,1])
        let b = try OppoControlPacket(command: 0x0204, payload: [0xaa,0,1,2])
        let bytes = a.bytes + b.bytes
        for split in 0...bytes.count {
            var framer = OppoControlFramer()
            let first = try framer.accept(Array(bytes.prefix(split)))
            let second = try framer.accept(Array(bytes.dropFirst(split)))
            XCTAssertEqual(first + second, [a,b]); try framer.finish()
        }
        var framer = OppoControlFramer(); var packets: [OppoControlPacket] = []
        for byte in bytes { packets += try framer.accept([byte]) }
        XCTAssertEqual(packets, [a,b])
    }
    func testCorruptionFailsClosedAndDoesNotResynchronizeOnPayload() throws {
        for bytes: [UInt8] in [[0], [0xaa,6,0,0], [0xaa,7,4,0], [0xaa,7,0,0,0,0,0,1,0], [0xaa,7,0,0,0,0,0,0,1]] {
            var framer = OppoControlFramer()
            XCTAssertThrowsError(try framer.accept(bytes))
            XCTAssertThrowsError(try framer.accept(OppoControlPacket.hiResQuery().bytes))
        }
        var partial = OppoControlFramer(); _ = try partial.accept([0xaa,9,0,0])
        XCTAssertEqual(partial.bufferedBytes, 4); XCTAssertThrowsError(try partial.finish())
    }
    func testBoundedFramesAndStrictNotificationReply() throws {
        XCTAssertThrowsError(try OppoControlPacket(command: 1, payload: Array(repeating: 0, count: 4097)))
        let packet = try OppoControlPacket(command: 1, payload: Array(repeating: 0xaa, count: 248))
        var framer = OppoControlFramer()
        XCTAssertEqual(try framer.accept(packet.bytes), [packet]); XCTAssertEqual(framer.bufferedBytes, 0)
        XCTAssertEqual(try OppoControlPacket(command: 0x8200, payload: [0,2,4,5]).notificationIDs(), [4,5])
        for bytes: [UInt8] in [[], [0], [1,0], [0,2,4], [0,1,4,5], [0,2,4,4]] {
            XCTAssertThrowsError(try OppoControlPacket(command: 0x8200, payload: bytes).notificationIDs())
        }
    }
    func testUnverifiedStatusNeverBecomesFeatureSupport() throws {
        // A payload containing 18 01 alone is not evidence of a supported HiRes field.
        var report = OppoProbeReport()
        report.statusReplyHex = try OppoControlPacket(command: 0x810d, payload: [0,0x18,1]).hex
        XCTAssertNil(report.hiRes)
        XCTAssertEqual(try JSONDecoder().decode(OppoProbeReport.self, from: JSONEncoder().encode(report)), report)
    }
    func testReplyNeedsMatchingCommandAndSequence() throws {
        let request = OppoControlPacket.hiResQuery(sequence: 0xf1)
        XCTAssertTrue(try OppoControlPacket(command: 0x810d, sequence: 0xf1).isReply(to: request))
        XCTAssertFalse(try OppoControlPacket(command: 0x810d, sequence: 0xf0).isReply(to: request))
        XCTAssertFalse(try OppoControlPacket(command: 0x8200, sequence: 0xf1).isReply(to: request))
        XCTAssertFalse(try OppoControlPacket(command: 0x010d, sequence: 0xf1).isReply(to: request))
    }
    func testCapturedX4RepliesAndStrictSingleFeatureEnvelope() throws {
        // Captured 2026-10-11, SDP ELNK channel 15. Phone toggle meaning not verified.
        let notification: [UInt8] = [0xaa,0x12,0,0,0,0x82,0xf0,0x0b,0,0,9,1,2,3,4,8,0x0b,0xf1,0xf2,0xf3]
        let status: [UInt8] = [0xaa,0x0b,0,0,0x0d,0x81,0xf1,4,0,0,1,0x18,0]
        var framer = OppoControlFramer()
        let packets = try framer.accept(notification + status)
        XCTAssertEqual(try packets[0].notificationIDs(), [1,2,3,4,8,11,241,242,243])
        XCTAssertEqual(try packets[1].hiResCandidateValue(), 0)
        // Synthetic counterpart and malformed/ambiguous envelopes, not live on-state fixtures.
        XCTAssertEqual(try OppoControlPacket(command: 0x810d, payload: [0,1,0x18,1]).hiResCandidateValue(), 1)
        for bytes: [UInt8] in [[0,0x18,1], [1,1,0x18,1], [0,2,0x18,1], [0,1,0x28,1], [0,1,0x18,2], [0,1,0x18,1,0]] {
            XCTAssertThrowsError(try OppoControlPacket(command: 0x810d, payload: bytes).hiResCandidateValue())
        }
        var report = OppoProbeReport(); report.hiResCandidate = try packets[1].hiResCandidateValue()
        XCTAssertNil(report.hiRes)
    }
    func testCapturedPartialNotificationRegistration() throws {
        let ids: [UInt8] = [1,2,3,4,8,0x0b,0xf1,0xf2,0xf3]
        let request = try OppoControlPacket.notificationRegistration(ids)
        let payload: [UInt8] = [0,9,1,0,2,0,3,0,4,2,8,2,0x0b,2,0xf1,0,0xf2,0,0xf3,2]
        let packet = try OppoControlPacket(command: 0x8205, sequence: 0xf1, payload: payload)
        XCTAssertEqual(request.payload, [9] + ids)
        let results = try packet.notificationRegistrationResults(for: request)
        XCTAssertEqual(results.map(\.id), ids)
        XCTAssertEqual(results.map(\.result), [0,0,0,2,2,2,0,0,2])
        var report = OppoProbeReport(); report.notificationRegistration = results
        XCTAssertNil(report.hiRes)
        XCTAssertEqual(try JSONDecoder().decode(OppoProbeReport.self, from: JSONEncoder().encode(report)), report)
        var wrongID = payload; wrongID[2] = 0x18
        var duplicateID = payload; duplicateID[4] = 1
        let malformed: [[UInt8]] = [[], [0], [1] + Array(payload.dropFirst()), [0,8] + Array(payload.dropFirst(2)),
                                   Array(payload.dropLast()), payload + [0], wrongID, duplicateID]
        for bytes in malformed {
            XCTAssertThrowsError(try OppoControlPacket(command: 0x8205, sequence: 0xf1, payload: bytes)
                .notificationRegistrationResults(for: request))
        }
        XCTAssertThrowsError(try OppoControlPacket(command: 0x8205, sequence: 0xf0, payload: payload)
            .notificationRegistrationResults(for: request))
        XCTAssertThrowsError(try OppoControlPacket.notificationRegistration([1,1]))
    }
    func testCapturedBatchIsNotParsedByScanningForHiResID() throws {
        // Captured with phone HiRes reported enabled, then phone disconnected.
        let bytes: [UInt8] = [0xaa,0x1b,0,0,0x0d,0x81,0xf3,0x14,0,
            0,9,5,1,4,0,0x0b,1,0x11,0,0x13,1,0x18,0,6,1,0x27,1,0x28,0]
        var framer = OppoControlFramer()
        let packet = try XCTUnwrap(framer.accept(bytes).first)
        XCTAssertTrue(packet.isReply(to: .referenceBatchQuery()))
        XCTAssertThrowsError(try packet.hiResCandidateValue())
        var report = OppoProbeReport(); report.batchReplyHex = packet.hex
        XCTAssertNil(report.hiRes); XCTAssertNil(report.hiResCandidate)
    }
}
