import XCTest
@testable import SonoFerryCore

final class StartupHealthTests: XCTestCase {
    var good: [String: String] { ["halInstalled":"true", "halSignatureValid":"true", "engineCDHash":"new", "installedEngineCDHash":"new", "loadedEngineCDHash":"new", "driverRevision":"7", "bluetoothAuthorization":"3", "audioCapture":"granted"] }
    func testIndependentProblemsAndRestartRequiresMatchedDisk() {
        XCTAssertTrue(StartupHealth.issues(good).isEmpty)
        var state = good; state["bluetoothAuthorization"] = "0"; state["audioCapture"] = "denied"; state["loadedEngineCDHash"] = "old"
        XCTAssertEqual(StartupHealth.issues(state).map(\.action), [.bluetooth, .audioCapture, .restart])
        state["installedEngineCDHash"] = "old"
        XCTAssertNil(StartupHealth.issues(state).last?.action, "disk mismatch requires install; restart cannot fix it")
    }
    func testMissingInvalidAndUnknownAreDistinct() {
        var state = good; state["halInstalled"] = "false"
        XCTAssertTrue(StartupHealth.issues(state).last!.message.contains("未安装"))
        XCTAssertNil(StartupHealth.issues(state).last!.action)
        state = good; state["halSignatureValid"] = "false"
        XCTAssertTrue(StartupHealth.issues(state).last!.message.contains("签名"))
        state = good; state["driverQueryError"] = "failed"
        XCTAssertEqual(StartupHealth.issues(state).last!.action, .recheck)
        state = good; state.removeValue(forKey: "engineCDHash")
        XCTAssertEqual(StartupHealth.issues(state).last!.action, .recheck)
    }
    func testLegacyAndUnloadedDriverRequireReload() {
        for revision in ["not-loaded", "6"] {
            var state = good; state["driverRevision"] = revision; state.removeValue(forKey: "loadedEngineCDHash")
            XCTAssertEqual(StartupHealth.issues(state).map(\.action), [.restart])
        }
    }
    func testUnknownPermissionsCannotBecomeSuccess() {
        var state = good; state["bluetoothAuthorization"] = "1"; state["audioCapture"] = "unavailable"
        XCTAssertEqual(StartupHealth.issues(state).count, 2)
        XCTAssertNil(StartupHealth.issues(state)[0].action)
        XCTAssertEqual(StartupHealth.issues(state)[1].action, .audioSettings)
        state = ["healthError":"timeout", "audioCapture":"notDetermined"]
        XCTAssertEqual(StartupHealth.issues(state).map(\.action), [.recheck, .audioCapture])
    }
}
