import Foundation
import SonoFerryCore

/// Bounded control diagnostics: IDs/stages only, no addresses, names or payloads.
final class ControlTrace {
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(RuntimeIdentity.cacheDirectory + "/Control", isDirectory: true)
    private var file: URL?
    private var handle: FileHandle?
    private var bytes = 0
    private let limit = 256 * 1024
    func record(_ kind: String, request: WireMessage, detail: String) {
        record(kind, requestID: request.requestID, sessionID: request.sessionID, detail: detail)
    }
    func record(_ kind: String, requestID: UUID?, sessionID: UUID?, detail: String) {
        do {
            if file == nil {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.lastPathComponent.hasPrefix("control-") && $0.pathExtension == "jsonl" }
                    .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for old in existing.dropFirst(3) { try? FileManager.default.removeItem(at: old) }
                file = directory.appendingPathComponent("control-\(UUID().uuidString).jsonl")
            }
            let row: [String: Any] = ["time": Date().timeIntervalSince1970, "kind": kind,
                "requestID": requestID?.uuidString ?? "", "sessionID": sessionID?.uuidString ?? "", "detail": String(detail.prefix(400))]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
            if handle == nil || bytes + data.count > limit {
                try? handle?.close()
                FileManager.default.createFile(atPath: file!.path, contents: nil, attributes: [.posixPermissions: 0o600])
                handle = try FileHandle(forWritingTo: file!); bytes = 0
            }
            try handle?.write(contentsOf: data); bytes += data.count
        } catch { /* Diagnostic I/O must never block a control transaction. */ }
    }
    deinit { try? handle?.close() }
}
