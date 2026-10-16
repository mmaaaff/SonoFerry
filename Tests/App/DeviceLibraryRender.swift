import AppKit
import SwiftUI
import SonoFerryCore
@main struct RenderControlViews {
    @MainActor static func save<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat? = nil, dark: Bool = false, scrollToEnd: Bool = false) throws {
        let content = view.frame(width: width).frame(height: height).fixedSize(horizontal: false, vertical: height == nil)
            .background(dark ? Color.black : Color.white).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? host.fittingSize.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        if scrollToEnd {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            if let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: { $0.frame.height > 200 }), let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "render", code: 1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "render", code: 2) }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments.last! + "/" + name + ".png"))
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let h = try SoundPreviewHarness(); let m = h.model!
        defer { UserDefaults(suiteName: h.suite)?.removePersistentDomain(forName: h.suite) }
        try save(HeadsetSettingsView(model: m, group: "操作").content, name: "left-right-gestures", width: 586)
        let prefs = UserDefaults(suiteName: h.suite)!
        let x4 = m.devices[0], xm5 = BluetoothDevice(address: "00:11:22:33:44:66", name: "WH-1000XM5", connected: false, a2dpSink: true)
        prefs.set(try JSONEncoder().encode([RegisteredHeadphone(address: x4.address, model: .encoX4), .init(address: xm5.address, model: .wh1000xm5)]), forKey: "headphoneLibrary.v1")
        var menu: EngineClient!
        menu = EngineClient(previewMode: false, preferences: prefs, messageSink: { request in
            DispatchQueue.main.async {
                if request.kind == "oppoQuery" {
                    var reply = WireMessage("oppoResult", requestID: request.requestID, sessionID: request.sessionID)
                    reply.device = request.device
                    var report = OppoProbeReport(); report.currentCodecID = 2; reply.oppoReport = report; menu.receive(reply)
                } else if ["headsetWatch", "headsetRefresh"].contains(request.kind) {
                    var reply = WireMessage("headsetResult", requestID: request.requestID)
                    reply.device = request.device; reply.headset = menu.headset; reply.controlGeneration = menu.headset?.generation
                    menu.receive(reply)
                }
            }
        })
        menu.capabilities = [try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])]
        menu.selectedCapability = menu.capabilities[0].id; menu.probeComplete = true
        struct Cache: Encodable {
            let capabilities: [CodecCapabilities]; let selectedCapability: String
            let rate = 0; let quality = Quality.adaptive; let fixedBitrate = 0
        }
        prefs.set(try JSONEncoder().encode(Cache(capabilities: menu.capabilities, selectedCapability: menu.selectedCapability)), forKey: "device." + x4.address)
        var event = WireMessage("environment")
        event.environment = .init(generation: UUID(), revision: 1, devices: [x4,xm5], route: .init(uid: x4.address, bluetoothAddress: x4.address))
        menu.receive(event); menu.headset = m.headset; menu.headset?.currentCodec = 2; menu.nativeCodecID = 2
        menu.status = "已连接"; menu.detectedAt = Date(); menu.details["driverRevision"] = "6"
        try save(ControlPanelContainer(model: menu), name: "menu-fixed-footer", width: 440, height: 760)
        try save(ControlPanelContainer(model: menu), name: "menu-scrolled-footer", width: 440, height: 760, scrollToEnd: true)
        try save(ControlPanelContainer(model: menu), name: "menu-dark", width: 440, height: 760, dark: true)
        try save(ControlPanel(model: menu), name: "menu-full-content", width: 440)
        try save(HeadsetNoiseView(model: menu, snapshot: menu.headset!).padding(20), name: "noise-icons", width: 440)
        let emptyPrefs = UserDefaults(suiteName: h.suite + ".empty")!
        defer { emptyPrefs.removePersistentDomain(forName: h.suite + ".empty") }
        let empty = EngineClient(previewMode: true, preferences: emptyPrefs, messageSink: { _ in })
        empty.status = "请添加音频输出设备"; empty.details["driverRevision"] = "6"
        try save(ControlPanelContainer(model: empty), name: "first-launch-empty", width: 440, height: 660)
        print("Rendered production views with synthetic data only; no engine, Bluetooth or playback.")
    }
}
