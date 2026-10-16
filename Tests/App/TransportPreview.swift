import AppKit
import SwiftUI
import SonoFerryCore
@main struct RenderTransport {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for codec in [CodecID.lhdcV5, .ldac] {
            let model = EngineClient(previewMode: true)
            model.devices = [.init(address: "00:11:22:33:44:55", name: codec == .lhdcV5 ? "Enco X4 · 模拟" : "LDAC 耳机 · 模拟", connected: true, a2dpSink: true)]
            model.selectedAddress = model.devices[0].address
            let bytes: [UInt8] = codec == .lhdcV5 ? [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x16,0x11,0x40,0] : [0,255,0x2d,1,0,0,0xaa,0,0x3c,7]
            model.capabilities = [try! CapabilityParser.codec(endpoint: 3, bytes: bytes)]
            model.selectedCapability = model.capabilities[0].id; model.probeComplete = true
            model.nativeCodecID = 2; model.status = "查询或播放失败 · 模拟"; model.error = "耳机信令暂未就绪；自动尝试已结束。"
            if codec == .lhdcV5 { var h = HeadsetSnapshot(address: model.selectedAddress); h.productID = 0x06ec10; model.headset = h }
            for phase in ["failed", "waitingForDevice"] {
            model.connectionPhase = phase; model.busy = phase != "failed"
            model.error = phase == "failed" ? "耳机信令暂未就绪；自动尝试已结束。" : nil
            model.status = phase == "failed" ? "查询或播放失败 · 模拟" : "等待耳机连接稳定 · 模拟"
            let renderer = ImageRenderer(content: ControlPanel(model: model).fixedSize().background(Color.white).environment(\.colorScheme, .light))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { exit(2) }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments.last! + "/preview-transport-" + codec.rawValue + "-" + phase + ".png"))
            }
        }
    }
}
