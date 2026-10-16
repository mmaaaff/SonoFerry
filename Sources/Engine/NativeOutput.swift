#if !SONOFERRY_PUBLIC_APIS_ONLY
import SonoFerryCore
import CoreAudio
import CoreBluetooth
import Darwin
import Foundation
import IOBluetooth
import OSLog

struct LDACNativeVolume: Equatable, Codable, Sendable {
    var scalar: Float32
    var muted: Bool

    static func scalar(for volume: Int, range: ClosedRange<Int>) -> Float32 {
        range.lowerBound == range.upperBound ? 0 : Float32(volume - range.lowerBound) / Float32(range.upperBound - range.lowerBound)
    }

    func volume(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int((Double(scalar) * Double(range.upperBound - range.lowerBound)).rounded())
    }

    mutating func update(volume: Int, range: ClosedRange<Int>) -> Bool {
        guard self.volume(in: range) != volume else { return false }
        scalar = Self.scalar(for: volume, range: range)
        return true
    }

    static func shouldRestore(currentUID: String, savedUID: String) -> Bool {
        currentUID == LDACNativeOutput.uid && savedUID != LDACNativeOutput.uid
    }

    static func canHandoff(currentUID: String, savedUID: String?) -> Bool {
        currentUID == savedUID || currentUID == LDACNativeOutput.uid
    }
}

struct LDACRouteRecovery: Codable, Sendable {
    let address: String
    let model: String
    let sampleRate: LDACSampleRate
    let defaults: [UInt32: String]
    let controls: LDACNativeVolume
    let selected: Bool
}

@MainActor
final class LDACNativeOutput {
    nonisolated static let uid = AudioIdentifiers.virtualOutputUID
    private nonisolated static let leaseSelector: AudioObjectPropertySelector = 0x786D6C73
    private static let modelSelector: AudioObjectPropertySelector = 0x786D6E6D
    private static let rateControlSelector: AudioObjectPropertySelector = 0x786D7263
    private nonisolated static let prioritySelector: AudioObjectPropertySelector = 0x786D7072
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let defaultSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
    private static var routeOwner: FileHandle?
    private var holdsRouteOwner = false
    private let id: UUID
    private let address: String
    private nonisolated static let logger = Logger(subsystem: "local.SonoFerry", category: "LDACLifecycle")
    private let changed: (Result<LDACNativeVolume, Error>) -> Void
    private let sampleRateRequested: (Int) -> Void
    private var systemRateChoices: [Int] = []
    private var systemRateEnabled = false
    private var lastSystemRateSerial: Int64 = 0
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var stream = AudioObjectID(kAudioObjectUnknown)
    private var sampleRateHz = Float64(48000)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var renewTask: Task<Void, Never>?
    private var leaseActivity: NSObjectProtocol?
    private var savedDefaults: [AudioObjectPropertySelector: String] = [:]
    private var expected = LDACNativeVolume(scalar: 0, muted: true)
    private(set) var controls = LDACNativeVolume(scalar: 0, muted: true)
    private(set) var isSelected = false
    private(set) var userVolumeChanged = false
    private(set) var hasInitialVolume = false
    private var ready = false
    private var stopping = false
    private var restoring = false
    private var ownsLease = false
    private var observesPriority = false
    private var restoringOwner = false
    private var model = ""
    private var routeLog: FileHandle?
    private var routeLogBytes = 0
    private var claimStage = "not-started"

    private var handoffSelectors: [AudioObjectPropertySelector] {
        Self.defaultSelectors.filter {
            $0 == kAudioHardwarePropertyDefaultOutputDevice || savedDefaults[$0] == savedDefaults[kAudioHardwarePropertyDefaultOutputDevice]
        }
    }

    init(id: UUID, address: String, sampleRateRequested: @escaping (Int) -> Void,
         changed: @escaping (Result<LDACNativeVolume, Error>) -> Void) {
        self.id = id
        self.address = address
        self.changed = changed
        self.sampleRateRequested = sampleRateRequested
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(RuntimeIdentity.cacheDirectory + "/Routes", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previous = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let ordered = previous.filter { $0.pathExtension == "jsonl" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for stale in ordered.dropFirst(19) { try? FileManager.default.removeItem(at: stale) }
            let path = directory.appendingPathComponent(id.uuidString + ".jsonl").path
            if FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) {
                routeLog = FileHandle(forWritingAtPath: path)
            }
        }
    }

    static func driverRevision() throws -> Int? {
        guard let device = try resolve(uid) else { return nil }
        let selector: AudioObjectPropertySelector = 0x786D7672
        var property = property(selector)
        guard AudioObjectHasProperty(device, &property) else { return 0 }
        let value = try read(device, selector: selector, initial: Optional<Unmanaged<CFTypeRef>>.none)
        guard let value else { throw OutputError("The SonoFerry LDAC Output driver returned no version.", userFacing: String(localized: "未能检查 SonoFerry 音频插件版本。")) }
        let number = value.takeRetainedValue()
        guard CFGetTypeID(number) == CFNumberGetTypeID(), let number = number as? NSNumber,
              number.intValue > 0, number.doubleValue == Double(number.intValue) else {
            throw OutputError("The SonoFerry LDAC Output driver returned an invalid version.", userFacing: String(localized: "未能检查 SonoFerry 音频插件版本。"))
        }
        return number.intValue
    }

