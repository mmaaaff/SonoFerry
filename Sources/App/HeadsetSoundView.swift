import SwiftUI
import SonoFerryCore

struct HeadsetSoundView: View {
    @ObservedObject var model: EngineClient
    let snapshot: HeadsetSnapshot
    @State private var editor: EQEditorRequest?
    @State private var deleting: EQEditorRequest?
    private var presets: [HeadsetSoundPreset] { snapshot.supports(.preset) ? (snapshot.profile?.soundPresets ?? []) : [] }
    private var curves: [HeadsetEQ] { snapshot.equalizers?.value ?? [] }
    private var creationReason: String? {
        guard let curve = snapshot.newEqualizer else { return curves.count >= snapshot.customEQLimit ? "均衡器容量已满，请先删除一个" : "请先刷新均衡器状态" }
        return snapshot.restriction(for: .createEqualizer(curve))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("推荐").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18)
                VStack(spacing: 0) {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                        Button { model.setHeadset(.preset(preset.id)) } label: {
                            HStack(spacing: 20) {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 12) { Text(preset.name).font(.title3); if snapshot.isX4 || preset.brand == "丹拿" { DynaudioBadge() } }
                                    Text(preset.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                SoundRadio(selected: snapshot.soundSelection == .preset(preset.id))
                            }.padding(.vertical, 18).contentShape(Rectangle())
                        }.buttonStyle(SoundRowButtonStyle()).disabled(!model.canControlHeadset || snapshot.restriction(for: .preset(preset.id)) != nil)
                            .accessibilityLabel(preset.name).accessibilityValue(snapshot.soundSelection == .preset(preset.id) ? "已选择" : "未选择")
                        if index < presets.count - 1 { Divider() }
                    }
                }.padding(.horizontal, 20).soundCard()
            }
            if snapshot.supports(.bassWave) { BassWaveCard(model: model, snapshot: snapshot) }
            if snapshot.supports(.equalizers) { VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("自定义").foregroundStyle(.secondary)
                    Spacer()
                    Button("导入均衡器") { openNew(importing: true) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .disabled(!model.canControlHeadset || creationReason != nil).help(creationReason ?? "导入手机分享的均衡器码")
                }.font(.callout).padding(.horizontal, 18)
                VStack(spacing: 0) {
                    ForEach(Array(curves.enumerated()), id: \.element.id) { index, curve in
                        HStack(spacing: 10) {
                            Button { model.setHeadset(.selectEqualizer(curve.id)) } label: {
                                HStack {
                                    Text(curve.name.isEmpty ? "未命名均衡器" : curve.name).font(.title3).lineLimit(2)
                                    Spacer()
                                }.padding(.vertical, 20).contentShape(Rectangle())
                            }.buttonStyle(SoundRowButtonStyle()).disabled(!model.canControlHeadset || snapshot.restriction(for: .selectEqualizer(curve.id)) != nil)
                                .accessibilityValue(snapshot.soundSelection == .equalizer(curve.id) ? "已选择" : "未选择")
                            Menu {
                                Button("编辑均衡器") { editor = .init(curve: curve, snapshot: snapshot) }
                                if let code = try? HeadsetEQShareCode.encode(curve.gains) {
                                    Button("复制分享码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                                }
                                Button("删除均衡器", role: .destructive) { deleting = .init(curve: curve, snapshot: snapshot) }
                                    .disabled(!model.canControlHeadset || snapshot.restriction(for: .deleteEqualizer(curve)) != nil)
                            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 26) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("编辑或删除“\(curve.name)”")
                            Button { model.setHeadset(.selectEqualizer(curve.id)) } label: {
                                SoundRadio(selected: snapshot.soundSelection == .equalizer(curve.id))
                                    .frame(minHeight: 44).contentShape(Rectangle())
                            }
                                .buttonStyle(SoundRowButtonStyle()).disabled(!model.canControlHeadset || snapshot.restriction(for: .selectEqualizer(curve.id)) != nil)
                                .accessibilityLabel("选择“\(curve.name)”")
                                .accessibilityValue(snapshot.soundSelection == .equalizer(curve.id) ? "已选择" : "未选择")
                        }
                        if index < curves.count - 1 { Divider() }
                    }
                    if curves.isEmpty { Text(snapshot.equalizers == nil ? "尚未读取均衡器" : "暂无自定义均衡器").foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity) }
                }.padding(.horizontal, 20).soundCard()
                HStack {
                    Button { openNew(importing: false) } label: { Label("新增均衡器", systemImage: "plus") }
                        .disabled(!model.canControlHeadset || creationReason != nil).help(creationReason ?? "创建自定义曲线")
                    Spacer(); Text("\(curves.count) / \(snapshot.customEQLimit)").monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 18)
            }
            }
            if snapshot.soundSelection == nil && snapshot.supports(.preset) {
                Text(snapshot.preset?.stale == true || snapshot.equalizers?.stale == true ? "音效状态已过期，请刷新后选择" : "当前音效尚未确认，请刷新")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach([HeadsetQuery.preset, .equalizers], id: \.key) { query in
                if let issue = EngineClient.visibleControlIssue(snapshot.issues[query.key]) { Text(issue).font(.caption).foregroundStyle(.orange) }
            }
        }
        .sheet(item: $editor) { request in HeadsetEQEditor(model: model, request: request) }
        .confirmationDialog("删除“\(deleting?.curve.name ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let target = deleting {
                Button("删除均衡器", role: .destructive) {
                    if target.matches(model.headset) { model.setHeadset(.deleteEqualizer(target.curve)) }
                    else { model.headsetMessage = "设备或控制连接已变化，请刷新后再删除" }
                    deleting = nil
                }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("将从耳机中删除此曲线，手机端也会同步。") }
    }
    private func openNew(importing: Bool) {
        if let draft = snapshot.newEqualizer { editor = .init(curve: draft, snapshot: snapshot, creating: true, importing: importing) }
    }
}
private struct SoundRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.primary).opacity(configuration.isPressed ? 0.65 : 1)
    }
}
private struct SoundRadio: View {
    let selected: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Color.blue : Color.secondary.opacity(0.65), lineWidth: selected ? 6 : 1.5)
            if selected { Circle().fill(.white).padding(6) }
        }.frame(width: 26, height: 26).accessibilityHidden(true)
    }
}
private extension View {
    func soundCard() -> some View { background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 24)) }
}
/// Keep the user's released value until the correlated operation ends. Intermediate
/// baseline/notification snapshots must not move the thumb back to the old value.
struct BassWaveSliderState {
    var draft: Double?
    private(set) var pendingValue: Int?
    var waiting: Bool { pendingValue != nil }
    func displayed(_ actual: Int) -> Double { pendingValue.map(Double.init) ?? draft ?? Double(actual) }
    mutating func changed(_ value: Double) { if !waiting { draft = value } }
    mutating func release(actual: Int) -> Int? {
        guard !waiting, let draft else { return nil }
        let value = Int(draft.rounded())
        guard value != actual else { reset(); return nil }
        pendingValue = value; return value
    }
    mutating func reset() { draft = nil; pendingValue = nil }
}

