import SwiftUI
import SonoFerryCore

struct HeadsetQuickControls: View {
    @ObservedObject var model: EngineClient
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let snapshot = model.headsetDisplaySnapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("耳机", systemImage: "earbuds")
                Button { model.refreshAllHeadset() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("全量刷新耳机状态")
                    .accessibilityLabel("全量刷新耳机状态")
                    .disabled(!model.canRefreshAllHeadset)
                if model.isManuallyRefreshingHeadset || model.isDetectingHiRes {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("检测中").font(.caption).foregroundStyle(.secondary)
                    }.fixedSize()
                }
                Spacer()
                Button("耳机设置") { model.watchHeadset(); openWindow(id: "headset"); NSApp.activate(ignoringOtherApps: true) }
            }
            if snapshot?.supports(.battery) == true { HStack(spacing: 14) {
                ForEach(snapshot?.batteryParts ?? [], id: \.self) { id in
                    let entry = snapshot?.battery[id]
                    let percent = entry?.value.percent.map { "\($0)%" } ?? "—"
                    let charging = entry?.value.charging == true ? " ⚡︎" : ""
                    let stale = entry?.stale == true && !model.isManuallyRefreshingHeadset ? " · 上次" : ""
                    Text((snapshot?.profile?.componentLabel(id) ?? HeadsetSnapshot.earLabel(id)) + " " + percent + charging + stale)
                        .font(.caption).foregroundStyle(entry?.stale == true ? .secondary : .primary)
                }
            }
            }
            if let s = snapshot, s.supports(.noiseCurrent) {
                Divider().opacity(0.5)
                HeadsetNoiseView(model: model, snapshot: s)
            }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .task { model.watchHeadset() }
    }
}
struct HeadsetSettingsView: View {
    @ObservedObject var model: EngineClient
    @State private var group = "设备状态"
    private var groups: [String] {
        guard let s = model.headsetDisplaySnapshot, s.profile != nil else { return ["设备状态"] }
        var result = ["设备状态"]
        if s.supports(.keys) { result.append("操作") }
        if s.supports(.preset) || s.supports(.equalizers) || s.supports(.bassWave) { result.append("大师调音") }
        if s.supports(.feature(.goldenSound)) { result.append("黄金听感") }
        if s.supports(.ears) || s.supports(.feature(.multipoint)) || s.supports(.feature(.wearDetection)) { result.append("连接与佩戴") }
        return result
    }
    init(model: EngineClient, group: String = "设备状态") {
        self.model = model; _group = State(initialValue: group)
    }
    var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            if group != "大师调音" { Text(group).font(.title3.weight(.semibold)) }
            if let snapshot = model.headsetDisplaySnapshot, snapshot.profile != nil, groups.contains(group) {
                switch group {
                case "设备状态": status(snapshot)
                case "操作": keys(snapshot)
                case "大师调音": HeadsetSoundView(model: model, snapshot: snapshot)
                case "黄金听感": golden(snapshot)
                default: connection(snapshot)
                }
            } else { Text("尚未确认此设备的控制状态。请选择已适配设备后刷新。 ").foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22).groupBoxStyle(HeadsetGroupStyle())
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedDeviceTitle).font(.title2.weight(.semibold))
                    if let profile = model.headsetDisplaySnapshot?.profile { Text(profile.name + " · " + profile.status).font(.caption).foregroundStyle(.secondary) }
                    Text(model.isManuallyRefreshingHeadset ? "正在刷新耳机状态" : model.headset?.connected == true ? "耳机控制已连接" : "未连接 · 展示上次收到的状态").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.headsetBusy || model.headsetWriting { ProgressView().controlSize(.small); Button("取消") { model.cancelHeadset() } }
                Button("刷新") { model.refreshHeadset(page: group) }.disabled(model.headsetBusy || model.headsetWriting || model.oppoBusy || model.previewMode)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                List(groups, id: \.self, selection: $group) { Text($0).padding(.vertical, 6) }.frame(width: 150)
                Divider()
                ScrollView { content }
            }
            if !model.visibleHeadsetMessage.isEmpty {
                Divider()
                Text(model.visibleHeadsetMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }.frame(minWidth: 720, minHeight: 560)
            .task(id: model.selectedAddress + ":" + group + ":" + (model.headset?.generation.uuidString ?? "none")) { model.loadHeadsetPage(group) }
    }
    private func issue(_ s: HeadsetSnapshot, _ query: HeadsetQuery) -> some View {
        Group {
            if let error = EngineClient.visibleControlIssue(s.issues[query.key]) { Label("读取失败：" + error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            else if let caps = s.capabilities, !query.supported(by: caps) { Text("耳机未报告此查询能力").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func status(_ s: HeadsetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(Set((s.supports(.battery) ? s.batteryParts : []) + (s.supports(.versions) ? s.versions?.value.map(\.device) ?? [] : []))).sorted(), id: \.self) { id in
                GroupBox(s.profile?.componentLabel(id) ?? HeadsetSnapshot.earLabel(id)) {
                    VStack(alignment: .leading, spacing: 6) {
                        let item = s.battery[id]
                        if s.supports(.battery) { HStack { Text(item?.value.percent.map { "\($0)%" } ?? "电量未知").font(.title2.monospacedDigit()); Spacer(); Text(item?.value.charging.map { $0 ? "正在充电" : "未充电" } ?? "充电状态未知") } }
                        if s.supports(.versions) { if let versions = s.versions?.value.filter({ $0.device == id && [2, 3].contains($0.kind) }), !versions.isEmpty {
                            ForEach(versions) { Text("固件 \($0.version)").font(.caption) }
                        } else { Text("固件版本未知").font(.caption).foregroundStyle(.secondary) } }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            issue(s, .battery); issue(s, .versions)
        }
    }
    private func keys(_ s: HeadsetSnapshot) -> some View {
        let visible = s.keys?.value.filter { !(s.profile?.allowedFunctions($0).isEmpty ?? true) } ?? []
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(Set(visible.map(\.ear))).sorted(), id: \.self) { ear in
                GroupBox(HeadsetSnapshot.earLabel(ear)) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach([false, true], id: \.self) { isCall in
                            let entries = visible.filter { $0.ear == ear && ($0.button == 6) == isCall }
                            if !entries.isEmpty {
                            if isCall { Divider().opacity(0.5).padding(.vertical, 4) }
                            Text(isCall ? "通话状态" : "非通话状态").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(entries) { key in
                                Picker(s.profile?.keyLabel(key) ?? key.actionLabel, selection: Binding(get: { key.function }, set: { value in
                                    var edited = key; edited.function = value; model.setHeadset(.key(edited))
                                })) {
                                    if !(s.profile?.allowedFunctions(key) ?? []).contains(key.function) { Text(key.functionLabel).tag(key.function) }
                                    ForEach((s.profile?.allowedFunctions(key) ?? []), id: \.self) { Text(HeadsetKey.functions[$0]!).tag($0) }
                                }.disabled(!model.canControlHeadset || s.keys?.stale != false || s.capabilities?.hasBit(3) != true || (s.profile?.allowedFunctions(key) ?? []).isEmpty)
                            }
                            }
                        }
                    }.padding(8)
                }
            }
            issue(s, .keys)
            if s.keys == nil { Text("操作配置尚未读取，请刷新").font(.caption).foregroundStyle(.secondary) }
            else if s.keys?.stale == true { Text("操作配置已过期，请刷新").font(.caption).foregroundStyle(.secondary) }
            else if visible.isEmpty { Text("当前键位没有已确认的适配规则").font(.caption).foregroundStyle(.secondary) }
            if s.keys?.value.contains(where: { s.profile?.allowedFunctions($0).contains(25) == true }) == true { Text("AI 摘要操控需要手机支持并开启 AI 摘要。这里保存耳机操作配置，Mac 不执行 AI 摘要。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func golden(_ s: HeadsetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                HStack {
                    Text(s.features[11].map { ($0.value ? "开启" : "关闭") + ($0.stale ? "（上次）" : "") } ?? "状态未确认")
                    Spacer()
                    Toggle("黄金听感", isOn: Binding(get: { s.features[11]?.value ?? false }, set: { model.setHeadset(.feature(.goldenSound, $0)) }))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(!model.canControlHeadset || s.restriction(for: .feature(.goldenSound, !(s.features[11]?.value ?? false))) != nil)
                }.padding(6)
            }
            Text("测试记录存储在手机中，请前往手机设置查看").font(.callout).foregroundStyle(.secondary)
            if let reason = s.restriction(for: .feature(.goldenSound, !(s.features[11]?.value ?? false))) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func feature(_ f: HeadsetFeature, _ s: HeadsetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let value = s.features[f.rawValue] {
                Toggle(f.title, isOn: Binding(get: { value.value }, set: { model.setHeadset(.feature(f, $0)) }))
                    .disabled(!model.canControlHeadset || s.restriction(for: .feature(f, !value.value)) != nil)
            } else { Text(f.title + "：未知").foregroundStyle(.secondary) }
            issue(s, .feature(f))
        }
    }
    private func connection(_ s: HeadsetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if s.supports(.feature(.multipoint)) { feature(.multipoint, s)
            Text("切换双连可能断开当前连接。断开后等待重新连接确认，不重复发送设置。").font(.caption).foregroundStyle(.secondary)
            }
            if s.supports(.feature(.wearDetection)) { Divider(); feature(.wearDetection, s) }
            HStack {
                ForEach(s.earParts, id: \.self) { ear in
                    Text(HeadsetSnapshot.earLabel(ear) + "：" + (s.ears[ear].map { ($0.value.inEar ? "已佩戴" : "未佩戴") + ($0.stale ? "（上次）" : "") } ?? "未知"))
                }
            }.font(.caption)
            if s.isX4 { Toggle("Mac 摘戴播放联动", isOn: Binding(get: { model.wearAutomation }, set: { model.setWearAutomation($0) })).disabled(model.previewMode) }
        }
    }
}
private struct HeadsetGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label.font(.callout.weight(.semibold))
            configuration.content
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}
