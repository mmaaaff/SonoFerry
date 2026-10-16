import Foundation
import SonoFerryCore
import CoreBluetooth
import Security

/// Runs in a short-lived, externally timed subprocess; never acquires a HAL lease or opens Bluetooth.
@MainActor enum StartupDiagnostics {
    static func read() -> [String: String] {
        var values = ["bluetoothAuthorization": String(CBManager.authorization.rawValue)]
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data {
            values["engineCDHash"] = hash.map { String(format: "%02x", $0) }.joined()
        }
        let driver = URL(fileURLWithPath: RuntimeIdentity.driverPath, isDirectory: true)
        values["halInstalled"] = String(FileManager.default.fileExists(atPath: driver.path))
        if values["halInstalled"] == "true" {
            if let data = try? Data(contentsOf: driver.appendingPathComponent("Contents/Info.plist")),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                values["installedEngineCDHash"] = plist[RuntimeIdentity.engineHashKey] as? String
            }
            var installed: SecStaticCode?
            values["halSignatureValid"] = String(SecStaticCodeCreateWithPath(driver as CFURL, [], &installed) == errSecSuccess &&
                installed.map { SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess } == true)
        }
        do {
            values["driverRevision"] = try LDACNativeOutput.driverRevision().map(String.init) ?? "not-loaded"
            values["loadedEngineCDHash"] = try LDACNativeOutput.loadedEngineIdentity()
        } catch { values["driverQueryError"] = error.localizedDescription }
        return values
    }
}