/// Discrete values are labelled below their tick, sharing the same scale as the slider.
/// The current value remains available to VoiceOver without a separate trailing label.
private struct SoundValueSlider: View {
    @Binding var value: Double
    let minimum: Int
    let maximum: Int
    var unit = ""
    var editingChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: Double(minimum)...Double(max(minimum + 1, maximum)), onEditingChanged: editingChanged)
                .accessibilityValue("\(Int(value))\(unit)")
                .accessibilityAdjustableAction { direction in
                    editingChanged(true)
                    switch direction {
                    case .increment: value = min(Double(maximum), value + 1)
                    case .decrement: value = max(Double(minimum), value - 1)
                    @unknown default: break
                    }
                    editingChanged(false)
                }
            GeometryReader { geometry in
                ForEach(Array(minimum...maximum), id: \.self) { level in
                    Text("\(level)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(enabled && level == Int(value) ? Color.accentColor : Color.secondary)
                    .position(x: 8 + max(0, geometry.size.width - 16) * Double(level - minimum) / Double(max(1, maximum - minimum)), y: 10)
                }
            }.frame(height: 23).accessibilityHidden(true)
        }.opacity(enabled ? 1 : 0.5)
    }
}
private struct BassWaveCard: View {
    @ObservedObject var model: EngineClient
    let snapshot: HeadsetSnapshot
    @State private var slider = BassWaveSliderState()
    private var feature: HeadsetValue<Bool>? { snapshot.features[HeadsetFeature.bassWave.rawValue] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("BassWave\(Text("TM").font(.system(size: 9, weight: .medium)).baselineOffset(7))动态低音").font(.title3)
                    Text("动态增益低音，清晰且高保真地呈现深邃低音效果。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("BassWave 动态低音", isOn: Binding(get: { feature?.value ?? false }, set: { model.setHeadset(.feature(.bassWave, $0)) }))
                    .toggleStyle(.switch).labelsHidden().tint(.blue)
                    .disabled(!model.canControlHeadset || snapshot.restriction(for: .feature(.bassWave, !(feature?.value ?? false))) != nil)
            }
            if feature == nil || (feature?.stale == true && !slider.waiting) {
                Text(snapshot.capabilities?.hasBit(38) == false ? "耳机未报告 BassWave 能力" : "状态未确认，请刷新").font(.caption).foregroundStyle(.secondary)
            }
            if feature?.value == true {
                if let bass = snapshot.bassWave {
                    HStack(spacing: 12) {
                        Text("减弱").padding(.bottom, 23)
                        SoundValueSlider(value: Binding(get: { slider.displayed(bass.value.current) }, set: { slider.changed($0) }),
                                         minimum: bass.value.minimum, maximum: bass.value.maximum) { dragging in
                            if !dragging, let value = slider.release(actual: bass.value.current) {
                                if model.setHeadset(.bassWave(value)) == nil { slider.reset() }
                            }
                        }
                        .disabled(slider.waiting || !model.canControlHeadset || bass.value.minimum == bass.value.maximum || snapshot.restriction(for: .bassWave(bass.value.current)) != nil)
                        Text("增强").padding(.bottom, 23)
                    }.font(.caption).foregroundStyle(.secondary)
                    if !slider.waiting && bass.stale { Text("强度状态未确认，请刷新").font(.caption).foregroundStyle(.secondary) }
                } else { Text("强度尚未读取，请刷新").font(.caption).foregroundStyle(.secondary) }
            }
            if let error = EngineClient.visibleControlIssue(snapshot.issues[HeadsetQuery.feature(.bassWave).key]) ?? EngineClient.visibleControlIssue(snapshot.issues[HeadsetQuery.bassWave.key]) {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }.padding(20).soundCard()
            .onChange(of: model.headsetWriting) { _, busy in if !busy && slider.waiting { slider.reset() } }
            .onChange(of: snapshot.address) { _, _ in slider.reset() }
            .onChange(of: snapshot.generation) { _, _ in slider.reset() }
            .onChange(of: snapshot.connected) { _, connected in if !connected { slider.reset() } }
    }
}
struct EQEditorRequest: Identifiable {
    let id = UUID()
    let curve: HeadsetEQ
    var creating = false
    var importing = false
    let address: String
    let generation: UUID
    init(curve: HeadsetEQ, snapshot: HeadsetSnapshot, creating: Bool = false, importing: Bool = false) {
        self.curve = curve; address = snapshot.address; generation = snapshot.generation
        self.creating = creating; self.importing = importing
    }
    func matches(_ snapshot: HeadsetSnapshot?) -> Bool {
        snapshot?.address == address && snapshot?.generation == generation
    }
}
struct HeadsetEQEditor: View {
    @ObservedObject var model: EngineClient
    let request: EQEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HeadsetEQ
    @State private var code = ""
    @State private var importError: String?
    @State private var imported: Bool
    @State private var pending: HeadsetSetting?
    init(model: EngineClient, request: EQEditorRequest) {
        self.model = model; self.request = request; _draft = State(initialValue: request.curve); _imported = State(initialValue: !request.importing)
    }
    private var setting: HeadsetSetting { request.creating ? .createEqualizer(draft) : .equalizer(draft, replacing: request.curve) }
    private var restriction: String? {
        guard request.matches(model.headset) else { return "设备或控制连接已变化，请关闭后重新打开均衡器" }
        return model.headset?.restriction(for: setting)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.importing ? "导入均衡器" : request.creating ? "新增均衡器" : "编辑均衡器").font(.title2.weight(.semibold))
            TextField("均衡器名称", text: $draft.name).textFieldStyle(.roundedBorder).disabled(model.headsetWriting)
            if request.importing {
                HStack {
                    TextField("输入手机分享的均衡器码", text: $code).textFieldStyle(.roundedBorder)
                        .onChange(of: code) { _, _ in imported = false; importError = nil }
                    Button("读取") {
                        do { draft.gains = try HeadsetEQShareCode.decode(code, bands: draft.frequencies.count); imported = true; importError = nil }
                        catch { importError = error.localizedDescription }
                    }.disabled(code.isEmpty)
                }.disabled(model.headsetWriting)
                if let importError { Text(importError).font(.caption).foregroundStyle(.orange) }
                Text("分享码只包含增益；请使用相同型号、相同频段的均衡器码。").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(draft.frequencies.enumerated()), id: \.offset) { index, frequency in
                        HStack(spacing: 12) {
                            Text(frequency >= 1000 ? "\(Double(frequency) / 1000, specifier: "%g") kHz" : "\(frequency) Hz").font(.caption.monospacedDigit()).frame(width: 70, alignment: .leading)
                            SoundValueSlider(value: Binding(get: { Double(draft.gains[index]) }, set: { draft.gains[index] = Int($0.rounded()) }),
                                             minimum: draft.minimum, maximum: draft.maximum, unit: " dB")
                                .accessibilityLabel("\(frequency) Hz 增益")
                                .disabled(model.headsetWriting || draft.minimum == draft.maximum)
                        }
                    }
                }.padding(.vertical, 4)
            }.frame(maxHeight: 340)
            Text("\(draft.frequencies.count) 个频段 · \(draft.minimum)…\(draft.maximum) dB" + (request.creating ? "" : " · 保存后使用此均衡器"))
                .font(.caption).foregroundStyle(.secondary)
            if let restriction { Text(restriction).font(.caption).foregroundStyle(.orange) }
            if pending != nil && !model.visibleHeadsetMessage.isEmpty { Text(model.visibleHeadsetMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("重置曲线") { draft.gains = Array(repeating: min(draft.maximum, max(draft.minimum, 0)), count: draft.gains.count) }.disabled(model.headsetWriting)
                Spacer()
                if model.headsetWriting { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.disabled(model.headsetWriting)
                Button(request.creating ? "保存均衡器" : "保存并使用") { guard request.matches(model.headset) else { return }; pending = setting; model.setHeadset(setting) }
                    .buttonStyle(.borderedProminent).disabled(!model.canControlHeadset || restriction != nil || !imported || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 500).interactiveDismissDisabled(model.headsetWriting)
            .onChange(of: model.lastHeadsetResult) { _, result in
                if let result, result.setting == pending, result.confirmed { dismiss() }
            }
    }
}
