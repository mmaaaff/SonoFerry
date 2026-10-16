import AppKit
import SwiftUI
import SonoFerryCore

// Offline interactive fixture. Every request is handled locally; no engine is launched.
@MainActor final class SoundPreviewHarness {
    let suite = "local.SonoFerry.SoundPreview." + UUID().uuidString
    var model: EngineClient!
    var watchID: UUID?
    var pendingReply: WireMessage?
    private var pendingValidation: Bool { CommandLine.arguments.contains("--pending-validation") || Bundle.main.object(forInfoDictionaryKey: "SoundPreviewPending") as? Bool == true }
    private var bassMismatch: Bool { CommandLine.arguments.contains("--bass-mismatch") || Bundle.main.object(forInfoDictionaryKey: "SoundPreviewBassMismatch") as? Bool == true }
    init() throws {
        model = EngineClient(previewMode: false, preferences: UserDefaults(suiteName: suite)!, messageSink: { [weak self] in self?.answer($0) })
        let device = BluetoothDevice(address: "00:11:22:33:44:55", name: "Enco X4 · 离线模拟", connected: true, a2dpSink: true)
        model.devices = [device]; model.selectedAddress = device.address
        var s = HeadsetSnapshot(address: device.address); s.connected = true; s.productID = 0x06ec10
        s.capabilities = try .init(reply: .init(command: 0x8100, payload: [0,255,0x77,0x5a,0xee,0xee,0x8f,0xa6,0x5f,0x17]))
        s.noise = .init(4); s.noiseType = .init(5)
        s.battery = [1: .init(.init(percent: 90, charging: false)), 2: .init(.init(percent: 85, charging: false)), 3: .init(.init(percent: 60, charging: false), stale: true)]
        s.keys = .init([UInt8(1),2].flatMap { ear in
            (1...3).map { HeadsetKey(ear: ear, button: 6, action: UInt8($0), function: [29,28,25][$0-1]) } +
            (1...6).map { HeadsetKey(ear: ear, action: UInt8($0), function: [1,6,5,8,7,18][$0-1]) }
        })
        s.features[11] = .init(true); s.goldenResult = .init(true)
        s.preset = .init(0)
        s.equalizers = .init(["Master EQ Balance", "Master EQ Monitor", "Master EQ Pop"].enumerated().map { index, name in
            .init(id: UInt8(10 + index), name: name, minimum: -6, maximum: 6, frequencies: [31,62,125,250,500,1000,2000,4000,8000,16000], gains: Array(repeating: 0, count: 10))
        })
        if CommandLine.arguments.contains("--two-curves") || Bundle.main.object(forInfoDictionaryKey: "SoundPreviewTwoCurves") as? Bool == true { s.equalizers?.value.removeLast() }
        s.features[29] = .init(pendingValidation); s.bassWave = .init(.init(minimum: -5, maximum: 5, current: 0))
        model.headset = s; model.headsetMessage = "离线界面验证 · 无蓝牙连接或耳机设置"
    }
    func answer(_ request: WireMessage) {
        guard var s = model.headset else { return }
        if request.kind == "headsetWatch" { watchID = request.requestID }
        let before = s
        var delay = 0.1
        var confirmed = true
        if let setting = request.headsetSetting {
            switch setting {
            case .noise(let id): s.noise = .init(id)
            case .key(let key): if let i = s.keys?.value.firstIndex(where: { $0.id == key.id }) { s.keys?.value[i] = key }
            case .preset(let id): s.preset = .init(id); for i in s.equalizers!.value.indices { s.equalizers!.value[i].selected = false }
            case .selectEqualizer(let id):
                s.preset = .init(255); for i in s.equalizers!.value.indices { s.equalizers!.value[i].selected = s.equalizers!.value[i].id == id }
            case .equalizer(var curve, _), .createEqualizer(var curve):
                if case .createEqualizer = setting { curve.id = (s.equalizers!.value.map(\.id).max() ?? 10) + 1 }
                s.equalizers!.value.removeAll { $0.id == curve.id }
                for i in s.equalizers!.value.indices { s.equalizers!.value[i].selected = false }
                curve.selected = true; s.equalizers!.value.append(curve); s.preset = .init(255)
            case .deleteEqualizer(let curve):
                s.equalizers!.value.removeAll { $0.id == curve.id }
                if !s.equalizers!.value.contains(where: \.selected) { s.preset = .init(0) }
            case .feature(let feature, let enabled): s.features[feature.rawValue] = .init(enabled)
            case .bassWave(let value):
                s.bassWave = .init(.init(minimum: -5, maximum: 5, current: bassMismatch ? max(-5, value - 1) : value))
                confirmed = s.bassWave?.value.current == value
                if pendingValidation { delay = 4 }
            default: break
            }
        }
        var reply = WireMessage("headsetResult", requestID: request.requestID)
        reply.device = request.device; reply.controlGeneration = s.generation; reply.headset = s
        reply.message = confirmed ? "离线模拟：配置已确认" : "离线模拟：读回与目标不同，以设备值为准"
        if let setting = request.headsetSetting { reply.headsetResult = .init(setting: setting, acknowledged: true, confirmed: confirmed, message: reply.message!) }
        if delay > 1 {
            var update = WireMessage("headsetSnapshot", requestID: watchID)
            var baseline = before; baseline.bassWave?.stale = true; baseline.features[29]?.stale = true
            update.headset = baseline; update.device = request.device; update.controlGeneration = s.generation
            model.receive(update)
            pendingReply = reply
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.model.receive(reply) }
    }
    func finishPending(mismatch: Bool = false) {
        guard var reply = pendingReply else { return }
        pendingReply = nil
        if mismatch, let current = reply.headset?.bassWave?.value.current {
            reply.headset?.bassWave?.value.current = max(-5, current - 1)
            reply.headsetResult?.confirmed = false
            reply.message = "离线模拟：读回与目标不同，以设备值为准"
        }
        model.receive(reply)
    }
}
#if !CONTROL_UI_RENDER
@main struct HeadsetSoundNativePreview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let harness = try SoundPreviewHarness()
        let dark = !CommandLine.arguments.contains("--light")
        let view = VStack(spacing: 0) {
            #if CONTROL_UI_PREVIEW
            TabView {
                ScrollView { ControlPanel(model: harness.model) }.tabItem { Text("菜单栏") }
                HeadsetSettingsView(model: harness.model, group: "大师调音").tabItem { Text("耳机设置") }
                ApplicationSettingsView(model: harness.model).tabItem { Text("应用设置") }
            }
            #else
            HeadsetSettingsView(model: harness.model, group: "大师调音")
            #endif
            if Bundle.main.object(forInfoDictionaryKey: "SoundPreviewPending") as? Bool == true {
                HStack {
                    Text("离线测试回复：")
                    Button("模拟确认") { harness.finishPending() }
                    Button("模拟不同读回") { harness.finishPending(mismatch: true) }
                }.font(.caption).padding(8)
            }
        }.environment(\.colorScheme, dark ? .dark : .light)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 780, height: 990), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.title = "SonoFerry 大师调音 · 离线模拟"; window.contentView = NSHostingView(rootView: view)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { _ in
            MainActor.assumeIsolated { UserDefaults(suiteName: harness.suite)?.removePersistentDomain(forName: harness.suite); exit(0) }
        }
        NSApp.run()
    }
}

#endif
