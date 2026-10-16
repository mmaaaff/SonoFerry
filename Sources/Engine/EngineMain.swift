import Foundation
import AppKit
import Darwin
import SonoFerryCore

@MainActor
final class SessionController {
    private var output: LDACNativeOutput?
    private var session: LDACNativeSession?
    private var currentID: UUID?
    private var starting: Task<Void, Never>?
    private var capabilities: [CodecCapabilities] = []
    private var quitting = false
    private var signals: [DispatchSourceSignal] = []
    private var parentWatcher: DispatchSourceProcess?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sleeping = false
    private let discovery = DeviceDiscovery()
    private let pairedDevices: @MainActor () -> [BluetoothDevice]
    private let readRoute: @MainActor () -> OutputRoute
    private let selectNativeOutput: @MainActor (String, String?) throws -> Void
    private var configuration = PlaybackConfiguration()
    private var gain = 0.0
    private var targetAddress = ""
    private var probeSucceeded = false
    private var queryDetails: [String: String] = [:]
    private var lastError: String?
    private var playbackFailure: PlaybackFailureCode?
    private var restartSafe = false
    private var reconfigureStopID: UUID?
    private var stopStartedAt: TimeInterval?
    private var sessionActive = false
    private var bufferingRequestID: UUID?
    private var headsetService: HeadsetControlService?
    private var controlTask: Task<Void, Never>?
    private var controlRequestID: UUID?
    private var controlIsRead = false
    private var queuedControlRead: WireMessage?
    private var queuedControlTimer: Timer?
    private let controlQueueTimeout: TimeInterval
    private let emitHandler: ((WireMessage) -> Void)?
    private let makeControlService: @MainActor (BluetoothDevice) -> HeadsetControlService
    private let controlLog: ControlTrace?
    private var watchRequestID: UUID?
    private var watchedDevice: BluetoothDevice?
    private var controlRecoveryTask: Task<Void, Never>?
    private var controlRecoveryID: UUID?
    private var controlTransition = false
    private var controlTransitionID: UUID?
    private var pendingControlAudioID: UUID?
    private var refreshTimer: Timer?
    private var environmentTimer: Timer?
    private let environmentGeneration = UUID()
    private var environmentRevision: UInt64 = 0
    private var lastEnvironment: DeviceEnvironment?
    private var lastBluetoothAuthorization: String?
    private var selectingOutput = false
    private let media = MacMediaController()

