import SwiftUI
import AppKit
import SonoFerryCore

struct DeviceLibraryView: View {
    @ObservedObject var model: EngineClient
    @State private var adding = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音频输出设备").font(.headline)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(model.registeredHeadphones) { item in
                        let connected = model.isConnected(item)
                        let selected = model.selectedOutputAddress == item.address
                        Button { model.selectHeadphone(item) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: item.symbol).font(.system(size: 25))
                                    .foregroundStyle(connected ? (selected ? Color.accentColor : .primary) : .secondary)
                                    .frame(width: 58, height: 58)
                                    .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05), in: Circle())
                                    .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                                Circle().fill(connected ? Color.green : .clear).frame(width: 5, height: 5)
                                Text((model.devices.first { $0.address == item.address }?.name ?? item.displayTitle)).font(.caption2).foregroundStyle(connected ? .primary : .secondary)
                            }.frame(width: 92).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(model.localDataBusy || model.libraryActionBusy || model.previewMode)
                            .contextMenu {
                                Button(role: .destructive) { model.removeHeadphone(item) } label: { Label("删除设备", systemImage: "trash") }
                                    .disabled(model.localDataBusy || model.libraryActionBusy || model.previewMode)
                            }
                            .accessibilityLabel((model.devices.first { $0.address == item.address }?.name ?? item.displayTitle))
                            .accessibilityValue(!connected ? "未连接" : selected ? "已选择" : "已连接")
                            .help(connected ? "切换系统音频输出到 \((model.devices.first { $0.address == item.address }?.name ?? item.displayTitle))" : "请先连接耳机蓝牙")
                    }
                    Button { adding = true; model.scanConnectedDevices() } label: {
                        Image(systemName: "plus").font(.title2.weight(.light))
                            .frame(width: 58, height: 58).background(Color.primary.opacity(0.05), in: Circle())
                            .overlay(Circle().stroke(.secondary.opacity(0.5), lineWidth: 1))
                    }.buttonStyle(.plain).help("添加音频输出设备").accessibilityLabel("添加音频输出设备")
                        .disabled(model.localDataBusy || model.previewMode)
                        .popover(isPresented: $adding) {
                            DeviceDiscoveryView(model: model) { adding = false }
                                .onDisappear { model.endDeviceDiscovery() }
                        }
                }.padding(3)
            }.scrollIndicators(.hidden)
            if !adding && model.discoveryControlBusy {
                HStack(spacing: 6) {
                    if model.identifyingDevices { ProgressView().controlSize(.mini) }
                    Text(model.discoveryMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.libraryMessage.isEmpty {
                HStack(spacing: 6) {
                    if model.libraryActionBusy { ProgressView().controlSize(.mini); Button("取消") { model.cancelAddingDevice() } }
                    Text(model.libraryMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = model.codecProbeState.error, model.device != nil {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.device != nil && !model.registeredHeadphones.isEmpty {
                HStack {
                    if let date = model.detectedAt { Text("能力检测于 \(date, style: .time)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("重新检测") { model.retryDeviceDetection() }
                        .disabled(model.device?.connected != true || !model.canEditSettings || model.libraryActionBusy || model.previewMode)
                        .help("重新读取编码能力；会停止高清发送并短暂重新连接耳机")
                }
            }
        }
    }
}


/// Shared with the isolated UI renderer; opening this view alone performs no device access.
struct DeviceDiscoveryView: View {
    @ObservedObject var model: EngineClient
    var dismiss: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加设备").font(.headline)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                    .opacity(model.scanningDevices || model.identifyingDevices ? 1 : 0)
                    .accessibilityHidden(!model.scanningDevices && !model.identifyingDevices)
                Text(statusMessage).font(.caption)
                    .foregroundStyle(model.scanMessage.isEmpty ? Color.secondary : .orange)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 36)
            if ["1", "2", "0"].contains(model.details["bluetoothAuthorization"] ?? "0") {
                Button("授权蓝牙") { model.send(WireMessage("authorize")) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.connectedAudioDevices.isEmpty && !model.scanningDevices {
                        Text("没有已连接的蓝牙音频设备。请先在系统蓝牙设置中连接。").foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(model.connectedAudioDevices) { device in
                        Button { model.addHeadphone(device); dismiss() } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(model.discoveryModelName(device) ?? " ").font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).accessibilityHidden(model.discoveryModelName(device) == nil)
                                    if let failure = model.discoveryFailure(device) {
                                        Text(failure).font(.caption).foregroundStyle(.orange)
                                    }
                                    if model.connectedAudioDevices.filter({ $0.name == device.name }).count > 1 {
                                        Text(String(device.address.suffix(8))).font(.caption.monospaced())
                                    }
                                }
                                Spacer(); Text(model.discoveryLabel(device)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.disabled(!model.canAddDevice || model.registeredHeadphones.contains { $0.address == device.address })
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("刷新") { model.scanConnectedDevices() }.disabled(model.scanningDevices || model.discoveryControlBusy)
                Spacer()
                Button("系统蓝牙设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }
            }
        }.padding(20).frame(width: 330, height: 320)
    }
    private var statusMessage: String {
        if !model.scanMessage.isEmpty { return model.scanMessage }
        if model.busy { return "切换回系统默认蓝牙编码以添加设备" }
        if model.scanningDevices { return "正在读取已连接设备…" }
        return model.discoveryMessage
    }
}

/// Footer belongs to the container, outside the scroll view in both window and menu extra.
struct ControlPanelContainer: View {
    @ObservedObject var model: EngineClient
    @Environment(\.openWindow) private var openWindow
    private var driver: String {
        guard let value = model.details["driverRevision"] else { return "—" }
        return value == "not-loaded" ? "未加载" : value
    }
    private var version: String { ApplicationVersion.display }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { ControlPanel(model: model).padding(.bottom, 66) }
                .overlay(alignment: .bottom) { footer }
        }.frame(width: 440)
    }
    private var footer: some View {
        HStack {
                Button { openWindow(id: "app-settings"); NSApp.activate(ignoringOtherApps: true) } label: {
                    Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 30, height: 30)
                }.help("应用设置").accessibilityLabel("应用设置")
                Spacer()
                Text("v\(version)  ·  HAL \(driver)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 17)).frame(width: 30, height: 30)
                }.help("退出 SonoFerry").accessibilityLabel("退出 SonoFerry")
            }.buttonStyle(.plain).padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)
                .background {
                    Rectangle().fill(.ultraThinMaterial)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
    }
}
