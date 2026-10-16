import SwiftUI
import SonoFerryCore

struct ApplicationSettingsView: View {
    @ObservedObject var model: EngineClient
    @State private var showsBufferInfo = false
    @State private var confirmsReset = false
    var body: some View {
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("应用设置").font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("外观").font(.headline)
                        HStack(spacing: 10) {
                            ForEach(ApplicationAppearance.allCases, id: \.self) { item in
                                Button { model.appearance = item } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: item.symbol).font(.title2)
                                        Text(item.title).font(.callout.weight(.medium))
                                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                                        .foregroundStyle(model.appearance == item ? Color.accentColor : Color.primary)
                                        .background(model.appearance == item ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.appearance == item ? Color.accentColor.opacity(0.5) : .clear))
                                }.buttonStyle(.plain).accessibilityValue(model.appearance == item ? "已选择" : "未选择")
                            }
                        }.disabled(model.localDataBusy || model.previewMode)
                    }
                    bufferingControls
                    VStack(spacing: 10) {
                        Button(role: .destructive) { confirmsReset = true } label: {
                            Text("清空应用数据").font(.callout.weight(.medium)).foregroundStyle(.red)
                        }.buttonStyle(.plain).disabled(model.localDataBusy || model.libraryActionBusy || model.previewMode)
                        if model.localDataBusy { ProgressView().controlSize(.small) }
                        if !model.localDataMessage.isEmpty { Text(model.localDataMessage).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity).padding(.top, 4)
                }.frame(maxWidth: 650).frame(maxWidth: .infinity).padding(28)
            }.tabItem { Label("应用设置", systemImage: "gearshape") }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("能力与诊断").font(.title2.weight(.semibold)); Spacer(); Button("导出诊断") { model.export() } }
                    CapabilityDetails(model: model)
                }.padding(24)
            }.tabItem { Label("能力与诊断", systemImage: "info.circle") }
            aboutPage.tabItem { Label("关于", systemImage: "info.circle.fill") }
        }.frame(minWidth: 580, minHeight: 500)
            .alert("清空应用数据？", isPresented: $confirmsReset) {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) { model.clearApplicationData() }
            } message: {
                Text("将停止高清发送，清空已添加设备、能力缓存、应用偏好和诊断记录，并恢复默认设置。耳机自身设置和系统蓝牙配对不受影响。")
            }
    }
    private var aboutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("关于 SonoFerry").font(.title2.weight(.semibold))
                    Text("版本 \(ApplicationVersion.display)").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("耳机功能与标识说明").font(.headline)
                    Text("丹拿联合调音、降噪、BassWave 等为相应耳机的内置功能。SonoFerry 仅提供这些功能的独立控制，相关名称与图标用于识别对应的耳机功能。")
                    Text("丹拿联合调音及“CO-CREATED WITH DYNAUDIO”标识指耳机及其内置调音，不表示 SonoFerry 与丹拿联合开发。")
                    Text("SonoFerry 与丹拿及相关品牌无官方合作或背书关系。相关名称、商标及图标的权利归各自权利人所有。")
                }.font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.frame(maxWidth: 650, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading).padding(28)
        }
    }
    private var bufferingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Text("缓冲与追赶").font(.headline)
                Button { showsBufferInfo.toggle() } label: { Image(systemName: "info.circle").font(.callout).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("关于缓冲与追赶").accessibilityLabel("关于缓冲与追赶")
                    .popover(isPresented: $showsBufferInfo) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("缓冲与追赶").font(.headline)
                            Text("连续追赶达到时限才跳过；跳过后保留启动预缓冲量。追上后重新计时。")
                            Text("这是本机缓冲。追赶时限为 0.1–15.0 秒，步长 0.1 秒；预缓冲为 10–1000 ms，步长 1 ms。按设备保存，修改后自动应用；新的预缓冲目标用于后续跳过和下次启动。")
                                .foregroundStyle(.secondary)
                        }.font(.callout).padding(18).frame(width: 310)
                    }
            }
            VStack(spacing: 22) {
                bufferingRow("追赶最长持续", key: \.catchupLimitTenths, range: 1...150,
                             value: String(format: "%.1f 秒", Double(model.catchupLimitTenths) / 10))
                bufferingRow("启动预缓冲", key: \.prefillMilliseconds, range: 10...1000,
                             value: "\(model.prefillMilliseconds) ms")
            }.padding(18).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                .disabled(!model.canEditSettings || model.device == nil || model.previewMode)
        }
    }
    private func bufferingRow(_ title: String, key: ReferenceWritableKeyPath<EngineClient, Int>, range: ClosedRange<Int>, value: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
                Stepper(title, value: bufferingBinding(key), in: range).labelsHidden().fixedSize()
            }
            // Round the binding instead of requesting native ticks for all 991 positions.
            Slider(value: Binding(get: { Double(model[keyPath: key]) }, set: { bufferingBinding(key).wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)).accessibilityLabel(title)
        }
    }
    private func bufferingBinding(_ key: ReferenceWritableKeyPath<EngineClient, Int>) -> Binding<Int> {
        Binding(get: { model[keyPath: key] }, set: { value in
            guard model.canEditSettings, model[keyPath: key] != value else { return }
            model[keyPath: key] = value; model.bufferingChanged()
        })
    }
}