    static func loadedEngineIdentity() throws -> String? {
        guard let device = try resolve(uid) else { return nil }
        let selector: AudioObjectPropertySelector = 0x786d6569
        var address = property(selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        return try readString(device, selector: selector)
    }

    nonisolated static func canSelect(alive: UInt32, hidden: UInt32, defaultOutput: UInt32, systemOutput: UInt32) -> Bool {
        alive == 1 && hidden == 0 && defaultOutput == 1 && systemOutput == 1
    }

    nonisolated static func canTransferControls(uid: String, transport: UInt32, address: String) -> Bool {
        guard transport == kAudioDeviceTransportTypeBluetooth,
              uid.count == 17 || (uid.count > 17 && uid.dropFirst(17).first == ":"),
              let target = BluetoothIdentity.normalizedAddress(address),
              let source = BluetoothIdentity.normalizedAddress(String(uid.prefix(17))) else { return false }
        return source == target
    }

    func claim(model: String, targetAddress: String, sampleRate: LDACSampleRate = .hz48000,
               availableRates: [Int], recovering: LDACRouteRecovery? = nil) async throws {
        claimStage = "resolve"
        record("claim-requested", reason: "model=\(model) rate=\(sampleRate.rawValue) choices=\(availableRates)")
        guard let endpoint = try Self.resolve(Self.uid) else {
            throw OutputError(String(localized: "请运行 SonoFerry 安装包安装音频插件，然后重新启动 Mac。"))
        }
        do { try Self.acquireRouteOwner(); holdsRouteOwner = true }
        catch {
            throw OutputError("macOS could not reserve LDAC route ownership: \(error.localizedDescription)", userFacing: String(localized: "系统未能启用 SonoFerry 音频输出，请重试。"))
        }
        self.model = model
        restoringOwner = recovering != nil
        controls.muted = true
        if let recovering {
            savedDefaults = recovering.defaults
            controls = recovering.controls
            isSelected = recovering.selected
        } else {
            for selector in Self.defaultSelectors {
                let output: AudioObjectID = try Self.read(Self.system, selector: selector, initial: 0)
                let savedUID = try Self.readString(output, selector: kAudioDevicePropertyDeviceUID)
                guard savedUID != Self.uid else { throw OutputError(String(localized: "请先在系统声音设置中选择耳机作为输出，然后重新开始。")) }
                savedDefaults[selector] = savedUID
                record("saved-route", reason: "selector=\(selector) device=\(output) uid=\(savedUID)")

            }
        }
        device = endpoint
        sampleRateHz = Float64(sampleRate.rawValue)
        claimStage = "lease"
        do { try setLease(true) }
        catch {
            throw OutputError("macOS could not claim the experimental LDAC output: \(error.localizedDescription)", userFacing: String(localized: "系统未能启用 SonoFerry 音频输出，请重试。"))
        }
        ownsLease = true
        leaseActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "LDAC audio playback")
        guard try leaseIsOwned() else { throw OutputError("macOS did not confirm ownership of the experimental LDAC output.", userFacing: String(localized: "系统未能启用 SonoFerry 音频输出，请重试。")) }
        record("lease-owned", reason: "device=\(device) retainedVolume=\(hasInitialVolume) scalar=\(controls.scalar) retainedUserMute=\(controls.muted)")
        claimStage = "initial-controls"
        try Self.write(device, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(1), requiringLease: true)
        try Self.write(device, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, value: Float32(0), requiringLease: true)
        try Self.write(device, selector: Self.modelSelector, value: model as CFString)
        renewTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard self != nil else { return }
                do {
                    try Task.checkCancellation()
                    guard try Self.leaseIsOwned(endpoint) else { throw OutputError("The experimental LDAC output lost its owner.", userFacing: String(localized: "SonoFerry 音频输出已不可用，请重试。")) }
                    try Task.checkCancellation()
                    try Self.write(endpoint, selector: Self.leaseSelector, value: ["claim": kCFBooleanTrue!] as CFDictionary)
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.ownsLease, !self.restoring else { return }
                        self.record("lease-failed", reason: error.localizedDescription)
                        self.changed(.failure(error))
                    }
                    return
                }
            }
        }
        claimStage = "previous-priority"
        try await clearPreviousPriority()
        claimStage = "visibility"
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while true {
            try Task.checkCancellation()
            if try Self.isSelectableEndpoint(device) { break }
            guard clock.now < deadline else { throw OutputError("macOS did not make the experimental LDAC output available. Retry LDAC.", userFacing: String(localized: "系统未能启用 SonoFerry 音频输出，请重试。")) }
            try await Task.sleep(for: .milliseconds(100))
        }
        stream = try Self.read(device, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, initial: AudioObjectID(0))
        systemRateChoices = availableRates
        claimStage = "format-configuration"
        record("format-configuration", reason: "rate=\(sampleRateHz) choices=\(availableRates)")
        var lastBusyStatus: String?
        try await OutputTransition.wait(stage: "format-configuration") {
            guard try leaseIsOwned() else { throw OutputError("Lost lease while configuring format", userFacing: "SonoFerry 音频输出已不可用，请重试。") }
            let state = try outputTransitionState()
            guard !state.running else {
                if lastBusyStatus == nil { record("format-wait", reason: "old IO still running alive=\(state.alive)") }
                lastBusyStatus = "IO-running"; return false
            }
            do {
                try setSystemRateChangesEnabled(false)
                let currentRate: Float64 = try Self.read(device, selector: kAudioDevicePropertyNominalSampleRate, initial: 0)
                if currentRate != sampleRateHz {
                    var property = Self.property(kAudioDevicePropertyAvailableNominalSampleRates)
                    var size: UInt32 = 0
                    let status = AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size)
                    guard status == noErr, size > 0, size % UInt32(MemoryLayout<AudioValueRange>.stride) == 0 else {
                        throw OutputError(String(localized: "未能读取音频插件支持的采样率。"))
                    }
                    var rates = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.stride)
                    let readStatus = rates.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!) }
                    guard readStatus == noErr else { throw OutputError(String(localized: "未能读取音频插件支持的采样率。")) }
                    guard rates.contains(where: { $0.mMinimum <= sampleRateHz && sampleRateHz <= $0.mMaximum }) else {
                        throw OutputError(String(localized: "请安装当前 SonoFerry 安装包并重新启动 Mac，以使用所选采样率。"))
                    }
                    try Self.write(device, selector: kAudioDevicePropertyNominalSampleRate, value: sampleRateHz)
                }
                return true
            } catch let error as OutputError where error.status == kAudioHardwareIllegalOperationError {
                // Host StopIO/configuration callbacks can race the observation above.
                // Reapply only this local idempotent setup within the same deadline.
                if lastBusyStatus != error.diagnostic { record("format-wait", reason: error.diagnostic) }
                lastBusyStatus = error.diagnostic
                return false
            }
        }
        claimStage = "format-readback"
        let formatDeadline = clock.now.advanced(by: .seconds(5))
        while try !hasSelectedFormat() {
            try Task.checkCancellation()
            guard clock.now < formatDeadline else { throw OutputError(String(localized: "音频插件未确认所选采样率，请安装匹配版本的 SonoFerry 后重试。")) }
            try await Task.sleep(for: .milliseconds(100))
        }
        claimStage = "observers"
        record("claim-ready", reason: "device=\(device) visible and eligible")
        try listen(device, selector: kAudioDevicePropertyNominalSampleRate)
        try listen(device, selector: Self.rateControlSelector)
        for selector in [kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyVirtualFormat] {
            try listen(stream, selector: selector)
        }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            try listen(device, selector: selector, scope: kAudioObjectPropertyScopeOutput)
        }
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyIsHidden] {
            try listen(device, selector: selector)
        }
        for selector in [kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice] {
            var property = Self.property(selector, scope: kAudioObjectPropertyScopeOutput)
            if AudioObjectHasProperty(device, &property) { try listen(device, selector: selector, scope: kAudioObjectPropertyScopeOutput) }
        }
        for selector in Self.defaultSelectors { try listen(Self.system, selector: selector) }
    }

    var routeRecovery: LDACRouteRecovery {
        LDACRouteRecovery(address: address, model: model, sampleRate: LDACSampleRate(rawValue: Int(sampleRateHz))!,
                          defaults: savedDefaults, controls: controls, selected: isSelected)
    }

    func setSoftwareGain(_ gain: Double) throws {
        claimStage = "software-gain"
        guard gain.isFinite, (0...1).contains(gain) else { throw ProtocolFailure("无效音量") }
        controls.scalar = Float32(gain); controls.muted = gain == 0
        try applyControls()
    }

    func setSystemRateChangesEnabled(_ enabled: Bool) throws {
        systemRateEnabled = false
        guard ownsLease, !systemRateChoices.isEmpty else { return }
        var property = Self.property(Self.rateControlSelector)
        guard AudioObjectHasProperty(device, &property) else {
            throw OutputError("需要安装新版 SonoFerry 音频插件并重新加载音频服务，才能从 MIDI 修改采样率。")
        }
        try Self.write(device, selector: Self.rateControlSelector,
                       value: ["enabled": enabled, "rates": systemRateChoices] as CFDictionary)
        systemRateEnabled = enabled
    }

    private func refreshSystemRateRequest() throws {
        guard systemRateEnabled, ready, isSelected, !restoring else { return }
        try verifyRoute()
        guard let value = try Self.read(device, selector: Self.rateControlSelector,
                                       initial: Optional<Unmanaged<CFDictionary>>.none) else { return }
        let request = value.takeRetainedValue() as NSDictionary
        guard request["enabled"] as? Bool == true,
              let sequence = request["serial"] as? NSNumber, sequence.int64Value > lastSystemRateSerial,
              let rate = request["requestedRate"] as? NSNumber,
              systemRateChoices.contains(rate.intValue), rate.doubleValue == Double(rate.intValue) else { return }
        lastSystemRateSerial = sequence.int64Value
        record("system-rate-request", reason: "rate=\(rate.intValue) serial=\(sequence.int64Value)")
        sampleRateRequested(rate.intValue)
    }

    func configure(volume: Int, range: ClosedRange<Int>, preservingUserChange: Bool = false) throws {
        guard !preservingUserChange || (!userVolumeChanged && !hasInitialVolume) else { return }
        guard controls.update(volume: volume, range: range) else { return }
        try applyControls()
    }

    func priorityControl() throws -> LDACPriorityControl {
        claimStage = "priority-preparation"
        var property = Self.property(Self.prioritySelector)
        guard AudioObjectHasProperty(device, &property) else {
            throw OutputError("Update the SonoFerry LDAC Output driver, then retry LDAC.", userFacing: String(localized: "需要更新 SonoFerry 音频插件。请安装当前版本并重新启动 Mac。"))
        }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(device, &property, &settable)
        guard status == noErr, settable.boolValue else {
            throw OutputError("Update the SonoFerry LDAC Output driver, then retry LDAC.", userFacing: String(localized: "需要更新 SonoFerry 音频插件。请安装当前版本并重新启动 Mac。"))
        }
        let device = device
        let address = address
        _ = try Self.priorityState(device, address: address)
        if !observesPriority {
            try listen(device, selector: Self.prioritySelector)
            observesPriority = true
        }
        let preparation: [String: Any] = ["address": address as CFString, "enabled": kCFBooleanFalse!, "prepare": kCFBooleanTrue!]
        try Self.write(device, selector: Self.prioritySelector, value: preparation as CFDictionary)
        return LDACPriorityControl(request: { enabled, disconnected in
            var value: [String: Any] = ["address": address as CFString, "enabled": enabled ? kCFBooleanTrue! : kCFBooleanFalse!]
            if disconnected { value["disconnected"] = kCFBooleanTrue! }
            try Self.write(device, selector: Self.prioritySelector, value: value as CFDictionary)
        }, state: {
            try Self.priorityState(device, address: address)
        })
    }

    private func clearPreviousPriority() async throws {
        let previous = try Self.prioritySnapshot(device)
        guard previous.state.phase != "idle" else { return }
        let previousAddress = previous.address!
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(45))
        var disconnected = false
        record("priority-cleanup-requested", reason: "phase=\(previous.state.phase)")
        try Self.write(device, selector: Self.prioritySelector, value: [
            "address": previousAddress as CFString, "enabled": kCFBooleanFalse!
        ] as CFDictionary)
        while true {
            try Task.checkCancellation()
            guard try leaseIsOwned() else {
                throw OutputError("The LDAC output lease ended during previous-session cleanup.", userFacing: String(localized: "SonoFerry 音频输出已不可用，请重试。"))
            }
            let current = try Self.prioritySnapshot(device)
            if current.state.phase == "idle" { return }
            guard current.address == previousAddress else {
                throw OutputError("The Bluetooth priority target changed during cleanup.", userFacing: String(localized: "音频插件报告的连接属于其他设备，当前会话已停止。"))
            }
            if !disconnected, Self.priorityConnectionDisconnected(address: previousAddress) {
                disconnected = true
                try Self.write(device, selector: Self.prioritySelector, value: [
                    "address": previousAddress as CFString, "enabled": kCFBooleanFalse!, "disconnected": kCFBooleanTrue!
                ] as CFDictionary)
            }
            guard clock.now < deadline else {
                throw LDACPriorityCleanupError(message: String(localized: "音频会话未完全停止，请检查蓝牙连接和系统输出。"))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func priorityConnectionDisconnected(address: String) -> Bool {
        guard CBManager.authorization == .allowedAlways,
              let device = IOBluetoothDevice(addressString: address), device.isPaired() else { return false }
        return !device.isClassicConnected()
    }

    func selectForHandoff() throws {
        try verifyRoute()
        for selector in handoffSelectors {
            let current: AudioObjectID = try Self.read(Self.system, selector: selector, initial: 0)
            guard try LDACNativeVolume.canHandoff(currentUID: Self.readString(current, selector: kAudioDevicePropertyDeviceUID),
                                                 savedUID: savedDefaults[selector]) else {
                throw OutputError("The Mac audio output changed before LDAC handoff. Retry LDAC.", userFacing: String(localized: "启动前系统输出已改变，当前会话已取消。"))
            }
        }
        isSelected = true
        for selector in handoffSelectors { try Self.write(Self.system, selector: selector, value: device) }
        try verifyRoute()
        record("selected", reason: "silent endpoint selected")
    }

    func validateForRecovery() throws {
        try verifyRoute()
    }

    func prepareForReconnect() throws -> LDACPriorityControl {
        try verifyRoute()
        return try priorityControl()
    }

    func finishPreparation() throws {
        try verifyRoute()
        ready = true
        try applyControls()
        record("prepared", reason: "scalar=\(controls.scalar) userMuted=\(controls.muted)")
    }

    @discardableResult
    func silence() -> String? {
        // During ordered shutdown priority can temporarily require cleanup. The
        // session owns that cleanup; only restoreAndRelease decides its outcome.
        stopping = true
        ready = false
        try? setSystemRateChangesEnabled(false)
        if ownsLease {
            do {
                try Self.write(device, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(1), requiringLease: true)
                expected.muted = true
            } catch {
                NSLog("Could not mute LDAC output: %@", error.localizedDescription)
                return error.localizedDescription
            }
        }
        return nil
    }

    func recordStartFailure(_ error: Error) {
        let diagnostic = (error as? OutputError)?.diagnostic ?? String(describing: error)
        let state = try? outputTransitionState()
        record("start-failed", reason: "stage=\(claimStage) state=[\(state?.diagnostic ?? "unreadable")] error=\(diagnostic)")
    }

    private func outputTransitionState() throws -> OutputTransition.State {
        let alive: UInt32 = try Self.read(device, selector: kAudioDevicePropertyDeviceIsAlive, initial: 0)
        let running: UInt32 = try Self.read(device, selector: kAudioDevicePropertyDeviceIsRunning, initial: 0)
        let hidden: UInt32 = try Self.read(device, selector: kAudioDevicePropertyIsHidden, initial: 0)
        let canDefault: UInt32 = try Self.read(device, selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                              scope: kAudioObjectPropertyScopeOutput, initial: 0)
        let canSystemDefault: UInt32 = try Self.read(device, selector: kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
                                                    scope: kAudioObjectPropertyScopeOutput, initial: 0)
        return .init(alive: alive != 0, hidden: hidden != 0, running: running != 0,
                     canDefault: canDefault != 0, canSystemDefault: canSystemDefault != 0)
    }

    func restoreAndRelease(targetDisconnected: Bool = false) async -> String? {
        restoring = true
        record("restoring", reason: "selected=\(isSelected) userMuted=\(controls.muted)")
        let silenceError = silence()
        var errors = [silenceError].compactMap { $0 }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        if isSelected {
            for selector in handoffSelectors {
                guard let savedUID = savedDefaults[selector] else { continue }
                do {
                    while true {
                        guard try leaseIsOwned() else {
                            throw OutputError("The LDAC output lease ended before route restoration.", userFacing: String(localized: "SonoFerry 音频输出已不可用，请重试。"))
                        }
                        let current: AudioObjectID = try Self.read(Self.system, selector: selector, initial: 0)
                        let currentUID = try Self.readString(current, selector: kAudioDevicePropertyDeviceUID)
                        guard LDACNativeVolume.shouldRestore(currentUID: currentUID, savedUID: savedUID) else {
                            record("route-preserved", reason: "selector=\(selector) currentUID=\(currentUID)")
                            break
                        }
                        if let restored = try Self.resolve(savedUID), try Self.isAliveOutput(restored) {
                            try Self.write(Self.system, selector: selector, value: restored)
                            record("route-restored", reason: "selector=\(selector) savedUID=\(savedUID) userMuted=\(controls.muted)")
                            break
                        }
                        if targetDisconnected || clock.now >= deadline {
                            if targetDisconnected { break }
                            record("missing-saved-route", reason: "selector=\(selector) savedUID=\(savedUID) resolved=\(String(describing: try? Self.resolve(savedUID))) currentUID=\(currentUID)")
                            errors.append(String(localized: "原来的系统音频输出未重新出现，请在声音设置中手动选择输出。"))
                            break
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                } catch {
                    record("restore-failed", reason: error.localizedDescription)
                    errors.append(error.localizedDescription)
                }
            }
        }
        for (object, property, block) in listeners {
            var property = property
            let status = AudioObjectRemovePropertyListenerBlock(object, &property, .main, block)
            if status != noErr && status != kAudioHardwareBadObjectError {
                record("observer-removal-failed", reason: "status=\(status)")
                errors.append(String(localized: "音频会话未完全停止，请检查蓝牙连接和系统输出。"))
            }
        }
        listeners = []
        renewTask?.cancel()
        await renewTask?.value
        renewTask = nil
        if ownsLease {
            do {
                try setLease(false)
                record("lease-released", reason: "waiting for host retirement before allowing next claim")
                // Cleanup must finish even when the startup task was canceled.
                var previousState: OutputTransition.State?
                try await OutputTransition.retire { [self] in
                    guard try !leaseIsOwned() else {
                        throw OutputError("HAL still reports the released lease as owned", userFacing: "音频输出尚未确认释放，请稍后重试。")
                    }
                    let state = try outputTransitionState()
                    if state != previousState {
                        record("lease-retirement-state", reason: state.diagnostic)
                        previousState = state
                    }
                    return state.retired
                }
                record("lease-retired", reason: "lease released, device hidden, default eligibility withdrawn and IO stopped")
            } catch {
                record("lease-retirement-failed", reason: String(describing: error))
                errors.append(error.localizedDescription)
            }
        }
        ownsLease = false
        if let leaseActivity {
            ProcessInfo.processInfo.endActivity(leaseActivity)
            self.leaseActivity = nil
        }
        if holdsRouteOwner {
            do { try Self.routeOwner?.close() }
            catch { errors.append(error.localizedDescription) }
            Self.routeOwner = nil
            holdsRouteOwner = false
        }
        device = AudioObjectID(kAudioObjectUnknown)
        record("restored", reason: errors.isEmpty ? "complete" : errors.joined(separator: " "))
        return errors.isEmpty ? nil : Array(Set(errors)).sorted().joined(separator: " ")
    }

    private func applyControls() throws {
        expected = LDACNativeVolume(scalar: controls.scalar, muted: !ready || controls.muted)
        try Self.write(device, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, value: expected.scalar, requiringLease: true)
        try Self.write(device, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(expected.muted ? 1 : 0), requiringLease: true)
    }

    private func verifyRoute() throws {
        guard try leaseIsOwned(), try Self.isSelectableEndpoint(device) else { throw OutputError("The experimental LDAC output became unavailable.", userFacing: String(localized: "SonoFerry 音频输出已不可用，请重试。")) }
        guard try hasSelectedFormat() else { throw OutputError(String(localized: "系统音频格式已改变，当前会话已停止。")) }
        if isSelected {
            for selector in handoffSelectors {
                let current: AudioObjectID = try Self.read(Self.system, selector: selector, initial: 0)
                guard current == device else { throw OutputError(String(localized: "系统输出已切换，SonoFerry 已停止并保留你的选择。")) }
            }
        }
    }

    private func hasSelectedFormat() throws -> Bool {
        let rate: Float64 = try Self.read(device, selector: kAudioDevicePropertyNominalSampleRate, initial: 0)
        guard rate == sampleRateHz else { return false }
        for selector in [kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyVirtualFormat] {
            let format = try Self.read(stream, selector: selector, initial: AudioStreamBasicDescription())
            guard format.mSampleRate == sampleRateHz, format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags == kAudioFormatFlagsNativeFloatPacked, format.mChannelsPerFrame == 2,
                  format.mBitsPerChannel == 32, format.mBytesPerFrame == 8,
                  format.mFramesPerPacket == 1, format.mBytesPerPacket == 8 else { return false }
        }
        return true
    }

    private func refresh() throws {
        guard !restoring, !stopping else { return }
        try verifyRoute()
        // Before sending starts, NativeSession owns priority readiness and its
        // typed failure. An observer must not race it with a generic stop error.
        if observesPriority && ready {
            let priority = try Self.priorityState(device, address: address)
            guard priority.phase != "cleanup-required" else {
                Self.logger.error("LDAC priority cleanup required: \(priority.error ?? "No driver error", privacy: .private)")
                throw LDACPriorityCleanupError(message: String(localized: "音频会话未完全停止，请检查蓝牙连接和系统输出。"))
            }
        }
        let scalar: Float32 = try Self.read(device, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, initial: 0)
        let muted: UInt32 = try Self.read(device, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, initial: 0)
        guard scalar.isFinite, (0...1).contains(scalar), muted <= 1 else { throw OutputError("macOS returned invalid LDAC volume controls.", userFacing: String(localized: "未能读取 SonoFerry 音频设置，请重试。")) }
        let actual = LDACNativeVolume(scalar: scalar, muted: muted == 1)
        guard actual != expected else { return }
        guard isSelected else {
            record("preselection-controls-ignored", reason: "scalar=\(scalar) muted=\(actual.muted)")
            try applyControls()
            return
        }
        if actual.scalar != expected.scalar { controls.scalar = scalar; userVolumeChanged = true }
        if actual.muted != expected.muted { controls.muted = actual.muted }
        expected = actual
        if !ready && !actual.muted { try applyControls() }
        changed(.success(controls))
    }

    private static func acquireRouteOwner() throws {
        guard routeOwner == nil else { throw POSIXError(.EBUSY) }
        // Shared with the installer; the route-owner contract test verifies this exact path.
        let directory = "/Library/Application Support/SonoFerry"
        var metadata = stat()
        guard lstat(directory, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else {
            throw POSIXError(.EPERM)
        }
        let descriptor = Darwin.open(directory + "/ldac-route-owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { if routeOwner == nil { try? handle.close() } }
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0, metadata.st_nlink == 1 else {
            throw POSIXError(.EPERM)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        routeOwner = handle
    }

    private func setLease(_ value: Bool) throws {
        try Self.write(device, selector: Self.leaseSelector, value: ["claim": value ? kCFBooleanTrue! : kCFBooleanFalse!] as CFDictionary)
    }

    private func leaseIsOwned() throws -> Bool {
        try Self.leaseIsOwned(device)
    }

    private nonisolated static func leaseIsOwned(_ device: AudioObjectID) throws -> Bool {
        let value = try read(device, selector: leaseSelector, initial: Optional<Unmanaged<CFBoolean>>.none)
        guard let value else { throw OutputError("macOS could not read the experimental LDAC output owner.", userFacing: String(localized: "未能检查 SonoFerry 音频输出是否可用，请重试。")) }
        return CFBooleanGetValue(value.takeRetainedValue())
    }

    private func listen(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var property = Self.property(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.ownsLease else { return }
                do {
                    if selector == Self.rateControlSelector { try self.refreshSystemRateRequest() }
                    else { try self.refresh() }
                }
                catch {
                    self.record("observed-failure", reason: error.localizedDescription)
                    self.changed(.failure(error))
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &property, .main, block)
        guard status == noErr else { throw OutputError("macOS could not observe the experimental LDAC output (\(status)).", userFacing: String(localized: "未能监听 SonoFerry 音频输出变化，请重试。")) }
        listeners.append((object, property, block))
    }

    private func record(_ event: String, reason: String) {
        Self.logger.notice("LDAC output \(event, privacy: .public); target=\(self.address, privacy: .private(mask: .hash)) session=\(self.id.uuidString, privacy: .public) reason=\(reason, privacy: .private)")
        // Private local diagnostics only; GUI export uses its separate allow-list.
        if routeLogBytes < 131072, let data = try? JSONSerialization.data(withJSONObject: ["time": Date().timeIntervalSince1970, "event": event, "reason": reason]) {
            try? routeLog?.write(contentsOf: data + Data([10])); routeLogBytes += data.count + 1
        }
    }

    private static func setMute(_ object: AudioObjectID, muted: Bool) throws {
        var property = property(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(object, &property) else {
            if muted { throw OutputError("The previous Mac output could not preserve LDAC mute. Select an output in Sound settings before unmuting.", userFacing: String(localized: "未能恢复原来的静音设置，播放前请检查系统声音设置。")) }
            return
        }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(object, &property, &settable)
        guard status == noErr, settable.boolValue else {
            throw OutputError("macOS could not restore the LDAC mute state on its previous output (\(status)).", userFacing: String(localized: "未能恢复原来的静音设置，播放前请检查系统声音设置。"))
        }
        try write(object, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(muted ? 1 : 0))
        let actual: UInt32 = try read(object, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, initial: 0)
        guard actual == (muted ? 1 : 0) else { throw OutputError("macOS did not confirm the restored audio mute state.", userFacing: String(localized: "未能恢复原来的静音设置，播放前请检查系统声音设置。")) }
    }

    private static func isSelectableEndpoint(_ object: AudioObjectID) throws -> Bool {
        let alive: UInt32 = try read(object, selector: kAudioDevicePropertyDeviceIsAlive, initial: 0)
        let hidden: UInt32 = try read(object, selector: kAudioDevicePropertyIsHidden, initial: 0)
        let defaultOutput: UInt32 = try read(object, selector: kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput, initial: 0)
        let systemOutput: UInt32 = try read(object, selector: kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope: kAudioObjectPropertyScopeOutput, initial: 0)
        guard canSelect(alive: alive, hidden: hidden, defaultOutput: defaultOutput, systemOutput: systemOutput) else { return false }
        return try isAliveOutput(object)
    }

    private static func isAliveOutput(_ object: AudioObjectID) throws -> Bool {
        let alive: UInt32 = try read(object, selector: kAudioDevicePropertyDeviceIsAlive, initial: 0)
        guard alive == 1 else { return false }
        var property = property(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
        guard status == noErr else { throw OutputError("macOS could not inspect the restored audio output (\(status)).", userFacing: String(localized: "未能检查原来的系统输出，请在声音设置中选择输出。")) }
        return size >= MemoryLayout<AudioStreamID>.size
    }

    private static func resolve(_ uid: String) throws -> AudioObjectID? {
        var property = property(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifier in
            AudioObjectGetPropertyData(system, &property, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        guard status == noErr, size == MemoryLayout<AudioObjectID>.size else { throw OutputError("macOS could not resolve an audio output identity (\(status)).", userFacing: String(localized: "未找到音频输出，请检查声音设置后重试。")) }
        return device == kAudioObjectUnknown ? nil : device
    }

    private static func readString(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        let value = try read(object, selector: selector, initial: Optional<Unmanaged<CFString>>.none)
        guard let value else { throw OutputError("macOS returned no audio output identity.", userFacing: String(localized: "未能识别音频输出，请检查声音设置后重试。")) }
        return value.takeRetainedValue() as String
    }

    private nonisolated static func priorityState(_ object: AudioObjectID, address: String) throws -> LDACPriorityControl.State {
        let snapshot = try prioritySnapshot(object)
        if let reportedAddress = snapshot.address, reportedAddress != BluetoothIdentity.normalizedAddress(address) {
            throw OutputError("The SonoFerry LDAC Output driver reported Bluetooth priority for a different device.", userFacing: String(localized: "音频插件报告的连接属于其他设备，当前会话已停止。"))
        }
        return snapshot.state
    }

    private nonisolated static func prioritySnapshot(_ object: AudioObjectID) throws -> (state: LDACPriorityControl.State, address: String?) {
        let value = try read(object, selector: prioritySelector, initial: Optional<Unmanaged<CFTypeRef>>.none)
        guard let value else { throw OutputError("The SonoFerry LDAC Output driver returned no Bluetooth priority state.", userFacing: String(localized: "音频插件未能确认蓝牙配置，请重试。")) }
        let state = value.takeRetainedValue()
        guard CFGetTypeID(state) == CFDictionaryGetTypeID(), let state = state as? [String: Any],
              let phaseValue = state["phase"], CFGetTypeID(phaseValue as CFTypeRef) == CFStringGetTypeID(),
              let phase = phaseValue as? String,
              ["idle", "observing", "configuring", "configured", "stopping", "cleanup-required"].contains(phase) else {
            throw OutputError("The SonoFerry LDAC Output driver returned an invalid Bluetooth priority state.", userFacing: String(localized: "音频插件未能确认蓝牙配置，请重试。"))
        }
        var address: String?
        if let reportedAddress = state["address"] {
            guard CFGetTypeID(reportedAddress as CFTypeRef) == CFStringGetTypeID(),
                  let reportedAddress = reportedAddress as? String,
                  let normalized = BluetoothIdentity.normalizedAddress(reportedAddress) else {
                throw OutputError("The SonoFerry LDAC Output driver returned an invalid Bluetooth priority device.", userFacing: String(localized: "音频插件未能识别目标耳机，请重试。"))
            }
            address = normalized
        } else if phase != "idle" {
            throw OutputError("The SonoFerry LDAC Output driver returned no Bluetooth priority device.", userFacing: String(localized: "音频插件未能识别目标耳机，请重试。"))
        }
        var error: String?
        if let reportedError = state["error"] {
            guard CFGetTypeID(reportedError as CFTypeRef) == CFStringGetTypeID(), let reportedError = reportedError as? String else {
                throw OutputError("The SonoFerry LDAC Output driver returned an invalid Bluetooth priority error.", userFacing: String(localized: "音频插件返回了异常响应，请重试。"))
            }
            error = reportedError
        }
        let failureCode = state["failureCode"] as? String
        return (LDACPriorityControl.State(phase: phase, error: error, failureCode: failureCode,
            diagnostics: (state["diagnostics"] as? String).map { String($0.prefix(256)) }), address)
    }

    private nonisolated static func read<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var property = property(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0) }
        guard status == noErr, size == MemoryLayout<T>.size else { throw OutputError("read object=\(object) selector=\(String(selector, radix: 16)) scope=\(String(scope, radix: 16)) status=\(status) size=\(size)", status: status, userFacing: String(localized: "未能读取 SonoFerry 音频设置，请重试。")) }
        return value
    }

    private nonisolated static func write<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, value: T, requiringLease: Bool = false) throws {
        var property = property(selector, scope: scope)
        var value = value
        var qualifier = leaseSelector
        let status = withUnsafePointer(to: &qualifier) { qualifier in
            withUnsafePointer(to: &value) { value in
                AudioObjectSetPropertyData(object, &property, requiringLease ? UInt32(MemoryLayout<AudioObjectPropertySelector>.size) : 0,
                    requiringLease ? qualifier : nil, UInt32(MemoryLayout<T>.size), value)
            }
        }
        guard status == noErr else { throw OutputError("write object=\(object) selector=\(String(selector, radix: 16)) scope=\(String(scope, radix: 16)) status=\(status)", status: status, userFacing: String(localized: "未能更新 SonoFerry 音频设置，请重试。")) }
    }

    private nonisolated static func property(_ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private struct OutputError: LocalizedError {
        let message: String
        let diagnostic: String
        let status: OSStatus?
        var errorDescription: String? { message }
        init(_ message: String, status: OSStatus? = nil, userFacing: String? = nil) {
            self.diagnostic = message; self.status = status
            self.message = userFacing ?? message
            if userFacing != nil { LDACNativeOutput.logger.error("\(message, privacy: .private)") }
        }
    }
}
#endif
