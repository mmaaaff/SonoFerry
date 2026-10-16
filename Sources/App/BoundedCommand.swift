import Foundation
import Darwin

/// No shell for diagnostic calls. Output and lifetime are bounded, including hung Core Audio queries.
struct BoundedCommandResult: Sendable {
    var output: Data
    var status: Int32
}
private final class CommandBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; if data.count + bytes.count > 65536 { overflow = true }; data.append(bytes.prefix(max(0, 65536 - data.count))) }
    func snapshot() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, overflow) }
}
enum BoundedCommand {
    @MainActor static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> BoundedCommandResult {
        let process = Process(), pipe = Pipe(), buffer = CommandBuffer()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
        defer { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline, !buffer.snapshot().1 else {
                    throw NSError(domain: "SonoFerry.Diagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: "检查超时或输出超过上限，未自动重试"])
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // A descendant could inherit stdout after its parent exits: never wait for EOF.
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var tail = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &tail, tail.count)
            if count <= 0 { break }
            buffer.append(Data(tail.prefix(count)))
            if buffer.snapshot().1 { break }
        }
        let (data, overflow) = buffer.snapshot()
        guard !overflow else { throw NSError(domain: "SonoFerry.Diagnostic", code: 2, userInfo: [NSLocalizedDescriptionKey: "检查输出超过上限"]) }
        return .init(output: data, status: process.terminationStatus)
    }
}
