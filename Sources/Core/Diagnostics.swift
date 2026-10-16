import Foundation

/// Converts native diagnostic records to a numeric allow-list. Never controls a session.
public enum DiagnosticMetrics {
    public static func parse(_ record: String) -> [String: Double] {
        let fields = record.split(separator: " ")
        guard let type = fields.first, ["SOCKET", "LIVE_PROGRESS", "SENDER_WINDOW", "PCM_RATE_CONVERSION", "PCM_CAPTURE_READY", "FORMAT"].contains(String(type)) else { return [:] }
        let allowed: Set<String> = ["outgoingMTU", "sentPackets", "drainedPackets", "sourceSamples", "sentSamples", "drainedSamples", "bufferedFrames", "blocked", "late", "elapsed", "skippedFrames", "sentBytes", "catchupSeconds", "senderEventWait", "windowSeconds", "windowPackets", "windowBytes", "encodeBlocks", "packetBytesMax", "encodeMaxMs", "scheduleLateMaxMs", "drainMaxMs", "drainMeanMs", "drainOver8ms", "drainOver50ms", "drainPendingMs", "sessionDrainMaxMs", "sessionDrainOver8ms", "sessionDrainOver50ms", "waitCalls", "waitTimeouts"]
        var result: [String: Double] = [:]
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Double(pair[1]), value.isFinite, value >= 0 else { continue }
            let name = String(pair[0])
            if allowed.contains(name) { result[name] = value }
            if type == "FORMAT", name == "rate" { result["captureRate"] = value }
            if type == "PCM_RATE_CONVERSION", name == "input" { result["captureRate"] = value }
            if type == "PCM_RATE_CONVERSION", name == "output" { result["pipelineRate"] = value }
            if type == "PCM_CAPTURE_READY", name == "rate" { result["pipelineRate"] = value }
        }
        return result
    }
}
