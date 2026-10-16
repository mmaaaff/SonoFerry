import SwiftUI
import AppKit
import CryptoKit
import SonoFerryCore

struct ControlPanel: View {
    @ObservedObject var model: EngineClient
    private var tint: Color { model.error != nil ? .orange : model.active ? .green : .accentColor }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("SonoFerry").font(.title2.weight(.semibold))
                    Text("LDAC / LHDC V5").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            DeviceLibraryView(model: model).disabled(model.audioMaintenance)
            StartupHealthView(health: model.startupHealth, model: model)
            HStack(spacing: 8) {
                if model.busy && !model.active { ProgressView().controlSize(.small) }
                else { Circle().fill(tint).frame(width: 7, height: 7) }
                Text(model.status).font(.callout).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            if model.device != nil {
                if model.showsHeadsetControls { HeadsetQuickControls(model: model) }
                codecSelector.disabled(model.audioMaintenance)
            }
            if model.showsHDSettings, let cap = model.capability {
                codecControls(cap).disabled(model.audioMaintenance)
            }
            if model.showsHDSettings {
                Label(model.showsLiveFormat ? "参数修改后点击“应用修改”，应用时会短暂重连。" : "参数已保存在本机，启用 \(model.capability?.codec?.title ?? "高清音频") 后才生效。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.settingsMessage.isEmpty { Text(model.settingsMessage).font(.caption).foregroundStyle(.secondary) }
            if model.showsHDSettings {
                VolumeControls(model: model)
            }
            if let error = model.error {
                if model.showsReconnectAdvice {
                    Text(EngineClient.reconnectAdvice).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }.padding(20).frame(width: 440)
    }
    private func parameterBinding<T: Equatable>(_ key: ReferenceWritableKeyPath<EngineClient, T>) -> Binding<T> {
        Binding(get: { model[keyPath: key] }, set: { value in
            guard model.canEditSettings, model[keyPath: key] != value else { return }
            model[keyPath: key] = value; model.parametersChanged()
        })
    }
    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var codecSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow("编码") {
                Picker("编码", selection: Binding(get: { model.transportChoice }, set: { model.chooseCodec($0) })) {
                    Text(model.systemCodecLabel).tag("system")
                    ForEach(model.codecChoices, id: \.self) { codec in
                        Text(codec.title).tag(codec.rawValue).disabled(!model.canChooseHDCodec)
                    }
                }.pickerStyle(.menu).disabled(model.device == nil || model.previewMode)
            }
            if model.transportChoice == "system" {
                Text("系统编码由 macOS 协商；仅显示已检测到的可用高清编码，连接时会再次核验。")
                if model.availableHDCodecs.isEmpty { Text(model.probeComplete ? "当前未检测到本机可用的高清编码。" : "请先检测耳机能力。") }
                if model.resettableCodec != nil {
                    Button("使用当前能力的默认参数连接") { model.useDefaultPlaybackSettings() }
                        .disabled(model.busy || model.oppoBusy)
                }

            } else if !model.showsLiveFormat {
                Text("正在连接；下方是本机目标参数，成功后显示实际协商结果。选择系统蓝牙可取消。")
            } else { Text("选择系统蓝牙可停用高清音频并恢复系统输出。") }
        }.font(.caption).foregroundStyle(.secondary).padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
    private func codecControls(_ cap: CodecCapabilities) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Text(model.transportSettingsTitle).foregroundColor(.secondary))\(Text(model.transportSettingsNotice.map { "  ·  " + $0 } ?? "").bold().foregroundColor(.orange))")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                settingRow("目标采样率") {
                    Picker("目标采样率", selection: parameterBinding(\.rate)) {
                        Text("自动 · 优先 \(Double(model.defaultRate) / 1000, specifier: "%g") kHz").tag(0)
                        ForEach(model.availableRates, id: \.self) { rate in
                            Text(String(format: "%g kHz", Double(rate) / 1000) + (model.commonRates.contains(rate) ? "" : "（强制启用）")).tag(rate)
                        }
                    }
                }
                settingRow("码率策略") {
                    Picker("码率策略", selection: parameterBinding(\.quality)) {
                        if cap.codec == .lhdcV5 {
                            Text("自适应").tag(Quality.adaptive); Text("固定码率").tag(Quality.connection)
                        } else {
                            ForEach(Quality.allCases, id: \.self) { value in Text(value.displayName).tag(value) }
                        }
                    }
                }
                if cap.codec == .lhdcV5 && model.quality != .adaptive {
                    settingRow("固定码率") {
                        Picker("固定码率", selection: parameterBinding(\.fixedBitrate)) {
                            Text("默认 · \((try? cap.configuration(rate: model.selectedRate, quality: .connection, allowUnreported: true).bitrateKbps) ?? 400) kbps").tag(0)
                            ForEach(model.bitrates, id: \.self) { bitrate in
                                Text("\(bitrate) kbps" + (cap.fixedBitrates(rate: model.selectedRate).contains(bitrate) ? "" : "（强制启用）")).tag(bitrate)
                            }
                        }
                    }
                }
            }.pickerStyle(.menu).controlSize(.regular).disabled(!model.canEditSettings)
            if model.showsHeadsetControls && model.headsetDisplaySnapshot?.supports(.feature(.hiRes)) == true && model.showsLiveFormat { HiResControls(model: model) }
            if model.showsApplySettings {
                HStack {
                    Spacer()
                    Button(model.applySettingsTitle) { model.requestApplySettings() }
                        .disabled(!model.canApplySettings)
                }
            }
            if model.showsLiveFormat, let format = model.format {
                Divider().opacity(0.5)
                HStack {
                    metric("协议采样率", String(format: "%g kHz", Double(format.sampleRateHz) / 1000))
                    Divider().frame(height: 28)
                    metric("实际编码码率", "\(format.bitrateKbps) kbps")
                    Divider().frame(height: 28)
                    metric("编码输入", model.currentInputDescription)
                }.padding(.top, 4)
            }
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption.monospacedDigit()) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HiResControls: View {
    @ObservedObject var model: EngineClient
    @State private var showingRefresh = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("HiRes 音频", isOn: Binding(get: { model.hiResDisplayedValue }, set: { model.setOppoHiRes($0) }))
                    .toggleStyle(.switch).fixedSize()
                    .disabled(!model.canSetOppoHiRes)
                    .accessibilityValue(model.hiResValue.map { $0 ? "开启" : "关闭" } ?? "状态未确认")
                if model.oppoBusy {
                    Button("取消读取 / 设置") { model.cancelOppo() }
                        .buttonStyle(.plain).foregroundStyle(.secondary).fixedSize()
                } else if showingRefresh {
                    Text("耳机状态已刷新").foregroundStyle(.secondary).transition(.opacity)
                }
                if !model.isDetectingHiRes {
                    if model.oppoBusy {
                        ProgressView().controlSize(.small)
                        Text("设置中").foregroundStyle(.secondary)
                    } else if model.hiResValue == nil {
                        Text("状态未确认").foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if !model.visibleOppoMessage.isEmpty { Text(model.visibleOppoMessage).foregroundStyle(.secondary) }
        }.font(.caption).padding(.top, 6)
            .task(id: model.hiResRefreshedAt) {
                showingRefresh = false
                guard let date = model.hiResRefreshedAt, !model.oppoBusy else { return }
                let remaining = 1 - Date().timeIntervalSince(date)
                guard remaining > 0 else { return } // Opening the menu later never replays an old success.
                showingRefresh = true
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                withAnimation(.easeOut(duration: 0.25)) { showingRefresh = false }
            }
    }
}

