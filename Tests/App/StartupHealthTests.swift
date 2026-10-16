import Foundation
import SonoFerryCore

@main struct StartupHealthControllerTests {
    @MainActor static func main() async throws {
        func expect(_ value: Bool, _ reason: String) { precondition(value, reason) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SonoFerry-health-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = ["halInstalled":"true", "halSignatureValid":"true", "engineCDHash":"new", "installedEngineCDHash":"new", "loadedEngineCDHash":"new", "driverRevision":"7", "bluetoothAuthorization":"3"]
        var commands: [[String]] = [], restarted = false, prepared = false, finished: Bool?
        let health = StartupHealthController(bundle: URL(fileURLWithPath: "/offline/SonoFerry.app"), logRoot: root.appendingPathComponent("success"), run: { url, args, _ in
            commands.append([url.lastPathComponent] + args)
            let data: Data
            if args == ["--startup-health"] {
                var state = good; if !restarted { state["loadedEngineCDHash"] = "old" }
                data = try JSONEncoder().encode(state)
            } else if args == ["--permission-status"] {
                data = try JSONEncoder().encode(["audioCapture":"granted"])
            } else if url.lastPathComponent == "osascript" {
                expect(prepared, "restart must wait for successful cleanup")
                expect(args == ["-e", "do shell script \"/usr/bin/killall coreaudiod\" with administrator privileges"], "only fixed one-shot command")
                restarted = true; data = Data()
            } else { preconditionFailure("unexpected command") }
            return .init(output: data, status: 0)
        })
        expect(health.engine.path == "/offline/SonoFerry.app/Contents/Helpers/SonoFerry Engine.app/Contents/MacOS/SonoFerryEngine", "startup health must locate the existing engine inside the renamed app")
        expect(health.capture.path == "/offline/SonoFerry.app/Contents/Helpers/SonoFerry Engine.app/Contents/Helpers/SonoFerry Audio.app/Contents/MacOS/SonoFerryAudio", "capture permission check must locate the same installed helper as playback")
        expect(commands.isEmpty, "constructing controller must not run a check")
        await health.refresh()
        expect(commands.count == 2 && !restarted, "startup only checks, no authorization or restart")
        expect(health.issues.map(\.action) == [.restart], "loaded/disk mismatch exposed")
        health.restart(prepare: { prepared = true }, finish: { finished = $0 })
        for _ in 0..<100 where finished == nil { try await Task.sleep(for: .milliseconds(10)) }
        expect(finished == true && health.restartAttempted, "confirmed command resumes the idle engine without a health gate")
        expect(commands.filter { $0.first == "ps" || $0.contains("--doctor") }.isEmpty, "no baseline process dump or 45-second check")
        expect(commands.count == 5, "initial checks, single command, ordinary display refresh only")
        expect(!health.message.contains("检查完成"), "command completion is not a health certificate")
        health.restart(prepare: { preconditionFailure("no loop") }, finish: { _ in })
        expect(commands.filter { $0.first == "osascript" }.count == 1, "no automatic or repeated restart")
        let logs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("success"), includingPropertiesForKeys: nil)
        expect(logs.count == 1, "operation log saved")
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: logs[0])) as! [String: Any]
        expect(record["restartCommandSucceeded"] as? Bool == true && record["extendedHealthCheckPerformed"] as? Bool == false, "log distinguishes command from health")
        expect(record["healthy"] == nil && record["samples"] == nil, "no fabricated health result")
        expect(health.canAcknowledgeRestartNotice, "completed restart notice is dismissible")
        health.acknowledgeRestartNotice()
        expect(health.message.isEmpty && !health.canAcknowledgeRestartNotice && health.restartAttempted, "acknowledgment hides notice without authorizing another restart")
        await health.refresh()
        expect(health.message.isEmpty, "ordinary refresh does not resurrect dismissed notice")
        var blockedCommands = 0
        let blocked = StartupHealthController(logRoot: root, run: { _, args, _ in
            blockedCommands += 1
            var state = good; state["loadedEngineCDHash"] = "old"
            return .init(output: try JSONEncoder().encode(args == ["--startup-health"] ? state : ["audioCapture":"granted"]), status: 0)
        })
        await blocked.refresh(); var blockedFinished = false
        blocked.restart(prepare: { throw ProtocolFailure("cleanup failed") }, finish: { _ in blockedFinished = true })
        for _ in 0..<100 where !blockedFinished { try await Task.sleep(for: .milliseconds(10)) }
        expect(blockedCommands == 2 && !blocked.restartAttempted, "cleanup failure never launches privileged action")
        expect(blocked.message.hasPrefix("尚未执行热重启"), "preparation failure is distinct from command failure")
        for outcome in ["cancelled", "throws", "refresh-failed", "still-unloaded"] {
            var called = 0, completion: Bool?, submitted = false
            let controller = StartupHealthController(logRoot: root.appendingPathComponent(outcome), run: { url, args, _ in
                if url.lastPathComponent == "osascript" {
                    called += 1; submitted = true
                    if outcome == "throws" { throw ProtocolFailure("mock command timeout") }
                    return .init(output: Data(), status: outcome == "cancelled" ? 1 : 0)
                }
                expect(args == ["--startup-health"] || args == ["--permission-status"], "only ordinary driver/permission check allowed")
                if submitted && outcome == "refresh-failed" { throw ProtocolFailure("mock diagnostic failure") }
                var state = good; state["loadedEngineCDHash"] = "old"
                return .init(output: try JSONEncoder().encode(args == ["--startup-health"] ? state : ["audioCapture":"granted"]), status: 0)
            })
            await controller.refresh()
            controller.restart(prepare: {}, finish: { completion = $0 })
            for _ in 0..<100 where completion == nil { try await Task.sleep(for: .milliseconds(10)) }
            let success = outcome == "refresh-failed" || outcome == "still-unloaded"
            expect(completion == success && called == 1, "command status independent of display refresh: \(outcome)")
            expect(!controller.issues.isEmpty, "unknown or unloaded state not erased")
            expect(controller.message.hasPrefix(success ? "音频服务重启命令已执行" : "热重启未确认"), "correct stage-specific message")
            let issues = controller.issues
            controller.acknowledgeRestartNotice()
            expect(controller.message.isEmpty && controller.issues == issues, "acknowledgment preserves actual driver and permission issues")
            controller.restart(prepare: { preconditionFailure("must not retry") }, finish: { _ in })
            expect(called == 1, "failure never retries privileged command")
        }
        health.request(.recheck, bluetooth: { preconditionFailure("read-only recheck") })
        expect(!health.requested.contains(.recheck), "rechecking is repeatable and is not a permission request")
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        let beforeRecheck = commands.count
        health.request(.recheck, bluetooth: { preconditionFailure("read-only recheck") })
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        expect(commands.count == beforeRecheck + 2, "second recheck runs checks instead of opening permission settings")
        let start = ContinuousClock.now
        do {
            _ = try await BoundedCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["3"], timeout: 0.05)
            preconditionFailure("timeout expected")
        } catch { expect(start.duration(to: .now) < .seconds(2), "hung child is bounded") }
        do {
            _ = try await BoundedCommand.run(URL(fileURLWithPath: "/usr/bin/head"), ["-c", "70000", "/dev/zero"], timeout: 2)
            preconditionFailure("oversized output must remain bounded")
        } catch { expect(error.localizedDescription.contains("输出超过上限"), "retain diagnostic output protection") }
        print("STARTUP_HEALTH PASS: passive checks, independent issues, confirmation boundary, cleanup failure, one restart, no CPU/doctor gate, cancelled/failed command, refresh failure, child timeout/overflow (all restart/auth calls mocked)")
    }
}
