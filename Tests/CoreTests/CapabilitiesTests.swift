import XCTest
@testable import SonoFerryCore

final class CapabilitiesTests: XCTestCase {
    let ldac: [UInt8] = [0,255,0x2d,1,0,0,0xaa,0,0x3c,7]
    let lhdc: [UInt8] = [0,255,0x3a,5,0,0,0x35,0x4c,0x35,6,0x11,0,0]
    func testLDACDoesNotInventBitDepth() throws {
        let cap = try CapabilityParser.codec(endpoint: 1, bytes: ldac)
        XCTAssertEqual(cap.sampleRates, [44100,48000,88200,96000]); XCTAssertNil(cap.bitDepths)
        XCTAssertEqual(try cap.configuration().sampleRate, .hz48000)
        XCTAssertThrowsError(try cap.configuration(rate: 192000))
    }
    func testLHDCNegotiatesOnlyImplementedBits() throws {
        var bytes = lhdc; bytes[9] = 7
        let cap = try CapabilityParser.codec(endpoint: 4, bytes: bytes)
        XCTAssertEqual(cap.bitDepths, [16,24,32]); XCTAssertEqual(try cap.configuration().bits, 24)
        bytes[9] = 1
        XCTAssertFalse(try CapabilityParser.codec(endpoint: 4, bytes: bytes).playable)
    }
    func testNoSilentManualRateFallback() throws {
        var bytes = ldac; bytes[8] = 0x20
        let cap = try CapabilityParser.codec(endpoint: 2, bytes: bytes)
        XCTAssertEqual(try cap.configuration().sampleRate, .hz44100)
        XCTAssertThrowsError(try cap.configuration(rate: 48000))
    }
    func testMalformedCapabilityDoesNotBecomeSupport() {
        for length in 0..<ldac.count { XCTAssertThrowsError(try CapabilityParser.codec(endpoint: 1, bytes: Array(ldac.prefix(length)))) }
        XCTAssertThrowsError(try CapabilityParser.serviceCategories([7,10,0]))
        XCTAssertThrowsError(try CapabilityParser.serviceCategories([1,0,1,0]))
    }
    func testUnknownVendorPreserved() throws {
        var bytes = ldac; bytes[2] = 0
        let cap = try CapabilityParser.codec(endpoint: 1, bytes: bytes)
        XCTAssertNil(cap.codec); XCTAssertFalse(cap.playable); XCTAssertFalse(cap.rawHex.isEmpty)
    }
    func testFragmentsAndTransactionMismatch() throws {
        var parser = AVDTPReassembler()
        XCTAssertNil(try parser.accept([0x16,3,12,1,0]))
        XCTAssertNil(try parser.accept([0x1a,7,2]))
        XCTAssertEqual(try parser.accept([0x1e,0,255]), [0x12,12,1,0,7,2,0,255])
        XCTAssertNil(try parser.accept([0x16,2,12,1]))
        XCTAssertThrowsError(try parser.accept([0x2e,0]))
        XCTAssertEqual(try parser.accept([0x12,1]), [0x12,1])
    }
    func testCodecSpecificBitrates() throws {
        let low = try CapabilityParser.codec(endpoint: 1, bytes: ldac).configuration(rate: 44100, quality: .quality)
        XCTAssertEqual(low.bitrateKbps, 909)
        var limited = lhdc; limited[9] = 0x26
        let configuration = try CapabilityParser.codec(endpoint: 2, bytes: limited).configuration(quality: .quality)
        XCTAssertEqual(configuration.maximumBitrate, 500); XCTAssertEqual(configuration.bitrateKbps, 500)
    }
    func testManualLHDCBitrateHonorsCapabilityIntersection() throws {
        var bytes = lhdc; bytes[8] = 0x30; bytes[9] = 0x16
        let cap = try CapabilityParser.codec(endpoint: 3, bytes: bytes)
        XCTAssertEqual(cap.fixedBitrates(rate: 48000), [64,160,192,256,320,400])
        XCTAssertEqual(cap.fixedBitrates(rate: 44100), [64,160,192,240,320,400])
        let config = try cap.configuration(quality: .connection, fixedBitrate: 320)
        XCTAssertEqual(config.bitrateKbps, 320)
        XCTAssertEqual(Array(config.helperArguments.suffix(2)), ["--bitrate", "320"])
        XCTAssertThrowsError(try cap.configuration(quality: .connection, fixedBitrate: 500))
        XCTAssertThrowsError(try cap.configuration(quality: .connection, fixedBitrate: 240))
        XCTAssertThrowsError(try cap.configuration(quality: .adaptive, fixedBitrate: 320))
        XCTAssertThrowsError(try CapabilityParser.codec(endpoint: 1, bytes: ldac).configuration(quality: .quality, fixedBitrate: 990))
    }
    func testMetricsKeepOnlyFiniteNumericAllowList() {
        XCTAssertEqual(DiagnosticMetrics.parse("LIVE_PROGRESS sentPackets=32 elapsed=1.5 address=11:22:33:44:55:66 path=/Users/private sentBytes=nan late=-1 blocked=inf"), ["sentPackets":32,"elapsed":1.5])
        XCTAssertEqual(DiagnosticMetrics.parse("SENDER_WINDOW windowSeconds=1.002 windowPackets=198 encodeMaxMs=0.08 drainMaxMs=60.1 sessionDrainOver8ms=4 drainPendingMs=0 address=11:22:33:44:55:66 waitCalls=nan drainMeanMs=-2"), ["windowSeconds":1.002,"windowPackets":198,"encodeMaxMs":0.08,"drainMaxMs":60.1,"sessionDrainOver8ms":4,"drainPendingMs":0])
        XCTAssertTrue(DiagnosticMetrics.parse("UNTRUSTED sentPackets=99").isEmpty)
        XCTAssertEqual(DiagnosticMetrics.parse("PCM_RATE_CONVERSION input=44100 output=48000"), ["captureRate":44100,"pipelineRate":48000])
        XCTAssertEqual(DiagnosticMetrics.parse("FORMAT rate=96000 channels=2"), ["captureRate":96000])
    }
    func testObservedLHDCRestrictionAndHigherCapability() throws {
        let reported: [UInt8] = [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x16,0x11,0x40,0]
        let limited = try CapabilityParser.codec(endpoint: 3, bytes: reported)
        XCTAssertEqual(limited.sampleRates, [44100,48000]); XCTAssertEqual(limited.maximumBitrate,400)
        XCTAssertThrowsError(try limited.configuration(rate:96000))
        var unrestricted = reported; unrestricted[8] = 0x35; unrestricted[9] = 0x06
        let full = try CapabilityParser.codec(endpoint: 3, bytes: unrestricted)
        XCTAssertEqual(full.sampleRates,[44100,48000,96000,192000]); XCTAssertEqual(full.maximumBitrate,1000)
        XCTAssertEqual(try full.configuration(rate:192000,quality:.quality,fixedBitrate:1000).bitrateKbps,1000)
    }
    func testExplicitForcedLHDCParametersAndAutomaticDefaults() throws {
        let reported: [UInt8] = [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x16,0x11,0x40,0]
        let cap = try CapabilityParser.codec(endpoint: 3, bytes: reported)
        let automatic = try cap.configuration(allowUnreported: true)
        XCTAssertEqual(automatic.sampleRate, .hz48000)
        XCTAssertEqual(automatic.maximumBitrate, 400)
        XCTAssertFalse(automatic.isForced)
        for rate in [96000,192000] {
            for bitrate in [500,900,1000] {
                let config = try cap.configuration(rate: rate, quality: .connection, fixedBitrate: bitrate, allowUnreported: true)
                XCTAssertTrue(config.isForced)
                XCTAssertEqual(config.sampleRate.rawValue, rate)
                XCTAssertEqual(config.bitrateKbps, bitrate)
                XCTAssertEqual(config.maximumBitrate, bitrate)
                XCTAssertEqual(config.signalingArguments.suffix(2), ["--force-sample-rate", "--force-bitrate"])
                XCTAssertFalse(config.helperArguments.contains("--force-bitrate"))
            }
        }
        let rateOnly = try cap.configuration(rate: 96000, allowUnreported: true)
        XCTAssertEqual(rateOnly.forceSampleRate, true); XCTAssertNil(rateOnly.forceBitrate)
        XCTAssertEqual(rateOnly.maximumBitrate, 400)
        let bitrateOnly = try cap.configuration(rate: 44100, quality: .connection, fixedBitrate: 480, allowUnreported: true)
        XCTAssertNil(bitrateOnly.forceSampleRate); XCTAssertEqual(bitrateOnly.forceBitrate, true)
        XCTAssertEqual(bitrateOnly.maximumBitrate, 500); XCTAssertEqual(bitrateOnly.bitrateKbps, 480)
        // The reported evidence remains intact even after generating forced configurations.
        XCTAssertEqual(cap.sampleRates, [44100,48000]); XCTAssertEqual(cap.maximumBitrate, 400)
        XCTAssertEqual(try cap.configuration(rate: 48000, quality: .connection, fixedBitrate: 400, allowUnreported: true).isForced, false)
        XCTAssertThrowsError(try cap.configuration(rate: 88200, allowUnreported: true))
        XCTAssertThrowsError(try cap.configuration(quality: .connection, fixedBitrate: 1100, allowUnreported: true))
        XCTAssertThrowsError(try cap.configuration(fixedBitrate: 1000, allowUnreported: true))
        XCTAssertThrowsError(try cap.configuration(rate: 96000))
    }
    func testForcedLDACStillNeedsAdvertisedCodecAndStereo() throws {
        var bytes = ldac; bytes[8] = 0x10
        let cap = try CapabilityParser.codec(endpoint: 1, bytes: bytes)
        let config = try cap.configuration(rate: 96000, allowUnreported: true)
        XCTAssertEqual(config.forceSampleRate, true); XCTAssertNil(config.forceBitrate)
        XCTAssertThrowsError(try cap.configuration(rate: 192000, allowUnreported: true))
        bytes[9] = 0
        XCTAssertThrowsError(try CapabilityParser.codec(endpoint: 1, bytes: bytes).configuration(rate: 96000, allowUnreported: true))
    }
    func testForcedWireCompatibilityAndValidation() throws {
        let old = Data(#"{"codec":"lhdcV5","sampleRate":48000,"quality":"auto","bits":24,"endpoint":3,"minimumBitrate":64,"maximumBitrate":400,"probeOnly":false}"#.utf8)
        var config = try JSONDecoder().decode(PlaybackConfiguration.self, from: old)
        XCTAssertFalse(config.isForced); try config.validate()
        config.forceBitrate = true
        XCTAssertThrowsError(try config.validate())
        config.forceBitrate = nil; config.forceSampleRate = true; config.endpoint = 0
        XCTAssertThrowsError(try config.validate())
        config.endpoint = 3; config.probeOnly = true
        XCTAssertThrowsError(try config.validate())
        config.probeOnly = false; config.sampleRate = .hz192000
        try config.validate()
        XCTAssertEqual(try JSONDecoder().decode(PlaybackConfiguration.self, from: JSONEncoder().encode(config)), config)
    }
    func testBufferingDefaultsAndWireCompatibility() throws {
        let old = Data(#"{"codec":"ldac","sampleRate":48000,"quality":"auto","bits":24,"endpoint":1,"minimumBitrate":64,"maximumBitrate":1000,"probeOnly":false}"#.utf8)
        var config = try JSONDecoder().decode(PlaybackConfiguration.self, from: old)
        XCTAssertEqual(config.bufferingSettings, BufferingConfiguration())
        XCTAssertEqual(config.mediaArguments.suffix(4), ["--catchup-limit-ms", "5000", "--prefill-ms", "250"])
        config.buffering = .init(catchupLimitTenths: 150, prefillMilliseconds: 1000)
        try config.validate()
        XCTAssertEqual(try JSONDecoder().decode(PlaybackConfiguration.self, from: JSONEncoder().encode(config)), config)
        XCTAssertEqual(config.mediaArguments.suffix(4), ["--catchup-limit-ms", "15000", "--prefill-ms", "1000"])
        XCTAssertFalse(config.signalingArguments.contains("--prefill-ms"))
        XCTAssertEqual(DiagnosticMetrics.parse("LIVE_PROGRESS catchupSeconds=4.9"), ["catchupSeconds": 4.9])
    }
    func testBufferingRangesAndStorage() throws {
        for time in [1, 50, 150] {
            for prefill in [10, 250, 1000] {
                let settings = BufferingConfiguration(catchupLimitTenths: time, prefillMilliseconds: prefill)
                try settings.validate()
                for rate in [44100, 48000, 88200, 96000, 192000] {
                    let target = Double(rate) * Double(prefill) / 1000
                    XCTAssertEqual(settings.prefillFrames(rate: rate), Int(ceil(target)))
                    XCTAssertEqual(settings.storageFrames(rate: rate) % 128, 0)
                    XCTAssertGreaterThanOrEqual(settings.storageFrames(rate: rate), Int(ceil(Double(rate) * (Double(prefill) / 1000 + Double(time) / 10 + 1))))
                    XCTAssertLessThanOrEqual(settings.storageFrames(rate: rate) * 8, 27_648_000)
                }
            }
        }
        for settings in [BufferingConfiguration(catchupLimitTenths: 0), .init(catchupLimitTenths: 151), .init(prefillMilliseconds: 9), .init(prefillMilliseconds: 1001)] {
            var config = PlaybackConfiguration(); config.buffering = settings
            XCTAssertThrowsError(try config.validate())
        }
    }
    func testReconfigurationAndBitDepthSources() throws {
        var current = PlaybackConfiguration()
        var next = current
        next.buffering = .init(catchupLimitTenths: 1, prefillMilliseconds: 10)
        XCTAssertFalse(next.requiresReconnect(from: current))
        XCTAssertEqual(next.bufferingSettings.storageFrames(rate: 192000), current.bufferingSettings.storageFrames(rate: 192000))
        next.sampleRate = .hz88200
        XCTAssertTrue(next.requiresReconnect(from: current))
        XCTAssertEqual(current.encoderInputDescription, "Float32 PCM")
        XCTAssertTrue(current.negotiatedBitDepthDescription.contains("不可查询"))
        current.codec = .lhdcV5; current.bits = 16
        XCTAssertEqual(current.encoderInputDescription, "16-bit 整数 PCM")
        XCTAssertEqual(current.negotiatedBitDepthDescription, "16-bit")
        current.bits = 24
        XCTAssertEqual(current.negotiatedBitDepthDescription, "24-bit")
        XCTAssertTrue(CodecID.ldac.sampleRates.contains(88200))
        XCTAssertFalse(CodecID.ldac.sampleRates.contains(176400))
        XCTAssertFalse(CodecID.lhdcV5.sampleRates.contains(88200))
        XCTAssertFalse(CodecID.lhdcV5.sampleRates.contains(176400))
        XCTAssertTrue(CodecID.lhdcV5.fixedBitrates(rate: 48000).filter { $0 > 500 && $0 < 900 }.isEmpty)
    }
    func testSystemRateChangeKeepsQualityAndCapabilityEvidence() throws {
        var reported = lhdc; reported[8] = 0x30; reported[9] = 0x16
        let cap = try CapabilityParser.codec(endpoint: 3, bytes: reported)
        var current = try cap.configuration(rate: 48000, quality: .connection, fixedBitrate: 500, allowUnreported: true)
        current.buffering = .init(catchupLimitTenths: 70, prefillMilliseconds: 320)
        let at441 = try cap.changingSampleRate(to: 44100, from: current)
        XCTAssertEqual(at441.fixedBitrateKbps, 480); XCTAssertEqual(at441.buffering, current.buffering)
        XCTAssertEqual(at441.quality, .connection); XCTAssertTrue(at441.forceBitrate == true)
        let at96 = try cap.changingSampleRate(to: 96000, from: at441)
        XCTAssertEqual(at96.fixedBitrateKbps, 500); XCTAssertTrue(at96.forceSampleRate == true)
        XCTAssertEqual(cap.sampleRates, [44100,48000])
        XCTAssertThrowsError(try cap.changingSampleRate(to: 88200, from: current))
        XCTAssertThrowsError(try cap.changingSampleRate(to: 176400, from: current))
        current.endpoint = 4
        XCTAssertThrowsError(try cap.changingSampleRate(to: 48000, from: current))
        let sony = try CapabilityParser.codec(endpoint: 1, bytes: ldac)
        let ldacConfig = try sony.configuration(quality: .balanced)
        XCTAssertEqual(try sony.changingSampleRate(to: 88200, from: ldacConfig).quality, .balanced)
        XCTAssertThrowsError(try sony.changingSampleRate(to: 192000, from: ldacConfig))
    }
}