struct CapabilityDetails: View {
    @ObservedObject var model: EngineClient
    private func rateList(_ rates: [Int]) -> String { rates.isEmpty ? "未取得" : rates.map { String(format: "%g", Double($0) / 1000) }.joined(separator: " / ") + " kHz" }
    private func number(_ key: String, suffix: String = "") -> String { model.metrics[key].map { String(format: "%g", $0) + suffix } ?? "未取得" }
    private func pcmDuration(_ key: String) -> String {
        guard let frames = model.metrics[key] else { return "未取得" }
        let count = String(format: "%g 帧", frames)
        guard let rate = model.format?.sampleRateHz, rate > 0 else { return count }
        return count + String(format: "（%.0f ms）", frames * 1000 / Double(rate))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("耳机报告") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.capabilities.isEmpty { Text("尚未检测。选择耳机并检测能力后显示。").foregroundStyle(.secondary) }
                    ForEach(model.capabilities) { cap in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(cap.codecLabel) · 端点 \(cap.endpoint)").fontWeight(.medium)
                            if cap.codec != nil {
                                Text("采样率：" + rateList(cap.sampleRates))
                                Text("耳机报告位深：" + (cap.codec == .ldac ? "不可查询（能力报文无此字段）" : (cap.bitDepths ?? []).isEmpty ? "未取得" : (cap.bitDepths ?? []).map(String.init).joined(separator: " / ") + " bit"))
                                if let min = cap.minimumBitrate, let max = cap.maximumBitrate { Text("目标码率：\(min)–\(max) kbps") }
                            } else { Text("已识别端点，本版未实现该编码发送。").foregroundStyle(.secondary) }
                            Text(cap.rawHex).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("耳机控制协议 · 只读诊断") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.oppoReport == nil { Text("尚未取得控制能力；连接状态变化后自动重新读取。") }
                    if let report = model.oppoReport {
                        if let codec = report.currentCodecID {
                            Text("控制协议报告当前编码：" + OppoControlCodec.label(codec))
                        }
                        if let mask = report.codecListMask {
                            Text("控制协议编码列表：" + OppoControlCodec.ids(in: mask).map(OppoControlCodec.label).joined(separator: " / "))
                            Text("此列表不代表 AVDTP 已广播相应端点，也不代表 Mac 已协商使用。").font(.caption).foregroundStyle(.secondary)
                        }
                        if let caps = report.controlCapabilities {
                            Text("编码设置命令：\(caps.supportsCodecSelection ? "已报告" : "未报告") · 功能设置命令：\(caps.supportsFeatureSetter ? "已报告" : "未报告")")
                                .font(.caption)
                        }
                        if let mtu = report.controlReceiveMTU {
                            Text("耳机控制接收 MTU：\(mtu) 字节（不是音频媒体 MTU）").font(.caption)
                        }
                        Text("控制通道 \(report.channel) · 收到 \(report.receivedFrames) 帧")
                            .font(.caption)

                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            if let cap = model.capability, let codec = cap.codec {
                GroupBox("本机实现与可选参数") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本机采样率：" + rateList(codec.sampleRates))
                        Text("双方交集：" + rateList(model.commonRates))
                        Text("编码输入：" + model.inputDescription)
                        Text(codec == .ldac ? "Float32 描述编码器输入，不代表耳机位深。" : "本机支持 16 / 24-bit；不启用 Lossless 或未实现扩展。").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            GroupBox("采样率与系统音频路径") {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        detailRow("实际协议采样率", model.active ? rate(model.format.map { Double($0.sampleRateHz) }) : "高清协议未启用")
                        detailRow("SonoFerry 虚拟输出", rate(model.audioState?.virtualOutput?.sampleRate))
                        detailRow("系统蓝牙耳机输出", rate(model.audioState?.nativeOutput?.sampleRate))
                        detailRow("系统耳机可选格式", model.audioState?.nativeOutput.map { rateList($0.availableRates.map(Int.init)) } ?? "设备未出现")
                        detailRow("默认输出为 SonoFerry", model.audioState.map { $0.defaultIsVirtual ? "是" : "否" } ?? "未读取")
                    }
                    Text("自动策略：优先 48 kHz，其次 44.1 kHz，再选双方最低共同采样率；不跟随歌曲切换。")
                    Text("启用时可在音频 MIDI 设置中选择“耳机名称 · SonoFerry”修改采样率；应用会同步为手动采样率并自动重连。重连期间会短暂中断声音。")
                    Text("MIDI 仅列出当前编码器支持的采样率；耳机未报告的值仍按强制参数尝试，可在应用中查看标记。")
                    Text("MIDI 中的耳机项属于 macOS 原生蓝牙通路；SonoFerry 的 LDAC / LHDC 使用独立虚拟输出，采样率可以不同。")
                    Button("刷新系统音频状态") { model.refreshAudioState() }.disabled(model.previewMode)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("本次会话") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    detailRow("状态", model.active ? "持续发送中" : model.busy ? "准备 / 清理中" : "未在播放")
                    detailRow(model.active ? "实际编码码率" : "上次编码码率", model.format.map { "\($0.bitrateKbps) kbps" } ?? "未协商")
                    detailRow(model.active ? "本次协商位深" : "上次协商位深", model.negotiated?.negotiatedBitDepthDescription ?? "未协商")
                    detailRow("本次编码输入", model.negotiated?.encoderInputDescription ?? "未协商")
                    detailRow("强制参数", model.negotiated.map { $0.isForced ? $0.forcedDescription + "（尚未经听音验证）" : "无" } ?? "未协商")
                    detailRow("耳机音量绑定", "暂不可用 · 使用独立软件音量")
                    detailRow("捕获 → 编码", number("captureRate", suffix: " Hz") + " → " + number("pipelineRate", suffix: " Hz"))
                    detailRow("重采样", resampling)
                    detailRow("媒体 MTU", number("outgoingMTU", suffix: " 字节"))
                    detailRow("发送 / 排空包数", number("sentPackets") + " / " + number("drainedPackets"))
                    detailRow("追赶时限 / 预缓冲", model.negotiated.map { String(format: "%.1f 秒 / %d ms", $0.bufferingSettings.catchupLimitSeconds, $0.bufferingSettings.prefillMilliseconds) } ?? "尚未启用")
                    detailRow("本次连续追赶", number("catchupSeconds", suffix: " 秒"))
                    detailRow("本机 PCM 缓冲", pcmDuration("bufferedFrames"))
                    detailRow("积压恢复跳过", pcmDuration("skippedFrames"))
                    detailRow("已发送时长", number("elapsed", suffix: " 秒"))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            if model.metrics["windowSeconds"] != nil {
                GroupBox("LHDC 发送诊断") {
                    VStack(alignment: .leading, spacing: 8) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            detailRow("统计窗口", number("windowSeconds", suffix: " 秒"))
                            detailRow("窗口排空包数 / 最大包", number("windowPackets") + " / " + number("packetBytesMax", suffix: " 字节"))
                            detailRow("最长 / 平均发送等待", milliseconds("drainMaxMs") + " / " + milliseconds("drainMeanMs"))
                            detailRow("开始编码时最长落后", milliseconds("scheduleLateMaxMs"))
                            detailRow("最长编码耗时", milliseconds("encodeMaxMs"))
                            detailRow("当前包已等待", milliseconds("drainPendingMs"))
                            detailRow("本次最长发送等待", milliseconds("sessionDrainMaxMs"))
                            detailRow("本次等待 > 8 / 50 ms", number("sessionDrainOver8ms") + " / " + number("sessionDrainOver50ms") + " 次")
                        }
                        Text("约每秒汇总全部编码块和发送包；停止时保留最后一个窗口。等待次数按已排空包统计，不等于耳机卡顿或无线重传次数。").foregroundStyle(.secondary)
                        Text("发送等待包含本机发送、socket 排空及唤醒延迟；调度延迟指开始处理音频块时落后于发送时间表的量。").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            Text("发送和排空仅反映本机传输状态；耳机是否收到及无线丢包率无法由这些统计判断。").foregroundStyle(.secondary)
            Text("积压恢复跳过是本机主动丢弃的音频时长，不是耳机卡顿次数；本机缓冲不包含耳机内部缓冲。").foregroundStyle(.secondary)
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Text("macOS \(model.details["os"] ?? ProcessInfo.processInfo.operatingSystemVersionString) · HAL \(model.details["driverRevision"] ?? "待检查")").font(.caption2).foregroundStyle(.secondary)
        }.font(.caption).textSelection(.enabled)
    }
    private func milliseconds(_ key: String) -> String {
        model.metrics[key].map { String(format: "%.2f ms", $0) } ?? "未取得"
    }
    private var resampling: String {
        guard let source = model.metrics["captureRate"], let output = model.metrics["pipelineRate"] else { return "尚未取得捕获格式" }
        return source == output ? "无" : "Core Audio 原生转换"
    }
    private func rate(_ value: Double?) -> String { value.map { String(format: "%g kHz", $0 / 1000) } ?? "未启用或未取得" }
    private func detailRow(_ label: String, _ value: String) -> some View { GridRow { Text(label).foregroundStyle(.secondary); Text(value).monospacedDigit() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var client: EngineClient?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let client else { return .terminateNow }
        client.quit()
        // Engine remains alive until ordered teardown; parent-death detection is the fallback.
        Task { @MainActor in
            while client.busy { try? await Task.sleep(for: .milliseconds(100)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
@main struct SonoFerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = EngineClient()
    var body: some Scene {
        Window("SonoFerry", id: "control") {
            ControlPanelContainer(model: model).frame(width: 440).frame(minHeight: 600)
                .task { delegate.client = model; model.launch() }
        }.defaultSize(width: 440, height: 690).defaultLaunchBehavior(model.previewMode ? .presented : .suppressed)
        MenuBarExtra("SonoFerry", systemImage: model.active ? "waveform" : "headphones") {
            ControlPanelContainer(model: model)
                .frame(width: 440, height: min(model.showsHDSettings ? 760 : 660, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
                .task { delegate.client = model; model.launch() }
        }.menuBarExtraStyle(.window)
        Window("SonoFerry · 耳机设置", id: "headset") { HeadsetSettingsView(model: model) }.defaultSize(width: 780, height: 650).defaultLaunchBehavior(.suppressed)
        Window("SonoFerry · 应用设置", id: "app-settings") { ApplicationSettingsView(model: model) }.defaultSize(width: 680, height: 720).defaultLaunchBehavior(.suppressed)
        Settings { ApplicationSettingsView(model: model) }
    }
}
