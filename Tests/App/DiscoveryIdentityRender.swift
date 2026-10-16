import AppKit
import SwiftUI
import SonoFerryCore

/// Isolated production popover, synthetic replies only. No engine or Bluetooth access.
@main struct DiscoveryIdentityRender {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "local.SonoFerry.DiscoveryRender." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var commands: [WireMessage] = []
        let model = EngineClient(previewMode: false, preferences: prefs, messageSink: { commands.append($0) }, controlScheduler: { _, _ in })
        let a = BluetoothDevice(address: "00:11:22:33:44:55", name: "我的耳机", connected: true, a2dpSink: true, controlServices: [HeadsetDialect.elnk079A.rawValue])
        let b = BluetoothDevice(address: "00:11:22:33:44:66", name: "我的耳机", connected: true, a2dpSink: true, controlServices: a.controlServices)
        let c = BluetoothDevice(address: "00:11:22:33:44:77", name: "Bluetooth Speaker", connected: true, a2dpSink: true)
        var revision: UInt64 = 0
        let generation = UUID()
        func scan() {
            model.scanConnectedDevices(); revision += 1
            var event = WireMessage("environment", requestID: commands.last!.requestID)
            event.environment = .init(generation: generation, revision: revision, devices: [a,b,c], route: .init(uid: "BuiltInSpeakerDevice"), audioSessionID: nil, transitioning: false)
            event.details = ["bluetoothAuthorization":"3"]; model.receive(event)
        }
        func identity(_ product: UInt32?) {
            let request = commands.last { $0.kind == "deviceIdentity" }!
            var event = WireMessage("deviceIdentity", requestID: request.requestID)
            event.device = request.device; event.restartSafe = true
            if let product { event.headsetIdentity = .init(address: request.device!.address, productID: product, serviceUUID: HeadsetDialect.elnk079A.rawValue, generation: UUID()) }
            else { event.message = "未取得产品 ID，请刷新重试。" }
            model.receive(event)
        }
        func save(_ name: String, model renderedModel: EngineClient? = nil) throws {
            let view = DeviceDiscoveryView(model: renderedModel ?? model).fixedSize(horizontal: false, vertical: true)
                .background(Color.white).environment(\.colorScheme, .light)
            // Native hosting is required: ImageRenderer omits ScrollView contents.
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .aqua)
            guard host.fittingSize == NSSize(width: 330, height: 320) else { throw ProtocolFailure("Discovery popover changed size: \(name) \(host.fittingSize)") }
            host.frame = NSRect(x: 0, y: 0, width: 330, height: 320)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProtocolFailure("UI bitmap failed") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ProtocolFailure("UI render failed") }
            let directory = URL(fileURLWithPath: ".build/discovery-identity-ui", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        model.scanConnectedDevices(); try save("scanning")
        scan(); try save("identifying")
        identity(0x06ec10); identity(0x061410); try save("confirmed")
        scan(); identity(nil); identity(0xabcdef); try save("failed-unknown")
        model.busy = true; scan(); try save("audio-busy")
        prefs.set(try JSONEncoder().encode([RegisteredHeadphone(address: a.address, model: .encoX4)]), forKey: "headphoneLibrary.v1")
        var savedCommands: [WireMessage] = []
        let savedModel = EngineClient(previewMode: false, preferences: prefs, messageSink: { savedCommands.append($0) }, controlScheduler: { _, _ in })
        savedModel.scanConnectedDevices()
        var event = WireMessage("environment", requestID: savedCommands.last!.requestID)
        event.environment = .init(generation: UUID(), revision: 1, devices: [a], route: .init(uid: a.address, bluetoothAddress: a.address))
        event.details = ["bluetoothAuthorization":"3"]; savedModel.receive(event)
        try save("registered-system-codec", model: savedModel)
        print("Production discovery views rendered from synthetic replies; no engine, Bluetooth or playback.")
    }
}
