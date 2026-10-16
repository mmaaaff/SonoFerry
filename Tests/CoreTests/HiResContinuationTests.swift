import XCTest
@testable import SonoFerryCore

final class HiResContinuationTests: XCTestCase {
    private func cap(_ hires: Bool) throws -> CodecCapabilities {
        try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,hires ? 0x35 : 0x30,hires ? 0x06 : 0x16,0x11,0x40,0])
    }
    func testSupportedParametersAndBuffersSurvive() throws {
        let full = try cap(true)
        var old = try full.configuration(rate: 96000, quality: .connection, fixedBitrate: 900)
        old.buffering = .init(catchupLimitTenths: 80, prefillMilliseconds: 333)
        XCTAssertEqual(try full.supportedContinuation(from: old), old)
        let low = try full.configuration(rate: 44100, quality: .connection, fixedBitrate: 320)
        let continued = try cap(false).supportedContinuation(from: low)
        XCTAssertEqual(continued.sampleRate, .hz44100)
        XCTAssertEqual(continued.fixedBitrateKbps, 320)
        XCTAssertFalse(continued.isForced)
    }
    func testHiResOffDropsOnlyUnsupportedSelectionsWithoutForce() throws {
        let full = try cap(true), off = try cap(false)
        let old = try full.configuration(rate: 96000, quality: .connection, fixedBitrate: 900)
        let next = try off.supportedContinuation(from: old)
        XCTAssertEqual(next.sampleRate, .hz48000)
        XCTAssertEqual(next.quality, .adaptive)
        XCTAssertNil(next.fixedBitrateKbps)
        XCTAssertEqual(next.maximumBitrate, 400)
        XCTAssertFalse(next.isForced)
        let safeBitrate = try full.configuration(rate: 192000, quality: .connection, fixedBitrate: 320)
        XCTAssertEqual(try off.supportedContinuation(from: safeBitrate).fixedBitrateKbps, 320)
    }
    func testOtherCodecCannotResumeOriginalConnection() throws {
        let previous = try cap(true).configuration()
        let ldac = try CapabilityParser.codec(endpoint: 1, bytes: [0,255,0x2d,1,0,0,0xaa,0,0x3c,7])
        XCTAssertThrowsError(try ldac.supportedContinuation(from: previous))
    }
    func testRecoveryMetadataIsOptionalAndCorrelatedOnWire() throws {
        let old = try JSONDecoder().decode(WireMessage.self, from: Data(#"{"version":1,"kind":"failed","message":"MTU"}"#.utf8))
        XCTAssertNil(old.playbackFailure)
        XCTAssertNil(old.restartSafe)
        var failed = WireMessage("failed", sessionID: UUID())
        failed.playbackFailure = .mediaMTU; failed.restartSafe = false
        let decoded = try JSONDecoder().decode(WireMessage.self, from: JSONEncoder().encode(failed))
        XCTAssertEqual(decoded.sessionID, failed.sessionID)
        XCTAssertEqual(decoded.playbackFailure, .mediaMTU)
        XCTAssertEqual(decoded.restartSafe, false)
    }

}
