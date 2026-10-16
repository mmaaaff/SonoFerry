import AppKit
import SwiftUI
import SonoFerryCore
@main struct RenderSettingsSyncViews {
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
        try save(ApplicationSettingsView(model: m), name: "settings-light", width: 680, height: 660)
        try save(ApplicationSettingsView(model: m), name: "settings-dark", width: 680, height: 660, dark: true)
        m.headset?.ears[1] = .init(.init(raw: 1)); m.headset?.ears[2] = .init(.init(raw: 1))
        try save(HeadsetNoiseView(model: m, snapshot: m.headset!).padding(20), name: "noise-unworn", width: 440)
        m.headset?.ears[1] = .init(.init(raw: 3))
        try save(HeadsetNoiseView(model: m, snapshot: m.headset!).padding(20), name: "noise-one-ear", width: 440)
        m.status = "已连接"; m.details["driverRevision"] = "6"
        try save(ControlPanelContainer(model: m), name: "footer-light", width: 440, height: 660, scrollToEnd: true)
        try save(ControlPanelContainer(model: m), name: "footer-dark", width: 440, height: 660, dark: true, scrollToEnd: true)
        var report = OppoProbeReport(); report.hiRes = true; m.oppoReport = report
        try save(HiResControls(model: m).padding(20), name: "hires-refresh", width: 440)
        print("Rendered settings, wearing controls, footer and HiRes with synthetic data only.")
    }
}
