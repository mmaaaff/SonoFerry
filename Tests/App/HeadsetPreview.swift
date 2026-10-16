import AppKit
import SwiftUI
import SonoFerryCore
@main struct RenderHeadset {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = EngineClient(previewMode: true); model.launch()
        for (name, group) in [("status","设备状态"),("keys","操作"),("sound","大师调音"),("golden","黄金听感"),("wear","连接与佩戴")] {
            let view = HeadsetSettingsView(model: model, group: group).content.frame(width: 586).fixedSize(horizontal: false, vertical: true).background(Color.white).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            guard let cg = renderer.cgImage else { exit(2) }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
            try! data.write(to: URL(fileURLWithPath: CommandLine.arguments.last! + "/preview-" + name + ".png"))
        }
        for (name, dark, bassOn, custom, empty) in [("sound-dark",true,false,false,false), ("sound-custom-bass",true,true,true,false), ("sound-empty",false,false,false,true)] {
            if empty { model.headset?.equalizers = .init([]); model.headset?.preset = .init(0) }
            if custom { model.headset?.preset = .init(255); model.headset?.equalizers?.value[1].selected = true }
            model.headset?.features[29] = .init(bassOn)
            let renderer = ImageRenderer(content: HeadsetSettingsView(model: model, group: "大师调音").content.frame(width: 586).fixedSize(horizontal: false, vertical: true)
                .background(dark ? Color(white: 0.10) : Color.white).environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments.last! + "/preview-" + name + ".png"))
        }
        if let draft = model.headset?.newEqualizer {
            let renderer = ImageRenderer(content: HeadsetEQEditor(model: model, request: .init(curve: draft, snapshot: model.headset!, creating: true, importing: true)).fixedSize().background(Color.white).environment(\.colorScheme, .light))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments.last! + "/preview-eq-editor.png"))
        }
    }
}
