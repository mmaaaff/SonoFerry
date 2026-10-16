import Foundation

public struct StartupIssue: Equatable, Identifiable, Sendable {
    public enum Action: String, Sendable { case bluetooth, audioCapture, audioSettings, restart, recheck }
    public let id: String
    public let message: String
    public let action: Action?
    public init(_ id: String, _ message: String, _ action: Action? = nil) {
        self.id = id; self.message = message; self.action = action
    }
}
/// Read-only observations. These warnings never authorize, probe, claim a lease or retry playback.
public enum StartupHealth {
    public static func issues(_ values: [String: String]) -> [StartupIssue] {
        var issues: [StartupIssue] = []
        if let error = values["healthError"] { issues.append(.init("health", error, .recheck)) }
        switch values["bluetoothAuthorization"] {
        case "0": issues.append(.init("bluetooth", "蓝牙权限尚未授权", .bluetooth))
        case "1": issues.append(.init("bluetooth", "蓝牙权限受系统限制，请检查系统管理策略"))
        case "2": issues.append(.init("bluetooth", "蓝牙权限未获允许", .bluetooth))
        case "3", nil: break
        default: issues.append(.init("bluetooth", "蓝牙权限状态未能确认", .recheck))
        }
        switch values["audioCapture"] {
        case "granted", nil: break
        case "denied": issues.append(.init("audio", "系统音频录制权限未获允许", .audioCapture))
        case "notDetermined": issues.append(.init("audio", "系统音频录制权限尚未授权", .audioCapture))
        default: issues.append(.init("audio", "系统音频录制权限未能确认，请检查系统设置", .audioSettings))
        }
        if values["halInstalled"] == "false" {
            issues.append(.init("hal", "未安装 HAL 音频驱动，请安装当前版本的完整安装包并重启 Mac"))
        } else if values["halInstalled"] == "true" {
            if values["halSignatureValid"] == "false" {
                issues.append(.init("hal", "HAL 签名检查失败，请重新安装当前版本的完整安装包并重启 Mac"))
            } else if let expected = values["engineCDHash"], !expected.isEmpty,
                      let installed = values["installedEngineCDHash"], !installed.isEmpty {
                if expected != installed {
                    issues.append(.init("hal", "应用与已安装 HAL 不匹配，请安装当前版本的完整安装包并重启 Mac"))
                } else if values["driverQueryError"] != nil {
                    issues.append(.init("hal", "无法检查已加载的 HAL，请重新检查；持续失败时请重启 Mac", .recheck))
                } else if values["driverRevision"] == "not-loaded" ||
                            (Int(values["driverRevision"] ?? "") ?? 0) < 7 ||
                            values["loadedEngineCDHash"] != expected {
                    issues.append(.init("hal", "HAL 尚未加载当前版本，需要重启 Mac；或您可选择仅热重启音频服务（不推荐）", .restart))
                }
            } else {
                issues.append(.init("hal", "HAL 与引擎的匹配状态未能确认", .recheck))
            }
        }
        return issues
    }
}
