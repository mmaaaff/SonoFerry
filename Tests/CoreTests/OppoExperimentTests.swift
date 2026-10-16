import XCTest
@testable import SonoFerryCore

final class OppoExperimentTests: XCTestCase {
    func testVerifiedWriteRequiresMatchingReadbackForBothDirections() throws {
        for enabled in [false, true] {
            var transaction = OppoHiResTransaction(enabled: enabled)
            let packet = try transaction.begin(after: baseline(enabled ? 0 : 1))
            XCTAssertEqual(packet.payload, [0x18, enabled ? 1 : 0])
            try transaction.markWriteAttempt(packet); transaction.recordWriteSubmission(0)
            _ = transaction.receive(try .init(command: 0x8403, sequence: 0xf4, payload: [0]))
            XCTAssertFalse(transaction.report.verified)
            _ = transaction.receive(try baseline(enabled ? 1 : 0, sequence: 0xf5))
            XCTAssertTrue(transaction.report.verified)
        }
    }
    func testHiResAvailabilityRequiresHDCodecAndCurrentState() throws {
        var report = OppoProbeReport()
        report.controlCapabilities = try .init(reply: .init(command: 0x8100, payload: [0,0x80]))
        report.hiRes = false
        for codec: UInt8 in [0,1,2,7,9,255] {
            report.currentCodecID = codec; XCTAssertFalse(report.canSetHiRes)
        }
        report.currentCodecID = 8; XCTAssertTrue(report.canSetHiRes)
        report.hiRes = nil; XCTAssertFalse(report.canSetHiRes)
    }
    private func baseline(_ value: UInt8 = 0, sequence: UInt8 = 0xf2) throws -> OppoControlPacket {
        try OppoControlPacket(command: 0x810d, sequence: sequence, payload: [0,1,0x18,value])
    }
    func testWriteRequiresCurrentWellFormedBaselineAndCannotRepeat() throws {
        var transaction = OppoHiResTransaction()
        XCTAssertThrowsError(try transaction.begin(after: baseline(sequence: 0xf1)))
        XCTAssertThrowsError(try transaction.begin(after: baseline(2)))
        XCTAssertEqual(transaction.report.writeAttempts, 0)
        let request = try transaction.begin(after: baseline())
        XCTAssertEqual(request.bytes, [0xaa,9,0,0,3,4,0xf4,2,0,0x18,1])
        XCTAssertThrowsError(try transaction.begin(after: baseline()))
        XCTAssertThrowsError(try transaction.markWriteAttempt(.hiResSet(false, sequence: 0xf4)))
        XCTAssertEqual(transaction.report.writeAttempts, 0)
        try transaction.markWriteAttempt(request)
        XCTAssertThrowsError(try transaction.markWriteAttempt(request))
        XCTAssertEqual(transaction.report.writeAttempts, 1)
    }
    func testACKIsNotStateAndDuplicateOrStaleRepliesDoNotAdvance() throws {
        var transaction = OppoHiResTransaction()
        let request = try transaction.begin(after: baseline())
        let ack = try OppoControlPacket(command: 0x8403, sequence: 0xf4, payload: [0])
        XCTAssertNil(transaction.receive(ack)) // Not submitted yet.
        try transaction.markWriteAttempt(request); transaction.recordWriteSubmission(0)
        XCTAssertNil(transaction.receive(try OppoControlPacket(command: 0x8403, sequence: 0xf0, payload: [0])))
        XCTAssertNil(transaction.receive(try baseline(1, sequence: 0xf5))) // Before ACK.
        XCTAssertEqual(transaction.receive(ack), OppoHiResTransaction.readbackQuery)
        XCTAssertEqual(transaction.report.acknowledgementCode, 0)
        XCTAssertNil(transaction.report.readbackCandidate)
        XCTAssertNil(transaction.receive(ack)) // No second query or write.
        XCTAssertNil(transaction.receive(try baseline(1))) // Old baseline sequence.
        XCTAssertFalse(transaction.finished)
        XCTAssertNil(transaction.receive(try baseline(1, sequence: 0xf5)))
        XCTAssertTrue(transaction.finished)
        XCTAssertEqual(transaction.report.readbackCandidate, 1)
        var report = OppoProbeReport(); report.experiment = transaction.report
        XCTAssertNil(report.hiRes) // Transport promotes state only after verifying context.
        XCTAssertTrue(transaction.report.verified)
        XCTAssertEqual(try JSONDecoder().decode(OppoProbeReport.self, from: JSONEncoder().encode(report)), report)
    }
    func testNonzeroAndUnknownACKsOnlyTriggerReadbackNotAnotherWrite() throws {
        for payload: [UInt8] in [[2], [], [0,0x18,1]] {
            var transaction = OppoHiResTransaction()
            let request = try transaction.begin(after: baseline())
            try transaction.markWriteAttempt(request); transaction.recordWriteSubmission(0)
            let ack = try OppoControlPacket(command: 0x8403, sequence: 0xf4, payload: payload)
            XCTAssertEqual(transaction.receive(ack), OppoHiResTransaction.readbackQuery)
            XCTAssertEqual(transaction.report.acknowledgementCode, payload.count == 1 ? payload[0] : nil)
            _ = transaction.receive(try baseline(sequence: 0xf5))
            XCTAssertEqual(transaction.report.readbackCandidate, 0)
            XCTAssertEqual(transaction.report.writeAttempts, 1)
        }
    }
    func testDisconnectOrTimeoutDoesNotRetryOrInventReadback() throws {
        for reason in ["disconnected", "timeout", "cancelled", "write failed"] {
            var transaction = OppoHiResTransaction()
            let request = try transaction.begin(after: baseline())
            try transaction.markWriteAttempt(request)
            transaction.interrupt(reason)
            XCTAssertTrue(transaction.finished)
            XCTAssertNil(transaction.receive(try OppoControlPacket(command: 0x8403, sequence: 0xf4, payload: [0])))
            XCTAssertNil(transaction.receive(try baseline(1, sequence: 0xf5)))
            XCTAssertThrowsError(try transaction.begin(after: baseline()))
            XCTAssertNil(transaction.report.readbackCandidate)
            XCTAssertEqual(transaction.report.terminationReason, reason)
            XCTAssertEqual(transaction.report.writeAttempts, 1)
        }
    }
    func testMalformedReadbackRemainsUnknown() throws {
        var transaction = OppoHiResTransaction()
        let request = try transaction.begin(after: baseline())
        try transaction.markWriteAttempt(request)
        _ = transaction.receive(try OppoControlPacket(command: 0x8403, sequence: 0xf4, payload: [0]))
        _ = transaction.receive(try baseline(2, sequence: 0xf5))
        XCTAssertTrue(transaction.finished)
        XCTAssertNotNil(transaction.report.readbackHex)
        XCTAssertNil(transaction.report.readbackCandidate)
    }
    func testCapturedX4EnableReplyAndUnchangedReadback() throws {
        // Actual 2026-10-11 X4 experiment: host queued the write successfully,
        // peer returned 02, then feature 18 remained 00. No confirmed activation.
        let ack: [UInt8] = [0xaa,8,0,0,3,0x84,0xf4,1,0,2]
        let readback: [UInt8] = [0xaa,0x0b,0,0,0x0d,0x81,0xf5,4,0,0,1,0x18,0]
        var framer = OppoControlFramer()
        let replies = try framer.accept(ack + readback)
        var transaction = OppoHiResTransaction()
        let request = try transaction.begin(after: baseline())
        try transaction.markWriteAttempt(request); transaction.recordWriteSubmission(0)
        XCTAssertEqual(transaction.receive(replies[0]), OppoHiResTransaction.readbackQuery)
        XCTAssertNil(transaction.receive(replies[1]))
        XCTAssertEqual(transaction.report.writeSubmissionStatus, 0)
        XCTAssertEqual(transaction.report.acknowledgementCode, 2)
        XCTAssertEqual(transaction.report.baselineCandidate, 0)
        XCTAssertEqual(transaction.report.readbackCandidate, 0)
        XCTAssertEqual(transaction.report.writeAttempts, 1)
        XCTAssertTrue(transaction.finished)
    }
}
