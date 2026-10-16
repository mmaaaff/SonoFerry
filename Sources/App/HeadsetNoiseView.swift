import SwiftUI
import SonoFerryCore

struct HeadsetNoiseView: View {
    @ObservedObject var model: EngineClient
    let snapshot: HeadsetSnapshot
    @State private var pendingGroup: HeadsetNoiseGroup?
    @State private var remembered: [HeadsetNoiseGroup: UInt8] = [:]
    // Wearing state changes the presentation only; retain the reported mode for re-wearing.
    private var group: HeadsetNoiseGroup? { snapshot.bothEarsUnworn ? .off : pendingGroup ?? snapshot.noise.flatMap { value in ((snapshot.profile?.noiseModes ?? []) + (snapshot.profile?.noise ?? [])).first { $0.protocolIndex == value.value }?.group } }
    private func choose(_ mode: UInt8, group: HeadsetNoiseGroup) {
        if model.setHeadset(.noise(mode)) != nil { pendingGroup = group; if (snapshot.profile?.modes(in: group) ?? []).contains(mode) { remembered[group] = mode } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("降噪控制").font(.callout.weight(.medium))
                Spacer()
                if snapshot.bothEarsUnworn {
                    Text("佩戴耳机以启用降噪").font(.caption).foregroundStyle(.secondary)
                }
                if model.headsetWriting { ProgressView().controlSize(.mini) }
            }
            HStack(spacing: 6) {
                ForEach(snapshot.profile?.noiseGroups ?? [], id: \.self) { item in
                    let modes = (snapshot.profile?.modes(in: item) ?? []).filter(snapshot.noiseChoices.contains)
                    Button {
                        let mode: UInt8? = item == .adaptive && snapshot.noiseChoices.contains(11) ? 11 : remembered[item].flatMap { modes.contains($0) ? $0 : nil } ?? (modes.contains(item.defaultMode) ? item.defaultMode : modes.first)
                        if let mode { choose(mode, group: item) }
                    } label: {
                        VStack(spacing: 6) {
                            NoiseModeIcon(mode: item).fill().frame(width: 24, height: 24).opacity(0.9)
                            Text(item.rawValue).font(.callout.weight(group == item ? .semibold : .regular))
                        }.padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(group == item ? Color.white : snapshot.bothEarsUnworn ? Color.secondary : Color.primary)
                            // accentColor resolves to gray inside a disabled macOS control.
                            .background(group == item ? (snapshot.bothEarsUnworn ? Color.blue.opacity(0.5) : Color.accentColor) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(group == item ? "已选择" : "未选择")
                        .disabled(snapshot.bothEarsUnworn || !model.canControlHeadset || !snapshot.canChooseNoise || modes.isEmpty)
                        .saturation(snapshot.bothEarsUnworn ? 0.55 : 1)
                }
            }
            if let group, (snapshot.profile?.modes(in: group).count ?? 0) > 1 {
                VStack(spacing: 0) {
                    ForEach((snapshot.profile?.modes(in: group) ?? []).filter(snapshot.noiseChoices.contains), id: \.self) { mode in
                        if let profile = snapshot.profile {
                            let detail = profile.noiseDetail(mode)
                            Button { choose(mode, group: group) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 7) {
                                            Text(mode == 7 ? snapshot.intelligentNoiseTitle ?? detail.name : detail.name).font(.callout)
                                            if profile.realtimeNoiseBadge(mode) { RealtimeNoiseBadge() }
                                        }
                                        Text(detail.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: snapshot.noise?.value == mode ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(snapshot.noise?.value == mode ? Color.accentColor : Color.secondary)
                                }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!model.canControlHeadset || snapshot.restriction(for: .noise(mode)) != nil)
                                .saturation(snapshot.bothEarsUnworn ? 0 : 1).opacity(snapshot.bothEarsUnworn ? 0.75 : 1)
                                .accessibilityLabel(detail.name).accessibilityValue(snapshot.noise?.value == mode ? "已选择" : "未选择")
                            if mode != snapshot.profile?.modes(in: group).last { Divider().opacity(0.5) }
                        }
                    }
                }
            }
            if !snapshot.bothEarsUnworn && (snapshot.noise?.stale != false || group == nil) {
                Text(model.headsetResumeInProgress ? "正在恢复耳机状态" : snapshot.noise == nil ? "降噪状态尚未读取，请刷新" : "当前状态尚未确认，请刷新").font(.caption).foregroundStyle(.secondary)
                    .opacity(model.isManuallyRefreshingHeadset ? 0 : 1)
                    .accessibilityHidden(model.isManuallyRefreshingHeadset)
            }
            if model.headsetWriting {
                if !model.visibleHeadsetMessage.isEmpty { Text(model.visibleHeadsetMessage).font(.caption).foregroundStyle(.secondary) }
            }
            else if let result = model.lastHeadsetResult, case .noise = result.setting, !result.confirmed {
                Text(result.message).font(.caption).foregroundStyle(.orange)
            }
            if !model.headsetResumeInProgress, let error = EngineClient.visibleControlIssue(snapshot.issues[HeadsetQuery.noiseCurrent.key]) { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .onChange(of: model.headsetWriting) { _, busy in if !busy { pendingGroup = nil } }
        .onChange(of: snapshot.noise?.value) { _, mode in if let mode, let group = snapshot.profile?.noiseModes.first(where: { $0.protocolIndex == mode })?.group { remembered[group] = mode } }
        .onChange(of: snapshot.generation) { _, _ in pendingGroup = nil; remembered = [:] }
        .onChange(of: snapshot.address) { _, _ in pendingGroup = nil; remembered = [:] }
        .onChange(of: snapshot.connected) { _, connected in if !connected { pendingGroup = nil } }
    }
}
