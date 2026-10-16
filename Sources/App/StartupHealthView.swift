import SwiftUI
import SonoFerryCore

struct StartupHealthView: View {
    @ObservedObject var health: StartupHealthController
    @ObservedObject var model: EngineClient
    @State private var confirmingRestart = false
    var body: some View {
        if health.checking || health.operating || !health.issues.isEmpty || !health.message.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if health.checking { HStack { ProgressView().controlSize(.mini); Text("正在检查驱动与权限…").font(.caption) } }
                ForEach(health.issues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if let action = issue.action {
                            HStack {
                                Spacer(minLength: 0)
                                if action == .restart {
                                    Button("仅热重启音频服务", role: .destructive) { confirmingRestart = true }
                                        .foregroundStyle(.red)
                                        .disabled(health.checking || health.operating || health.restartAttempted || !model.canPrepareAudioRestart)
                                } else {
                                    Button(title(action)) { health.request(action) { model.send(WireMessage("authorize")) } }
                                        .disabled(health.checking || health.operating || model.previewMode)
                                }
                            }.controlSize(.small)
                            if action == .restart && !model.canPrepareAudioRestart && !health.operating {
                                Text("请先切换回系统默认编码并等待当前操作结束").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !health.message.isEmpty {
                    HStack(alignment: .top) {
                        if health.operating { ProgressView().controlSize(.mini) }
                        Text(health.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    if health.canAcknowledgeRestartNotice {
                        HStack {
                            Spacer()
                            Button("我已知晓") { health.acknowledgeRestartNotice() }
                                .controlSize(.small)
                        }
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .alert("仅热重启音频服务？", isPresented: $confirmingRestart) {
                    Button("取消", role: .cancel) {}
                    Button("确认热重启音频服务", role: .destructive) {
                        health.restart(prepare: { try await model.prepareAudioRestart() }, finish: { model.finishAudioRestart(commandSucceeded: $0) })
                    }
                } message: { Text(StartupHealthController.restartWarning) }
        }
    }
    private func title(_ action: StartupIssue.Action) -> String {
        if health.requested.contains(action), [.bluetooth, .audioCapture].contains(action) { return "前往系统设置" }
        switch action {
        case .bluetooth: return "请求蓝牙授权"
        case .audioCapture: return "请求系统音频录制授权"
        case .audioSettings: return "前往系统设置"
        case .recheck: return "重新检查"
        case .restart: return "仅热重启音频服务"
        }
    }
}
