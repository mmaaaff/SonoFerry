import AppKit
import SwiftUI
import SonoFerryCore

// Native hosting preserves NSSwitch/NSProgressIndicator rendering. The injected
// transport records messages only; this preview cannot access a real headset.
@main struct HiResPreview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let suite = "local.SonoFerry.HiResPreview." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let titles = ["检测中 · 模拟", "已确认开启 · 模拟", "已确认关闭 · 模拟", "读取失败 · 模拟"]
        let models = try titles.indices.map { index -> EngineClient in
            var commands: [WireMessage] = []
            let model = EngineClient(previewMode: false, preferences: preferences, messageSink: { commands.append($0) })
            let device = BluetoothDevice(address: "00:11:22:33:44:55", name: "模拟耳机", connected: true, a2dpSink: true)
            model.devices = [device]; model.selectedAddress = device.address
            model.capabilities = [try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x06,0x11,0,0])]
            model.selectedCapability = model.capabilities[0].id; model.probeComplete = true
            model.start()
            let start = commands.last!
            var active = WireMessage("active", sessionID: start.sessionID)
            active.configuration = start.configuration; active.format = start.configuration?.format; model.receive(active)
            if index != 0 {
                let query = commands.last!
                var result = WireMessage(index == 3 ? "oppoFailed" : "oppoResult", requestID: query.requestID, sessionID: query.sessionID)
                result.device = device
                var report = OppoProbeReport(); report.hiRes = index == 1; report.currentCodecID = 8
                report.controlCapabilities = try .init(reply: .init(command: 0x8100, payload: [0,0x80,0,2,0,0x20]))
                result.oppoReport = report; result.message = index == 3 ? "查询超时，可手动重试。" : "耳机状态已刷新"
                model.receive(result)
            }
            return model
        }
        let view = VStack(alignment: .leading, spacing: 12) {
            ForEach(titles.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(titles[i]).font(.headline)
                    HiResControls(model: models[i])
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(16).frame(width: 440).background(Color.white).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.title = "SonoFerry HiRes · 模拟界面"; window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        // Leave a bounded window for native screenshot/accessibility inspection.
        Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in
            MainActor.assumeIsolated {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                exit(0)
            }
        }
        NSApp.run()
    }
}
