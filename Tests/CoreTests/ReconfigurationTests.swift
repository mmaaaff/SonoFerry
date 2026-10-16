import XCTest
@testable import SonoFerryCore
final class ReconfigurationTests: XCTestCase {
    func testExplicitSameSessionParametersOnly() throws {
        let id = UUID(), device = BluetoothDevice(address: "00:11:22:33:44:55", name: "Fixture", connected: true, a2dpSink: true)
        let current = PlaybackConfiguration()
        var next = current; next.sampleRate = .hz96000
        var request = WireMessage("stop", sessionID: id)
        request.stopIntent = .reconfigure; request.device = device; request.configuration = next
        func allowed(_ r: WireMessage, active: Bool = true) -> Bool {
            AudioStopIntent.permits(r, currentID: id, address: device.address, configuration: current, active: active)
        }
        XCTAssertTrue(allowed(request))
        XCTAssertFalse(allowed(request, active: false))
        var r = request; r.sessionID = UUID(); XCTAssertFalse(allowed(r))
        r = request; r.sessionID = nil; XCTAssertFalse(allowed(r))
        r = request; r.device = nil; XCTAssertFalse(allowed(r))
        r = request; r.kind = "start"; XCTAssertFalse(allowed(r))
        r = request; r.stopIntent = nil; XCTAssertFalse(allowed(r))
        r = request; r.configuration = nil; XCTAssertFalse(allowed(r))
        r = request; r.configuration = current; XCTAssertFalse(allowed(r))
        r = request; r.configuration?.probeOnly = true; XCTAssertFalse(allowed(r))
        r = request; r.configuration?.codec = .lhdcV5; XCTAssertFalse(allowed(r))
        r = request; r.configuration?.buffering = .init(catchupLimitTenths: 0, prefillMilliseconds: 250); XCTAssertFalse(allowed(r))
        r = request; r.linkHardwareVolume = true; XCTAssertFalse(allowed(r))
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(WireMessage.self, from: encoded).stopIntent, .reconfigure)
        XCTAssertNil(try JSONDecoder().decode(WireMessage.self, from: Data("{\"version\":1,\"kind\":\"stop\"}".utf8)).stopIntent)
    }
}