    init(observeSystem: Bool = true, controlQueueTimeout: TimeInterval = 20,
         emitHandler: ((WireMessage) -> Void)? = nil,
         pairedDevices: @escaping @MainActor () -> [BluetoothDevice] = { DeviceDiscovery.paired() },
         readRoute: @escaping @MainActor () -> OutputRoute = { SystemAudio.currentRoute() },
         selectNativeOutput: @escaping @MainActor (String, String?) throws -> Void = { try SystemAudio.selectNative(address: $0, expectedUID: $1) },
         makeControlService: @escaping @MainActor (BluetoothDevice) -> HeadsetControlService = { HeadsetControlService(address: $0.address) }) {
        self.controlQueueTimeout = controlQueueTimeout; self.emitHandler = emitHandler
        self.pairedDevices = pairedDevices; self.readRoute = readRoute; self.selectNativeOutput = selectNativeOutput
        self.makeControlService = makeControlService; self.controlLog = observeSystem ? ControlTrace() : nil
        guard observeSystem else { return }
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }; source.resume(); signals.append(source)
        }
        if getppid() > 1 {
            let source = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }; source.resume(); parentWatcher = source
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                self?.emit(WireMessage("systemSleep"))
                self?.stop(reason: "系统即将睡眠，会话已停止；唤醒后请手动开始。")
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false }
        }
        media.changed = { [weak self] text in
            guard let self else { return }; var reply = WireMessage("headsetMedia", requestID: self.watchRequestID)
            reply.device = self.watchedDevice; reply.mediaStatus = text; self.emit(reply)
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.controlTask == nil, !self.controlTransition,
                      self.headsetService?.snapshot.connected == true else { return }
                self.refreshWatched()
            }
        }
        discovery.stateChanged = { [weak self] in self?.sendDevices() }
    }
    func emit(_ message: WireMessage) {
        if message.kind.hasPrefix("oppo") || message.kind == "headsetResult" {
            controlLog?.record(message.kind, request: message, detail: message.message ?? "")
        }
        if let emitHandler { emitHandler(message); return }
        guard let data = try? JSONEncoder().encode(message), data.count <= 65536 else { return }
        do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) } catch { quit() }
    }
    func event(_ kind: String, _ message: String? = nil) {
        var result = WireMessage(kind, sessionID: currentID); result.message = message; emit(result)
    }
    func sendDevices(_ request: UUID? = nil) {
        var result = WireMessage("devices", requestID: request); result.devices = DeviceDiscovery.paired(); result.details = DeviceDiscovery.diagnostics(); emit(result)
    }
    private func environment() -> DeviceEnvironment {
        .init(generation: environmentGeneration, revision: environmentRevision, devices: pairedDevices(),
              route: readRoute(), audioSessionID: currentID ?? pendingControlAudioID,
              transitioning: controlTransition || currentID != nil && !sessionActive)
    }
    private func sendEnvironment(requestID: UUID? = nil, force: Bool = false, diagnostics: Bool = false) {
        guard !sleeping, !quitting else { return }
        // Reuse the passive observer even when permission changes without a device/route change.
        // A separate event updates warnings without entering output selection or control recovery.
        let authorization = DeviceDiscovery.bluetoothAuthorization
        if authorization != lastBluetoothAuthorization {
            lastBluetoothAuthorization = authorization
            var permission = WireMessage("permissionState")
            permission.details = ["bluetoothAuthorization": authorization]
            emit(permission)
        }
        var value = environment()
        // Poll only passive OS state. Never open a Bluetooth channel or query capabilities here.
        var previous = lastEnvironment; previous?.revision = environmentRevision
        guard force || value != previous else { return }
        environmentRevision &+= 1; value.revision = environmentRevision; lastEnvironment = value
        var reply = WireMessage("environment", requestID: requestID); reply.environment = value
        if diagnostics { reply.details = DeviceDiscovery.diagnostics() }
        emit(reply)
    }
    private func selectOutput(_ message: WireMessage) {
        guard let requestID = message.requestID else { return }
        func reject(_ reason: String) {
            var reply = WireMessage("outputSelected", requestID: requestID)
            reply.device = message.device; reply.message = reason; emit(reply)
            sendEnvironment(force: true)
        }
        guard currentID == nil, !controlTransition, controlRecoveryID == nil, !sleeping, !quitting, !selectingOutput else {
            reject("音频会话尚未清理完成，请稍后重试。"); return
        }
        guard let device = message.device, let expected = message.environment,
              expected.generation == environmentGeneration,
              pairedDevices().contains(where: { $0.address == device.address && $0.connected }) else {
            reject("耳机连接已变化，请连接蓝牙后重试。"); return
        }
        guard let uid = expected.route.uid, readRoute().uid == uid else {
            reject("系统输出已变化，请重新选择耳机。"); return
        }
        do { try selectNativeOutput(device.address, uid) }
        catch { reject(error.localizedDescription); return }
        selectingOutput = true
        Task {
            defer { selectingOutput = false }
            // Read back only. A different output winning the race is never overwritten.
            for _ in 0..<10 {
                let route = readRoute()
                if route.bluetoothAddress == device.address || route.uid != expected.route.uid { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            var reply = WireMessage("outputSelected", requestID: requestID); reply.device = device
            if readRoute().bluetoothAddress != device.address { reply.message = "系统未确认所选耳机输出，已保留系统实际选择。" }
            emit(reply); sendEnvironment(force: true)
        }
    }
    func handle(_ message: WireMessage) {
        guard message.version == 1 else { event("error", "不支持的控制协议版本"); return }
        switch message.kind {
        case "devices": sendDevices(message.requestID)
        case "environmentWatch":
            if environmentTimer == nil {
                environmentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sendEnvironment() }
                }
            }
            sendEnvironment(requestID: message.requestID, force: true, diagnostics: true)
        case "environment": sendEnvironment(requestID: message.requestID, force: true, diagnostics: true)
        case "selectOutput": selectOutput(message)
        case "authorize": discovery.requestAccess()
        case "doctor": var reply = WireMessage("doctor", requestID: message.requestID); reply.details = DeviceDiscovery.diagnostics(); emit(reply)
        case "audioState":
            if let address = message.device?.address, BluetoothIdentity.normalizedAddress(address) != nil { sendAudioState(address: address, requestID: message.requestID) }
        case "headsetRecover": recoverHeadset(message)
        case "deviceIdentity", "oppoQuery", "oppoSetHiRes", "headsetWatch", "headsetListen", "headsetRefresh", "headsetSet": queryHeadset(message)
        case "oppoCancel", "headsetCancel":
            if message.requestID == controlRecoveryID { controlRecoveryTask?.cancel() }
            if message.requestID == queuedControlRead?.requestID { cancelQueuedRead("HiRes 查询已取消"); return }
            if message.requestID == controlRequestID || message.requestID == watchRequestID {
                controlTask?.cancel()
                let service = headsetService; Task { try? await service?.suspend() }
            }
        case "headsetUnwatch":
            controlRecoveryTask?.cancel()
            cancelQueuedRead("耳机选择或监听已变化，未执行排队查询")
            watchRequestID = nil; watchedDevice = nil; media.cancel(); media.enabled = false
            controlTask?.cancel(); let service = headsetService; Task { try? await service?.suspend() }
        case "headsetWear":
            guard message.device?.address == watchedDevice?.address else { return }
            media.enabled = message.wearAutomation == true
            var reply = WireMessage("headsetMedia", requestID: watchRequestID)
            reply.device = watchedDevice; reply.mediaStatus = media.status; reply.wearAutomation = false; emit(reply)
        case "probe", "start":
            guard let device = message.device, BluetoothIdentity.normalizedAddress(device.address) != nil else { event("error", "未提供有效设备"); return }
            guard currentID == nil else { event("error", "请先停止当前会话"); return }
            guard !controlTransition, controlRecoveryID == nil, !sleeping, !selectingOutput else {
                var reply = WireMessage("failed", requestID: message.requestID, sessionID: message.sessionID)
                reply.message = sleeping ? "系统正在睡眠，未启动播放" : "正在关闭耳机控制通道"
                emit(reply); return
            }
            var config = message.configuration ?? PlaybackConfiguration(); config.probeOnly = message.kind == "probe"
            // The HD handoff removes the native A2DP Core Audio endpoint. Never use
            // that endpoint as proof of a working volume path, or claim the HAL first.
            if !config.probeOnly && message.linkHardwareVolume == true {
                var reply = WireMessage("failed", requestID: message.requestID, sessionID: message.sessionID)
                reply.message = HardwareVolumeSupport.unavailableReason
                reply.volumeLinkState = "unavailable"
                emit(reply); return
            }
            do { try config.validate() } catch {
                var reply = WireMessage("failed", requestID: message.requestID, sessionID: message.sessionID)
                reply.message = error.localizedDescription; emit(reply); return
            }
            controlTransition = true; controlTask?.cancel(); media.cancel()
            let transition = UUID(), audioID = message.sessionID ?? UUID()
            controlTransitionID = transition; pendingControlAudioID = audioID
            let configuration = config
            Task {
                defer { if controlTransitionID == transition { controlTransition = false; controlTransitionID = nil; pendingControlAudioID = nil } }
                do {
                    try await suspendControl()
                    guard controlTransitionID == transition, !quitting, !sleeping else { return }
                    start(device, configuration: configuration, gain: message.gain ?? 0, id: audioID)
                } catch {
                    guard controlTransitionID == transition else { return }
                    var reply = WireMessage("failed", requestID: message.requestID, sessionID: message.sessionID)
                    reply.message = error.localizedDescription; emit(reply)
                }
            }
        case "stop":
            if message.sessionID == nil || message.sessionID == currentID || message.sessionID == pendingControlAudioID {
                let reconfigure = AudioStopIntent.permits(message, currentID: currentID, address: targetAddress,
                                                          configuration: configuration, active: sessionActive)
                stop(reason: nil, reconfigure: reconfigure)
            }
        case "gain":
            guard message.sessionID == currentID, let value = message.gain, value.isFinite, (0...1).contains(value) else { return }
            applyVolume(value)
        case "buffering":
            guard let currentID, message.sessionID == currentID, let requestID = message.requestID else { return }
            do {
                guard sessionActive, let session, bufferingRequestID == nil, let settings = message.buffering else {
                    throw ProtocolFailure("当前会话尚不可更新缓冲设置")
                }
                try settings.validate()
                bufferingRequestID = requestID
                session.updateBuffering(settings, requestID: requestID)
            } catch {
                var reply = WireMessage("bufferingRejected", requestID: requestID, sessionID: currentID)
                reply.message = error.localizedDescription; emit(reply)
            }
        case "quit": quit()
        default: event("error", "未知控制命令")
        }
    }
    private func service(for device: BluetoothDevice) -> HeadsetControlService {
        if let headsetService, headsetService.snapshot.address == device.address { return headsetService }
        let service = makeControlService(device)
        service.trace = { [weak self] kind, detail in
            self?.controlLog?.record(kind, requestID: self?.controlRequestID, sessionID: self?.currentID, detail: detail)
        }
        var connectionGeneration: UUID?, connectionReady: Bool?, hiResObservation: HeadsetValue<Bool>?
        service.changed = { [weak self, weak service] snapshot in
            guard let self, self.headsetService === service else { return }
            let hiRes = snapshot.features[HeadsetFeature.hiRes.rawValue]
            if connectionGeneration != snapshot.generation || connectionReady != snapshot.connected || hiResObservation != hiRes {
                connectionGeneration = snapshot.generation; connectionReady = snapshot.connected; hiResObservation = hiRes
                var state = WireMessage("headsetConnection", sessionID: self.currentID)
                state.device = device; state.controlGeneration = snapshot.generation; state.headset = snapshot
                self.emit(state)
            }
            guard self.watchedDevice?.address == snapshot.address else { return }
            self.media.wearing = snapshot.wearMask
            if !snapshot.connected { self.media.cancel() }
            var event = WireMessage("headsetSnapshot", requestID: self.watchRequestID, sessionID: self.currentID)
            event.device = self.watchedDevice; event.controlGeneration = snapshot.generation; event.headset = snapshot
            self.emit(event)
        }
        service.gesture = { [weak self] in self?.media.observe($0) }
        headsetService = service; return service
    }
    // Closing RFCOMM alone is insufficient: a canceled refresh may still be
    // waiting for an earlier close/open callback. Drain its task before AVDTP.
    private func suspendControl() async throws {
        cancelQueuedRead("音频连接正在切换，已取消排队查询")
        let recovery = controlRecoveryTask
        recovery?.cancel()
        let task = controlTask
        task?.cancel()
        try await headsetService?.suspend()
        await task?.value
        await recovery?.value
    }
    // Explicit user recovery only. Quiesce the old transaction and transport before
    // reopening; never replay an interrupted setting or restart the audio stream.
    private func recoverHeadset(_ request: WireMessage) {
        guard let id = request.requestID, let device = request.device,
              BluetoothIdentity.normalizedAddress(device.address) != nil else { return }
        var failure = WireMessage("headsetResult", requestID: id, sessionID: request.sessionID)
        failure.device = device
        guard !sleeping, !quitting, !selectingOutput, !controlTransition, controlRecoveryID == nil,
              currentID == nil || (sessionActive && targetAddress == device.address),
              request.sessionID == currentID else {
            failure.message = "连接正在切换或上次清理尚未结束，请稍后再次全量刷新"; emit(failure); return
        }
        controlRecoveryID = id
        cancelQueuedRead("用户全量刷新，已取消排队操作；未重发设置")
        let previous = controlTask
        previous?.cancel()
        controlRecoveryTask = Task {
            defer { if controlRecoveryID == id { controlRecoveryID = nil; controlRecoveryTask = nil } }
            do {
                try await headsetService?.suspend()
                await previous?.value
                try Task.checkCancellation()
                guard request.sessionID == currentID, !sleeping, !quitting, !controlTransition,
                      currentID == nil || sessionActive else { throw ProtocolFailure("音频会话已变化，请稍后全量刷新") }
                controlRecoveryID = nil; controlRecoveryTask = nil
                watchRequestID = id; watchedDevice = device
                var read = request; read.kind = "headsetRefresh"
                read.details = ["refreshScope": "full", "includeHiRes": "true", "source": "manual-recovery"]
                queryHeadset(read)
            } catch {
                // Even a failed shutdown must drain the canceled operation before
                // allowing another attempt. The service retains failed transports.
                await previous?.value
                failure.message = "全量刷新未完成：" + error.localizedDescription; emit(failure)
            }
        }
    }
    private func refreshWatched() {
        guard !sleeping, let device = watchedDevice, let id = watchRequestID else { return }
        var request = WireMessage("headsetRefresh", requestID: id); request.device = device
        request.details = ["refreshScope": "quick", "source": "periodic"]
        queryHeadset(request)
    }
    private func queryHeadset(_ request: WireMessage) {
        guard let id = request.requestID, let device = request.device,
              BluetoothIdentity.normalizedAddress(device.address) != nil else { return }
        let identifying = request.kind == "deviceIdentity"
        let legacy = request.kind.hasPrefix("oppo")
        let sameActiveDevice = sessionActive && device.address == targetAddress
        let resumeBaseline = request.kind == "oppoQuery" && request.details?["source"] == "audio-resume" &&
            sameActiveDevice && request.sessionID == currentID
        let setting: HeadsetSetting? = request.kind == "oppoSetHiRes" ? request.hiResEnabled.map { .feature(.hiRes, $0) } : request.headsetSetting
        var reply = WireMessage(identifying ? "deviceIdentity" : legacy ? "oppoFailed" : "headsetResult", requestID: id, sessionID: request.sessionID)
        reply.device = device
        controlLog?.record("request", request: request, detail: request.kind + " scope=" + (request.details?["refreshScope"] ?? "default") + " source=" + (request.details?["source"] ?? "user"))
        guard !sleeping, !quitting, !selectingOutput, !controlTransition, controlRecoveryID == nil, currentID == nil || sameActiveDevice else {
            reply.message = "请等待当前耳机／音频连接操作结束"; emit(reply); return
        }
        if identifying {
            guard currentID == nil, setting == nil,
                  let observed = pairedDevices().first(where: { $0.address == device.address && $0.connected && $0.isAudio }),
                  observed.controlServices?.contains(where: { HeadsetDialect(rawValue: $0) != nil }) == true else {
                reply.message = "设备连接或已识别的 OPPO 控制服务已变化"; reply.restartSafe = controlTask == nil && headsetService == nil
                emit(reply); return
            }
        }
        if case .feature(.hiRes, _) = setting, !sameActiveDevice || request.sessionID != currentID {
            reply.message = "HiRes 只允许用于当前高清会话"; emit(reply); return
        }
        if let requestSession = request.sessionID, requestSession != currentID {
            reply.message = "音频会话已变化，未执行耳机操作"; emit(reply); return
        }
        if controlTask != nil {
            // One bounded slot. A user write may wait only behind a read and
            // only with explicit opt-in; it is revalidated and sent at most once.
            let mayWait = setting == nil || (controlIsRead && request.details?["waitForRead"] == "true")
            guard mayWait, queuedControlRead == nil else {
                reply.message = "请等待当前耳机操作结束"; emit(reply); return
            }
            queuedControlRead = request
            if legacy {
                var progress = WireMessage("oppoProgress", requestID: id, sessionID: request.sessionID)
                progress.device = device; progress.message = "等待当前耳机状态读取结束"; emit(progress)
            }
            let timer = Timer(timeInterval: controlQueueTimeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.queuedControlRead?.requestID == id else { return }
                    self?.cancelQueuedRead("等待耳机控制通道超时；未发送排队操作")
                }
            }
            queuedControlTimer = timer; RunLoop.main.add(timer, forMode: .common)
            return
        }
        if request.kind == "headsetWatch" || request.kind == "headsetListen" || resumeBaseline { watchRequestID = id; watchedDevice = device }
        controlRequestID = id; controlIsRead = setting == nil
        controlTask = Task {
            defer {
                controlTask = nil; controlRequestID = nil; controlIsRead = false
                if let queued = queuedControlRead {
                    queuedControlRead = nil; queuedControlTimer?.invalidate(); queuedControlTimer = nil
                    queryHeadset(queued) // Revalidate device/session after waiting.
                }
            }
            do {
                if headsetService?.snapshot.address != device.address { try await headsetService?.suspend() }
                let service = service(for: device)
                service.progress = { [weak self] text in
                    guard legacy, self?.controlRequestID == id else { return }
                    var progress = WireMessage("oppoProgress", requestID: id, sessionID: request.sessionID)
                    progress.device = device; progress.message = text; self?.emit(progress)
                }
                if identifying {
                    watchRequestID = nil; watchedDevice = nil
                    do { reply.headsetIdentity = try await service.identify() }
                    catch { reply.message = error.localizedDescription }
                    try await service.suspend()
                    reply.restartSafe = true
                    if Task.isCancelled { reply.headsetIdentity = nil; reply.message = "身份查询已取消" }
                    emit(reply); return
                }
                if let setting {
                    let generation = request.controlGeneration
                    guard let generation else { throw ProtocolFailure("缺少控制连接代次，请先刷新") }
                    let result = await service.set(setting, generation: generation)
                    reply.headsetResult = result; reply.message = result.message
                    if legacy {
                        var report = service.legacyReport
                        var experiment = OppoHiResExperimentReport()
                        experiment.requestedHiRes = request.hiResEnabled
                        if result.confirmed {
                            experiment.writeAttempts = 1; experiment.writeSubmissionStatus = 0
                            experiment.acknowledgementCode = 0; experiment.readbackCandidate = request.hiResEnabled == true ? 1 : 0
                        }
                        report.experiment = experiment; report.message = result.message; reply.oppoReport = report
                    }
                } else {
                    if resumeBaseline { _ = try await service.resumeAfterAudioStart() }
                    else if legacy { _ = try await service.refreshHiRes() }
                    else if request.kind == "headsetListen" || request.kind == "headsetWatch" { _ = try await service.listen() }
                    else {
                        let scopeName = request.details?["refreshScope"] ?? "full"
                        guard let scope = HeadsetRefreshScope(rawValue: scopeName == "live" ? "quick" : scopeName) else {
                            throw ProtocolFailure("未知的耳机读取范围")
                        }
                        _ = try await service.refresh(scope: scope, missingOnly: request.details?["missingOnly"] == "true",
                                                      includeHiRes: request.details?["includeHiRes"] == "true")
                    }
                    reply.oppoReport = legacy ? service.legacyReport : nil; reply.message = "耳机状态已刷新"
                }
                reply.kind = legacy ? "oppoResult" : "headsetResult"
                reply.headset = service.snapshot; reply.controlGeneration = service.snapshot.generation
            } catch { reply.message = error.localizedDescription }
            if identifying { reply.restartSafe = false }
            if !identifying, headsetService?.snapshot.profile == nil {
                watchRequestID = nil; watchedDevice = nil
                do { try await headsetService?.suspend() } catch { reply.message = error.localizedDescription }
            }
            emit(reply)
        }
    }
    private func cancelQueuedRead(_ reason: String) {
        guard let request = queuedControlRead else { return }
        queuedControlRead = nil; queuedControlTimer?.invalidate(); queuedControlTimer = nil
        var reply = WireMessage(request.kind == "deviceIdentity" ? "deviceIdentity" : request.kind.hasPrefix("oppo") ? "oppoFailed" : "headsetResult", requestID: request.requestID, sessionID: request.sessionID)
        reply.device = request.device; reply.message = reason; emit(reply)
    }
    private func sendAudioState(address: String, requestID: UUID? = nil) {
        var reply = WireMessage("audioState", requestID: requestID, sessionID: currentID); reply.audioState = SystemAudio.snapshot(address: address); emit(reply)
    }
    private func applyVolume(_ value: Double) {
        // HAL stores Float32. Repeated callbacks or key-repeat at an endpoint
        // must not keep rewriting controls and flooding the sender's stdin.
        guard Float32(value) != Float32(gain) else { return }
        do {
            gain = value
            try output?.setSoftwareGain(value)
            session?.updateGain(value)
            var reply = WireMessage("gain", sessionID: currentID); reply.gain = value; emit(reply)
        } catch { session?.updateGain(0); stop(reason: error.localizedDescription) }
    }
    private func start(_ device: BluetoothDevice, configuration: PlaybackConfiguration, gain: Double, id: UUID) {
        guard gain.isFinite, (0...1).contains(gain) else { event("error", "无效音量"); return }
        currentID = id; self.configuration = configuration; self.gain = gain; capabilities = []; probeSucceeded = false; lastError = nil
        playbackFailure = nil; restartSafe = false; reconfigureStopID = nil; stopStartedAt = nil
        sessionActive = false; bufferingRequestID = nil
        targetAddress = device.address
        queryDetails = [:]
        event("preparing", configuration.probeOnly ? "正在准备能力检测" : "正在准备播放")
        let output = LDACNativeOutput(id: id, address: device.address, sampleRateRequested: { [weak self] rate in
            guard let self, self.currentID == id, self.sessionActive else { return }
            do {
                guard let capability = self.capabilities.first(where: { $0.codec == self.configuration.codec && $0.endpoint == self.configuration.endpoint }) else {
                    throw ProtocolFailure("当前会话缺少可用的端点能力，无法应用 MIDI 采样率请求")
                }
                var reply = WireMessage("sampleRateRequested", sessionID: id)
                reply.configuration = try capability.changingSampleRate(to: rate, from: self.configuration)
                reply.capabilities = self.capabilities
                self.emit(reply)
            } catch {
                var reply = WireMessage("settingsRejected", sessionID: id); reply.message = error.localizedDescription; self.emit(reply)
            }
        }) { [weak self] result in
            guard let self, self.currentID == id else { return }
            switch result {
            case .success(let controls):
                let value = controls.muted ? 0 : Double(controls.scalar)
                self.applyVolume(value)
            case .failure(let error): self.stop(reason: error.localizedDescription)
            }
        }
        self.output = output
        starting = Task {
            do {
                let helpers = LDACNativeSession.Helpers(bundle: .main)
                guard helpers.isAvailable else { throw ProtocolFailure("安装缺少音频辅助程序，请重新构建") }
                try await output.claim(model: device.name, targetAddress: device.address, sampleRate: configuration.sampleRate,
                                       availableRates: configuration.codec.sampleRates)
                try Task.checkCancellation()
                try output.setSoftwareGain(self.gain)
                let priority = try output.priorityControl()
                sendAudioState(address: device.address)
                let session = LDACNativeSession(id: id, address: device.address, helpers: helpers, gain: self.gain,
                    outputDeviceUID: LDACNativeOutput.uid, priority: priority, configuration: configuration) { [weak self] event in
                        guard let self, self.currentID == id else { return }; self.receive(event)
                    }
                self.session = session; self.starting = nil; session.start()
            } catch {
                output.recordStartFailure(error)
                lastError = error.localizedDescription
                await finish(disconnected: false)
            }
        }
    }
    private func receive(_ event: LDACNativeSession.Event) {
        switch event {
        case .connecting: self.event("connecting")
        case .stopPhase(let phase): stopProgress(phase)
        case .handoffReady:
            do { try output?.selectForHandoff(); session?.allowHandoff() } catch { stop(reason: error.localizedDescription) }
        case .capability(let cap):
            capabilities.removeAll { $0.endpoint == cap.endpoint }; capabilities.append(cap)
            var reply = WireMessage("capabilities", sessionID: currentID); reply.capabilities = capabilities; emit(reply)
        case .probeComplete(let queried, let succeeded):
            probeSucceeded = queried == 0 || succeeded > 0
            queryDetails = ["endpointsQueried": String(queried), "endpointsFailed": String(queried - succeeded)]
            if queried > 0 && succeeded == 0 { lastError = "全部音频接收端点查询失败，无法判断编码支持情况。" }
        case .telemetry(let text):
            var reply = WireMessage("telemetry", sessionID: currentID); reply.message = text; reply.metrics = DiagnosticMetrics.parse(text); emit(reply)
        case .active(let format):
            do {
                try output?.finishPreparation(); try output?.setSoftwareGain(gain)
                try output?.setSystemRateChangesEnabled(true)
            } catch { stop(reason: error.localizedDescription); return }
            sessionActive = true
            var reply = WireMessage("active", sessionID: currentID); reply.format = format; reply.configuration = configuration; emit(reply)
            sendAudioState(address: targetAddress)
            // App owns the post-active HiRes read, then refreshes its watch.
            // Starting an invisible refresh here races and rejects that read.
        case .formatChanged(let format): var reply = WireMessage("format", sessionID: currentID); reply.format = format; emit(reply)
        case .gainApplied: break
        case .bufferingApplied(let requestID, let settings):
            guard sessionActive, bufferingRequestID == requestID else { break }
            bufferingRequestID = nil; configuration.buffering = settings
            var reply = WireMessage("bufferingApplied", requestID: requestID, sessionID: currentID)
            reply.buffering = settings; emit(reply)
        case .audioCaptureAccess(let access): self.event("capturePermission", String(describing: access))
        case .failed(let message):
            _ = output?.silence()
            sessionActive = false
            controlTask?.cancel(); media.cancel(); Task { try? await headsetService?.suspend() }
            lastError = message; self.event("error", message)
        case .connectionLost(let message): stop(reason: message)
        case .finished(let completion):
            session = nil
            playbackFailure = completion.playbackFailure; restartSafe = completion.restartSafe
            if completion.requiresAttention || completion.message != nil { lastError = completion.message ?? lastError }
            Task { await finish(disconnected: completion.targetDisconnected) }
        }
    }
    private func stopProgress(_ phase: AudioStopPhase) {
        guard let currentID else { return }
        var reply = WireMessage("stopProgress", sessionID: currentID); reply.stopPhase = phase
        reply.metrics = ["stopElapsedSeconds": max(0, ProcessInfo.processInfo.systemUptime - (stopStartedAt ?? ProcessInfo.processInfo.systemUptime))]
        emit(reply)
    }
    private func finish(disconnected: Bool) async {
        _ = output?.silence()
        sessionActive = false; bufferingRequestID = nil
        controlTask?.cancel(); media.cancel()
        do { try await suspendControl() } catch { lastError = error.localizedDescription; restartSafe = false }
        if reconfigureStopID == currentID, reconfigureStopID != nil {
            // A user route change during teardown cancels automatic restart.
            // Restoration below still preserves their chosen output.
            do { try output?.validateForRecovery() }
            catch { lastError = error.localizedDescription; restartSafe = false }
        }
        stopProgress(.route)
        if let error = await output?.restoreAndRelease(targetDisconnected: disconnected) {
            lastError = [lastError, error].compactMap { $0 }.joined(separator: "\n"); restartSafe = false
        }
        output = nil; starting = nil
        sendAudioState(address: targetAddress)
        var reply = WireMessage(lastError == nil ? "stopped" : "failed", sessionID: currentID)
        reply.message = lastError; reply.capabilities = capabilities
        reply.playbackFailure = playbackFailure; reply.restartSafe = restartSafe && !quitting && !sleeping
        reply.details = queryDetails.merging(["probeComplete": String(probeSucceeded), "hardwareAcceptance": "not-asserted"]) { _, new in new }
        emit(reply); currentID = nil
        if environmentTimer != nil { sendEnvironment(force: true) }
        // The app decides whether to reconnect or resume idle monitoring only
        // after receiving this terminal event. Do not reopen ELNK in that gap.
        if quitting { exit(lastError == nil ? 0 : 1) }
    }
    func stop(reason: String?, reconfigure: Bool = false) {
        reconfigureStopID = reconfigure && reason == nil && !quitting && !sleeping ? currentID : nil
        if stopStartedAt == nil { stopStartedAt = ProcessInfo.processInfo.systemUptime }
        controlRecoveryTask?.cancel()
        cancelQueuedRead("会话已停止，未执行排队查询")
        sessionActive = false; bufferingRequestID = nil
        controlTask?.cancel(); media.cancel()
        if let pendingControlAudioID {
            var reply = WireMessage("stopped", sessionID: pendingControlAudioID); reply.message = reason; emit(reply)
        }
        controlTransitionID = nil; pendingControlAudioID = nil; controlTransition = false
        if let reason { lastError = reason }
        starting?.cancel()
        if let session {
            event("stopping", reason); stopProgress(.control); _ = output?.silence()
            Task {
                do { try await suspendControl() }
                catch { lastError = error.localizedDescription; reconfigureStopID = nil }
                if reconfigureStopID != nil {
                    do { try output?.validateForRecovery() }
                    catch { lastError = error.localizedDescription; reconfigureStopID = nil }
                }
                stopProgress(.transport)
                session.stop(reconfigure: reconfigureStopID != nil && reconfigureStopID == currentID)
            }
        }
        else {
            let service = headsetService
            Task {
                do { try await service?.suspend() } catch { lastError = error.localizedDescription }
                if starting == nil, currentID == nil, quitting { exit(lastError == nil ? 0 : 1) }
            }
        }
    }
    func quit() { if quitting { return }; quitting = true; stop(reason: nil) }
}

#if !CONTROL_COORDINATOR_TESTS
@main
struct EngineMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--startup-health") {
            let values = StartupDiagnostics.read()
            if let data = try? JSONEncoder().encode(values) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        let controller = SessionController()
        if CommandLine.arguments.contains("--devices") { controller.sendDevices(); return }
        if CommandLine.arguments.contains("--doctor") { controller.handle(WireMessage("doctor")); return }
        if let index = CommandLine.arguments.firstIndex(of: "--audio-state"), index + 1 < CommandLine.arguments.count {
            var request = WireMessage("audioState")
            request.device = BluetoothDevice(address: CommandLine.arguments[index + 1], name: "", connected: false, a2dpSink: false)
            controller.handle(request); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            while true {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { Task { @MainActor in controller.quit() }; return }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
                    guard line.count <= 65536, let message = try? JSONDecoder().decode(WireMessage.self, from: line) else { Task { @MainActor in controller.quit() }; return }
                    Task { @MainActor in controller.handle(message) }
                }
                if pending.count > 65536 { Task { @MainActor in controller.quit() }; return }
            }
        }
        RunLoop.main.run()
    }
}
#endif
