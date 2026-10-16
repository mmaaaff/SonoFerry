import Foundation

/// Core Audio finishes route removal and StopIO asynchronously after lease release.
/// A new lease must not cancel that removal while clients still use the old clock.
enum OutputTransition {
    struct State: Equatable {
        // Core Audio can retain DeviceIsAlive=1 for a hidden, stopped plugin.
        // Keep it for diagnostics; it is not the lease retirement signal.
        var alive: Bool
        var hidden: Bool
        var running: Bool
        var canDefault: Bool
        var canSystemDefault: Bool
        var retired: Bool { hidden && !running && !canDefault && !canSystemDefault }
        var diagnostic: String {
            "alive=\(alive) hidden=\(hidden) running=\(running) canDefault=\(canDefault) canSystemDefault=\(canSystemDefault)"
        }
    }
    struct Timeout: LocalizedError {
        let stage: String
        var errorDescription: String? { "系统尚未完成音频输出交接，已停止本次连接。请稍后重试。" }
    }
    // A canceled startup still owns resources. Finish bounded retirement in an
    // independent task; cancellation must not skip the host's StopIO barrier.
    @MainActor static func retire(timeout: Duration = .seconds(5),
                                  ready: @escaping @MainActor () throws -> Bool) async throws {
        try await Task { @MainActor in
            try await wait(stage: "lease-retirement", timeout: timeout, ready: ready)
        }.value
    }
    @MainActor static func wait(stage: String, timeout: Duration = .seconds(5),
                               interval: Duration = .milliseconds(100),
                               ready: () throws -> Bool) async throws {
        let clock = ContinuousClock(), start = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            if try ready() { return }
            guard clock.now - start < timeout else { throw Timeout(stage: stage) }
            try await Task.sleep(for: interval)
        }
    }
}
