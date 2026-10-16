// Manual, silent hardware check. Requires an installed matching engine/HAL and
// explicit user authorization to take over Bluetooth/system audio temporarily.
import Foundation
import Darwin
import SonoFerryCore

@MainActor final class FixedReconnectCheck {
    let engine = Process(), pipe = Pipe(), output = Pipe()
    let suite = "local.SonoFerry.FixedReconnect." + UUID().uuidString
    lazy var preferences = UserDefaults(suiteName: suite)!
    var client: EngineClient!
    var prepared = false, completed = false, failed = false
    var activeSince: Date?, stopSent = false
    var round = 0
    let name: String
    let caps: [CodecCapabilities]
    init(name: String, caps: [CodecCapabilities], executable: String) {
        self.name = name; self.caps = caps
        engine.executableURL = URL(fileURLWithPath: executable)
        engine.standardInput = pipe; engine.standardOutput = output
        client = EngineClient(previewMode: false, preferences: preferences) { [weak self] message in
            guard let self else { return }
            if message.kind == "start" {
                precondition(message.gain == 0 && message.configuration?.isForced == false)
            }
            print("COMMAND \(message.kind) session=\(message.sessionID?.uuidString ?? "none")")
            do { try self.pipe.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(message) + Data([10])) }
            catch { self.failed = true; self.completed = true }
        }
    }
    func handle(_ data: Data) {
        guard let event = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        if !prepared {
            guard event.kind == "devices", let device = event.devices?.first(where: { $0.name == name }) else { return }
            prepared = true
            client.devices = [device]; client.selectedAddress = device.address
            client.capabilities = caps; client.probeComplete = true
            client.selectedCapability = caps.first(where: { $0.codec == .lhdcV5 && $0.playable })!.id
            client.rate = 48000; client.quality = .connection; client.fixedBitrate = 400; client.parametersChanged()
            client.setGain(0) // Isolated defaults; never modifies the user's volume preference.
            var audio = WireMessage("audioState"); audio.device = device; client.send(audio)
            return
        }
        client.receive(event)
        if round == 0, event.kind == "audioState" {
            round = 1
            client.chooseCodec("system")
            client.chooseCodec(CodecID.lhdcV5.rawValue) // Also exercises cancellation sequencing.
        }
        if ["active", "error", "failed", "stopped", "oppoResult", "oppoFailed"].contains(event.kind) {
            print("EVENT round=\(round) kind=\(event.kind) message=\(event.message ?? "")")
        }
        if event.kind == "active" {
            guard event.configuration?.codec == .lhdcV5, event.configuration?.sampleRate == .hz48000, event.configuration?.fixedBitrateKbps == 400, client.codecChoices == [.lhdcV5] else {
                failed = true; client.stop(); stopSent = true; return
            }
            print("ACTIVE rate=\(event.configuration!.sampleRate.rawValue) bits=\(event.configuration!.bits) gain=\(client.gain)")
            activeSince = Date()
        }
        if event.kind == "failed", !client.busy { failed = true }
        if event.kind == "stopped" || event.kind == "failed" && !client.busy {
            print("CLEANUP round=\(round) native=\(client.audioState?.nativeOutput != nil) virtualDefault=\(client.audioState?.defaultIsVirtual == true)")
            if client.audioState?.nativeOutput == nil || client.audioState?.defaultIsVirtual != false {
                failed = true
            }
            if failed || round == 2 { completed = true }
        }
        if stopSent, !client.busy, !client.oppoBusy, !completed,
           ["oppoResult", "oppoFailed"].contains(event.kind) {
            round += 1; activeSince = nil; stopSent = false
            client.chooseCodec(CodecID.lhdcV5.rawValue)
        }
    }
    func run() async throws -> Bool {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try engine.run()
        let handle = output.fileHandleForReading
        Task.detached { [weak self] in
            var pending = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { return }
                pending.append(data)
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending.prefix(upTo: end)); pending.removeSubrange(...end)
                    await self?.handle(line)
                }
            }
        }
        client.send(WireMessage("devices"))
        let deadline = Date().addingTimeInterval(180)
        while !completed && engine.isRunning && Date() < deadline {
            if let activeSince, !stopSent, Date().timeIntervalSince(activeSince) >= 20 {
                stopSent = true; client.chooseCodec("system")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !completed { failed = true; client.stop() }
        client.cancelOppo(); client.send(WireMessage("quit"))
        try? pipe.fileHandleForWriting.close()
        let cleanup = Date().addingTimeInterval(90)
        while engine.isRunning && Date() < cleanup { try await Task.sleep(nanoseconds: 100_000_000) }
        if engine.isRunning { engine.terminate(); failed = true }
        print("RESULT completed=\(completed) rounds=\(round) failed=\(failed)")
        return completed && !failed
    }
}

@main struct FixedReconnectIntegration {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 4 else {
            print("Usage: FixedReconnectIntegration ENGINE DEVICE_NAME CAPABILITIES_JSONL"); exit(2)
        }
        let data = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        let caps = data.split(separator: "\n").compactMap { try? JSONDecoder().decode(WireMessage.self, from: Data($0.utf8)) }
            .last(where: { $0.kind == "stopped" && $0.details?["probeComplete"] == "true" })?.capabilities ?? []
        guard caps.contains(where: { $0.codec == .lhdcV5 && $0.playable }) else { exit(2) }
        let check = FixedReconnectCheck(name: CommandLine.arguments[2], caps: caps, executable: CommandLine.arguments[1])
        exit(try await check.run() ? 0 : 1)
    }
}
