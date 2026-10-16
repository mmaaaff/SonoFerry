import AppKit
import SwiftUI
import SonoFerryCore

@MainActor final class StartupHealthController: ObservableObject {
    @Published private(set) var values: [String: String] = [:]
    @Published private(set) var checking = false
    @Published private(set) var operating = false
    @Published private(set) var message = ""
    @Published private(set) var restartNoticePending = false
    @Published private(set) var restartAttempted = false
    @Published private(set) var requested: Set<StartupIssue.Action> = []
    private var generation = UUID()
    private var observer: NSObjectProtocol?
    private var hasStarted = false
    private var bluetoothObservation: UInt64 = 0
    private var latestBluetoothAuthorization: String?
    private var permissionMessageAction: StartupIssue.Action?
    private let run: (URL, [String], TimeInterval) async throws -> BoundedCommandResult
    private let logRoot: URL
    private let bundle: URL
    init(bundle: URL = Bundle.main.bundleURL,
         logRoot: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent(RuntimeIdentity.cacheDirectory + "/StartupHealth"),
         run: @escaping (URL, [String], TimeInterval) async throws -> BoundedCommandResult = { try await BoundedCommand.run($0, $1, timeout: $2) }) {
        self.bundle = bundle; self.run = run; self.logRoot = logRoot
    }
    var issues: [StartupIssue] { StartupHealth.issues(values) }
    var canAcknowledgeRestartNotice: Bool { restartNoticePending && !operating && !message.isEmpty }
    func acknowledgeRestartNotice() {
        guard canAcknowledgeRestartNotice else { return }
        message = ""; restartNoticePending = false
    }
    var engine: URL { bundle.appendingPathComponent(RuntimeIdentity.engineExecutablePath) }
    var capture: URL { bundle.appendingPathComponent(RuntimeIdentity.engineBundlePath).appendingPathComponent(RuntimeIdentity.captureExecutablePath) }
    func start() {
        guard !hasStarted else { return }; hasStarted = true
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        check()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func check() {
        guard !checking, !operating else { return }
        Task { await refresh() }
    }
    private func json(_ result: BoundedCommandResult) throws -> [String: String] {
        guard result.status == 0 else { throw ProtocolFailure("检查进程返回失败（\(result.status)）") }
        return try JSONDecoder().decode([String: String].self, from: result.output)
    }
    func observeBluetoothAuthorization(_ authorization: String?) {
        guard let authorization, ["0", "1", "2", "3"].contains(authorization) else { return }
        bluetoothObservation &+= 1
        latestBluetoothAuthorization = authorization
        values["bluetoothAuthorization"] = authorization
        clearResolvedPermissionMessage()
    }
    private func clearResolvedPermissionMessage() {
        let resolved = permissionMessageAction == .bluetooth && values["bluetoothAuthorization"] == "3"
            || permissionMessageAction == .audioCapture && values["audioCapture"] == "granted"
        if resolved { message = ""; permissionMessageAction = nil }
    }
    func refresh() async {
        guard !checking else { return }
        checking = true; let id = UUID(); generation = id
        let observationAtStart = bluetoothObservation
        var next: [String: String] = [:]
        // Separate probes: an unavailable HAL never hides permission issues.
        do {
            next = try json(await run(engine, ["--startup-health"], 8))
            guard next["bluetoothAuthorization"] != nil, ["true", "false"].contains(next["halInstalled"] ?? "") else {
                throw ProtocolFailure("健康检查回复缺少必需字段")
            }
        }
        catch { next["healthError"] = "启动健康检查未完成：" + error.localizedDescription }
        do {
            let audio = try json(await run(capture, ["--permission-status"], 6))
            next.merge(audio) { _, new in new }
            if next["audioCapture"] == nil { next["audioCapture"] = "unavailable" }
        }
        catch { next["audioCapture"] = "unavailable" }
        guard id == generation else { return }
        // A startup probe begun before authorization may finish after the live update.
        if bluetoothObservation != observationAtStart, let latestBluetoothAuthorization {
            next["bluetoothAuthorization"] = latestBluetoothAuthorization
        }
        values = next; checking = false
        clearResolvedPermissionMessage()
    }
    func request(_ action: StartupIssue.Action, bluetooth: () -> Void) {
        guard !operating, !checking else { return }
        if [.bluetooth, .audioCapture].contains(action) {
            if requested.contains(action) { openSettings(action); return }
            requested.insert(action)
        }
        switch action {
        case .bluetooth:
            restartNoticePending = false
            permissionMessageAction = .bluetooth
            message = "已请求蓝牙权限；若系统不再弹窗，请在系统设置中允许。"
            bluetooth()
            Task { try? await Task.sleep(for: .seconds(1)); await refresh() }
        case .audioCapture:
            restartNoticePending = false
            permissionMessageAction = .audioCapture
            operating = true; message = "请在系统弹窗中允许系统音频录制"
            Task {
                do {
                    let result = try json(await run(capture, ["--request-permission"], 60))
                    if result["audioCapture"] == "granted" {
                        message = ""; permissionMessageAction = nil
                        values["audioCapture"] = "granted"
                    } else {
                        message = "授权未确认；若系统不再弹窗，请在系统设置中允许。"
                    }
                } catch { message = "授权未确认：" + error.localizedDescription }
                operating = false; await refresh()
            }
        case .audioSettings: openSettings(action)
        case .recheck: check()
        case .restart: break // Only the explicit confirmation path below may perform this action.
        }
    }
    func openSettings(_ action: StartupIssue.Action) {
        let pane = action == .bluetooth ? "Privacy_Bluetooth" : "Privacy_AudioCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    static let restartWarning = "不推荐热重启，建议重启 Mac。\n\n这会短暂中断所有应用音频，可能导致持续高 CPU、无声或驱动无法正常加载。若出现问题，请重启 Mac。\n\n确认后将请求管理员认证，仅重启一次音频服务；不会开始播放。"
    func restart(prepare: @escaping () async throws -> Void, finish: @escaping (Bool) -> Void) {
        guard !operating, !checking, !restartAttempted, issues.contains(where: { $0.action == .restart }) else { return }
        permissionMessageAction = nil
        restartNoticePending = false
        operating = true; message = "正在确认应用会话已安全结束…"
        Task {
            var commandSucceeded = false
            var stage = "prepare"
            do {
                try await prepare()
                // Fixed command; no device names, paths or user text enter the privileged script.
                restartAttempted = true; stage = "restart-command"
                message = "等待管理员认证；仅热重启一次音频服务…"
                let result = try await run(URL(fileURLWithPath: "/usr/bin/osascript"),
                    ["-e", "do shell script \"/usr/bin/killall coreaudiod\" with administrator privileges"], 60)
                guard result.status == 0 else { throw ProtocolFailure("管理员认证已取消或热重启未确认，未重试") }
                commandSucceeded = true; stage = "command-completed"
                message = "音频服务重启命令已执行，未自动播放。若仍无声或驱动未加载，请重启 Mac。"
                // Refresh the ordinary driver/permission display once. No CPU sampling, doctor,
                // delay loop or health gate; a failed observation cannot undo command completion.
                await refresh()
            } catch {
                let prefix = restartAttempted ? "热重启未确认" : "尚未执行热重启"
                message = "\(prefix)：\(error.localizedDescription)。未重试；如音频异常，请重启 Mac。"
            }
            save(commandSucceeded: commandSucceeded, stage: stage)
            operating = false; restartNoticePending = true; finish(commandSucceeded)
        }
    }
    private func save(commandSucceeded: Bool, stage: String) {
        let root = logRoot
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in files.dropFirst(19) where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
            let report: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "restartAttempted": restartAttempted, "restartCommandSucceeded": commandSucceeded, "stage": stage, "extendedHealthCheckPerformed": false, "message": message, "diagnostics": values]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("\(Int(Date().timeIntervalSince1970)).json"), options: .atomic)
        } catch { message += "；操作日志未能保存" }
    }
}
