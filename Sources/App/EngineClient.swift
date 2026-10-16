import SwiftUI
import AppKit
import CryptoKit
import SonoFerryCore

@MainActor
final class EngineClient: ObservableObject {
    let startupHealth: StartupHealthController
    @Published private(set) var audioMaintenance = false
    var canPrepareAudioRestart: Bool { !previewMode && !busy && !active && !libraryActionBusy && !discoveryControlBusy && !localDataBusy && !headsetBusy && !headsetWriting && !oppoBusy && !audioMaintenance }
    func prepareAudioRestart() async throws {
        guard canPrepareAudioRestart else { throw ProtocolFailure("当前会话尚未结束，未执行热重启") }
        audioMaintenance = true
        quit()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while process?.isRunning == true {
            guard ContinuousClock.now < deadline else { throw ProtocolFailure("引擎清理超时，未执行热重启") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process == nil || process?.terminationStatus == 0 else { throw ProtocolFailure("引擎清理失败，未执行热重启") }
    }
    func finishAudioRestart(commandSucceeded: Bool) {
        audioMaintenance = false
        // Resume the idle engine only after command success; this does not certify service health.
        if commandSucceeded { launch() }
    }
    @Published var appearance: ApplicationAppearance = .system {
        didSet {
            guard !previewMode else { return }
            preferences.set(appearance.rawValue, forKey: "appearance")
            NSApp?.appearance = appearance.native
        }
    }
    @Published private(set) var localDataBusy = false
    @Published private(set) var localDataMessage = ""
    private enum LocalDataAction { case remove(String), reset }
    private var localDataAction: LocalDataAction?
    private var resetWaitingForEngine = false
    private var resetTimeout: Task<Void, Never>?
    private let preferencesDomain: String
    private let clearStoredFiles: () throws -> Void
    @Published var transportChoice = "system"
    @Published var nativeCodecID: UInt8?
    @Published var initialSettingsSource = ""
    private var codecSelectionManaged = false
    private var pendingCodecActivation: CodecID?
    private var playbackPreferences: [String: PlaybackConfiguration] = [:]
    @Published private(set) var resettableCodec: CodecID?
    @Published var devices: [BluetoothDevice] = []
    @Published private(set) var registeredHeadphones: [RegisteredHeadphone] = []
    @Published private(set) var environment: DeviceEnvironment?
    @Published private(set) var libraryMessage = ""
    @Published private(set) var libraryActionBusy = false
    private var needsIdleRefresh = false
    private var libraryManaged = false
    private var addingDevice: BluetoothDevice?
    private var addingIdentity: HeadsetIdentity?
    private var identityRequestID: UUID?
    private var addingCancelled = false
    private var scanRequestID: UUID?
    @Published private(set) var scanningDevices = false
    @Published private(set) var scanMessage = ""
    private var discoveryOpen = false
    private var discoveryRefreshPending = false
    private var discoveryScanRequests: Set<UUID> = []
    private var discoveryQueue: [String] = []
    private struct DiscoveryRequest { let id: UUID; let device: BluetoothDevice; var cancelled = false }
    private var discoveryRequest: DiscoveryRequest?
    @Published private(set) var identifyingDevices = false
    @Published private var discoveryCleanupBlocked = false
    @Published private var discoveryIdentities: [String: HeadsetIdentity] = [:]
    @Published private var discoveryFailures: [String: String] = [:]
    @Published private(set) var discoveryMessage = ""
    private var discoveryRestoreWatch = false
    var discoveryControlBusy: Bool { identifyingDevices || discoveryCleanupBlocked }
    @Published private(set) var codecProbeState = CodecProbeState(.notProbed)
    private var libraryProbeAddress: String?
    private var libraryRequestID: UUID?
    private var pendingOutputAddress: String?
    private var outputRequestID: UUID?
    private var attemptedAutomaticProbes: Set<String> = []
    private var libraryTimeout: Task<Void, Never>?
    @Published var selectedAddress = ""
    @Published var capabilities: [CodecCapabilities] = []
    @Published var selectedCapability = ""
    @Published var rate = 0
    @Published var quality: Quality = .adaptive
    @Published var gain = 1.0
    @Published private(set) var softwareVolumeEnabled = false
    @Published var status = "未检测"
    @Published var error: String?
    @Published var details: [String: String] = [:]
    @Published var telemetry = ""
    @Published var busy = false
    @Published var active = false
    @Published var format: AudioFormat?
    @Published var negotiated: PlaybackConfiguration?
    @Published var probeComplete = false
    @Published var metrics: [String: Double] = [:]
    @Published var catchupLimitTenths = 50
    @Published var prefillMilliseconds = 250
    @Published var fixedBitrate = 0
    @Published var detectedAt: Date?
    @Published var connectionPhase = "idle"
    @Published var linkHardwareVolume = false
    @Published var volumeLinkState = "off"
    @Published var volumeLinkMessage = ""
    @Published var audioState: SystemAudioState?
    private var audioRequestID: UUID?
    @Published var applyingBuffering = false
    @Published var settingsMessage = ""
    @Published var headset: HeadsetSnapshot?
    @Published var headsetBusy = false
    @Published var lastHeadsetResult: HeadsetOperationResult?
    @Published var headsetMessage = "打开耳机设置后读取状态"
    @Published var mediaMessage = "Mac 摘戴联动默认关闭"
    @Published var wearAutomation = false
    private var headsetWatchID: UUID?
    private var headsetRequestID: UUID?
    @Published private var headsetWriteID: UUID?
    private var headsetWriteSetting: HeadsetSetting?
    private var headsetRequestGeneration: UUID?
    private var pendingHeadsetPage: (HeadsetRefreshScope, Bool)?
    private var loadedHeadsetPages: Set<String> = []
    @Published private var headsetReadIncludesHiRes = false
    @Published private var headsetRecoveryID: UUID?
    // Presentation only: a recovery rebuilds live identity/capabilities in stages.
    // Keep the existing layout until its terminal reply, never use this for writes.
    private var headsetRefreshPresentation: HeadsetSnapshot?
    var isManuallyRefreshingHeadset: Bool { headsetRecoveryID != nil }
    var headsetDisplaySnapshot: HeadsetSnapshot? {
        if isManuallyRefreshingHeadset, let saved = headsetRefreshPresentation, saved.address == selectedAddress { return saved }
        return headset
    }
    var showsHeadsetControls: Bool { isManuallyRefreshingHeadset || supportsHeadsetControl }
    private var retiredGenerations: Set<UUID> = []
    private var wantsHeadset = false
    @Published var oppoBusy = false
    @Published var oppoMessage = "尚未查询"
    @Published private(set) var hiResRefreshedAt: Date?
    @Published var oppoReport: OppoProbeReport?
    @Published private(set) var oppoQueryInProgress = false
    @Published private var pendingHiResQuerySessionID: UUID?
    @Published private(set) var headsetResumeInProgress = false
    private var autoHiResQuerySessionID: UUID?
    private var oppoRequestID: UUID?
    private var oppoControlGeneration: UUID?
    private var oppoReadTimeoutID: UUID?
    private var oppoReadTimeoutTask: Task<Void, Never>?
    private let controlScheduler: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)?
    private var oppoRefreshMessage: String?
    private var hiResContinuation: StartRequest?
    private var hiResWriteSessionID: UUID?
    private var hiResWriteControlGeneration: UUID?
    private var hiResVerified = false
    private var hiResDeadline: Date?
    private var hiResRetries = 0
    private var currentStart: StartRequest?
    private var automaticRecoveryAllowed = false
    private var recoveryID: UUID?
    private var recoveryTask: Task<Void, Never>?
    private let recoveryScheduler: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)?
    private let now: () -> Date
    let previewMode: Bool
    private let preferences: UserDefaults
    private let messageSink: ((WireMessage) -> Void)?
    private var pendingMIDIStart: StartRequest?
    private var bufferingRequestID: UUID?
    private var bufferingInFlight: BufferingConfiguration?
    private struct StartRequest {
        let device: BluetoothDevice
        let configuration: PlaybackConfiguration
        var gain: Double
        var linkHardwareVolume = false
        var defaultFallback = false
        var connectionRetries = 0
        var capabilityFallback = false
    }
    private var pendingStart: StartRequest?
    private var pendingStopID: UUID?
    init(previewMode: Bool = CommandLine.arguments.contains("--ui-preview"),
         startupHealth: StartupHealthController? = nil,
         preferences: UserDefaults = .standard, messageSink: ((WireMessage) -> Void)? = nil,
         recoveryScheduler: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil,
         controlScheduler: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil,
         now: @escaping () -> Date = Date.init,
         preferencesDomain: String = RuntimeIdentity.preferencesDomain,
         clearStoredFiles: @escaping () throws -> Void = ApplicationData.clearFiles) {
        self.preferencesDomain = preferencesDomain; self.clearStoredFiles = clearStoredFiles
        self.startupHealth = startupHealth ?? StartupHealthController()
        self.previewMode = previewMode; self.preferences = preferences; self.messageSink = messageSink
        softwareVolumeEnabled = preferences.bool(forKey: "softwareVolumeEnabled")
        self.recoveryScheduler = recoveryScheduler; self.now = now
        self.controlScheduler = controlScheduler
        appearance = ApplicationAppearance(rawValue: preferences.string(forKey: "appearance") ?? "") ?? .system
        if !previewMode { NSApp?.appearance = appearance.native }
        if let data = (preferences.data(forKey: "headphoneLibrary.v2") ?? preferences.data(forKey: "headphoneLibrary.v1")),
           let stored = try? JSONDecoder().decode([RegisteredHeadphone].self, from: data) {
            var seen: Set<String> = []
            registeredHeadphones = stored.compactMap { item in
                guard let address = BluetoothIdentity.normalizedAddress(item.address), seen.insert(address).inserted else { return nil }
                return RegisteredHeadphone(address: address, model: item.model, name: item.name, identity: item.identity)
            }
        }
    }
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var sessionID: UUID?
    private var requestDevice: String?
    private var requestVolumeLinked = false
    private var requestIsProbe = false
    private var history: [WireMessage] = []
    var systemCodecLabel: String {
        if transportChoice != "system" {
            return nativeCodecID.map { "系统蓝牙（上次 " + OppoControlCodec.label($0) + "）" } ?? "系统蓝牙（切换后检测）"
        }
        if let nativeCodecID { return OppoControlCodec.label(nativeCodecID) + " · 系统" }
        return oppoBusy ? "系统蓝牙 · 正在识别" : "系统蓝牙 · 编码未识别"
    }
    var showsHDSettings: Bool { capability?.playable == true }
    var showsLiveFormat: Bool { active && selectedIsPlaying }
    // Only standard AVDTP sink capabilities authorize a selectable encoder.
    // OPPO's private codec bitmap may include codecs absent from its audio endpoints.
    var availableHDCodecs: [CodecID] {
        CodecID.allCases.filter { codec in capabilities.contains { $0.codec == codec && $0.playable } }
    }
    var codecChoices: [CodecID] {
        var choices = availableHDCodecs
        // Capability replies arrive one endpoint at a time. Keep only the already
        // validated in-flight selection visible while that list is being rebuilt.
        if (busy && selectedIsPlaying) || pendingCodecActivation != nil,
           let selected = CodecID(rawValue: transportChoice), !choices.contains(selected) {
            choices.append(selected)
        }
        return choices
    }
    var canChooseHDCodec: Bool { !discoveryControlBusy && !libraryActionBusy && device?.connected == true && (!busy || active) && pendingCodecActivation == nil && !previewMode }
    var selectedOutputAddress: String? {
        if busy && !requestIsProbe, selectedIsPlaying { return requestDevice }
        return environment?.route.bluetoothAddress
    }
    var supportsHeadsetControl: Bool {
        if let headset, headset.address == selectedAddress, headset.productID != nil, headset.profile == nil { return false }
        return registeredHeadphones.first(where: { $0.address == selectedAddress })?.profile?.dialect != nil
    }
    func isConnected(_ item: RegisteredHeadphone) -> Bool {
        devices.contains { $0.address == item.address && $0.connected }
    }
    func removeHeadphone(_ item: RegisteredHeadphone) {
        guard !discoveryControlBusy, !previewMode, !localDataBusy, !libraryActionBusy,
              registeredHeadphones.contains(where: { $0.address == item.address }) else { return }
        localDataAction = .remove(item.address); localDataBusy = true; libraryActionBusy = true
        libraryMessage = "正在切回系统通道并删除设备…"
        if busy && requestDevice == item.address { stop() }
        else { finishLocalDataAction() }
    }
    func clearApplicationData() {
        guard !discoveryControlBusy, !previewMode, !localDataBusy, !libraryActionBusy else { return }
        localDataAction = .reset; localDataBusy = true; libraryActionBusy = true
        localDataMessage = "正在停止会话并清空应用数据…"
        cancelRecovery(); hiResContinuation = nil; pendingCodecActivation = nil
        if busy { stop() } else { finishLocalDataAction() }
    }
    private func failLocalDataAction(_ reason: String) {
        resetTimeout?.cancel(); resetTimeout = nil
        localDataAction = nil; localDataBusy = false; resetWaitingForEngine = false
        finishLibraryAction(reason); localDataMessage = reason
    }
    private func finishLocalDataAction() {
        guard let action = localDataAction else { return }
        switch action {
        case .remove(let address):
            // The final stopped event precedes this path for an active device.
            // Native Bluetooth stays connected; only app-owned data is removed.
            registeredHeadphones.removeAll { $0.address == address }
            preferences.removeObject(forKey: "device." + address)
            preferences.removeObject(forKey: "headset." + address)
            for linked in [false, true] { preferences.removeObject(forKey: volumeKey(address: address, linked: linked)) }
            attemptedAutomaticProbes.remove(address)
            if let data = try? JSONEncoder().encode(registeredHeadphones) { preferences.set(data, forKey: "headphoneLibrary.v2") }
            if selectedAddress == address {
                if oppoBusy { cancelOppo() }
                pendingCodecActivation = nil; cancelPendingSettings()
                selectedAddress = ""; transportChoice = "system"; localDataBusy = false; deviceChanged()
                preferences.removeObject(forKey: "selectedDevice")
            }
            localDataAction = nil; localDataBusy = false
            finishLibraryAction("已删除设备"); send(WireMessage("environment"))
        case .reset:
            resetWaitingForEngine = true
            // Invalidate observers before quit; late messages cannot re-save data.
            headsetWatchID = nil; headsetRequestID = nil; headsetWriteID = nil; headsetWriteSetting = nil; pendingHeadsetPage = nil; loadedHeadsetPages.removeAll(); headsetReadIncludesHiRes = false; headsetRecoveryID = nil; wantsHeadset = false
            cancelRecovery(); cancelPendingSettings(); resetOppo(message: "尚未查询")
            if process?.isRunning != true && messageSink == nil { finishApplicationReset(exitStatus: 0); return }
            send(WireMessage("quit"))
            resetTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.resetWaitingForEngine else { return }
                self.failLocalDataAction("等待会话退出超时，未清空数据；请关闭应用后重试。")
            }
        }
    }
    func finishApplicationReset(exitStatus: Int32) {
        guard resetWaitingForEngine else { return }
        resetTimeout?.cancel(); resetTimeout = nil
        guard exitStatus == 0 else { failLocalDataAction("会话未正常退出，未清空数据，请重试。"); return }
        do { try clearStoredFiles() }
        catch { failLocalDataAction("未能清空全部缓存：" + error.localizedDescription); return }
        reader?.cancel(); reader = nil; process = nil; input = nil
        registeredHeadphones = []; selectedAddress = ""; transportChoice = "system"; devices = []
        environment = nil; attemptedAutomaticProbes = []; needsIdleRefresh = false
        headset = nil; headsetRequestGeneration = nil; retiredGenerations = []
        lastHeadsetResult = nil; headsetBusy = false; headsetWriteID = nil; headsetWriteSetting = nil; pendingHeadsetPage = nil; loadedHeadsetPages.removeAll(); headsetReadIncludesHiRes = false; headsetRecoveryID = nil; wearAutomation = false
        headsetMessage = "打开耳机设置后读取状态"; mediaMessage = "Mac 摘戴联动默认关闭"
        capabilities = []; selectedCapability = ""; probeComplete = false; codecProbeState = .init(.notProbed); detectedAt = nil
        playbackPreferences = [:]; resettableCodec = nil; rate = 0; quality = .adaptive; fixedBitrate = 0
        softwareVolumeEnabled = false; gain = 1; catchupLimitTenths = 50; prefillMilliseconds = 250; linkHardwareVolume = false
        volumeLinkState = "off"; volumeLinkMessage = ""; nativeCodecID = nil; audioState = nil; audioRequestID = nil
        busy = false; active = false; sessionID = nil; requestDevice = nil; currentStart = nil
        requestIsProbe = false; requestVolumeLinked = false; autoHiResQuerySessionID = nil
        hiResWriteSessionID = nil; hiResWriteControlGeneration = nil; hiResVerified = false; hiResDeadline = nil; hiResRetries = 0; oppoRefreshMessage = nil
        metrics = [:]; format = nil; negotiated = nil; history = []; details = [:]; telemetry = ""
        error = nil; settingsMessage = ""; initialSettingsSource = ""; connectionPhase = "idle"
        appearance = .system
        preferences.removePersistentDomain(forName: preferencesDomain)
        preferences.synchronize()
        localDataAction = nil; localDataBusy = false; resetWaitingForEngine = false
        finishLibraryAction(""); localDataMessage = "应用数据已清空"; status = "请添加音频输出设备"
        if messageSink == nil { launch() }
    }
    var connectedAudioDevices: [BluetoothDevice] { devices.filter { $0.connected && $0.isAudio } }
    var canAddDevice: Bool { !previewMode && !busy && !libraryActionBusy && !localDataBusy && !discoveryControlBusy && recoveryID == nil && environment?.transitioning != true && environment?.audioSessionID == nil }
    func discoveryLabel(_ device: BluetoothDevice) -> String {
        if registeredHeadphones.contains(where: { $0.address == device.address }) { return "已添加" }
        if discoveryRequest?.device.address == device.address { return "正在确认型号…" }
        if discoveryFailures[device.address] != nil { return "型号确认失败" }
        if let identity = discoveryIdentities[device.address] { return identity.profile?.status ?? "未适配" }
        if HeadphoneModel.wh1000xm5.matches(device) { return "实验性" }
        return hasIdentityService(device) ? "等待确认型号" : "未适配"
    }
    func discoveryModelName(_ device: BluetoothDevice) -> String? {
        // Added rows cannot be selected here. Their saved model is presentation
        // only; reopening this list must not tear down their live control watch.
        if let saved = registeredHeadphones.first(where: { $0.address == device.address }) {
            if let profile = saved.profile { return profile.name }
            if let identity = saved.identity { return String(format: "未知型号 · 产品 ID %06X", identity.productID) }
            return saved.model?.displayTitle
        }
        guard let identity = discoveryIdentities[device.address] else { return nil }
        return identity.profile?.name ?? String(format: "未知型号 · 产品 ID %06X", identity.productID)
    }
    func discoveryFailure(_ device: BluetoothDevice) -> String? { discoveryFailures[device.address] }
    private func hasIdentityService(_ device: BluetoothDevice) -> Bool {
        device.controlServices?.contains { HeadsetDialect(rawValue: $0) != nil } == true
    }
    private func needsDiscoveryIdentity(_ device: BluetoothDevice) -> Bool {
        hasIdentityService(device) && !registeredHeadphones.contains { $0.address == device.address }
    }
    /// List-only identities never authorize controls or replace the selected-device recheck.
    private func advanceDiscovery() {
        guard discoveryOpen, !scanningDevices, scanMessage.isEmpty, !discoveryControlBusy else { return }
        discoveryQueue.removeAll { address in !connectedAudioDevices.contains { $0.address == address && needsDiscoveryIdentity($0) } }
        guard let address = discoveryQueue.first else {
            discoveryMessage = ""; restoreDiscoveryWatch(); return
        }
        guard canAddDevice, !active, !audioMaintenance, !headsetBusy, !headsetWriting,
              !oppoBusy, headsetRecoveryID == nil, hiResContinuation == nil, pendingStart == nil,
              pendingCodecActivation == nil, let device = connectedAudioDevices.first(where: { $0.address == address }) else {
            discoveryMessage = "等待当前音频或耳机操作结束后确认型号。"; return
        }
        discoveryQueue.removeFirst()
        let id = UUID()
        discoveryRequest = .init(id: id, device: device); identifyingDevices = true
        discoveryMessage = "正在确认 \(device.name) 的型号…"
        discoveryRestoreWatch = discoveryRestoreWatch || wantsHeadset
        // Share the existing owner and its shutdown barrier; never create another channel.
        send(WireMessage("headsetUnwatch"))
        headsetWatchID = nil; headsetRequestID = nil; headset?.markStale()
        var request = WireMessage("deviceIdentity", requestID: id); request.device = device
        send(request)
        let expire: @MainActor () -> Void = { [weak self] in
            guard let self, self.discoveryRequest?.id == id, self.discoveryRequest?.cancelled == false else { return }
            self.discoveryFailures[device.address] = "型号查询超时，请刷新重试。"
            self.cancelDiscoveryRequest()
        }
        if let controlScheduler { controlScheduler(60, expire) }
        else { Task { try? await Task.sleep(for: .seconds(60)); expire() } }
    }
    private func cancelDiscoveryRequest() {
        guard let request = discoveryRequest, !request.cancelled else { return }
        discoveryRequest?.cancelled = true
        discoveryMessage = "正在等待型号查询安全关闭…"
        send(WireMessage("headsetCancel", requestID: request.id))
    }
    func endDeviceDiscovery() {
        discoveryOpen = false; discoveryRefreshPending = false; discoveryQueue.removeAll()
        cancelDiscoveryRequest()
        restoreDiscoveryWatch()
    }
    private func restoreDiscoveryWatch() {
        guard discoveryRestoreWatch, !discoveryControlBusy else { return }
        discoveryRestoreWatch = false
        if wantsHeadset { watchHeadset() }
    }
    private func receiveDiscoveryIdentity(_ event: WireMessage) {
        guard let request = discoveryRequest, event.requestID == request.id,
              event.device?.address == request.device.address else { return }
        discoveryRequest = nil; identifyingDevices = false
        guard event.restartSafe == true else {
            discoveryCleanupBlocked = true; discoveryRefreshPending = false; discoveryQueue.removeAll()
            discoveryFailures[request.device.address] = "控制通道关闭未确认。"
            discoveryMessage = "控制通道关闭未确认，请正常退出应用后重新打开再试。"
            return
        }
        if discoveryOpen, discoveryRefreshPending { scanConnectedDevices(); return }
        if !request.cancelled, discoveryOpen,
           let current = connectedAudioDevices.first(where: { $0.address == request.device.address }),
           current.controlServices == request.device.controlServices {
            if let identity = event.headsetIdentity, identity.address == current.address,
               current.controlServices?.contains(identity.serviceUUID) == true {
                discoveryIdentities[current.address] = identity
            } else { discoveryFailures[current.address] = event.message ?? "未取得产品 ID，可刷新重试或添加为通用音频设备。" }
        }
        if discoveryOpen { advanceDiscovery() } else { restoreDiscoveryWatch() }
    }
    private func reconcileDiscoveryDevices() {
        for address in Array(discoveryIdentities.keys) {
            guard let identity = discoveryIdentities[address] else { continue }
            if !connectedAudioDevices.contains(where: { $0.address == address && $0.controlServices?.contains(identity.serviceUUID) == true }) {
                discoveryIdentities.removeValue(forKey: address)
            }
        }
        if let request = discoveryRequest,
           !connectedAudioDevices.contains(where: { $0.address == request.device.address && $0.controlServices == request.device.controlServices }) {
            cancelDiscoveryRequest()
        }
    }
    func scanConnectedDevices() {
        guard !previewMode, !audioMaintenance else { return }
        discoveryOpen = true
        guard !discoveryCleanupBlocked else { return }
        if identifyingDevices {
            if discoveryRequest?.cancelled == true { discoveryRefreshPending = true }
            return
        }
        guard !scanningDevices else { return }
        discoveryRefreshPending = false; discoveryQueue.removeAll(); discoveryIdentities.removeAll(); discoveryFailures.removeAll()
        discoveryMessage = ""
        let id = UUID(); scanRequestID = id; scanningDevices = true; scanMessage = ""
        discoveryScanRequests.insert(id)
        send(WireMessage("environment", requestID: id))
        let expire: @MainActor () -> Void = { [weak self] in
            guard let self, self.scanRequestID == id else { return }
            self.scanRequestID = nil; self.scanningDevices = false; self.scanMessage = "读取蓝牙设备超时，请刷新。"
        }
        if let controlScheduler { controlScheduler(8, expire) }
        else { Task { try? await Task.sleep(for: .seconds(8)); expire() } }
    }
    func addHeadphone(_ device: BluetoothDevice) {
        guard canAddDevice, device.connected, device.isAudio,
              !registeredHeadphones.contains(where: { $0.address == device.address }) else { return }
        discoveryOpen = false; discoveryQueue.removeAll(); discoveryRestoreWatch = false
        libraryManaged = true; codecSelectionManaged = true
        addingDevice = device; addingIdentity = nil; addingCancelled = false
        libraryActionBusy = true; libraryMessage = "正在检查所选设备的连接…"
        let id = UUID(); libraryRequestID = id
        send(WireMessage("environment", requestID: id)); startLibraryTimeout(id)
    }
    func cancelAddingDevice() {
        guard addingDevice != nil else { return }
        addingCancelled = true
        if let id = identityRequestID {
            send(WireMessage("headsetCancel", requestID: id)); libraryMessage = "正在取消并等待控制通道关闭…"
        } else if busy { stop() }
        else { finishLibraryAction("已取消添加") }
    }
    private func beginLibraryIdentity(_ device: BluetoothDevice) {
        libraryTimeout?.cancel(); libraryRequestID = nil
        guard device.controlServices?.contains(where: { HeadsetDialect(rawValue: $0) != nil }) == true else {
            beginLibraryProbe(device); return
        }
        // The one existing owner cancels/drains prior reads. Never create another control channel.
        send(WireMessage("headsetUnwatch"))
        headsetWatchID = nil; headsetRequestID = nil; headsetBusy = false; headset?.markStale()
        if oppoBusy { cancelOppo() }
        let id = UUID(); identityRequestID = id
        var request = WireMessage("deviceIdentity", requestID: id); request.device = device
        libraryMessage = "正在读取产品 ID…"; send(request)
        let expire: @MainActor () -> Void = { [weak self] in
            guard let self, self.identityRequestID == id else { return }
            self.addingCancelled = true
            self.send(WireMessage("headsetCancel", requestID: id))
            self.libraryMessage = "身份查询超时，正在等待安全清理；未添加设备。"
        }
        if let controlScheduler { controlScheduler(60, expire) }
        else { Task { try? await Task.sleep(for: .seconds(60)); expire() } }
    }
    private func receiveLibraryIdentity(_ event: WireMessage) {
        guard let id = identityRequestID, event.requestID == id, let device = addingDevice,
              event.device?.address == device.address else { return }
        identityRequestID = nil
        guard !addingCancelled, event.restartSafe == true else {
            finishLibraryAction(addingCancelled ? "已取消添加" : "身份查询清理未确认，未添加设备：" + (event.message ?? "请重试")); return
        }
        addingIdentity = event.headsetIdentity
        beginLibraryProbe(device)
    }
    func selectHeadphone(_ item: RegisteredHeadphone) {
        guard selectedOutputAddress != item.address else { return }
        guard !discoveryControlBusy, !previewMode, isConnected(item), !libraryActionBusy, !busy || active else { return }
        pendingOutputAddress = item.address; libraryActionBusy = true; libraryMessage = "正在切换音频输出…"
        if busy { stop() } else { requestOutputSelection() }
    }
    private func requestOutputSelection() {
        let id = UUID(); libraryRequestID = id
        send(WireMessage("environment", requestID: id)); startLibraryTimeout(id)
    }
    private func startLibraryTimeout(_ id: UUID) {
        libraryTimeout?.cancel()
        let expire: @MainActor () -> Void = { [weak self] in
            guard let self, self.libraryRequestID == id || self.outputRequestID == id else { return }
            self.finishLibraryAction("设备查询超时，请重试。")
        }
        if let controlScheduler { controlScheduler(8, expire) }
        else {
            libraryTimeout = Task {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                expire()
            }
        }
    }

    private func finishLibraryAction(_ message: String) {
        libraryTimeout?.cancel(); libraryTimeout = nil
        libraryActionBusy = false; addingDevice = nil; addingIdentity = nil; identityRequestID = nil; addingCancelled = false; libraryProbeAddress = nil
        libraryRequestID = nil; outputRequestID = nil; pendingOutputAddress = nil
        libraryMessage = message
    }
    private func beginLibraryProbe(_ device: BluetoothDevice) {
        guard devices.contains(where: { $0.address == device.address && $0.connected && $0.isAudio }) else {
            finishLibraryAction("所选音频设备已断开，未开始能力检测。"); return
        }
        libraryTimeout?.cancel(); libraryRequestID = nil
        // The engine's existing close barrier waits for cancelled control opens to finish.
        if oppoBusy { cancelOppo() }
        selectedAddress = device.address; deviceChanged(); transportChoice = "system"
        libraryProbeAddress = device.address; libraryActionBusy = true
        libraryMessage = addingDevice == nil ? "正在自动检测耳机能力…" : "正在检测 LDAC／LHDC V5 能力…"
        attemptedAutomaticProbes.insert(device.address)
        begin(probe: true)
        if !busy { finishLibraryAction("未能开始能力检测，请重试。") }
    }
    private func finishLibraryProbe(_ event: WireMessage) {
        let address = libraryProbeAddress
        let safe = event.restartSafe == true && selectedAddress == address
        let complete = event.kind == "stopped" && event.details?["probeComplete"] == "true"
        if safe, !addingCancelled, let address {
            let partial = Int(event.details?["endpointsFailed"] ?? "0") ?? 0
            codecProbeState = .init(complete && partial == 0 ? .complete : .failed, date: now(), error: complete ? (partial > 0 ? "部分端点查询失败；已保留取得的能力，可重试。" : nil) : event.message ?? "编码查询失败")
            probeComplete = complete; if !complete { capabilities = []; selectedCapability = "" }
            savePreferences()
            if let candidate = addingDevice {
                let identity = addingIdentity
                let legacy = identity?.profile?.isX4 == true ? HeadphoneModel.encoX4 : HeadphoneModel.wh1000xm5.matches(candidate) ? .wh1000xm5 : nil
                let item = RegisteredHeadphone(address: address, model: legacy, name: candidate.name, identity: identity)
                if let index = registeredHeadphones.firstIndex(where: { $0.address == address }) { registeredHeadphones[index] = item }
                else { registeredHeadphones.append(item) }
                if let data = try? JSONEncoder().encode(registeredHeadphones) { preferences.set(data, forKey: "headphoneLibrary.v2") }
                finishLibraryAction(complete ? "已添加 " + candidate.name : "已保存系统音频设备，编码检测失败，可重试。")
                pendingOutputAddress = address; libraryActionBusy = true; requestOutputSelection(); return
            }
            finishLibraryAction(complete ? "" : "编码检测失败，可重试。")
        } else { finishLibraryAction(addingCancelled ? "已取消添加" : "未添加设备：清理未确认，未切换输出。") }
        send(WireMessage("environment"))
    }
    private func receiveEnvironment(_ event: WireMessage) {
        guard let value = event.environment else { return }
        if let old = environment {
            guard old.generation == value.generation, value.revision > old.revision else { return }
        }
        libraryManaged = true; codecSelectionManaged = true
        let oldDevices = devices, oldRoute = environment?.route
        environment = value; devices = value.devices
        reconcileDiscoveryDevices()
        defer { advanceDiscovery() }
        details.merge(event.details ?? [:]) { _, new in new }
        startupHealth.observeBluetoothAuthorization(event.details?["bluetoothAuthorization"])
        if let id = event.requestID, discoveryScanRequests.contains(id) {
            guard id == scanRequestID else { return }
            scanRequestID = nil; scanningDevices = false
            scanMessage = ["1", "2"].contains(details["bluetoothAuthorization"] ?? "") ? "未获得蓝牙权限，请在系统设置中授权。" : ""
            if discoveryOpen, scanMessage.isEmpty {
                discoveryQueue = connectedAudioDevices.filter { needsDiscoveryIdentity($0) }.map(\.address)
            }
            return // Enumeration never changes output or starts a codec/audio probe.
        }
        // Probe-induced disconnects must not create an automatic detection loop.
        if !busy && libraryProbeAddress == nil && recoveryID == nil {
            for device in oldDevices where device.connected && !devices.contains(where: { $0.address == device.address && $0.connected }) {
                attemptedAutomaticProbes.remove(device.address)
            }
        }
        if event.requestID == libraryRequestID, libraryRequestID != nil {
            libraryTimeout?.cancel(); libraryRequestID = nil
            if let selected = addingDevice {
                guard !busy, !value.transitioning, value.audioSessionID == nil,
                      let candidate = devices.first(where: { $0.address == selected.address && $0.connected && $0.isAudio }) else {
                    finishLibraryAction("所选音频设备已断开或连接忙碌，请刷新。"); return
                }
                addingDevice = candidate; beginLibraryIdentity(candidate); return
            }
            if let address = pendingOutputAddress {
                guard !busy, !value.transitioning, value.audioSessionID == nil,
                      let device = devices.first(where: { $0.address == address && $0.connected }) else {
                    finishLibraryAction("耳机未连接或音频会话尚未结束，请重试。"); return
                }
                let id = UUID(); outputRequestID = id
                var request = WireMessage("selectOutput", requestID: id); request.device = device; request.environment = value
                send(request); startLibraryTimeout(id); return
            }
        }
        guard !libraryActionBusy else { return }
        if recoveryID != nil {
            guard !value.transitioning, value.audioSessionID == nil,
                  value.route.uid != nil, !value.route.isVirtual,
                  value.route.bluetoothAddress != requestDevice else { return }
            // After safe cleanup, an unrelated stable output is a system takeover.
            // Do not re-enter HD from a delayed retry and steal that output back.
            stop(); settingsMessage = "系统输出已切换，已取消自动重连。"
        }
        if busy {
            // Only a stable active session can interpret a non-virtual route as takeover.
            // Probe, HiRes reset, reconnect and ordered teardown all create temporary routes.
            if active, hiResContinuation == nil, !value.transitioning, value.audioSessionID == sessionID,
               value.route.uid != nil, !value.route.isVirtual {
                stop(); transportChoice = "system"
            }
            return
        }
        guard !value.transitioning, value.audioSessionID == nil else { return }
        guard !discoveryOpen, !discoveryControlBusy else { return }
        let address = registeredHeadphones.first { $0.address == value.route.bluetoothAddress && isConnected($0) }?.address ?? ""
        let changed = selectedAddress != address
        if changed { selectedAddress = address; deviceChanged(); transportChoice = "system" }
        if !address.isEmpty {
            if changed || oldRoute != value.route || needsIdleRefresh {
                needsIdleRefresh = false
                transportChoice = "system"; refreshDetectedState()
            }
            if codecProbeState.status == .notProbed, !probeComplete, !attemptedAutomaticProbes.contains(address), let device {
                beginLibraryProbe(device); return
            }
        } else if registeredHeadphones.isEmpty { status = "请添加音频输出设备" }
        else if !registeredHeadphones.contains(where: { isConnected($0) }) { status = "耳机未连接" }
        else if value.route.uid != nil { status = "当前使用其他系统输出" }
        // A newly connected registered device without cache is checked once, serially.
        if let candidate = registeredHeadphones.first(where: { item in
            isConnected(item) && !attemptedAutomaticProbes.contains(item.address) && !hasCachedCapabilities(item.address)
        }), let device = devices.first(where: { $0.address == candidate.address }) { beginLibraryProbe(device) }
    }
    private func hasCachedCapabilities(_ address: String) -> Bool {
        guard let data = preferences.data(forKey: "device." + address),
              let saved = try? JSONDecoder().decode(SavedDevice.self, from: data) else { return false }
        return saved.codecProbeState?.status != .notProbed && saved.codecProbeState != nil || !saved.capabilities.isEmpty
    }
    func selectDevice(_ address: String) {
        guard canEditSettings else { return }
        pendingCodecActivation = nil
        selectedAddress = address
        deviceChanged()
        transportChoice = active && selectedIsPlaying ? negotiated?.codec.rawValue ?? "system" : "system"
        nativeCodecID = nil
        if codecSelectionManaged && !busy { refreshDetectedState() }
    }
    func chooseCodec(_ value: String) {
        guard !discoveryControlBusy, device?.connected == true, !previewMode, !libraryActionBusy else { return }
        codecSelectionManaged = true
        if value == "system" {
            pendingCodecActivation = nil; transportChoice = "system"
            if oppoBusy { cancelOppo() }
            if busy { stop() } else { refreshDetectedState() }
            return
        }
        guard canChooseHDCodec, let codec = CodecID(rawValue: value), availableHDCodecs.contains(codec) else { return }
        if active && selectedIsPlaying && negotiated?.codec == codec { return }
        transportChoice = value
        if oppoBusy, let id = oppoRequestID {
            // Cancellation closes a real RFCOMM channel. Wait for its terminal
            // response before claiming the AVDTP session instead of racing it.
            pendingCodecActivation = codec
            initialSettingsSource = "正在结束耳机控制查询，随后连接高清编码。"
            send(WireMessage("oppoCancel", requestID: id))
        } else { startDetectedCodec(codec) }
    }
    private func startDetectedCodec(_ codec: CodecID) {
        guard let cap = capabilities.first(where: { $0.codec == codec && $0.playable }) else {
            transportChoice = "system"
            error = "本次检测未取得 " + codec.title + " 的可用能力，未启动高清音频。"
            refreshDetectedState(); return
        }
        selectedCapability = cap.id
        var config: PlaybackConfiguration
        if let saved = playbackPreferences[codec.rawValue] {
            do {
                if !allowsUnreportedParameters || !saved.isForced {
                    config = try cap.supportedContinuation(from: saved)
                } else {
                    config = try cap.configuration(rate: saved.sampleRate.rawValue, quality: saved.quality,
                                                   fixedBitrate: saved.fixedBitrateKbps, allowUnreported: true)
                }
                let adjusted = config.sampleRate != saved.sampleRate || config.quality != saved.quality || config.fixedBitrateKbps != saved.fixedBitrateKbps || config.isForced != saved.isForced
                playbackPreferences[codec.rawValue] = config
                initialSettingsSource = adjusted
                    ? "耳机能力已变化，超出范围的参数已恢复为支持的设置：\(config.sampleRate.rawValue) Hz／\(config.fixedBitrateKbps.map { String($0) + " kbps" } ?? "自适应码率")。"
                    : "沿用此耳机上次明确设置的采样率和码率；连接内重新核验，成功后显示实际参数。"
            } catch {
                transportChoice = "system"; resettableCodec = codec
                self.error = "保存参数未能应用：" + error.localizedDescription + "。可选择使用当前能力的默认参数。"
                return
            }
        } else {
            let inputRate = audioState?.nativeOutput?.sampleRate.flatMap { value -> Int? in
                guard value.isFinite, value >= 1, value <= 384000 else { return nil }
                return Int(value)
            }
            let initialRate = inputRate.flatMap { commonRates.contains($0) ? $0 : nil } ?? defaultRate
            guard let initial = try? cap.configuration(rate: initialRate) else { return }
            config = initial
            initialSettingsSource = "首次连接按系统输出格式与耳机能力交集选择采样率，码率使用自适应；明确修改后将按此耳机保存。"
        }
        resettableCodec = nil
        config.buffering = bufferingSettings
        rate = config.sampleRate.rawValue; quality = config.quality; fixedBitrate = config.fixedBitrateKbps ?? 0
        guard let device else { return }
        let initialGain = active && !selectedIsPlaying ? rememberedGain(address: device.address, linked: false) : gain
        let request = StartRequest(device: device, configuration: config, gain: initialGain)
        if active { replaceSession(with: request) } else { begin(request) }
    }
    func useDefaultPlaybackSettings() {
        guard !busy, !oppoBusy, let codec = resettableCodec else { return }
        playbackPreferences.removeValue(forKey: codec.rawValue); resettableCodec = nil
        savePreferences(); chooseCodec(codec.rawValue)
    }
    func refreshDetectedState() {
        guard !previewMode, device?.connected == true, pendingCodecActivation == nil else { return }
        if !active { nativeCodecID = nil }
        refreshAudioState()
        if supportsHeadsetControl && canQueryOppo { queryOppo() }
    }
    var device: BluetoothDevice? { devices.first { $0.address == selectedAddress } }
    var capability: CodecCapabilities? { capabilities.first { $0.id == selectedCapability } }
    var commonRates: [Int] { guard let cap = capability, let codec = cap.codec else { return [] }; return cap.sampleRates.filter(codec.sampleRates.contains).sorted() }
    var canStart: Bool { !discoveryControlBusy && !busy && !oppoBusy && probeComplete && capability?.playable == true }
    var defaultRate: Int { commonRates.contains(48000) ? 48000 : commonRates.contains(44100) ? 44100 : commonRates.first ?? 48000 }
    var selectedRate: Int { rate != 0 ? rate : defaultRate }
    // Product identity comes from ELNK, including its per-device cached identity.
    // X4 uses advertised choices even while HiRes status is stale/unknown.
    var allowsUnreportedParameters: Bool {
        if !libraryManaged { return !(headset?.address == selectedAddress && headset?.isX4 == true && capability?.codec == .lhdcV5) }
        switch registeredHeadphones.first(where: { $0.address == selectedAddress })?.model {
        case .wh1000xm5: return true
        case .encoX4: return capability?.codec != .lhdcV5
        case nil: return false
        }
    }
    var availableRates: [Int] { allowsUnreportedParameters ? capability?.codec?.sampleRates ?? [] : commonRates }
    var bitrates: [Int] { allowsUnreportedParameters ? capability?.codec?.fixedBitrates(rate: selectedRate) ?? [] : capability?.fixedBitrates(rate: selectedRate) ?? [] }
    var transportSettingsTitle: String { (capability?.codec?.title ?? "音频") + " 传输设置" }
    var selectedDeviceTitle: String {
        guard let device else { return "未选择耳机" }
        return device.name + (HeadphoneModel.wh1000xm5.matches(device) ? "（实验性）" : "")
    }
    static func visibleControlMessage(_ message: String) -> String {
        // Pending readback still protects controls; it is not a user-facing error.
        if message == "设置待读回确认" || message == "等待读回确认" || message == "等待读回确认…"
            || (message.hasPrefix("正在设置") && message.hasSuffix("，等待读回确认")) { return "" }
        return message.replacingOccurrences(of: "配置已确认；实际效果需实机验收", with: "")
            .replacingOccurrences(of: "耳机状态已刷新", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "； "))
    }
    static func visibleControlIssue(_ issue: String?) -> String? {
        guard let issue else { return nil }
        let visible = visibleControlMessage(issue)
        return visible.isEmpty ? nil : visible
    }
    var visibleHeadsetMessage: String { Self.visibleControlMessage(headsetMessage) }
    var visibleOppoMessage: String { isDetectingHiRes ? "" : Self.visibleControlMessage(oppoMessage) }
    var transportSettingsNotice: String? {
        if selectedCodecIsActive { return hasTransportEdits ? "修改尚未应用" : nil }
        guard !busy, pendingStart == nil, pendingCodecActivation == nil, recoveryID == nil, hiResContinuation == nil else { return nil }
        return "选择 " + (capability?.codec?.title ?? "对应") + " 编码后生效"
    }
    static let reconnectAdvice = "请尝试重新检测并连接，若依旧失败则尝试重启应用并重新连接耳机蓝牙"
    var showsReconnectAdvice: Bool { error != nil && !busy && !active && connectionPhase == "failed" }
    var canEditSettings: Bool { !discoveryControlBusy && pendingMIDIStart == nil && !localDataBusy && (!busy || active) && !oppoBusy && pendingCodecActivation == nil }
    // The engine serializes reads with both visible and periodic headset work.
    var canQueryOppo: Bool { !discoveryControlBusy && supportsHeadsetControl && !libraryActionBusy && headsetRecoveryID == nil && !localDataBusy && device?.connected == true && (!busy || (active && requestDevice == selectedAddress)) && !oppoBusy && !previewMode }
    var canSetOppoHiRes: Bool {
        canQueryOppo && headsetRecoveryID == nil && !headsetReadIncludesHiRes && headsetWriteID == nil && active &&
        headset?.address == selectedAddress && headset?.connected == true &&
        headset?.controlReport.canSetHiRes == true
    }
    var hiResValue: Bool? { headset?.address == selectedAddress ? headset?.controlReport.hiRes : nil }
    var hiResDisplayedValue: Bool { headsetDisplaySnapshot?.address == selectedAddress && headsetDisplaySnapshot?.features[24]?.value == true }
    var isDetectingHiRes: Bool { oppoQueryInProgress || pendingHiResQuerySessionID != nil || headsetReadIncludesHiRes }
    var headsetWriting: Bool { headsetWriteID != nil }
    var hasPendingStart: Bool { pendingStart != nil }
    var selectedIsPlaying: Bool { requestDevice == selectedAddress }
    var currentInputDescription: String { negotiated?.encoderInputDescription ?? "未协商" }
    var selectedCodecIsActive: Bool { showsLiveFormat && negotiated?.codec == capability?.codec }
    var hasTransportEdits: Bool {
        guard selectedCodecIsActive, let config = configuration, let negotiated else { return false }
        return config.requiresReconnect(from: negotiated)
    }
    var showsApplySettings: Bool { showsHDSettings && (!busy || active) && (!selectedCodecIsActive || hasTransportEdits) }
    var applySettingsTitle: String { selectedCodecIsActive ? "应用修改" : "启用 " + (capability?.codec?.title ?? "高清音频") + " 并应用" }
    var canApplySettings: Bool {
        canEditSettings && canChooseHDCodec && !applyingBuffering && configuration != nil &&
        (!selectedCodecIsActive || hasTransportEdits)
    }
    var inputDescription: String { capability?.codec == .lhdcV5 ? "\((capability?.bitDepths ?? []).contains(24) ? 24 : 16)-bit 整数 PCM" : "Float32 PCM" }
    var bufferingSettings: BufferingConfiguration { .init(catchupLimitTenths: catchupLimitTenths, prefillMilliseconds: prefillMilliseconds) }
    var configuration: PlaybackConfiguration? {
        guard var config = try? capability?.configuration(rate: rate == 0 ? nil : rate, quality: quality,
            fixedBitrate: capability?.codec == .lhdcV5 && quality != .adaptive && fixedBitrate != 0 ? fixedBitrate : nil, allowUnreported: allowsUnreportedParameters) else { return nil }
        config.buffering = bufferingSettings
        return config
    }
    private struct SavedDevice: Codable { var codecProbeState: CodecProbeState? = nil; var capabilities: [CodecCapabilities]; var detectedAt: Date?; var selectedCapability: String; var rate: Int; var quality: Quality; var fixedBitrate: Int; var linkHardwareVolume: Bool? = nil; var buffering: BufferingConfiguration? = nil; var playbackPreferences: [String: PlaybackConfiguration]? = nil }
    func bufferingChanged() {
        catchupLimitTenths = min(150, max(1, catchupLimitTenths))
        prefillMilliseconds = min(1000, max(10, prefillMilliseconds))
        savePreferences()
        applyBuffering()
    }
    private func savePreferences() {
        guard !previewMode, !selectedAddress.isEmpty else { return }
        let saved = SavedDevice(codecProbeState: codecProbeState, capabilities: probeComplete ? capabilities : [], detectedAt: detectedAt, selectedCapability: selectedCapability, rate: rate, quality: quality, fixedBitrate: fixedBitrate, linkHardwareVolume: linkHardwareVolume, buffering: bufferingSettings, playbackPreferences: playbackPreferences)
        if let data = try? JSONEncoder().encode(saved) { preferences.set(data, forKey: "device." + selectedAddress) }
        preferences.set(selectedAddress, forKey: "selectedDevice")
    }
    func parametersChanged(userInitiated: Bool = true) {
        if rate != 0 && !availableRates.contains(rate) { rate = 0 }
        if capability?.codec == .lhdcV5 && quality != .adaptive { quality = .connection }
        if fixedBitrate != 0 && !bitrates.contains(fixedBitrate) {
            // Preserve the same LHDC quality index across the 44.1/48 kHz families.
            let mapped = [240: 256, 256: 240, 480: 500, 500: 480][fixedBitrate]
            fixedBitrate = mapped.flatMap { bitrates.contains($0) ? $0 : nil } ?? 0
        }
        if userInitiated, (!busy || active), let config = configuration {
            playbackPreferences[config.codec.rawValue] = config
        }
        savePreferences()
    }
    static func defaultGain(linked: Bool) -> Double { linked ? 0.4 : 1.0 }
    private func volumeKey(address: String, linked: Bool) -> String {
        "volume.v2." + (linked ? "linked." : "software.") + address
    }
    private func rememberedGain(address: String, linked: Bool) -> Double {
        guard softwareVolumeEnabled else { return 1 }
        // The new defaults replace the old mute-on-first-use policy once per device.
        // Subsequent explicit adjustments are remembered separately for each mode.
        guard let value = preferences.object(forKey: volumeKey(address: address, linked: linked)) as? Double,
              value.isFinite, (0...1).contains(value) else { return Self.defaultGain(linked: linked) }
        return value
    }
    private func rememberGain(_ value: Double, address: String, linked: Bool) {
        guard softwareVolumeEnabled, !previewMode, !address.isEmpty else { return }
        preferences.set(value, forKey: volumeKey(address: address, linked: linked))
    }
    func setSoftwareVolumeEnabled(_ enabled: Bool) {
        guard enabled != softwareVolumeEnabled else { return }
        softwareVolumeEnabled = enabled
        if !previewMode { preferences.set(enabled, forKey: "softwareVolumeEnabled") }
        let address = busy ? requestDevice ?? selectedAddress : selectedAddress
        let linked = busy ? requestVolumeLinked : linkHardwareVolume
        // Bypass the slider guard to restore unity without replacing the remembered adjustment.
        applyGain(enabled ? rememberedGain(address: address, linked: linked) : 1)
    }
    func setVolumeLink(_ enabled: Bool) {
        guard !busy, enabled != linkHardwareVolume, !enabled || HardwareVolumeSupport.available else { return }
        linkHardwareVolume = enabled; volumeLinkState = "off"; volumeLinkMessage = ""
        setGain(Self.defaultGain(linked: enabled)); savePreferences()
    }
    func refreshAudioState() {
        guard !previewMode, let device, input != nil else { return }
        let id = UUID(); audioRequestID = id
        var request = WireMessage("audioState", requestID: id); request.device = device; send(request)
    }

    func launch() {
        guard !audioMaintenance else { return }
        codecSelectionManaged = true
        libraryManaged = true
        if previewMode {
            if devices.isEmpty {
                devices = [.init(address: "00:11:22:33:44:55", name: "预览耳机", connected: true, a2dpSink: true)]
                selectedAddress = devices[0].address
                capabilities = [try! CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x16,0x11,0x40,0])]
                capabilities.append(try! CapabilityParser.codec(endpoint: 1, bytes: [0,255,0x2d,1,0,0,0xaa,0,0x3c,7]))
                selectedCapability = capabilities[0].id; probeComplete = true; detectedAt = Date(); status = "界面预览 · 模拟能力数据"
                if CommandLine.arguments.contains("--ui-preview-native") {
                    nativeCodecID = 2; status = "界面预览 · 模拟系统 AAC，未启用高清音频"
                }
                if CommandLine.arguments.contains("--ui-preview-headset") {
                    devices[0] = .init(address: selectedAddress, name: "Enco X4 · 模拟预览", connected: true, a2dpSink: true)
                    var state = HeadsetSnapshot(address: selectedAddress); state.connected = true; state.productID = 0x06ec10
                    state.battery = [1: .init(.init(percent: 86, charging: false)), 2: .init(.init(percent: 91, charging: true)), 3: .init(.init(percent: 55, charging: false), at: Date().addingTimeInterval(-3600), stale: true)]
                    state.capabilities = try! .init(reply: .init(command: 0x8100, payload: [0,255,0x77,0x5a,0xee,0xee,0x8f,0xa6,0x5f,0x17]))
                    state.noiseAvailable = .init([3,8,4,5,6,7]); state.noise = .init(3); state.preset = .init(7)
                    state.keys = .init([HeadsetKey(ear: 1, action: 1, function: 1), HeadsetKey(ear: 2, action: 2, function: 6)])
                    state.features = [4: .init(true),17: .init(true)]
                    state.equalizers = .init(["Master EQ Balance", "Master EQ Monitor", "Master EQ Pop"].enumerated().map { index, name in
                        HeadsetEQ(id: UInt8(index + 10), name: name, minimum: -6, maximum: 6, frequencies: [31,62,125,250,500,1000,2000,4000,8000,16000], gains: Array(repeating: 0, count: 10))
                    })
                    state.features[29] = .init(false); state.bassWave = .init(.init(minimum: -5, maximum: 5, current: 0))
                    headset = state; headsetMessage = "模拟数据预览 · 不连接耳机、不发送设置"
                }
                if CommandLine.arguments.contains("--ui-preview-oppo") {
                    capabilities.removeAll { $0.codec == .ldac }
                    capabilities[0] = try! CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])
                    var report = OppoProbeReport(); report.hiRes = true; report.currentCodecID = 8
                    report.codecListMask = 0x146; report.controlReceiveMTU = 4600
                    report.controlCapabilities = try! .init(reply: .init(command: 0x8100, payload: [0,0x80,0,2,0,0x20]))
                    var preview = headset ?? HeadsetSnapshot(address: selectedAddress)
                    preview.connected = true; preview.features[24] = .init(true)
                    preview.currentCodec = report.currentCodecID; preview.capabilities = report.controlCapabilities
                    headset = preview
                    oppoReport = report; oppoMessage = "界面预览 · 模拟 HiRes 开启，控制操作已禁用"
                }
                if CommandLine.arguments.contains("--ui-preview-active") {
                    busy = true; active = true; requestDevice = selectedAddress; sessionID = UUID()
                    negotiated = configuration; format = negotiated?.format; connectionPhase = "active"
                    transportChoice = negotiated?.codec.rawValue ?? "system"
                    rate = negotiated?.sampleRate.rawValue ?? 0
                    status = "界面预览 · 模拟启用状态"
                    if CommandLine.arguments.contains("--ui-preview-sender") {
                        metrics = ["windowSeconds":1.003,"windowPackets":198,"packetBytesMax":578,
                            "drainMaxMs":12.4,"drainMeanMs":1.3,"scheduleLateMaxMs":4.7,
                            "encodeMaxMs":0.09,"drainPendingMs":0,"sessionDrainMaxMs":64.2,
                            "sessionDrainOver8ms":3,"sessionDrainOver50ms":1]
                    }
                }
                registeredHeadphones = [.init(address: selectedAddress, model: .encoX4)]
                environment = .init(generation: UUID(), revision: 1, devices: devices,
                                    route: .init(uid: "preview", bluetoothAddress: selectedAddress, isVirtual: active))
                details["driverRevision"] = "6"
            }; return
        }
        if process?.isRunning == true { send(WireMessage("environment")); return }
        environment = nil; attemptedAutomaticProbes = []
        let executable = Bundle.main.bundleURL.appendingPathComponent(RuntimeIdentity.engineExecutablePath)
        let process = Process(), toEngine = Pipe(), fromEngine = Pipe(), errors = Pipe()
        process.executableURL = executable; process.standardInput = toEngine; process.standardOutput = fromEngine; process.standardError = errors
        // Stderr is diagnostic only and never interpreted as control messages.
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self else { return }
                guard self.process === child else { return }
                if self.resetWaitingForEngine { self.finishApplicationReset(exitStatus: child.terminationStatus); return }
                if self.localDataAction != nil { self.failLocalDataAction("引擎已退出，未确认系统通道恢复；保留设备记录。") }
                self.busy = false; self.active = false; self.input = nil
                self.pendingCodecActivation = nil; self.transportChoice = "system"
                self.resetOppo(message: "引擎已退出，请重新查询")
                self.headset?.markStale(); self.headsetBusy = false; self.headsetWatchID = nil
                self.headsetRequestID = nil; self.headsetWriteID = nil; self.headsetWriteSetting = nil; self.pendingHeadsetPage = nil; self.loadedHeadsetPages.removeAll(); self.headsetReadIncludesHiRes = false; self.headsetRecoveryID = nil; self.wearAutomation = false; self.mediaMessage = "引擎已退出，联动已关闭"
                self.hiResContinuation = nil
                self.cancelRecovery()
                self.cancelPendingSettings()
                if child.terminationStatus != 0 { self.error = "会话引擎异常结束（\(child.terminationStatus)）；HAL 租约会自动释放。" }
                self.status = "引擎已退出"
                self.finishLibraryAction("引擎已退出，未完成的设备操作已取消。")
                self.discoveryOpen = false; self.discoveryRefreshPending = false; self.discoveryQueue.removeAll(); self.discoveryRequest = nil
                self.identifyingDevices = false; self.discoveryCleanupBlocked = false; self.discoveryRestoreWatch = false
                self.discoveryIdentities.removeAll(); self.discoveryFailures.removeAll()
                self.scanRequestID = nil; self.scanningDevices = false
                self.discoveryMessage = "引擎已退出，请刷新设备列表。"
                self.environment = nil
                self.devices = self.devices.map { .init(address: $0.address, name: $0.name, connected: false, a2dpSink: $0.a2dpSink) }
            }
        }
        do {
            try process.run(); self.process = process; input = toEngine.fileHandleForWriting
            let handle = fromEngine.fileHandleForReading
            reader = Task.detached { [weak self] in
                var buffer = Data()
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty { return }; buffer.append(data)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                        guard line.count < 65536, let event = try? JSONDecoder().decode(WireMessage.self, from: line), event.version == 1 else { return }
                        await self?.receive(event)
                    }
                    if buffer.count > 65536 { return }
                }
            }
            send(WireMessage("environmentWatch"))
            if messageSink == nil { startupHealth.start() }
        } catch { self.error = error.localizedDescription }
    }
    func send(_ message: WireMessage) {
        guard !audioMaintenance || ["quit", "oppoCancel", "headsetCancel", "headsetUnwatch"].contains(message.kind) else { return }
        if let messageSink { messageSink(message); return }
        do { guard let input else { throw ProtocolFailure("引擎尚未运行") }; try input.write(contentsOf: JSONEncoder().encode(message) + Data([10])) }
        catch {
            self.error = error.localizedDescription
            if process?.isRunning != true { busy = false; active = false; resetOppo(message: "引擎未运行，未执行查询") }
        }
    }
    func receive(_ event: WireMessage) {
        if resetWaitingForEngine || audioMaintenance { return }
        if event.kind == "permissionState" {
            if let authorization = event.details?["bluetoothAuthorization"] {
                details["bluetoothAuthorization"] = authorization
                startupHealth.observeBluetoothAuthorization(authorization)
            }
            return
        }
        if event.kind == "environment" { receiveEnvironment(event); return }
        if event.kind == "outputSelected" {
            guard let id = outputRequestID, event.requestID == id else { return }
            finishLibraryAction(event.message ?? "")
            // Confirm the real route in a fresh observation; never select optimistically.
            send(WireMessage("environment")); return
        }

        // A control transaction may still be closing when audio becomes active.
        // Drain the one-shot read after its terminal reply, never race or poll it.
        defer { queryPendingHiRes(); advanceDiscovery(); drainHeadsetPage() }
        if event.kind == "deviceIdentity" {
            if event.requestID == discoveryRequest?.id { receiveDiscoveryIdentity(event) }
            else { receiveLibraryIdentity(event) }
            return
        }
        if event.kind.hasPrefix("headset") { receiveHeadset(event); return }
        if ["oppoProgress", "oppoResult", "oppoFailed"].contains(event.kind) {
            guard oppoBusy, let id = oppoRequestID, event.requestID == id,
                  event.device?.address == selectedAddress,
                  event.sessionID == nil || event.sessionID == sessionID || event.sessionID == hiResWriteSessionID else { return }
            oppoMessage = event.message ?? "未取得状态"
            if event.kind != "oppoProgress" {
                let wasReading = oppoQueryInProgress
                let wasResuming = headsetResumeInProgress
                headsetResumeInProgress = false
                finishHiResReadTimeout()
                oppoBusy = false; oppoRequestID = nil; oppoQueryInProgress = false
                if let codec = pendingCodecActivation {
                    pendingCodecActivation = nil
                    oppoReport = nil
                    startDetectedCodec(codec)
                    return
                }
                let currentControl = event.controlGeneration.map { !retiredGenerations.contains($0) } ?? false
                oppoReport = event.kind == "oppoResult" && currentControl ? event.oppoReport : nil
                oppoControlGeneration = event.kind == "oppoResult" && currentControl ? event.controlGeneration : nil
                if let snapshot = event.headset { acceptHeadset(snapshot) }
                if event.kind != "oppoResult" { headset?.markStale(.feature(.hiRes), reason: event.message ?? "HiRes 读取失败") }
                if wasReading, currentControl, event.kind == "oppoResult", oppoReport?.hiRes != nil,
                   headset?.connected == true, headset?.generation == event.controlGeneration,
                   headset?.features[HeadsetFeature.hiRes.rawValue]?.stale == false {
                    hiResRefreshedAt = Date()
                }
                if !busy { nativeCodecID = oppoReport?.currentCodecID }
                // A correlated ACK/readback remains a completed transaction even
                // when its profile restart has already made the live snapshot stale.
                if hiResContinuation != nil, event.kind == "oppoResult", event.controlGeneration == hiResWriteControlGeneration,
                   let report = event.oppoReport, report.experiment?.verified == true {
                    hiResVerified = true
                    oppoRefreshMessage = report.message
                    if active { probe() }
                    // A profile restart may have started teardown before the reply.
                    // Its terminal event is the sole gate for the next connection.
                } else {
                    hiResContinuation = nil; hiResWriteSessionID = nil; hiResWriteControlGeneration = nil; hiResVerified = false
                    if wantsHeadset, !wasResuming, event.kind == "oppoResult" { listenHeadset() }
                }
            }
            return
        }
        if let id = event.sessionID, id != sessionID { return }
        history.append(event); if history.count > 600 { history.removeFirst(history.count - 600) }
        switch event.kind {
        case "systemSleep":
            endDeviceDiscovery()
            if localDataAction != nil { failLocalDataAction("系统正在睡眠，已取消删除或清空操作。") }
            finishLibraryAction("系统即将睡眠，设备操作已取消。")
            stop()
        case "devices":
            devices = event.devices ?? []; details.merge(event.details ?? [:]) { _, new in new }
            startupHealth.observeBluetoothAuthorization(event.details?["bluetoothAuthorization"])
            if libraryManaged { return }
            if selectedAddress.isEmpty {
                let saved = preferences.string(forKey: "selectedDevice")
                if let first = devices.first(where: { $0.address == saved }) ?? devices.first(where: \.a2dpSink) ?? devices.first { selectedAddress = first.address; deviceChanged() }
            }
            if codecSelectionManaged && !busy { refreshDetectedState() } else { refreshAudioState() }
        case "audioState":
            if event.requestID == nil || event.requestID == audioRequestID { audioState = event.audioState }
        case "volumeLink": volumeLinkState = event.volumeLinkState ?? "off"; volumeLinkMessage = event.message ?? ""
        case "doctor":
            details = event.details ?? [:]
            startupHealth.observeBluetoothAuthorization(event.details?["bluetoothAuthorization"])
        case "preparing": busy = true; connectionPhase = "preparing"; status = event.message ?? "准备中"
        case "connecting": connectionPhase = "connecting"; status = "正在连接并协商"
        case "capabilities": if selectedIsPlaying { capabilities = event.capabilities ?? [] }
        case "active":
            guard let sessionID, event.sessionID == sessionID, busy, !active, !requestIsProbe,
                  connectionPhase != "stopping" else { return }
            error = nil
            hiResContinuation = nil; hiResDeadline = nil; hiResWriteSessionID = nil; hiResWriteControlGeneration = nil; hiResVerified = false
            resettableCodec = nil
            settingsMessage = ""
            active = true; connectionPhase = "active"; format = event.format; negotiated = event.configuration
            status = "正在发送 \(event.configuration?.codec.title ?? "音频") · \(devices.first(where: { $0.address == requestDevice })?.name ?? "当前耳机")"
            if codecSelectionManaged, selectedIsPlaying, let config = negotiated {
                transportChoice = config.codec.rawValue
                if let cap = capabilities.first(where: { $0.codec == config.codec && $0.endpoint == config.endpoint && $0.playable }) {
                    selectedCapability = cap.id; probeComplete = true; detectedAt = Date()
                }
                rate = config.sampleRate.rawValue; quality = config.quality
                fixedBitrate = config.fixedBitrateKbps ?? 0
                catchupLimitTenths = config.bufferingSettings.catchupLimitTenths
                prefillMilliseconds = config.bufferingSettings.prefillMilliseconds
                savePreferences()
            }
            if selectedIsPlaying, supportsHeadsetControl, (negotiated?.codec == .lhdcV5 || libraryManaged), autoHiResQuerySessionID != sessionID {
                autoHiResQuerySessionID = sessionID
                pendingHiResQuerySessionID = sessionID
                oppoMessage = "正在检测 HiRes 状态"
                startHiResReadTimeout(limit: 80)
            }
        case "format": format = event.format
        case "sampleRateRequested":
            guard active, let sessionID, event.sessionID == sessionID, let config = event.configuration,
                  let current = negotiated, config.codec == current.codec, config.endpoint == current.endpoint,
                  !config.probeOnly, (try? config.validate()) != nil, let requestDevice,
                  let caps = event.capabilities,
                  let cap = caps.first(where: { $0.codec == config.codec && $0.endpoint == config.endpoint }) else { return }
            // MIDI targets the playing virtual device even if the GUI is showing
            // a different (not yet detected) headphone selection.
            let wasPlayingSelection = selectedIsPlaying
            selectedAddress = requestDevice; capabilities = caps; selectedCapability = cap.id; probeComplete = true
            rate = config.sampleRate.rawValue; quality = config.quality; fixedBitrate = config.fixedBitrateKbps ?? 0
            if !wasPlayingSelection {
                catchupLimitTenths = config.bufferingSettings.catchupLimitTenths
                prefillMilliseconds = config.bufferingSettings.prefillMilliseconds
            }
            settingsMessage = "正在应用音频 MIDI 设置中的采样率修改。"
            parametersChanged()
            if let device, let updated = configuration {
                // MIDI is an explicit external request. Snapshot it so later UI
                // draft edits cannot be submitted by a delayed buffering ACK.
                pendingMIDIStart = StartRequest(device: device, configuration: updated, gain: gain, linkHardwareVolume: linkHardwareVolume)
                applyPendingMIDI()
            }
        case "settingsRejected":
            guard let sessionID, event.sessionID == sessionID else { return }
            settingsMessage = event.message ?? "系统采样率修改未能应用"
        case "bufferingApplied":
            guard applyingBuffering, event.requestID == bufferingRequestID, let settings = event.buffering,
                  settings == bufferingInFlight, (try? settings.validate()) != nil else { return }
            negotiated?.buffering = settings; applyingBuffering = false; bufferingRequestID = nil; bufferingInFlight = nil
            metrics["catchupSeconds"] = 0
            settingsMessage = "缓冲设置已自动应用。"
            if pendingMIDIStart != nil { applyPendingMIDI() }
            else { applyBuffering() } // Coalesce only buffer edits, never transport drafts.
        case "bufferingRejected":
            guard applyingBuffering, event.requestID == bufferingRequestID else { return }
            let attempted = bufferingInFlight
            applyingBuffering = false; bufferingRequestID = nil; bufferingInFlight = nil
            settingsMessage = event.message ?? "缓冲设置未能应用"
            if pendingMIDIStart != nil { applyPendingMIDI() }
            else if bufferingSettings != attempted { applyBuffering() }
        case "gain":
            if !requestIsProbe, connectionPhase != "stopping", let value = event.gain, value.isFinite, (0...1).contains(value) {
                if !softwareVolumeEnabled {
                    // Ignore late slider replies and restore unity after external HAL volume changes.
                    gain = 1
                    if value != 1, busy, let sessionID {
                        var command = WireMessage("gain", sessionID: sessionID); command.gain = 1; send(command)
                    }
                    return
                }
                gain = value
                if let requestDevice { rememberGain(value, address: requestDevice, linked: requestVolumeLinked) }
            }
        case "telemetry": telemetry = event.message ?? ""; metrics.merge(event.metrics ?? [:]) { _, new in new }
        case "capturePermission": status = event.message == "ready" ? "音频捕获已就绪，正在启动发送" : "需要在系统设置中允许录制系统音频"
        case "stopProgress":
            guard busy, connectionPhase == "stopping", event.sessionID == sessionID,
                  let phase = event.stopPhase else { return }
            status = phase.title
        case "stopping":
            pendingHiResQuerySessionID = nil
            if oppoQueryInProgress { cancelOppo() }
            active = false; connectionPhase = "stopping"; status = "正在停止并恢复音频输出"
        case "error":
            pendingHiResQuerySessionID = nil
            if oppoQueryInProgress { cancelOppo() }
            // A session's early error precedes cleanup. Recovery decisions use
            // only its correlated terminal event with a typed cause and cleanup result.
            if event.sessionID == nil { hiResContinuation = nil; cancelRecovery() }
            pendingCodecActivation = nil
            error = event.message; cancelPendingSettings(); settingsMessage = "设置应用已取消"
            if busy { active = false; connectionPhase = "stopping" }
        case "stopped", "failed":
            guard let currentID = sessionID, event.sessionID == currentID else { return }
            pendingHiResQuerySessionID = nil
            if oppoQueryInProgress { cancelOppo() }
            let failedRequest = currentStart
            var next = event.kind == "stopped" && event.sessionID == pendingStopID && event.message == nil && event.restartSafe != false ? pendingStart : nil
            // The old profile may disappear during a confirmed HiRes write. Use
            // final, independently verified cleanup, never an intermediate error.
            if automaticRecoveryAllowed, hiResVerified, hiResContinuation != nil,
               event.sessionID == hiResWriteSessionID, event.restartSafe == true {
                var probe = PlaybackConfiguration(); probe.probeOnly = true
                next = StartRequest(device: hiResContinuation!.device, configuration: probe, gain: 0)
            }
            cancelPendingSettings()
            busy = false; active = false; status = event.kind == "failed" ? "查询或播放失败" : "已停止"
            if volumeLinkState != "unavailable" { volumeLinkState = "off"; volumeLinkMessage = "" }
            connectionPhase = event.kind == "failed" ? "failed" : "idle"
            if event.kind == "failed" { error = event.message ?? error ?? "查询或播放失败" }
            else { error = event.message }
            details.merge(event.details ?? [:]) { _, new in new }
            if event.kind == "stopped", event.details?["probeComplete"] == "true", selectedIsPlaying {
                capabilities = event.capabilities ?? []; probeComplete = true; codecProbeState = .init(.complete, date: now())
                if !capabilities.contains(where: { $0.id == selectedCapability && $0.playable }) { selectedCapability = capabilities.first(where: \.playable)?.id ?? "" }
                let partial = Int(event.details?["endpointsFailed"] ?? "0") ?? 0
                if partial > 0 { codecProbeState = .init(.failed, date: now(), error: "部分端点查询失败；已保留取得的能力，可重试。") }
                status = partial > 0 ? "部分端点查询失败 · 已显示取得的能力" : capabilities.contains(where: \.playable) ? "耳机能力已读取" : "当前未广播本机可用编码"
                detectedAt = Date(); parametersChanged(userInitiated: false); savePreferences()
            }
            if requestIsProbe, event.restartSafe == true, event.details?["probeComplete"] != "true", selectedIsPlaying {
                codecProbeState = .init(.failed, date: now(), error: event.message ?? "编码检测未完成")
                probeComplete = false; savePreferences()
            }
            sessionID = nil
            needsIdleRefresh = true
            if localDataAction != nil {
                if event.restartSafe == true || event.restartSafe == nil && event.kind == "stopped" && event.message == nil { finishLocalDataAction() }
                else { failLocalDataAction("原音频会话未安全结束，未删除设备或清空数据。") }
                return
            }
            if libraryProbeAddress != nil {
                finishLibraryProbe(event)
                return
            }
            if pendingOutputAddress != nil {
                if event.restartSafe == true || event.kind == "stopped" && event.message == nil { requestOutputSelection() }
                else { finishLibraryAction("原音频会话未能正常清理，未切换输出。") }
                return
            }
            if next == nil, event.kind == "failed", let failedRequest,
               recoverAfterFailure(event, request: failedRequest) { return }
            if next == nil && (event.kind == "failed" || event.message != nil) { hiResContinuation = nil }
            let resume = next == nil && requestIsProbe && event.kind == "stopped" && event.details?["probeComplete"] == "true" ? hiResContinuation : nil
            if next == nil {
                if resume == nil { hiResContinuation = nil }
                if let message = oppoRefreshMessage {
                    oppoMessage = message + (resume != nil ? " 已更新音频能力，正在恢复高清连接。" : " 未自动恢复播放；能力查询失败时请重新检测。")
                    oppoRefreshMessage = nil
                }
            }
            if let next, hiResContinuation != nil {
                scheduleRecovery(next, delay: 5, message: "HiRes 已确认，等待耳机连接稳定后重新检测能力。")
            }
            else if let next { begin(next) }
            else if let resume { resumeAfterHiRes(resume) }
            else if codecSelectionManaged {
                transportChoice = "system"
                if libraryManaged { send(WireMessage("environment")) }
                else { refreshDetectedState() }
            } else if wantsHeadset { watchHeadset() }
        default: break
        }
    }
    private func resumeAfterHiRes(_ request: StartRequest) {
        guard selectedAddress == request.device.address,
              let cap = capabilities.first(where: { $0.codec == request.configuration.codec && $0.playable }) else {
            hiResContinuation = nil; hiResDeadline = nil
            recoveryFailed("HiRes 已切换，但原高清编码当前不可用；未自动重试。"); return
        }
        do {
            let config = try cap.supportedContinuation(from: request.configuration)
            selectedCapability = cap.id; transportChoice = config.codec.rawValue
            rate = config.sampleRate.rawValue; quality = config.quality; fixedBitrate = config.fixedBitrateKbps ?? 0
            if playbackPreferences[config.codec.rawValue] != nil { playbackPreferences[config.codec.rawValue] = config }
            let adjusted = config.sampleRate != request.configuration.sampleRate || config.quality != request.configuration.quality || config.fixedBitrateKbps != request.configuration.fixedBitrateKbps
            let message = adjusted ? "HiRes 已改变可用范围，将恢复 \(config.sampleRate.rawValue) Hz / \(config.fixedBitrateKbps.map { String($0) + " kbps" } ?? "自适应码率")；原先超出范围的参数未沿用。" : "HiRes 已确认并刷新能力，等待连接稳定后按原参数恢复高清连接。"
            scheduleRecovery(StartRequest(device: request.device, configuration: config, gain: request.gain, linkHardwareVolume: request.linkHardwareVolume), delay: 2, message: message)
        } catch {
            hiResContinuation = nil; hiResDeadline = nil
            recoveryFailed("HiRes 已切换，但恢复参数无效：" + error.localizedDescription)
        }
    }
    private func cancelRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil
        if recoveryID != nil {
            recoveryID = nil; busy = false; connectionPhase = "idle"
        }
        hiResDeadline = nil; hiResRetries = 0
    }
    private func recoveryFailed(_ message: String) {
        busy = false; active = false; transportChoice = "system"
        connectionPhase = "failed"; status = "查询或播放失败"; error = message
    }
    private func scheduleRecovery(_ request: StartRequest, delay: TimeInterval, message: String) {
        guard selectedAddress == request.device.address else { hiResContinuation = nil; return }
        if let deadline = hiResDeadline, now().addingTimeInterval(delay) >= deadline {
            hiResContinuation = nil; hiResDeadline = nil; transportChoice = "system"
            settingsMessage = "HiRes 已切换，但等待恢复已超时；可调整参数后手动启用。"
            recoveryFailed(settingsMessage)
            return
        }
        let id = UUID(); recoveryID = id
        error = nil // A recovered attempt is diagnostic history, not a final failure.
        busy = true; active = false; connectionPhase = "waitingForDevice"
        status = "等待耳机连接稳定"; settingsMessage = message + " 可选择系统蓝牙取消。"
        let action: @MainActor () -> Void = { [weak self] in
            guard let self, self.recoveryID == id, self.selectedAddress == request.device.address else { return }
            self.recoveryID = nil; self.recoveryTask = nil; self.busy = false
            if let deadline = self.hiResDeadline, self.now() >= deadline {
                self.hiResContinuation = nil; self.hiResDeadline = nil
                self.transportChoice = "system"; self.connectionPhase = "idle"
                self.settingsMessage = "等待耳机恢复超时，未继续自动连接；请手动启用。"
                self.recoveryFailed(self.settingsMessage)
                return
            }
            var latest = request; latest.gain = self.gain
            self.begin(latest)
            self.settingsMessage = message
        }
        if let recoveryScheduler { recoveryScheduler(delay, action) }
        else {
            recoveryTask = Task {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled else { return }; action()
            }
        }
    }
    private func recoverAfterFailure(_ event: WireMessage, request: StartRequest) -> Bool {
        guard selectedAddress == request.device.address else { hiResContinuation = nil; return false }
        if event.playbackFailure == .mediaMTU, !request.configuration.probeOnly,
           let cap = capabilities.first(where: { $0.codec == request.configuration.codec && $0.playable }),
           var defaults = try? cap.configuration() {
            defaults.buffering = request.configuration.buffering
            // Replace the rejected preference before attempting recovery. Even
            // unsafe cleanup or a failed fallback must leave editable safe values.
            selectedCapability = cap.id; rate = defaults.sampleRate.rawValue
            quality = defaults.quality; fixedBitrate = 0
            playbackPreferences[defaults.codec.rawValue] = defaults; savePreferences()
            resettableCodec = defaults.codec
            let message = "媒体 MTU 不足，参数已恢复为 \(rate) Hz／自适应码率。"
            settingsMessage = message
            hiResContinuation = nil; hiResDeadline = nil
            if automaticRecoveryAllowed, event.restartSafe == true, !request.defaultFallback, defaults.requiresReconnect(from: request.configuration) {
                transportChoice = defaults.codec.rawValue
                scheduleRecovery(StartRequest(device: request.device, configuration: defaults, gain: gain,
                                              linkHardwareVolume: request.linkHardwareVolume, defaultFallback: true),
                                 delay: 2, message: message + " 将用默认参数重连一次。")
                return true
            }
            settingsMessage += " 未继续自动重连；请检查连接后手动启用，参数仍可修改。"
        }
        if automaticRecoveryAllowed, event.restartSafe == true, event.playbackFailure == .capabilitiesChanged,
           !request.capabilityFallback, !request.configuration.isForced,
           let cap = event.capabilities?.first(where: { $0.codec == request.configuration.codec && $0.playable }),
           let updated = try? cap.supportedContinuation(from: request.configuration) {
            capabilities.removeAll { $0.codec == cap.codec }; capabilities.append(cap)
            selectedCapability = cap.id; detectedAt = now(); probeComplete = true
            rate = updated.sampleRate.rawValue; quality = updated.quality; fixedBitrate = updated.fixedBitrateKbps ?? 0
            playbackPreferences[updated.codec.rawValue] = updated; savePreferences()
            var next = StartRequest(device: request.device, configuration: updated, gain: gain, linkHardwareVolume: request.linkHardwareVolume)
            next.capabilityFallback = true; next.connectionRetries = request.connectionRetries
            scheduleRecovery(next, delay: 3, message: "连接时检测到耳机能力已改变，已刷新并按仍受支持的参数重连一次，无需手动重新检测。")
            return true
        }
        let transient = event.playbackFailure == .signalingUnavailable || event.playbackFailure == .deviceNotReady || event.playbackFailure == .audioHostUnavailable
        let attempts = hiResContinuation != nil ? hiResRetries : request.connectionRetries
        if automaticRecoveryAllowed, transient, event.restartSafe == true, attempts < 2 {
            let delay: TimeInterval = attempts == 0 ? 4 : 7
            guard hiResDeadline.map({ now().addingTimeInterval(delay) < $0 }) ?? true else { return false }
            var next = request; next.connectionRetries += 1
            if hiResContinuation != nil { hiResRetries += 1 }
            let reason = event.playbackFailure == .audioHostUnavailable ? "系统音频配置暂未就绪" : "耳机信令暂未就绪"
            scheduleRecovery(next, delay: delay, message: "\(reason)，资源已清理；等待后第 \(attempts + 1) 次重试（最多 2 次）。")
            return true
        }
        return false
    }
    func deviceChanged() {
        guard canEditSettings, !previewMode else { return }
        send(WireMessage("headsetUnwatch"))
        headsetWatchID = nil; headsetRequestID = nil; headsetWriteID = nil; headsetWriteSetting = nil; pendingHeadsetPage = nil; loadedHeadsetPages.removeAll(); headsetReadIncludesHiRes = false; headsetRecoveryID = nil; headsetBusy = false; retiredGenerations.removeAll()
        headset = preferences.data(forKey: "headset." + selectedAddress).flatMap { try? JSONDecoder().decode(HeadsetSnapshot.self, from: $0) }
        headset?.markStale(); wearAutomation = false; mediaMessage = "Mac 摘戴联动默认关闭"
        nativeCodecID = nil
        cancelRecovery()
        oppoRefreshMessage = nil; hiResContinuation = nil
        resetOppo(message: "尚未查询")
        playbackPreferences = [:]; resettableCodec = nil
        capabilities = []; selectedCapability = ""; probeComplete = false; codecProbeState = .init(.notProbed); rate = 0; error = nil
        if !busy { status = "未检测" }
        catchupLimitTenths = 50; prefillMilliseconds = 250
        fixedBitrate = 0; detectedAt = nil; quality = .adaptive
        if !busy { metrics = [:]; format = nil; negotiated = nil; history = []; connectionPhase = "idle" }
        linkHardwareVolume = false; volumeLinkState = "off"; volumeLinkMessage = ""; audioState = nil
        if !busy { gain = rememberedGain(address: selectedAddress, linked: false) }
        if let data = preferences.data(forKey: "device." + selectedAddress), let saved = try? JSONDecoder().decode(SavedDevice.self, from: data) {
            playbackPreferences = saved.playbackPreferences ?? [:]
            capabilities = saved.capabilities; selectedCapability = saved.selectedCapability; rate = saved.rate; quality = saved.quality; fixedBitrate = saved.fixedBitrate; detectedAt = saved.detectedAt
            if let buffering = saved.buffering, (try? buffering.validate()) != nil {
                catchupLimitTenths = buffering.catchupLimitTenths; prefillMilliseconds = buffering.prefillMilliseconds
            }
            linkHardwareVolume = false
            if saved.linkHardwareVolume == true && !busy {
                volumeLinkMessage = HardwareVolumeSupport.migratedNotice
            }
            codecProbeState = saved.codecProbeState ?? .init(saved.capabilities.isEmpty ? .notProbed : .complete, date: saved.detectedAt)
            probeComplete = codecProbeState.status == .complete || codecProbeState.status == .failed && !capabilities.isEmpty
            if !busy { status = codecProbeState.status == .failed ? "编码检测有失败 · 可重试" : probeComplete ? "已连接" : "未检测" }
        }
        if active && !probeComplete { settingsMessage = "所选耳机尚未检测；检测能力后可启用。当前耳机继续播放。" }
        // Loading old drafts is not a new explicit parameter edit.
        normalizeRestrictedDraft()
        savePreferences()
        refreshAudioState()
    }
    private func cancelPendingSettings() {
        pendingMIDIStart = nil; pendingStart = nil; pendingStopID = nil; applyingBuffering = false; bufferingRequestID = nil; bufferingInFlight = nil
    }
    var highBitrateWarningEnabled: Bool { !preferences.bool(forKey: HighBitrateWarning.suppressionKey) }
    func requestApplySettings(confirm: @MainActor () -> (apply: Bool, suppress: Bool) = HighBitrateWarning.confirm) {
        guard canApplySettings, let device, let config = configuration, !previewMode else { return }
        if config.codec == .lhdcV5 && config.quality != .adaptive &&
            [900, 1000].contains(config.fixedBitrateKbps ?? 0) && highBitrateWarningEnabled {
            let decision = confirm()
            // A modal alert continues processing events; never apply a different draft/device.
            guard decision.apply, canApplySettings, self.device?.address == device.address,
                  configuration == config else { return }
            if decision.suppress { preferences.set(true, forKey: HighBitrateWarning.suppressionKey) }
        }
        applySettings()
    }
    func applySettings() {
        guard canApplySettings, let device, let config = configuration, !previewMode else { return }
        do {
            try config.validate()
            playbackPreferences[config.codec.rawValue] = config
            savePreferences()
            codecSelectionManaged = true; transportChoice = config.codec.rawValue
            let nextGain = active && !selectedIsPlaying ? rememberedGain(address: device.address, linked: linkHardwareVolume) : gain
            let request = StartRequest(device: device, configuration: config, gain: nextGain, linkHardwareVolume: linkHardwareVolume)
            if active { replaceSession(with: request) } else { begin(request) }
        } catch { self.error = error.localizedDescription }
    }
    private func applyBuffering() {
        guard active, selectedIsPlaying, !applyingBuffering, let negotiated, !previewMode,
              bufferingSettings != negotiated.bufferingSettings else { return }
        let settings = bufferingSettings
        guard (try? settings.validate()) != nil else { return }
        let id = UUID(); bufferingRequestID = id; applyingBuffering = true; bufferingInFlight = settings
        settingsMessage = "正在应用缓冲设置"
        var request = WireMessage("buffering", requestID: id, sessionID: sessionID)
        request.buffering = settings; send(request)
    }
    private func applyPendingMIDI() {
        guard !applyingBuffering, let requested = pendingMIDIStart else { return }
        pendingMIDIStart = nil
        guard active, requested.device.address == requestDevice else { return }
        var config = requested.configuration
        if selectedIsPlaying { config.buffering = bufferingSettings }
        replaceSession(with: StartRequest(device: requested.device, configuration: config, gain: gain, linkHardwareVolume: requested.linkHardwareVolume))
    }
    private func replaceSession(with request: StartRequest) {
        guard active, let sessionID else { return }
        pendingStart = request; pendingStopID = sessionID
        active = false; connectionPhase = "stopping"; settingsMessage = "正在应用设置：等待当前音频输出释放后重新连接。"
        var stop = WireMessage("stop", sessionID: sessionID)
        if hiResContinuation == nil, !request.configuration.probeOnly,
           request.device.address == requestDevice, request.configuration.codec == negotiated?.codec {
            stop.stopIntent = .reconfigure; stop.device = request.device
            stop.configuration = request.configuration; stop.linkHardwareVolume = request.linkHardwareVolume
        }
        send(stop)
    }
    func retryDeviceDetection() {
        guard let device, canEditSettings, !libraryActionBusy, !previewMode else { return }
        if active { probe(); return }
        guard canAddDevice else { return }
        addingDevice = device; addingIdentity = nil; addingCancelled = false
        libraryActionBusy = true; libraryMessage = "正在重新确认所选设备…"
        let id = UUID(); libraryRequestID = id
        send(WireMessage("environment", requestID: id)); startLibraryTimeout(id)
    }
    func probe() {
        guard let device, canEditSettings, !previewMode else { return }
        if active {
            var config = PlaybackConfiguration(); config.probeOnly = true
            replaceSession(with: StartRequest(device: device, configuration: config, gain: 0))
        } else { begin(probe: true) }
    }
    func start() { begin(probe: false) }
    private func begin(probe: Bool) {
        guard !discoveryControlBusy, let device, !busy, !oppoBusy, !previewMode else { return }
        guard var config = probe ? PlaybackConfiguration() : configuration else { error = "请先检测并选择可用编码"; return }
        config.probeOnly = probe
        begin(StartRequest(device: device, configuration: config, gain: probe ? 0 : gain, linkHardwareVolume: linkHardwareVolume && !probe))
    }
    private func begin(_ request: StartRequest) {
        guard !discoveryControlBusy, !busy, !oppoBusy, !previewMode else { return }
        var request = request
        if !request.configuration.probeOnly && !softwareVolumeEnabled { request.gain = 1 }
        do {
            let config = request.configuration
            try config.validate()
            resetOppo(message: oppoRefreshMessage.map { $0 + " 正在更新音频能力。" } ?? "进入正在发送状态后自动检测 HiRes")
            let id = UUID(); sessionID = id; requestDevice = request.device.address; error = nil; busy = true; active = false
            currentStart = request
            automaticRecoveryAllowed = true
            requestIsProbe = config.probeOnly; requestVolumeLinked = request.linkHardwareVolume
            gain = config.probeOnly ? rememberedGain(address: request.device.address, linked: request.linkHardwareVolume) : request.gain
            metrics = [:]; format = nil; negotiated = nil; history = []; settingsMessage = ""; savePreferences()
            if config.probeOnly { probeComplete = false; codecProbeState = .init(.notProbed); capabilities = [] }
            var command = WireMessage(config.probeOnly ? "probe" : "start", sessionID: id)
            command.device = request.device; command.configuration = config; command.gain = config.probeOnly ? 0 : gain
            command.linkHardwareVolume = request.linkHardwareVolume && !config.probeOnly; send(command)
        } catch { self.error = error.localizedDescription }
    }
    func setGain(_ value: Double) {
        guard softwareVolumeEnabled else { return }
        applyGain(value)
    }
    private func applyGain(_ value: Double) {
        guard value.isFinite, (0...1).contains(value) else { return }
        gain = value
        guard !previewMode else { return }
        rememberGain(value, address: busy ? requestDevice ?? selectedAddress : selectedAddress, linked: busy ? requestVolumeLinked : linkHardwareVolume)
        if let resume = hiResContinuation {
            hiResContinuation = StartRequest(device: resume.device, configuration: resume.configuration, gain: value, linkHardwareVolume: resume.linkHardwareVolume)
        }
        if let next = pendingStart, next.device.address == requestDevice, !next.configuration.probeOnly {
            pendingStart = StartRequest(device: next.device, configuration: next.configuration, gain: value, linkHardwareVolume: next.linkHardwareVolume)
        }
        if busy && !requestIsProbe && connectionPhase != "stopping", let sessionID {
            var command = WireMessage("gain", sessionID: sessionID); command.gain = value; send(command)
        }
    }
    func stop() {
        if addingDevice != nil { addingCancelled = true }
        pendingHiResQuerySessionID = nil
        automaticRecoveryAllowed = false
        cancelRecovery()
        hiResContinuation = nil; hiResWriteSessionID = nil; hiResWriteControlGeneration = nil; hiResVerified = false; oppoRefreshMessage = nil
        pendingCodecActivation = nil; transportChoice = "system"; nativeCodecID = nil
        if oppoBusy { cancelOppo() }
        cancelPendingSettings()
        if busy { active = false; connectionPhase = "stopping" }
        send(WireMessage("stop", sessionID: sessionID))
    }
    func quit() {
        discoveryRestoreWatch = false
        endDeviceDiscovery()
        finishLibraryAction("")
        automaticRecoveryAllowed = false
        cancelRecovery()
        hiResContinuation = nil
        pendingCodecActivation = nil
        cancelOppo()
        cancelPendingSettings()
        if previewMode { busy = false; active = false; return }
        if process?.isRunning == true { send(WireMessage("quit")); try? input?.close() }
    }
    func queryOppo(afterAudioStart: Bool = false) {
        guard canQueryOppo, let device else { return }
        cancelPendingSettings()
        hiResRefreshedAt = nil
        let id = UUID(); oppoRequestID = id; oppoBusy = true; oppoReport = nil
        oppoQueryInProgress = true; pendingHiResQuerySessionID = nil
        headsetResumeInProgress = afterAudioStart
        startHiResReadTimeout(limit: afterAudioStart ? 80 : 40)
        oppoMessage = active ? "正在检测 HiRes 状态" : "正在读取耳机控制状态"
        var request = WireMessage("oppoQuery", requestID: id, sessionID: active ? sessionID : nil)
        if afterAudioStart {
            // The engine now restores the compact HiRes + quick-control baseline
            // as one bounded read. Observe it even while the menu is closed.
            request.details = ["source": "audio-resume"]
            headsetWatchID = id; headsetRequestID = nil; headsetBusy = false
            headsetReadIncludesHiRes = false
        }
        request.device = device; send(request)
    }
    private func queryPendingHiRes() {
        guard let pending = pendingHiResQuerySessionID else { return }
        guard pending == sessionID, active, selectedIsPlaying, connectionPhase == "active" else {
            pendingHiResQuerySessionID = nil; return
        }
        guard canQueryOppo, pendingStart == nil, hiResContinuation == nil else { return }
        queryOppo(afterAudioStart: true)
    }
    private func startHiResReadTimeout(limit: TimeInterval = 40) {
        guard oppoReadTimeoutID == nil else { return }
        let token = UUID(); oppoReadTimeoutID = token
        let expire: @MainActor () -> Void = { [weak self] in
            guard let self, self.oppoReadTimeoutID == token, self.isDetectingHiRes else { return }
            let switching = self.pendingCodecActivation != nil
            self.pendingCodecActivation = nil
            if let id = self.oppoRequestID { self.send(WireMessage("oppoCancel", requestID: id)) }
            self.resetOppo(message: "耳机状态检测超过 \(Int(limit)) 秒，已取消本次查询；可点击耳机旁的刷新按钮。")
            if switching {
                self.transportChoice = self.active ? self.negotiated?.codec.rawValue ?? "system" : "system"
                self.initialSettingsSource = "控制查询未及时结束，本次编码切换已取消。"
            }
        }
        // Ordinary read: 20 s queue + 18 s read. Audio resume: queue + two
        // 18 s attempts + 15 s close barrier + 2 s backoff, with a small margin.
        if let controlScheduler { controlScheduler(limit, expire) }
        else {
            oppoReadTimeoutTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000)) } catch { return }
                expire()
            }
        }
    }
    private func finishHiResReadTimeout() {
        oppoReadTimeoutID = nil; oppoReadTimeoutTask?.cancel(); oppoReadTimeoutTask = nil
    }
    func setOppoHiRes(_ enabled: Bool) {
        guard canSetOppoHiRes, let device, let sessionID else { return }
        cancelPendingSettings()
        let id = UUID(); oppoRequestID = id; oppoBusy = true
        guard let negotiated else { oppoBusy = false; oppoRequestID = nil; return }
        hiResContinuation = StartRequest(device: device, configuration: negotiated, gain: gain, linkHardwareVolume: requestVolumeLinked)
        hiResWriteSessionID = sessionID; hiResWriteControlGeneration = headset?.generation; hiResVerified = false
        hiResDeadline = now().addingTimeInterval(90); hiResRetries = 0
        hiResRefreshedAt = nil
        oppoMessage = "正在" + (enabled ? "开启" : "关闭") + " HiRes，等待耳机确认"
        var request = WireMessage("oppoSetHiRes", requestID: id, sessionID: sessionID)
        request.device = device; request.hiResEnabled = enabled
        request.controlGeneration = headset?.generation; request.details = ["waitForRead": "true"]; send(request)
    }
    func cancelOppo() {
        hiResContinuation = nil; hiResWriteSessionID = nil; hiResWriteControlGeneration = nil; hiResVerified = false
        if let id = oppoRequestID { send(WireMessage("oppoCancel", requestID: id)) }
        resetOppo(message: "查询已取消")
    }
    private func resetOppo(message: String) {
        hiResRefreshedAt = nil
        headset?.markStale(.feature(.hiRes), reason: message)
        finishHiResReadTimeout()
        oppoRequestID = nil; oppoBusy = false; oppoReport = nil; oppoControlGeneration = nil; oppoMessage = message
        oppoQueryInProgress = false; pendingHiResQuerySessionID = nil
        headsetResumeInProgress = false
    }
    var canControlHeadset: Bool { !discoveryControlBusy && supportsHeadsetControl && !libraryActionBusy && headset?.profile != nil && headsetRecoveryID == nil && !audioMaintenance && !localDataBusy && !previewMode && headsetWriteID == nil && (!oppoBusy || oppoQueryInProgress) && (!busy || active) && headset?.connected == true }
    // Re-establish notifications after a compact HiRes read without immediately
    // requesting firmware, EQ and every other setting on the active audio link.
    private func listenHeadset() {
        guard !discoveryControlBusy, !previewMode, !libraryActionBusy, !localDataBusy, !headsetBusy, !headsetWriting, !oppoBusy, let device, device.connected else { return }
        let id = UUID(); headsetWatchID = id; headsetRequestID = id; headsetBusy = true
        var request = WireMessage("headsetListen", requestID: id, sessionID: active ? sessionID : nil)
        request.device = device; send(request)
    }
    func watchHeadset() {
        guard !audioMaintenance else { return }
        wantsHeadset = true
        guard !discoveryControlBusy, !previewMode, !libraryActionBusy, !localDataBusy, !headsetBusy, !headsetWriting, !oppoBusy, !busy || active, let device, device.connected, supportsHeadsetControl else { return }
        if headsetWatchID != nil, headset?.connected == true { return }
        let id = UUID(); headsetWatchID = id; headsetRequestID = id; headsetBusy = true
        headsetMessage = "正在读取耳机状态"
        var request = WireMessage("headsetWatch", requestID: id, sessionID: active ? sessionID : nil)
        request.device = device; send(request)
    }
    /// Opening a page reads only its missing fields once per control generation.
    /// Reopening a menu/window never refreshes already observed settings.
    func loadHeadsetPage(_ page: String) {
        if pendingHeadsetPage?.1 != true { pendingHeadsetPage = (.page(page), false) }
        watchHeadset(); drainHeadsetPage()
    }
    var canRefreshAllHeadset: Bool {
        !discoveryControlBusy && !previewMode && !audioMaintenance && !localDataBusy && headsetRecoveryID == nil &&
        (!busy || active) && device?.connected == true && supportsHeadsetControl
    }
    func refreshAllHeadset() {
        guard canRefreshAllHeadset, let device else { return }
        headsetRefreshPresentation = headset
        // Supersede App-side IDs, but keep controls locked until the engine has
        // drained the old work. Old terminals cannot unlock this new transaction.
        hiResContinuation = nil; hiResWriteSessionID = nil; hiResWriteControlGeneration = nil
        resetOppo(message: "")
        pendingCodecActivation = nil
        pendingHeadsetPage = nil; loadedHeadsetPages.removeAll()
        headsetWriteID = nil; headsetWriteSetting = nil; headsetRequestGeneration = nil
        lastHeadsetResult = nil; wantsHeadset = true
        headset?.markStale()
        let id = UUID(); headsetRecoveryID = id; headsetWatchID = id; headsetRequestID = id
        headsetBusy = true; headsetReadIncludesHiRes = true
        headsetMessage = "正在重新连接控制通道并全量刷新耳机状态"
        var request = WireMessage("headsetRecover", requestID: id, sessionID: active ? sessionID : nil)
        request.device = device; send(request)
        let expire: @MainActor () -> Void = { [weak self] in
            guard let self, self.headsetRecoveryID == id else { return }
            self.send(WireMessage("headsetCancel", requestID: id))
            self.headsetRecoveryID = nil; self.headsetRequestID = nil; self.headsetWatchID = nil
            self.headsetBusy = false; self.headsetReadIncludesHiRes = false
            self.headset?.markStale()
            self.headsetMessage = "全量刷新超时；未重发任何设置，可再次点击耳机旁的刷新按钮。"
        }
        // Only explicit recovery gets this fallback; no background retry loop.
        if let controlScheduler { controlScheduler(45, expire) }
        else { Task { @MainActor in try? await Task.sleep(nanoseconds: 45_000_000_000); expire() } }
    }
    func refreshHeadset(page: String = "设备状态") {
        pendingHeadsetPage = (.page(page), true)
        watchHeadset(); drainHeadsetPage()
    }
    private func drainHeadsetPage() {
        guard !discoveryControlBusy, let (scope, force) = pendingHeadsetPage, !previewMode, !localDataBusy, !audioMaintenance,
              !headsetBusy, headsetWriteID == nil, !oppoBusy, !busy || active,
              let device, device.connected, supportsHeadsetControl,
              headsetWatchID != nil, let snapshot = headset, snapshot.connected else { return }
        let key = snapshot.generation.uuidString + ":" + scope.rawValue
        pendingHeadsetPage = nil
        if !force && loadedHeadsetPages.contains(key) { return }
        if loadedHeadsetPages.count > 128 { loadedHeadsetPages.removeAll() }
        loadedHeadsetPages.insert(key)
        let id = UUID(); headsetRequestID = id; headsetBusy = true; headsetReadIncludesHiRes = force
        headsetMessage = "正在读取当前页面的耳机状态"
        var request = WireMessage("headsetRefresh", requestID: id, sessionID: active ? sessionID : nil)
        request.device = device
        request.details = ["refreshScope": scope.rawValue, "missingOnly": force ? "false" : "true",
                           "includeHiRes": force ? "true" : "false", "source": force ? "manual" : "page"]
        send(request)
    }
    @discardableResult func setHeadset(_ setting: HeadsetSetting) -> UUID? {
        guard canControlHeadset, let device, let snapshot = headset else { return nil }
        if let reason = snapshot.restriction(for: setting) { headsetMessage = reason; return nil }
        let id = UUID(); headsetWriteID = id; headsetRequestGeneration = snapshot.generation; headsetWriteSetting = setting
        lastHeadsetResult = nil
        headsetMessage = "正在设置\(setting.title)，等待读回确认"
        var request = WireMessage("headsetSet", requestID: id, sessionID: active ? sessionID : nil)
        request.device = device; request.controlGeneration = snapshot.generation; request.headsetSetting = setting
        request.details = ["waitForRead": "true"]; send(request)
        return id
    }
    func cancelHeadset() {
        guard let id = headsetWriteID ?? headsetRequestID else { return }
        send(WireMessage("headsetCancel", requestID: id))
    }
    func setWearAutomation(_ enabled: Bool) {
        guard let device, !previewMode else { return }
        var request = WireMessage("headsetWear", requestID: headsetWatchID); request.device = device
        request.wearAutomation = enabled; send(request)
    }
    private func acceptHeadset(_ snapshot: HeadsetSnapshot) {
        guard snapshot.address == selectedAddress, !retiredGenerations.contains(snapshot.generation) else { return }
        if let old = headset, old.generation != snapshot.generation {
            retiredGenerations.insert(old.generation)
            if retiredGenerations.count > 256 { retiredGenerations = [old.generation] }
        }
        headset = snapshot
        // Legacy reports are a projection, not a second HiRes authority. A fresh
        // notification/new-generation baseline immediately restores the switch.
        oppoReport = snapshot.connected ? snapshot.controlReport : nil
        oppoControlGeneration = snapshot.connected ? snapshot.generation : nil
        if snapshot.controlReport.hiRes != nil {
            if !oppoBusy { oppoMessage = "" }
        } else {
            hiResRefreshedAt = nil
            if !oppoBusy { oppoMessage = snapshot.connected ? "HiRes 状态未确认，可在耳机设置中刷新" : "耳机控制未连接" }
        }
        normalizeRestrictedDraft()
        if !previewMode, let data = try? JSONEncoder().encode(snapshot) { preferences.set(data, forKey: "headset." + selectedAddress) }
        if !busy { nativeCodecID = snapshot.currentCodec }
    }
    private func normalizeRestrictedDraft() {
        guard !allowsUnreportedParameters else { return }
        if rate != 0 && !availableRates.contains(rate) { rate = 0 }
        if fixedBitrate != 0 && !bitrates.contains(fixedBitrate) { fixedBitrate = 0; quality = .adaptive }
        // Do not call parametersChanged: a status notification is not permission
        // to stop or reconfigure an active stream. Saved targets are reconciled at start.
    }
    private func receiveHeadset(_ event: WireMessage) {
        guard event.device?.address == selectedAddress else { return }
        if event.kind == "headsetConnection" {
            guard event.sessionID == nil || event.sessionID == sessionID,
                  let snapshot = event.headset, event.controlGeneration == snapshot.generation else { return }
            acceptHeadset(snapshot)
        } else if event.kind == "headsetSnapshot" {
            guard event.requestID == headsetWatchID, headsetWatchID != nil,
                  event.sessionID == nil || event.sessionID == sessionID else { return }
            if let snapshot = event.headset { acceptHeadset(snapshot) }
        } else if event.kind == "headsetResult" {
            guard let id = event.requestID,
                  id == headsetRequestID || id == headsetWriteID || id == headsetWatchID else { return }
            if id == headsetRecoveryID {
                headsetRecoveryID = nil
                if event.headset == nil { headset?.markStale() }
            }
            let wasWrite = id == headsetWriteID
            let writeSetting = headsetWriteSetting
            let wasRead = id == headsetRequestID
            if wasRead { headsetBusy = false; headsetRequestID = nil; headsetReadIncludesHiRes = false }
            if wasWrite {
                headsetWriteID = nil; headsetWriteSetting = nil
                let expected = headsetRequestGeneration; headsetRequestGeneration = nil
                if let actual = event.controlGeneration, let expected, actual != expected {
                    headsetMessage = "连接已变化，请刷新实际状态"; return
                }
            }
            if let snapshot = event.headset { acceptHeadset(snapshot) }
            if wasWrite || headsetWriteID == nil {
                if wasWrite {
                    lastHeadsetResult = event.headsetResult ?? writeSetting.map {
                        HeadsetOperationResult(setting: $0, message: event.message ?? "未取得设置结果，未重试")
                    }
                }
                headsetMessage = event.message ?? "未取得结果"
            }
        } else if event.kind == "headsetMedia", event.requestID == headsetWatchID {
            wearAutomation = event.wearAutomation ?? false; mediaMessage = event.mediaStatus ?? "状态不可用"
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SonoFerry-diagnostics.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Session logs can contain addresses, UUIDs and local paths. Export an explicit allow-list only.
        let salt = UUID().uuidString
        let token = SHA256.hash(data: Data((salt + selectedAddress).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        struct Report: Encodable { let schema = 1; let os: String; let deviceToken: String; let capabilities: [CodecCapabilities]; let configuration: PlaybackConfiguration?; let hardwarePlaybackVerified = false; let statistics: [[String: Double]] }
        let stats = history.compactMap(\.metrics).filter { !$0.isEmpty }
        let report = Report(os: ProcessInfo.processInfo.operatingSystemVersionString, deviceToken: token, capabilities: capabilities,
            configuration: negotiated, statistics: stats)
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(report).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}

