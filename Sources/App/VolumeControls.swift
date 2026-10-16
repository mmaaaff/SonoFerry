import SwiftUI
import SonoFerryCore

struct VolumeControls: View {
    @ObservedObject var model: EngineClient
    @State private var showsInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("软件音量").font(.callout.weight(.medium))
                Toggle("启用软件音量", isOn: Binding(get: { model.softwareVolumeEnabled }, set: { model.setSoftwareVolumeEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .accessibilityLabel("启用软件音量")
                Button { showsInfo.toggle() } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("软件音量说明").accessibilityLabel("软件音量说明")
                .popover(isPresented: $showsInfo, arrowEdge: .top) {
                    VolumeInformation()
                }
                Spacer()
                Text(model.gain == 0 ? "静音" : "\(Int(model.gain * 100))%").font(.caption.monospacedDigit())
            }
            HStack {
                Button { model.setGain(0) } label: {
                    Image(systemName: model.gain == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }.buttonStyle(.plain).help("静音").accessibilityLabel("静音")
                Slider(value: Binding(get: { model.gain }, set: { model.setGain($0) }), in: 0...1)
                    .accessibilityLabel("软件音量")
            }.disabled(!model.softwareVolumeEnabled)
            if HardwareVolumeSupport.available {
                Toggle("绑定耳机音量",
                       isOn: Binding(get: { model.linkHardwareVolume }, set: { model.setVolumeLink($0) }))
                    .toggleStyle(.checkbox).font(.caption).disabled(model.busy)
            }
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct VolumeInformation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("软件音量说明").font(.headline)
            Text("此处调节的是软件音量，与耳机自身音量相互独立，建议禁用该功能并在耳机端调节音量")
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
            .padding(16).frame(width: 300, alignment: .leading)
    }
}
