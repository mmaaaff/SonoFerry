// Explicitly authorized, muted hardware test using the real app state machine.
// Does not install software, restart audio services, or alter the user's preferences.
import Foundation
import Darwin
import SonoFerryCore

@MainActor final class HiResReconnectCheck {
    let engine = Process(), input = Pipe(), output = Pipe()
    let suite = "local.SonoFerry.HiResIntegration." + UUID().uuidString
    var client: EngineClient!
    var phase = "devices", cycles = 0, done = false, failed = false
    var initialHiRes: Bool?, target: Bool?, activeAt: Date?
    let started = Date()
    let limit: Int
    let name: String
    init(enginePath: String, name: String, limit: Int) {
        self.name = name; self.limit = limit
        engine.executableURL = URL(fileURLWithPath: enginePath)
        engine.standardInput = input; engine.standardOutput = output
        client = EngineClient(previewMode: false, preferences: UserDefaults(suiteName: suite)!) { [weak self] message in
            guard let self else { return }
            if message.kind == "start" { precondition(message.gain == 0 && message.configuration?.isForced == false) }
            self.log("COMMAND", message)
            try! self.input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(message) + Data([10]))
        }
    }
    func log(_ label: String, _ message: WireMessage) {
        if message.kind == "telemetry" { return }
        let data = try! JSONEncoder().encode(message)
        let text = String(data: data, encoding: .utf8)!
            .replacingOccurrences(of: "[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}", with: "<BT>", options: .regularExpression)
        print(String(format: "%.3f %@ %@ %@", Date().timeIntervalSince(started), phase, label, text))
    }
    func handle(_ data: Data) {
        guard let event = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        log("EVENT", event)
        if phase == "devices" {
            guard event.kind == "devices", let device = event.devices?.first(where: { $0.name == name }) else { return }
            client.devices = [device]; client.selectedAddress = device.address; client.setGain(0)
            phase = "initialProbe"; client.probe(); return
        }
        client.receive(event)
        if phase == "initialProbe", event.kind == "stopped", client.probeComplete {
            phase = "initialConnect"; client.chooseCodec(CodecID.lhdcV5.rawValue)
        }
        if event.kind == "active" {
            precondition(event.configuration?.codec == .lhdcV5 && client.gain == 0)
            activeAt = Date()
            if phase == "switching" { cycles += 1; phase = "verify" }
        }
        if phase == "verify", event.kind == "oppoResult", !client.oppoBusy {
            guard client.oppoReport?.hiRes == target else { failed = true; done = true; return }
            print("VERIFIED cycle=\(cycles) target=\(target!)")
            if cycles == limit { phase = "cleanup"; client.stop() }
            else { phase = "initialConnect" }
        }
        if phase == "cleanup", ["failed", "stopped"].contains(event.kind) {
            failed = failed || event.kind == "failed" || client.audioState?.defaultIsVirtual != false
            done = true
        }
        if event.kind == "failed", !client.busy { failed = true; done = true }
    }
    func run() async throws -> Bool {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try engine.run()
        let reader = output.fileHandleForReading
        Task.detached { [weak self] in
            var pending = Data()
            while true {
                let data = reader.availableData; if data.isEmpty { return }; pending.append(data)
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending.prefix(upTo: end)); pending.removeSubrange(...end)
                    await self?.handle(line)
                }
            }
        }
        client.send(WireMessage("devices"))
        while !done && engine.isRunning && Date().timeIntervalSince(started) < 240 {
            if phase == "initialConnect", client.canSetOppoHiRes, let activeAt,
               Date().timeIntervalSince(activeAt) >= 3, let current = client.oppoReport?.hiRes {
                if initialHiRes == nil { initialHiRes = current }
                target = !current; phase = "switching"; client.setOppoHiRes(!current)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !done { failed = true }
        phase = "quitting"; client.stop(); client.send(WireMessage("quit"))
        let deadline = Date().addingTimeInterval(60)
        while engine.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if engine.isRunning { engine.terminate(); failed = true }
        print("RESULT cycles=\(cycles) failed=\(failed) originalHiRes=\(String(describing: initialHiRes)) lastRequested=\(String(describing: target))")
        return !failed && cycles == limit
    }
}
@main struct HiResReconnectIntegration {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard (3...4).contains(CommandLine.arguments.count) else { exit(2) }
        let check = HiResReconnectCheck(enginePath: CommandLine.arguments[1], name: CommandLine.arguments[2], limit: CommandLine.arguments.count == 4 ? Int(CommandLine.arguments[3])! : 2)
        exit(try await check.run() ? 0 : 1)
    }
}
