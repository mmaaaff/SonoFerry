import AppKit
import SwiftUI
import SonoFerryCore

/// Isolated production-view render. No engine, system observation, Bluetooth or playback.
@main struct FamilyProfileRender {
    @MainActor static func save<V: View>(_ view: V, name: String, width: CGFloat = 586) throws {
        let renderer = ImageRenderer(content: view.frame(width: width).fixedSize(horizontal: false, vertical: true).padding(20).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ProtocolFailure("render failed") }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "local.SonoFerry.FamilyRender." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let model = EngineClient(previewMode: true, preferences: prefs, messageSink: { _ in })
        for (id, stem): (UInt32, String) in [(0x06ec10,"x4"),(0x061410,"enco-x"),(0x06f010,"air4s"),(0x06b450,"r5")] {
            var s = HeadsetSnapshot(address: "00:11:22:33:44:55")
            s.connected = true; s.productID = id; s.serviceUUID = HeadphoneProfile.find(id)?.serviceUUID
            s.capabilities = try .init(reply: .init(command: 0x8100, payload: [0] + Array(repeating: 255, count: 9)))
            s.noise = .init(id == 0x061410 ? 3 : id == 0x06ec10 ? 4 : 0); s.noiseType = .init(1)
            s.preset = .init(0); s.equalizers = .init([]); s.features[29] = .init(false)
            s.keys = .init([.init(ear: 1, action: 1, function: 1),.init(ear: 2, action: 2, function: 6)])
            model.headset = s
            if s.supports(.noiseCurrent) { try save(HeadsetNoiseView(model: model, snapshot: s), name: stem + "-noise", width: 400) }
            try save(HeadsetSoundView(model: model, snapshot: s), name: stem + "-sound")
            try save(HeadsetSettingsView(model: model, group: "操作").content, name: stem + "-gestures")
        }
        print("Family views rendered with synthetic state; no real devices used.")
    }
}
