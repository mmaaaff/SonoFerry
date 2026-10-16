// Authorized, muted real-device test of parameter reconnect and MTU fallback.
import Foundation
import Darwin
import SonoFerryCore
@MainActor final class ParameterReconnectCheck {
    let process = Process(), input = Pipe(), output = Pipe()
    let suite = "local.SonoFerry.ParameterCheck." + UUID().uuidString
    var client: EngineClient!
    var phase = "devices", done = false, failed = false
    var phaseAt = Date(), readyAt: Date?
    let since = Date(), name: String
    init(engine: String, name: String) {
        self.name = name
        process.executableURL = URL(fileURLWithPath: engine); process.standardInput = input; process.standardOutput = output
        client = EngineClient(previewMode: false, preferences: UserDefaults(suiteName: suite)!) { [weak self] message in
            guard let self else { return }
            if message.kind == "start" { precondition(message.gain == 0 && message.configuration?.isForced != true) }
            self.log("COMMAND", message)
            try! self.input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(message) + Data([10]))
        }
    }
    func log(_ label: String, _ event: WireMessage) {
        if !["start","probe","stop","quit","active","failed","stopped","error","oppoFailed"].contains(event.kind) { return }
        let raw = String(data: try! JSONEncoder().encode(event), encoding: .utf8)!
        print(String(format: "%.3f %@ %@ %@", Date().timeIntervalSince(since), phase, label,
                     raw.replacingOccurrences(of: "[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}", with: "<BT>", options: .regularExpression)))
    }
    func enter(_ phase: String) { self.phase = phase; phaseAt = Date(); readyAt = nil }
    func handle(_ data: Data) {
        guard let event = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }; log("EVENT",event)
        if phase == "devices" {
            guard event.kind == "devices", let device = event.devices?.first(where: { $0.name == name }) else { return }
            client.devices = [device]; client.selectedAddress = device.address; client.setGain(0)
            enter("probe"); client.probe(); return
        }
        client.receive(event)
        if phase == "probe", event.kind == "stopped", client.probeComplete { enter("initial"); client.chooseCodec(CodecID.lhdcV5.rawValue) }
        if event.kind == "active" {
            readyAt = Date()
            guard let c = event.configuration, c.codec == .lhdcV5, client.gain == 0 else { failed = true; done = true; return }
            if phase == "rate96", c.sampleRate != .hz96000 || c.fixedBitrateKbps != 900 { failed = true; done = true }
            if phase == "mtu", c.sampleRate != .hz48000 || c.quality != .adaptive { failed = true; done = true }
            if phase == "fixed400", c.sampleRate != .hz48000 || c.fixedBitrateKbps != 400 { failed = true; done = true }
        }
        if phase == "stop", event.kind == "stopped" { done = true; failed = client.audioState?.defaultIsVirtual != false }
        if event.kind == "failed", !client.busy { done = true; failed = true }
    }
    func run() async throws -> Bool {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try process.run(); let handle = output.fileHandleForReading
        Task.detached { [weak self] in
            var bytes = Data()
            while true {
                let data = handle.availableData; if data.isEmpty { return }; bytes.append(data)
                while let end = bytes.firstIndex(of:10) {
                    let line = Data(bytes.prefix(upTo:end)); bytes.removeSubrange(...end); await self?.handle(line)
                }
            }
        }
        client.send(WireMessage("devices"))
        while !done && process.isRunning && Date().timeIntervalSince(since) < 240 && Date().timeIntervalSince(phaseAt) < 90 {
            if client.active, !client.oppoBusy, let readyAt, Date().timeIntervalSince(readyAt) >= 3 {
                switch phase {
                case "initial":
                    guard client.oppoReport?.hiRes == true else { print("PRECONDITION HiRes must already be on; no setting was written"); failed = true; done = true; continue }
                    enter("rate96"); client.rate = 96000; client.quality = .connection; client.fixedBitrate = 900; client.parametersChanged()
                case "rate96":
                    print("VERIFIED 96000/900"); enter("mtu")
                    client.rate = 44100; client.quality = .connection; client.fixedBitrate = 1000; client.parametersChanged()
                case "mtu":
                    print("VERIFIED MTU fallback 48000/adaptive"); enter("fixed400")
                    client.rate = 48000; client.quality = .connection; client.fixedBitrate = 400; client.parametersChanged()
                case "fixed400":
                    print("VERIFIED 48000/400 after fallback"); enter("stop"); client.stop()
                default: break
                }
            }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        if !done { failed = true }
        enter("quit"); client.stop(); client.send(WireMessage("quit"))
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds:100_000_000) }
        if process.isRunning { process.terminate(); failed = true }
        print("RESULT parameterReconnect failed=\(failed)"); return !failed
    }
}
@main struct ParameterReconnectIntegration {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); guard CommandLine.arguments.count == 3 else { exit(2) }
        let check = ParameterReconnectCheck(engine: CommandLine.arguments[1],name: CommandLine.arguments[2])
        exit(try await check.run() ? 0 : 1)
    }
}
