#if !SONOFERRY_PUBLIC_APIS_ONLY
import Darwin
import Foundation

import SonoFerryCore
typealias LDACFormat = AudioFormat
typealias LDACSampleRate = SampleRate
typealias LDACQuality = Quality
typealias LDACConfiguration = PlaybackConfiguration

enum LDACState: Equatable, Sendable {
    case off
    case requested
    case connecting
    case waitingForDevice
    case active(LDACFormat)
    case stopping
    case failed(String)
}

enum LDACAudioCaptureAccess: Equatable, Codable, Sendable {
    case unchecked
    case checking
    case ready
    case permissionRequired

    static var permissionGuidance: String {
        String(localized: "请在系统设置中允许 SonoFerry 和 SonoFerry Audio 录制系统音频，然后重新开始播放。")
    }
}

struct LDACPriorityControl: Sendable {
    struct State: Sendable {
        let phase: String
        let error: String?
        var failureCode: String? = nil
        var diagnostics: String? = nil
        var startupFailure: PlaybackFailureCode? {
            phase == "cleanup-required" && failureCode == "publicationUnavailable" ? .audioHostUnavailable : nil
        }
    }

    let request: @Sendable (Bool, Bool) throws -> Void
    let state: @Sendable () throws -> State
}

struct LDACPriorityCleanupError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

final class LDACNativeSession: @unchecked Sendable {
    private enum PriorityPhase {
        case unused, configuring, configured, stopping, uncertain, removing, removed
    }

    struct Helpers: Sendable {
        let signaling: URL
        let media: URL
        let capture: URL
        let connection: URL
        let logger: URL

        init(bundle: Bundle) {
            let directory = bundle.bundleURL.appendingPathComponent("Contents/Helpers")
            signaling = directory.appendingPathComponent("AVDTPSignaling")
            media = directory.appendingPathComponent("MediaTransport")
            capture = bundle.bundleURL.appendingPathComponent(RuntimeIdentity.captureExecutablePath)
            connection = directory.appendingPathComponent("ClassicConnection")
            logger = directory.appendingPathComponent("LogObserver")
        }

        var isAvailable: Bool {
            [signaling, media, capture, connection, logger].allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
    }

    enum Event: Codable, Sendable {
        case connecting
        case stopPhase(AudioStopPhase)
        case capability(CodecCapabilities)
        case probeComplete(queried: Int, succeeded: Int)
        case telemetry(String)
        case handoffReady
        case active(LDACFormat)
        case formatChanged(LDACFormat)
        case gainApplied(Double)
        case bufferingApplied(UUID, BufferingConfiguration)
        case audioCaptureAccess(LDACAudioCaptureAccess)
        case failed(String)
        case connectionLost(String)
        case finished(Completion)
    }

    struct Completion: Codable, Sendable {
        let message: String?
        let canRetry: Bool
        let requiresAttention: Bool
        let targetDisconnected: Bool
        let waitForReconnect: Bool
        var playbackFailure: PlaybackFailureCode? = nil
        var restartSafe: Bool = false
    }

    private static let daemonEventExpression = try! NSRegularExpression(pattern: "connectedCB cid:0x|l2capDisconnected for CID: 0x|l2capDataInd for CID: 0x|ACL connected:|Received connection result for \"A2DP Source\" profile on device ", options: .caseInsensitive)
    static let daemonPredicate = #"process == "bluetoothd" AND (eventMessage CONTAINS[c] "connectedCB cid:0x" OR eventMessage CONTAINS[c] "l2capDisconnected for CID: 0x" OR eventMessage CONTAINS[c] "l2capDataInd for CID: 0x" OR eventMessage CONTAINS[c] "ACL connected:" OR eventMessage CONTAINS[c] "Received connection result for \"A2DP Source\" profile on device ")"#

    let id: UUID
    private let address: String
    private let helpers: Helpers
    private var reportedCapabilities: [CodecCapabilities] = []
    private let configuration: LDACConfiguration
    private let outputDeviceUID: String?
    private let priority: LDACPriorityControl?
    private let receive: @MainActor @Sendable (Event) -> Void
    private let lock = NSLock()
    private var requestedStop = false
    private var recoveryRequested = false
    private var recoveryReason: String?
    private var pendingPriorityObservation: String?
    private var priorityObservation: String?
    private var priorityObservationDeadline = DispatchTime.distantFuture
    private var priorityRecoveryFailure: String?
    private var recoverableFailure = false
    private var hardFailure = false
    private var connectorSettled = false
    private let recoveryAttempt: Bool
    private let restoringOnly: Bool
    private var handoffAllowed = false
    private var handoffRequested = false
    private var restoreAudio = true
    private var reconfigureRequested = false
    private var lastStopPhase: AudioStopPhase?
    private var requestedGain: Double?
    private var requestedBuffering: (UUID, BufferingConfiguration)?
    private var awaitingBuffering: (UUID, BufferingConfiguration)?
    private var gain: Double
    private var children: [String: LDACNativeChild] = [:]
    private var signalingGate = LDACChannelGate()
    private var mediaGate = LDACChannelGate()
    private var preflightReady = false
    private var preflightCompleted = false
    private var preflightStopSent = false
    private var preflightStopDeadline = DispatchTime.distantFuture
    private var loggerReady = false
    private var daemonLost = false
    private var ownerInputsClosed = false
    private var ownerTerminationSent = false
    private var ownerExitDeadline = DispatchTime.distantFuture
    private var shutdownChecked = false
    private var shutdownUnverified = false
    private var unverifiedAcquisitions: Set<String> = []
    private var pendingOpenCleanup = LDACPendingOpenCleanup()
    private var connected = false
    private var connectorReady = false
    private var capabilityQueryComplete = false
    private var signalingPrepared = false
    private var connectorHandle: Int?
    private var originalConnectionEnded = false
    private var connectorStopSent = false
    private var connectorTerminationSent = false
    private var connectorStopDeadline = DispatchTime.distantFuture
    private var connectorSettlementUnverified = false
    private var nativeAudioFinished = false
    private var mediaPrepared = false
    private var mediaWaitingForACL = false
    private var signalingAwaitingMediaPreparation = false
    private var signalingAwaitingMediaReadiness = false
    private var preparedSent = false
    private var mediaReady: (cid: Int, mtu: Int)?
    private var readySent = false
    private var captureReady = false
    private var pcmReady = false
    private var startAccepted = false
    private var started = false
    private var priorityPhase = PriorityPhase.unused
    private var priorityDeadline = DispatchTime.distantFuture
    private var lastPriorityDiagnostic: String?
    private var mediaStopDeadline = DispatchTime.distantFuture
    private var active = false
    private var mediaStopSent = false
    private var mediaStopReady = false
    private var captureStopSent = false
    private var captureDestroyed = false
    private var captureCancelledBeforeStream = false
    private var feedFinished = false
    private var signalingStopSent = false
    private var signalingStopConfirmed = false
    private var mediaCloseRequired = false
    private var mediaCloseSent = false
    private var waitingMediaClosed = false
    private var mediaClosedSent = false
    private var waitingSignalingClosed = false
    private var signalingClosedSent = false
    private var waitingMediaTransportClosed = false
    private var mediaTransportClosedSent = false
    private var restoring = false
    private var restoreDisconnected = false
    private var targetUnavailableBeforeRestore = false
    private var nativeAudioRestored = false
    private var restoreDeadline = DispatchTime.distantFuture
    private var restoreTerminationSent = false
    private var failure: String?
    private var attentionFailure: String?
    private var publicFailureMessage: String?
    private var playbackFailure: PlaybackFailureCode?
    private var capturePermissionFailure: String?
    private var finalized = false
    private var deadline = DispatchTime.distantFuture
    private var captureStopDeadline = DispatchTime.distantFuture
    private var pcmRead: Int32 = -1
    private var pcmWrite: Int32 = -1
    private var rawURL: URL?
    private var log: FileHandle?
    private var diagnosticsLock: FileHandle?
    private var loggedBytes = 0

    init(id: UUID, address: String, helpers: Helpers, gain: Double, outputDeviceUID: String? = nil,
         priority: LDACPriorityControl? = nil,
         configuration: LDACConfiguration = LDACConfiguration(), recoveryAttempt: Bool = false, restoringOnly: Bool = false,
         receive: @escaping @MainActor @Sendable (Event) -> Void) {
        self.id = id
        self.address = address
        self.helpers = helpers
        self.configuration = configuration
        self.recoveryAttempt = recoveryAttempt
        self.restoringOnly = restoringOnly
        self.outputDeviceUID = outputDeviceUID
        self.priority = priority
        self.gain = gain
        self.receive = receive
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { self.run() }
    }

    func stop(restoreAudio: Bool = true, reconfigure: Bool = false) {
        lock.lock()
        // Ordinary stop/cancel revokes an earlier request; repeated stops cannot
        // upgrade a stop already in progress into an accelerated reconnect.
        reconfigureRequested = requestedStop ? reconfigureRequested && reconfigure : reconfigure
        requestedStop = true
        recoveryRequested = false
        recoveryReason = nil
        pendingPriorityObservation = nil
        self.restoreAudio = self.restoreAudio && restoreAudio
        lock.unlock()
    }

    func recoverConnection(reason: String) {
        lock.withLock {
            recoveryRequested = true
            recoveryReason = reason
        }
    }

    func verifyConnectionLoss(reason: String) {
        lock.withLock { pendingPriorityObservation = reason }
    }

    func allowHandoff() {
        lock.lock()
        handoffAllowed = true
        lock.unlock()
    }

    func updateGain(_ gain: Double) {
        lock.lock()
        requestedGain = gain
        lock.unlock()
    }

    func updateBuffering(_ settings: BufferingConfiguration, requestID: UUID) {
        lock.lock()
        requestedBuffering = (requestID, settings)
        lock.unlock()
    }

    #if DEBUG
    func simulateStartedMediaShutdown(media: LDACNativeChild, capture: LDACNativeChild) {
        children["media"] = media
        children["capture"] = capture
        started = true
        stop()
    }

    var simulatedMediaStopDeadline: DispatchTime { mediaStopDeadline }

    func advanceSimulatedShutdown(mediaDeadline: DispatchTime? = nil) {
        if let mediaDeadline { mediaStopDeadline = mediaDeadline }
        do { try advance() }
        catch { fail(error.localizedDescription) }
    }
    #endif

    private func emit(_ event: Event) {
        let receive = receive
        Task { @MainActor in receive(event) }
    }

    private func run() {
        defer {
            do {
                try log?.close()
                log = nil
                if let rawURL { try Self.completeDiagnostics(in: rawURL.deletingLastPathComponent(), releasing: diagnosticsLock) }
            } catch {}
            try? diagnosticsLock?.close()
            diagnosticsLock = nil
        }
        do {
            let sessions = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(RuntimeIdentity.cacheDirectory + "/Sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessions.path)
            let directory = sessions.appendingPathComponent(id.uuidString)
            diagnosticsLock = try Self.beginDiagnostics(in: directory)
            rawURL = directory.appendingPathComponent("signaling.bin")
            let logURL = directory.appendingPathComponent("session.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            log = try FileHandle(forWritingTo: logURL)
            record("SESSION_REQUEST probe=\(configuration.probeOnly) \(configuration.signalingArguments.joined(separator: " "))")
            if restoringOnly {
                shutdownChecked = true
                restoring = true
                stopPhase(.nativeOutput)
                try launch("restore", executable: helpers.connection, arguments: ["--address", address, "--restore"])
                restoreDeadline = DispatchTime.now() + 52
            } else if configuration.probeOnly {
                preflightCompleted = true
                deadline = DispatchTime.now() + 10
            } else {
                try launch("preflight", executable: helpers.capture, arguments: ["--check-permission"] + captureDeviceArguments)
                deadline = DispatchTime.now() + 90
            }
        } catch {
            record("START_FAILED \(error.localizedDescription)")
            emit(.finished(Completion(message: failureDescription, canRetry: false, requiresAttention: true,
                                      targetDisconnected: false, waitForReconnect: false)))
            return
        }
        while true {
            do {
                let names = Array(children.keys)
                var descriptors = names.compactMap { name -> pollfd? in
                    guard let child = children[name], !child.outputEnded else { return nil }
                    return pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)
                }
                var readyOutputs = Set<Int32>()
                if !descriptors.isEmpty {
                    let result = poll(&descriptors, nfds_t(descriptors.count), 50)
                    if result < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    if result > 0 { readyOutputs = Set(descriptors.filter { $0.revents != 0 }.map(\.fd)) }
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                for name in names {
                    guard let child = children[name] else { continue }
                    if readyOutputs.contains(child.output) {
                        for line in try child.readLines() { try handle(name, line: line) }
                    }
                    child.reap()
                }
                try advance()
                if canRestore {
                    do { try beginRestore() }
                    catch {
                        fail("Ordinary Bluetooth audio restoration could not start: \(error.localizedDescription)", userMessage: String(localized: "未能恢复系统蓝牙音频。请在蓝牙设置中重新连接耳机。"))
                        finish()
                    }
                }
                if finalized { return }
                if restoring && (children["restore"] == nil || children["restore"]?.finished == true) {
                    if let restore = children["restore"], restore.status != 0 || !nativeAudioRestored { fail("Ordinary Bluetooth audio could not be restored.", userMessage: String(localized: "未能恢复系统蓝牙音频。请在蓝牙设置中重新连接耳机。")) }
                    if !priorityRemovalFinished { continue }
                    finish()
                    return
                }
                if !restoring && children["disconnect"] == nil && children["connector"] == nil && children["probe"] == nil && shouldStop && children["preflight"]?.finished == true {
                    finish()
                    return
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private var captureDeviceArguments: [String] {
        ["--sample-rate", String(configuration.sampleRate.rawValue)] + (outputDeviceUID.map { ["--device-uid", $0] } ?? [])
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestedStop || failure != nil
    }

    private func launch(_ name: String, executable: URL, arguments: [String], pcm: Int32? = nil) throws {
        children[name] = try LDACNativeChild(executable: executable, arguments: arguments, inheritedPCM: pcm,
                                            blockStopSignals: name == "preflight" || name == "capture")
        record("LAUNCH \(name) \(arguments.joined(separator: " "))")
    }

    private func send(_ name: String, _ command: String) throws {
        guard let child = children[name], child.status == nil else { throw LDACSessionError("The \(name) audio helper exited before \(command).") }
        try child.send(command)
        record("COMMAND \(name) \(command)")
    }

    private func sendClosureAcknowledgment(_ name: String, _ command: String) throws -> Bool {
        if children[name]?.status != nil { return false }
        do {
            try send(name, command)
            return true
        } catch let error as POSIXError where error.code == .EPIPE {
            return false
        }
    }

    private func handle(_ source: String, line: String) throws {
        if source != "daemon" && !line.hasPrefix("SEND ") && !line.hasPrefix("DRAIN ") && !line.hasPrefix("RX ") {
            record("\(source) \(line)")
        }
        if (source == "probe" || source == "media") &&
            (line.hasPrefix("OPEN_CANCELLATION_UNCONFIRMED ") || line.hasPrefix("OPEN_TERMINAL_UNCONFIRMED ") || line.hasPrefix("OPEN_CLOSE_UNCONFIRMED ")) {
            unverifiedAcquisitions.insert(source)
        }
        if source == "preflight" {
            if line.hasPrefix("AUDIO_PERMISSION_ALLOWED") {
                guard let values = LDACChannelGate.captures("^AUDIO_PERMISSION_ALLOWED cleanup=1 callbacks=([0-9]+)$", line),
                      let callbacks = UInt64(values[0]), callbacks > 0 else {
                    throw LDACSessionError(String(localized: "未能检查系统音频录制权限，请重试。"))
                }
                preflightReady = true
            } else if line.hasPrefix("AUDIO_PERMISSION_DENIED ") {
                capturePermissionDenied()
            } else if line.hasPrefix("AUDIO_PERMISSION_FAILED") {
                if !shouldStop || LDACChannelGate.captures("^AUDIO_PERMISSION_FAILED cleanup=1 callbacks=([0-9]+) error=0 interrupted=(?:\(SIGINT)|\(SIGTERM))$", line) == nil {
                    failForUser(String(localized: "未能检查系统音频录制权限，请重试。"))
                }
            }
        } else if source == "daemon" {
            if line.contains("Must be admin to run 'stream' command") {
                failForUser(String(localized: "当前蓝牙日志接口需要 macOS 管理员账户。"))
                return
            }
            guard line.hasPrefix("Filtering the log data") || line.hasPrefix("Timestamp") ||
                  Self.daemonEventExpression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return }
            if let values = LDACChannelGate.captures("(?:connectedCB cid:0x|l2capDisconnected for CID: 0x|l2capDataInd for CID: 0x)([0-9a-f]+)\\b", line),
               let cid = Int(values[0], radix: 16), signalingGate.cid == nil || mediaGate.cid == nil || cid == signalingGate.cid || cid == mediaGate.cid {
                record("daemon \(line)")
            }
            try signalingGate.daemon(line)
            try mediaGate.daemon(line)
            if active, !shouldStop, signalingGate.closed || mediaGate.closed {
                connectionLost("The LDAC Bluetooth connection ended.")
            }
            if !loggerReady && (line.hasPrefix("Filtering the log data") || line.hasPrefix("Timestamp")) {
                loggerReady = true
                if !shouldStop {
                    try launch("disconnect", executable: helpers.connection, arguments: ["--address", address, "--disconnect"])
                    deadline = DispatchTime.now() + 45
                }
            }
            if children["connector"] != nil && !connected &&
                LDACChannelGate.captures("ACL connected: \(LDACChannelGate.addressPattern(address)), result (0)\\b", line) != nil {
                connected = true
                signalingGate = LDACChannelGate()
                mediaGate = LDACChannelGate()
                record("FRESH_ACL \(line)")
                if !shouldStop {
                    try send("probe", "acl-ready")
                    if !configuration.probeOnly { try send("media", "prepare") }
                    emit(.connecting)
                    deadline = DispatchTime.now() + 45
                }
            }
            if children["connector"] != nil, !restoring,
               let result = LDACChannelGate.captures("Received connection result for \"A2DP Source\" profile on device \(LDACChannelGate.addressPattern(address))(?:\\s+-\\s+|,\\s*|\\s+)result was (-?[0-9]+)\\b", line)?.first.flatMap(Int.init) {
                record("NATIVE_A2DP result=\(result) freshACL=\(connected) \(line)")
                if !shouldStop {
                    if result == 0 && signalingGate.cid == nil && !(configuration.probeOnly && capabilityQueryComplete) { failForUser("系统原生蓝牙音频抢先连接，请稍后重试检测或播放。", code: .deviceNotReady) }
                    else { nativeAudioFinished = true }
                }
            }
        } else if source == "connector" {
            pendingOpenCleanup.observeConnector(line)
            if pendingOpenCleanup.originalACLDisconnected { originalConnectionEnded = true }
            if line.hasPrefix("CONNECT_READY") {
                guard !connectorReady,
                      let values = LDACChannelGate.captures("^CONNECT_READY handle=([0-9A-Fa-f]{4}) guarded=1$", line),
                      let handle = Int(values[0], radix: 16), handle != 0xFFFF else {
                    throw LDACSessionError("The paired Bluetooth audio connection reported invalid readiness.")
                }
                connectorReady = true
                connectorHandle = handle
                if configuration.probeOnly && capabilityQueryComplete { stop() }
            } else if connectorReady && (line == "CONNECT_RETIRED reason=original-connection-ended" ||
                LDACChannelGate.captures("^CONNECTION_DISCONNECTED handle=([0-9A-Fa-f]{4}) connected=[01]$", line)?.first.flatMap({ Int($0, radix: 16) }) == connectorHandle) {
                originalConnectionEnded = true
                connectorSettled = true
                if !shouldStop { connectionLost("The paired Bluetooth audio connection ended.") }
            }
            if line.hasPrefix("CONNECT_DISARMED explicit=1 ") || line.hasPrefix("CONNECT_CANCELED ") &&
                (line.contains("settled=1") || line.contains("retired=1")) {
                connectorSettled = true
            }
            if recoveryAttempt, !shouldStop,
               let values = LDACChannelGate.captures("^AFTER callback=1 status=0x([0-9A-Fa-f]{8}) connected=0$", line),
               let status = UInt32(values[0], radix: 16), status != 0 {
                connectorSettled = true
                connectionLost("The headphones are still unavailable. LDAC will reconnect when they return.")
            }
            if line.hasPrefix("CONNECT_CANCELLATION_UNCONFIRMED ") || line.hasPrefix("CONNECT_TERMINAL_UNCONFIRMED ") {
                connectorSettlementUnverified = true
                fail("The pending Bluetooth connection could not be confirmed stopped.")
            }
        } else if source == "restore-disconnect" {
            // Display-only progress; protocol completion still uses exact terminal markers.
            if line.hasPrefix("RESTORE_STATE phase=wait-disconnect ") || line.hasPrefix("RESTORE_STATE phase=close ") {
                stopPhase(.disconnect)
            }
            if LDACChannelGate.captures("^BEFORE time=[0-9.]+ address=\(LDACChannelGate.addressPattern(address.replacingOccurrences(of: ":", with: "-"))) paired=[01] connected=(0)$", line) != nil {
                targetUnavailableBeforeRestore = true
            }
            if line == "RESTORE_DISCONNECTED disconnected=1" { restoreDisconnected = true }
            if line == "RESTORE_PRESERVED native=1 connected=1" { nativeAudioRestored = true }
        } else if source == "restore" {
            if line == "RESTORE_CONNECTED native=1 connected=1" ||
                line == "RESTORE_PRESERVED native=1 connected=1" { nativeAudioRestored = true }
        } else if source == "probe" {
            if line == "SIGNAL_PREPARED awaitingFreshACL=1" { signalingPrepared = true }
            if line.hasPrefix("WAIT_CONTROL media-prepared ") { signalingAwaitingMediaPreparation = true }
            if line.hasPrefix("WAIT_CONTROL media-ready ") { signalingAwaitingMediaReadiness = true }
            if let values = LDACChannelGate.captures("^CAPABILITY SEID=([0-9]+) category=7 bytes=([0-9A-F ]+)$", line), let endpoint = Int(values[0]) {
                let bytes = values[1].split(separator: " ").compactMap { UInt8($0, radix: 16) }
                do {
                    let cap = try CapabilityParser.codec(endpoint: endpoint, bytes: bytes)
                    reportedCapabilities.removeAll { $0.endpoint == endpoint }; reportedCapabilities.append(cap)
                    emit(.capability(cap))
                }
                catch { emit(.telemetry("CAPABILITY_PARSE_FAILED endpoint=\(endpoint) reason=\(error.localizedDescription)")) }
            }
            if line.hasPrefix("ENDPOINT_QUERY_FAILED ") { emit(.telemetry(line)) }
            if configuration.probeOnly,
               let values = LDACChannelGate.captures("^CAPABILITIES_COMPLETE queried=([0-9]+) succeeded=([0-9]+)$", line),
               let queried = Int(values[0]), let succeeded = Int(values[1]), succeeded <= queried, queried <= 62 {
                signalingStopConfirmed = true
                capabilityQueryComplete = true
                emit(.probeComplete(queried: queried, succeeded: succeeded))
                if connectorReady { stop() }
            }

            if line == "STOP_COMPLETE protocolCleanup=1", lock.withLock({ requestedStop }) {
                signalingStopConfirmed = true
            }
            try signalingGate.owned(line)
            if signalingGate.cid == nil, !shouldStop,
               LDACChannelGate.captures("^NO_PLAYBACK realCID=0000 owned=(?:0x0|\\(nil\\)) openExpired=[01] openError=(-?[0-9]+)$", line) != nil {
                failForUser("未能建立 " + configuration.codec.title + " 的蓝牙信令通道，尚未开始编码协商。请稍后重试。", code: .signalingUnavailable)
            } else if line == "LDAC_UNAVAILABLE rate=\(configuration.sampleRate.rawValue) channels=2" && !shouldStop {
                let refreshed = reportedCapabilities.first { $0.codec == configuration.codec && $0.playable }
                let changed = !configuration.isForced && refreshed.flatMap { try? $0.supportedContinuation(from: configuration) }.map { $0 != configuration } == true
                failForUser(String(localized: "耳机当前未提供所选编码的兼容配置。请检查耳机的音频设置后重新检测。"), code: changed ? .capabilitiesChanged : nil)
            } else if !shouldStop, let rejected = LDACChannelGate.captures("^RESPONSE_REJECTED transaction=[0-9]+ signal=(03|06|07) error=([0-9A-Fa-f]{2})$", line) {
                let forced = configuration.isForced ? "强制参数" : "所选参数"
                failForUser("耳机拒绝了\(forced)（AVDTP \(rejected[0])，错误 0x\(rejected[1])）；已停止，不会自动降低参数。请选择耳机报告的档位后重试。")
            } else if line == "PREPARE_MEDIA" && !shouldStop {
                guard children["media"] != nil && mediaWaitingForACL else {
                    throw LDACSessionError("The media helper was not prepared before Bluetooth handoff.")
                }
            } else if line.hasPrefix("OPEN_ACCEPTED") && !shouldStop {
                try send("media", "open")
            } else if line.hasPrefix("START_ACCEPTED") && !shouldStop {
                guard readySent, !startAccepted, !mediaCloseSent else { throw LDACSessionError("LDAC Start arrived without independent live media readiness.") }
                startAccepted = true
                if let priority {
                    priorityPhase = .configuring
                    deadline = DispatchTime.now() + 45
                    record("PRIORITY_CONFIGURE_REQUESTED")
                    try priority.request(true, false)
                }
            } else if !shouldStop, line == "PEER_COMMAND_UNSUPPORTED" || line.hasPrefix("CONTROL_FAILED ") {
                if active { connectionLost("The LDAC Bluetooth connection ended.") }
                else { failForUser(String(localized: "蓝牙音频连接未能完成配置，请重试。")) }
            } else if line.hasPrefix("STREAM_CLOSED") || line.hasPrefix("MEDIA_CLOSE_REQUIRED") {
                mediaCloseRequired = true
                if !shouldStop { connectionLost("The LDAC Bluetooth connection ended.") }
            } else if line == "WAIT_MEDIA_CLOSED" {
                waitingMediaClosed = true
            } else if line.hasPrefix("WAIT_TRANSPORT_CLOSED") {
                waitingSignalingClosed = true
            }
        } else if source == "media" {
            if line == "MEDIA_WAITING_FOR_ACL" { mediaWaitingForACL = true }
            if line == "OPEN_FAILED_TERMINAL no established channel to close", !shouldStop {
                failForUser("未能建立 " + configuration.codec.title + " 的蓝牙媒体通道，尚未开始发送音频。请稍后重试。")
            }
            if line.hasPrefix("LIVE_PROGRESS ") || line.hasPrefix("SOCKET ") || line.hasPrefix("SENDER_WINDOW ") { emit(.telemetry(line)) }
            if line == "PCM_STOP_READY started=0", mediaStopSent, !started, shouldStop { mediaStopReady = true }
            if line == "MEDIA_PREPARED" { mediaPrepared = true }
            if line.hasPrefix("READY ") {
                guard mediaReady == nil,
                      let values = LDACChannelGate.captures("^READY CID=([0-9A-Fa-f]+) outgoingMTU=([0-9]+) ", line),
                      let cid = Int(values[0], radix: 16), let mtu = Int(values[1]),
                      cid != signalingGate.cid else { throw LDACSessionError("The media helper reported invalid or repeated channel readiness.") }
                mediaReady = (cid, mtu)
                try mediaGate.owned("OWNED_CHANNEL CID=\(String(cid, radix: 16))")
                guard LDACChannelGate.captures("^READY CID=[0-9A-Fa-f]+ outgoingMTU=[0-9]+ socketFD=[0-9]+ PSM=0019 rate=\(configuration.sampleRate.rawValue) channels=2 bitrateKbps=\(configuration.bitrateKbps) eqmid=\(configuration.quality.encoderMode)$", line) != nil else {
                    throw LDACSessionError(String(localized: "耳机未按所选音频格式启动，当前会话已停止。"))
                }
            } else if line.hasPrefix("PCM_READY ") {
                let prefill = configuration.bufferingSettings.prefillFrames(rate: configuration.sampleRate.rawValue)
                let capacity = configuration.bufferingSettings.storageFrames(rate: configuration.sampleRate.rawValue)
                guard !pcmReady,
                      let values = LDACChannelGate.captures("^PCM_READY frames=\(prefill) rate=\(configuration.sampleRate.rawValue) channels=2 format=F32(?: bufferedFrames=([0-9]+))?$", line),
                      values[0].isEmpty || (prefill...capacity).contains(Int(values[0]) ?? -1) else {
                    throw LDACSessionError("Live PCM prefill did not match the verified format.")
                }
                pcmReady = true
            } else if line.hasPrefix("LIVE_SENT ") {
                guard line == "LIVE_SENT packets=1 rate=\(configuration.sampleRate.rawValue) channels=2 bitrateKbps=\(configuration.bitrateKbps) eqmid=\(configuration.quality.encoderMode)" else {
                    throw LDACSessionError(String(localized: "耳机未按所选音频格式启动，当前会话已停止。"))
                }
                guard started, readySent, captureReady, pcmReady, !active,
                      signalingGate.opened, !signalingGate.closed, mediaGate.opened, !mediaGate.closed else {
                    throw LDACSessionError("Live LDAC transmission was reported outside its owned channel lifetime.")
                }
                active = true
                deadline = .distantFuture
                if !shouldStop { emit(.active(configuration.format)) }
            } else if line.hasPrefix("LHDC_FORMAT ") {
                guard configuration.codec == .lhdcV5, active,
                      let values = LDACChannelGate.captures("^LHDC_FORMAT rate=\(configuration.sampleRate.rawValue) channels=2 bitrateKbps=([0-9]+) bits=\(configuration.bits)$", line),
                      let bitrate = Int(values[0]), (32...1100).contains(bitrate) else { throw LDACSessionError("LHDC 编码器报告了无效格式") }
                if !shouldStop { emit(.formatChanged(LDACFormat(sampleRateHz: configuration.sampleRate.rawValue, bitrateKbps: bitrate, channels: 2))) }
            } else if line.hasPrefix("LIVE_FORMAT ") {
                let rate = configuration.sampleRate.rawValue
                let frameSamples = rate > 48000 ? 256 : 128
                guard configuration.quality == .adaptive, active,
                      let values = LDACChannelGate.captures("^LIVE_FORMAT rate=\(rate) channels=2 bitrateKbps=([0-9]+) frameBytes=([0-9]+)$", line),
                      let bitrate = Int(values[0]), let frameBytes = Int(values[1]),
                      (49...330).contains(frameBytes), bitrate == frameBytes * 8 * rate / frameSamples / 1000 else {
                    throw LDACSessionError(String(localized: "编码器报告了无效音频格式，当前会话已停止。"))
                }
                if !shouldStop { emit(.formatChanged(LDACFormat(sampleRateHz: rate, bitrateKbps: bitrate, channels: 2))) }
            } else if line.hasPrefix("BUFFERING_APPLIED ") {
                guard let pending = awaitingBuffering,
                      line == "BUFFERING_APPLIED request=\(pending.0.uuidString) catchupLimitMs=\(pending.1.catchupLimitTenths * 100) prefillMs=\(pending.1.prefillMilliseconds)" else {
                    throw LDACSessionError("Live buffering acknowledgment did not match the request.")
                }
                awaitingBuffering = nil
                if !shouldStop { emit(.bufferingApplied(pending.0, pending.1)) }
            } else if let values = LDACChannelGate.captures("^GAIN_APPLIED gain=([0-9.eE+-]+)$", line),
                      let applied = Double(values[0]), applied.isFinite, (0...1).contains(applied) {
                emit(.gainApplied(applied))
            } else if line.hasPrefix("DRAIN_LIMIT "), active, !shouldStop {
                connectionLost("The Bluetooth connection stalled. LDAC will reconnect.")
            } else if line.hasPrefix("ENCODER_FAILED ") {
                fail("Live LDAC transmission ended with an error.")
            } else if line.hasPrefix("FEED_COMPLETE ") {
                feedFinished = true
                if active, !shouldStop, line.range(of: "\\bclosed=1\\b", options: .regularExpression) != nil {
                    connectionLost("The LDAC Bluetooth connection ended.")
                }
                guard line.range(of: "\\bresult=0\\b", options: .regularExpression) != nil else {
                    if recoverableFailure { return }
                    throw LDACSessionError("Live LDAC transmission ended with an error.")
                }
                if !shouldStop { throw LDACSessionError("The live LDAC stream ended unexpectedly.") }
            } else if line.hasPrefix("WAIT_TRANSPORT_CLOSED") {
                waitingMediaTransportClosed = true
            } else if line.hasPrefix("PCM_FAILED ") {
                if let values = LDACChannelGate.captures("^PCM_FAILED reason=lhdc-MTU required=([0-9]+) actual=([0-9]+)$", line) {
                    failForUser("当前 LHDC 参数要求至少 \(values[0]) 字节的媒体 MTU，连接只提供 \(values[1]) 字节。", code: .mediaMTU)
                } else {
                    fail(line)
                }
            }
        } else if source == "capture" {
            if line.hasPrefix("FORMAT ") || line.hasPrefix("PCM_RATE_CONVERSION ") || line.hasPrefix("PCM_CAPTURE_READY ") { emit(.telemetry(line)) }
            if line == "SET_SELF_EXCLUSION status=560492391" || line.hasPrefix("AUDIO_PERMISSION_DENIED ") {
                capturePermissionDenied()
            }
            if line.hasPrefix("PCM_CAPTURE_READY ") {
                guard !captureReady, line == "PCM_CAPTURE_READY rate=\(configuration.sampleRate.rawValue) channels=2 format=F32 interleaved=1 bytesPerFrame=8" else {
                    throw LDACSessionError("System audio capture did not match the verified format.")
                }
                captureReady = true
            }
            if line == "DESTROY_TAP status=0" { captureDestroyed = true }
            if !started, shouldStop,
               LDACChannelGate.captures("^PCM_CAPTURE_CANCELLED cleanup=1 error=0 interrupted=(\(SIGINT)|\(SIGTERM))$", line) != nil {
                captureCancelledBeforeStream = true
            }
        }
    }

    private func advance() throws {
        let pendingPriority = lock.withLock {
            let pending = pendingPriorityObservation
            pendingPriorityObservation = nil
            return pending
        }
        if let pendingPriority, priorityObservation == nil {
            priorityObservation = pendingPriority
            priorityObservationDeadline = DispatchTime.now() + 5
            record("PRIORITY_OBSERVATION_PENDING \(pendingPriority)")
        }
        let recoveryReason = lock.withLock {
            let reason = self.recoveryReason
            self.recoveryReason = nil
            return reason
        }
        if let recoveryReason { connectionLost(recoveryReason) }
        if lock.withLock({ requestedStop }) { priorityObservation = nil }
        if let observation = priorityObservation {
            if recoverableFailure {
                priorityObservation = nil
            } else if originalConnectionEnded {
                priorityObservation = nil
                connectionLost(observation)
            } else if DispatchTime.now() >= priorityObservationDeadline {
                priorityObservation = nil
                fail(observation)
            }
        }
        if shutdownChecked {
            let name = children["restore"] == nil ? "restore-disconnect" : "restore"
            if let child = children[name], !child.finished, DispatchTime.now() >= restoreDeadline {
                child.closeInput()
                child.signal(restoreTerminationSent ? SIGKILL : SIGTERM)
                record("RESTORE_TERMINATION helper=\(name) signal=\(restoreTerminationSent ? "SIGKILL" : "SIGTERM") restorationVerified=0")
                fail("Ordinary Bluetooth audio restoration timed out during \(name == "restore" ? "reconnection" : "disconnection").", userMessage: String(localized: "未能恢复系统蓝牙音频。请在蓝牙设置中重新连接耳机。"))
                restoreDeadline = restoreTerminationSent ? .distantFuture : DispatchTime.now() + 2
                restoreTerminationSent = true
            }
            return
        }
        if !preflightCompleted, let preflight = children["preflight"] {
            if !shouldStop && DispatchTime.now() >= deadline {
                failForUser(String(localized: "尚未确认系统音频录制权限，请检查系统设置后重试。"))
            }
            if shouldStop {
                if preflight.status == nil && !preflightStopSent {
                    preflight.signal(SIGTERM)
                    preflightStopSent = true
                    preflightStopDeadline = DispatchTime.now() + 5
                }
                if preflight.status == nil && DispatchTime.now() >= preflightStopDeadline {
                    preflight.signal(SIGKILL)
                    preflightStopDeadline = .distantFuture
                    failForUser(String(localized: "系统音频权限检查未能正常结束。"))
                }
                return
            }
            guard preflight.finished else { return }
            guard preflight.status == 0 && preflightReady else {
                failForUser(String(localized: "未能检查系统音频录制权限，请重试。"))
                return
            }
            preflightCompleted = true
            emit(.audioCaptureAccess(.ready))
            deadline = DispatchTime.now() + 10
        }
        if preflightCompleted, children["daemon"] == nil, !shouldStop {
            lock.lock()
            let allowed = handoffAllowed || outputDeviceUID == nil
            lock.unlock()
            if !allowed {
                if !handoffRequested { handoffRequested = true; emit(.handoffReady) }
                if DispatchTime.now() >= deadline { throw LDACSessionError("The silent LDAC output could not be selected before Bluetooth handoff.") }
                return
            }
            try launch("daemon", executable: helpers.logger, arguments: [
                "stream", "--style", "syslog", "--level", "info", "--predicate",
                Self.daemonPredicate
            ])
            deadline = DispatchTime.now() + 5
        }
        if children["daemon"]?.outputEnded == true && !daemonLost {
            daemonLost = true
            fail("Bluetooth logging ended before LDAC was stopped.")
        }
        if !shouldStop, let disconnect = children["disconnect"], disconnect.finished, children["connector"] == nil {
            guard disconnect.status == 0 else {
                failForUser("耳机尚未退出系统蓝牙音频连接，请稍后重试。",
                            code: disconnect.exitCode == 4 ? .deviceNotReady : nil)
                return
            }
            if children["probe"] == nil {
                guard let rawURL else { throw LDACSessionError("能力报文文件不可用") }
                try launch("probe", executable: helpers.signaling, arguments: [configuration.probeOnly ? "--capabilities-disconnected" : "--playback-disconnected", rawURL.path, "--address", address, "--await-acl"] + (configuration.probeOnly ? [] : ["--continuous"]) + configuration.signalingArguments)
                if !configuration.probeOnly {
                    var descriptors: [Int32] = [0, 0]
                    guard pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    pcmRead = descriptors[0]; pcmWrite = descriptors[1]
                    try launch("media", executable: helpers.media, arguments: ["--media", "--await-prepare", "--pcm-fd", "3", "--address", address] + configuration.mediaArguments, pcm: pcmRead)
                    Darwin.close(pcmRead); pcmRead = -1
                }
                deadline = DispatchTime.now() + 45
            }
            for name in ["probe", "media"] {
                if let helper = children[name], helper.finished || helper.outputEnded {
                    throw LDACSessionError("The \(name) helper exited before Bluetooth connection.")
                }
            }
            if !signalingPrepared || (!configuration.probeOnly && !mediaWaitingForACL) {
                if DispatchTime.now() >= deadline { throw LDACSessionError("Bluetooth helpers did not prepare before connection.") }
                return
            }
            if !shouldStop {
                nativeAudioFinished = false
                let priorityArguments = priority != nil ? (outputDeviceUID.map { ["--priority-device-uid", $0] } ?? []) : []
                try launch("connector", executable: helpers.connection, arguments: ["--address", address, "--watch-parent"] + priorityArguments)
                deadline = DispatchTime.now() + 45
            }
        }
        if !shouldStop {
            if let connector = children["connector"], connector.finished || connector.outputEnded {
                throw LDACSessionError("The paired Bluetooth audio connection failed.")
            }
            // The owned signaling channel already proves ACL readiness. Waiting
            // for openConnection's profile-completion callback gives native AAC
            // time to occupy the receiver before our SetConfiguration/Open.
            if mediaPrepared && signalingAwaitingMediaPreparation && !preparedSent && signalingGate.opened {
                try send("probe", "media-prepared")
                preparedSent = true
            }
            if let ready = mediaReady, mediaGate.opened, !readySent {
                guard !mediaGate.closed, mediaGate.mtu == ready.mtu else { throw LDACSessionError("The media channel disagreed with its Bluetooth daemon ownership evidence.") }
                if children["capture"] == nil {
                    try launch("capture", executable: helpers.capture, arguments: ["--stream", "3", "0"] + captureDeviceArguments, pcm: pcmWrite)
                    Darwin.close(pcmWrite)
                    pcmWrite = -1
                    deadline = DispatchTime.now() + 5
                }
                if captureReady && pcmReady && signalingAwaitingMediaReadiness {
                    try send("probe", "media-ready \(String(ready.cid, radix: 16)) \(ready.mtu)")
                    readySent = true
                    deadline = DispatchTime.now() + 30
                }
            }
            if DispatchTime.now() >= deadline { throw LDACSessionError("LDAC did not complete its required connection or live audio readiness checks.") }
            if startAccepted && !started {
                if let priority {
                    let state = try priority.state()
                    let diagnostic = "phase=\(state.phase) failureCode=\(state.failureCode ?? "none") error=\(state.error ?? "none") \(state.diagnostics ?? "diagnostics=unavailable")"
                    if diagnostic != lastPriorityDiagnostic {
                        lastPriorityDiagnostic = diagnostic
                        record("PRIORITY_START_STATE \(diagnostic)")
                    }
                    if let code = state.startupFailure {
                        failForUser("系统未能提供耳机的音频配置状态，尚未开始发送音频。", code: code)
                        return
                    }
                    if let error = state.error { throw LDACSessionError(error) }
                    guard state.phase == "configuring" || state.phase == "configured" else {
                        throw LDACSessionError("Bluetooth could not configure LDAC playback priority. Try LDAC again.")
                    }
                    if state.phase == "configured" {
                        priorityPhase = .configured
                        record("PRIORITY_CONFIGURATION_ATTEMPT_COMPLETED controllerAcknowledgment=0")
                    }
                }
                if priority == nil || priorityPhase == .configured {
                    started = true
                    try send("media", "start live \(gain) 0")
                    deadline = DispatchTime.now() + 10
                }
            }
            for name in ["daemon", "probe", "media", "capture"] {
                if name == "probe", configuration.probeOnly, capabilityQueryComplete { continue }
                if children[name]?.finished == true { throw LDACSessionError("The \(name) audio helper exited before LDAC was stopped.") }
            }
        }
        lock.lock()
        let changedGain = requestedGain
        requestedGain = nil
        let changedBuffering = requestedBuffering
        requestedBuffering = nil
        lock.unlock()
        if let (requestID, settings) = changedBuffering, started && !shouldStop {
            awaitingBuffering = (requestID, settings)
            try send("media", "buffering \(requestID.uuidString) \(settings.catchupLimitTenths * 100) \(settings.prefillMilliseconds)")
        }
        if let changedGain {
            gain = changedGain
            if started && !shouldStop { try send("media", "gain \(gain)") }
        }
        for length in signalingGate.takeLengths() {
            if let probe = children["probe"], probe.status == nil { try send("probe", "0x\(String(signalingGate.cid!, radix: 16)) \(length)") }
        }
        _ = mediaGate.takeLengths()
        if shouldStop {
            if ["probe", "media", "capture"].allSatisfy({ children[$0] == nil || children[$0]?.finished == true }),
               let connector = children["connector"], !connector.finished {
                if !connectorStopSent {
                    if !connectorSettled {
                        do { try send("connector", "disarm") }
                        catch { fail("The Bluetooth connection guardian could not be disarmed: \(error.localizedDescription)") }
                    }
                    connector.closeInput()
                    connectorStopSent = true
                    connectorStopDeadline = DispatchTime.now() + 3
                    record("CONNECTOR_INPUT_CLOSED")
                }
                if connector.status == nil && DispatchTime.now() >= connectorStopDeadline {
                    connector.signal(connectorTerminationSent ? SIGKILL : SIGTERM)
                    record("CONNECTOR_TERMINATION signal=\(connectorTerminationSent ? "SIGKILL" : "SIGTERM") settlementVerified=0")
                    connectorStopDeadline = connectorTerminationSent ? .distantFuture : DispatchTime.now() + 1
                    connectorTerminationSent = true
                    connectorSettlementUnverified = true
                    fail("The pending Bluetooth connection could not be confirmed stopped.")
                }
            }
            if (started || children["capture"] != nil) && !mediaStopSent, let media = children["media"], media.status == nil {
                mediaStopSent = true
                mediaStopDeadline = DispatchTime.now() + 5
                if daemonLost { try? send("media", "stop") }
                else { try send("media", "stop") }
            }
            if mediaStopSent, !feedFinished, !mediaStopReady, let media = children["media"], media.status == nil,
               DispatchTime.now() >= mediaStopDeadline {
                media.signal(SIGKILL)
                mediaStopDeadline = .distantFuture
                fail("The LDAC audio stream did not stop within five seconds.")
            }
            if !started || feedFinished || children["media"]?.finished == true {
                advancePriorityStop()
            }
            let canStopCapture = started ? feedFinished || failure != nil
                : children["media"] == nil || mediaStopReady || children["media"]?.finished == true
            if canStopCapture && !captureStopSent, let capture = children["capture"], capture.status == nil {
                capture.signal(SIGTERM)
                captureStopSent = true
                captureStopDeadline = DispatchTime.now() + 5
            }
            if captureStopSent, let capture = children["capture"], capture.status == nil, DispatchTime.now() >= captureStopDeadline {
                capture.signal(SIGKILL)
                captureStopDeadline = .distantFuture
                fail("System audio capture did not finish its tap cleanup within five seconds.")
            }
            if children["capture"] == nil || children["capture"]?.finished == true {
                if !captureStoppedCleanly {
                    fail("System audio capture could not confirm clean tap destruction.")
                }
                if !daemonLost && priorityCanClose && ownerExitDeadline == .distantFuture && !ownerInputsClosed {
                    ownerExitDeadline = DispatchTime.now() + 10
                }
                if daemonLost || ownerInputsClosed || DispatchTime.now() >= ownerExitDeadline {
                    if priorityPhase != .unused && priorityPhase != .removed && priorityPhase != .uncertain {
                        priorityCleanupFailed("Bluetooth disconnected before playback priority cleanup could be confirmed.")
                    }
                    if !ownerInputsClosed {
                        if !daemonLost { fail("Bluetooth did not confirm LDAC transport shutdown within ten seconds.") }
                        if !connectorStopSent, children["connector"]?.status == nil {
                            try? send("connector", "disarm")
                        }
                        for name in ["disconnect", "connector", "probe", "media"] { children[name]?.closeInput() }
                        ownerInputsClosed = true
                        ownerExitDeadline = DispatchTime.now() + 10
                        record("OWNER_INPUTS_CLOSED reason=\(daemonLost ? "daemon-log-ended" : "shutdown-timeout") closureVerified=0")
                    }
                    if DispatchTime.now() >= ownerExitDeadline {
                        for name in ["disconnect", "connector", "probe", "media"] {
                            children[name]?.signal(ownerTerminationSent ? SIGKILL : SIGTERM)
                        }
                        record("OWNER_TERMINATION signal=\(ownerTerminationSent ? "SIGKILL" : "SIGTERM") closureVerified=0")
                        ownerExitDeadline = ownerTerminationSent ? .distantFuture : DispatchTime.now() + 2
                        ownerTerminationSent = true
                    }
                    return
                }
                if priorityCanClose && !signalingStopSent, let probe = children["probe"], probe.status == nil {
                    try send("probe", failure == nil && feedFinished ? "media-finished" : "stop")
                    signalingStopSent = true
                }
                if priorityCanClose && mediaCloseRequired && !mediaCloseSent, let media = children["media"], media.status == nil {
                    try send("media", "close")
                    mediaCloseSent = true
                }
            }
        }
        if waitingMediaTransportClosed && mediaGate.closed && !mediaTransportClosedSent {
            mediaTransportClosedSent = try sendClosureAcknowledgment("media", "transport-closed")
        }
        if waitingMediaClosed && !mediaClosedSent && (children["media"] == nil || children["media"]?.finished == true) {
            mediaClosedSent = try sendClosureAcknowledgment("probe", "media-closed")
        }
        if waitingSignalingClosed && signalingGate.closed && !signalingClosedSent {
            signalingClosedSent = try sendClosureAcknowledgment("probe", "transport-closed")
        }
        if priorityCanClose, children["probe"]?.finished == true, let media = children["media"], media.status == nil, !mediaCloseSent {
            if children["capture"] == nil || children["capture"]?.finished == true {
                try send("media", "close")
                mediaCloseSent = true
            }
        }
    }

    private var captureStoppedCleanly: Bool {
        guard let capture = children["capture"] else { return true }
        return captureDestroyed && (capture.status == 0 || capture.exitCode == 1 && captureCancelledBeforeStream)
    }

    private var canRestore: Bool {
        !restoring && shouldStop && priorityCanClose && ["preflight", "disconnect", "connector", "probe", "media", "capture"].allSatisfy {
            children[$0] == nil || children[$0]?.finished == true
        }
    }

    private var priorityCanClose: Bool {
        priorityPhase == .unused || priorityPhase == .removed || priorityPhase == .uncertain
    }

    private func advancePriorityStop() {
        guard let priority, priorityPhase == .configuring || priorityPhase == .configured || priorityPhase == .stopping else { return }
        do {
            if priorityPhase != .stopping {
                priorityPhase = .stopping
                priorityDeadline = DispatchTime.now() + 45
                record("PRIORITY_STOP_REQUESTED feedFinished=\(feedFinished) mediaExited=\(children["media"]?.finished == true)")
                try priority.request(false, false)
            }
            let state = try priority.state()
            if let error = state.error { throw LDACSessionError(error) }
            if state.phase == "idle" {
                priorityPhase = .removed
                record("PRIORITY_CLEANUP_ATTEMPT_COMPLETED controllerAcknowledgment=0")
            } else if state.phase == "cleanup-required" || DispatchTime.now() >= priorityDeadline {
                throw LDACSessionError("Bluetooth playback priority cleanup could not be confirmed.")
            }
        } catch {
            priorityCleanupFailed(error.localizedDescription)
        }
    }

    private func priorityCleanupFailed(_ message: String) {
        priorityPhase = .uncertain
        record("PRIORITY_CLEANUP_UNCONFIRMED \(message)")
        if recoverableFailure || lock.withLock({ requestedStop }) { priorityRecoveryFailure = message }
        else { fail(message) }
    }

    private var priorityRemovalFinished: Bool {
        guard let priority, priorityPhase == .removing else { return true }
        do {
            let state = try priority.state()
            if state.phase == "idle" {
                priorityPhase = .removed
                record("PRIORITY_REMOVAL_COMPLETED oldACLDisconnected=1")
                return true
            }
            if let error = state.error { throw LDACSessionError(error) }
            if DispatchTime.now() >= priorityDeadline {
                throw LDACSessionError("Bluetooth playback priority cleanup is still pending after reconnection.")
            }
            return false
        } catch {
            priorityCleanupFailed(error.localizedDescription)
            return true
        }
    }

    private func stopPhase(_ phase: AudioStopPhase) {
        guard phase != lastStopPhase else { return }
        lastStopPhase = phase; record("STOP_PHASE phase=\(phase.rawValue)"); emit(.stopPhase(phase))
    }
    private func beginRestore() throws {
        if !shutdownChecked {
            shutdownChecked = true
            if children["probe"] != nil {
                // A missing open callback cannot leave a channel on an ACL that
                // the connector explicitly observed ending. Both owners must
                // have exited, and this exception never covers an acquired CID.
                for source in unverifiedAcquisitions.sorted() {
                    let cid = source == "probe" ? signalingGate.cid : mediaGate.cid
                    if pendingOpenCleanup.canRetire(acquiredCID: cid,
                        helperExited: children[source]?.finished == true,
                        connectorExitedCleanly: children["connector"]?.status == 0 && connectorSettled && !connectorSettlementUnverified) {
                        unverifiedAcquisitions.remove(source)
                        record("OPEN_RETIRED helper=\(source) originalACLDisconnected=1 ownersExited=1 acquiredCID=none")
                    }
                }
                shutdownUnverified = (signalingGate.cid != nil && !signalingGate.closed) ||
                    (mediaGate.cid != nil && !mediaGate.closed) ||
                    (signalingGate.cid == nil && unverifiedAcquisitions.contains("probe")) ||
                    (mediaGate.cid == nil && unverifiedAcquisitions.contains("media"))
                if shutdownUnverified {
                    let message = "Bluetooth did not confirm closure of the owned LDAC channels."
                    record("SHUTDOWN_UNVERIFIED \(message)")
                    fail(message)
                }
                do {
                    if !shutdownUnverified, let rawURL, signalingGate.cid != nil {
                        let bytes = try Data(contentsOf: rawURL)
                        try signalingGate.reconcile(bytes.count)
                    }
                } catch {
                    record("SHUTDOWN_ERROR \(error.localizedDescription)")
                    fail(error.localizedDescription)
                }
                let interruptedPlayback = recoverableFailure || (active || signalingStopConfirmed) && lock.withLock({ requestedStop })
                if (children["probe"]?.status != 0 && !(interruptedPlayback && children["probe"]?.exitCode == 5)) || (children["media"] != nil && children["media"]?.status != 0 && !(interruptedPlayback && children["media"]?.exitCode == 5)) {
                    fail("The LDAC transport exited with an error.")
                }
            }
        }
        lock.lock()
        let restoreAudio = restoreAudio
        lock.unlock()
        let recover = lock.withLock { recoveryRequested }
        if !recover && !restoreAudio && (priorityPhase == .unused || priorityPhase == .removed) { restoring = true; finish(); return }
        if children["disconnect"] == nil { restoring = true; finish(); return }
        if !originalConnectionEnded {
            if children["restore-disconnect"] == nil {
                var arguments = ["--address", address, "--disconnect", "--restore"]
                // Only a clean, established stream may shorten passive publication
                // grace. Owned channel/connector exit and native restoration remain mandatory.
                let accelerate = lock.withLock { reconfigureRequested && requestedStop } &&
                    failure == nil && !hardFailure && active && !configuration.probeOnly &&
                    !shutdownUnverified && unverifiedAcquisitions.isEmpty && captureStoppedCleanly &&
                    connectorReady && connectorSettled && !connectorSettlementUnverified &&
                    children["connector"]?.status == 0 && connectorHandle != nil && priorityPhase == .removed
                if accelerate { arguments.append("--reconfigure") }
                record("RESTORE_POLICY reconfigure=\(accelerate) publicationGrace=\(accelerate ? 1 : 8) closureDeadlineNotShortened=1")
                stopPhase(.nativeOutput)
                if let connectorHandle { arguments += ["--expected-handle", String(format: "%04X", connectorHandle)] }
                try launch("restore-disconnect", executable: helpers.connection, arguments: arguments)
                // Helper: up to 5 s for its ownership lock, 18 s for bounded
                // publication/close settlement, plus process startup margin.
                restoreDeadline = DispatchTime.now() + 26
                restoreTerminationSent = false
            }
            guard let disconnect = children["restore-disconnect"], disconnect.finished else { return }
            guard disconnect.status == 0 && (restoreDisconnected || nativeAudioRestored) else {
                fail("Ordinary Bluetooth audio could not be prepared for restoration.", userMessage: String(localized: "未能恢复系统蓝牙音频。请在蓝牙设置中重新连接耳机。"))
                restoring = true
                finish()
                return
            }
            if nativeAudioRestored { restoring = true; finish(); return }
        }
        if let priority, priorityPhase != .unused && priorityPhase != .removed {
            priorityPhase = .removing
            priorityDeadline = DispatchTime.now() + 45
            record("PRIORITY_REMOVAL_REQUESTED oldACLDisconnected=1")
            do { try priority.request(false, true) }
            catch { priorityCleanupFailed(error.localizedDescription) }
        }
        if recover || !restoreAudio { restoring = true; return }
        stopPhase(.nativeOutput)
        try launch("restore", executable: helpers.connection, arguments: ["--address", address, "--restore"])
        restoreDeadline = DispatchTime.now() + 52
        restoreTerminationSent = false
        restoring = true
    }

    private func connectionLost(_ message: String) {
        guard failure == nil else { return }
        failure = message
        recoverableFailure = true
        lock.withLock { recoveryRequested = true }
        record("CONNECTION_LOST \(message)")
        emit(.connectionLost(String(localized: "耳机连接中断，请重新开始播放。")))
    }

    private var failureDescription: String {
        if (restoring || restoringOnly) && !nativeAudioRestored {
            return String(localized: "未能恢复系统蓝牙音频。请在蓝牙设置中重新连接耳机。")
        }
        if restoring || restoringOnly || lock.withLock({ requestedStop }) || captureStopSent || mediaStopSent {
            return String(localized: "音频会话未完全停止，请检查蓝牙连接和系统输出。")
        }
        return active ? String(localized: "音频播放意外停止，请重新开始。")
            : String(localized: "音频会话未能启动，请重试。")
    }

    private func fail(_ message: String, userMessage: String? = nil) {
        hardFailure = true
        if attentionFailure == nil {
            attentionFailure = message
            let description = userMessage ?? failureDescription
            publicFailureMessage = description
            record("FAILED \(message)")
            emit(.failed(description))
        }
        if failure == nil { failure = message }
    }

    private func failForUser(_ message: String, code: PlaybackFailureCode? = nil) {
        if attentionFailure == nil { playbackFailure = code }
        fail(message, userMessage: message)
    }

    private func capturePermissionDenied() {
        let message = LDACAudioCaptureAccess.permissionGuidance
        capturePermissionFailure = message
        record("CAPTURE_PERMISSION_FAILED \(message)")
        emit(.audioCaptureAccess(.permissionRequired))
        failForUser(message)
    }

    private func finish() {
        guard !finalized else { return }
        finalized = true
        if priorityPhase != .unused && priorityPhase != .removed {
            record("PRIORITY_CLEANUP_PENDING_AT_EXIT")
            fail("Bluetooth playback priority cleanup could not be confirmed.")
        }
        children["daemon"]?.signal(SIGTERM)
        children["daemon"]?.closeInput()
        for child in children.values { child.closeInput() }
        let loggerDeadline = DispatchTime.now() + 2
        while let daemon = children["daemon"], daemon.status == nil, DispatchTime.now() < loggerDeadline {
            daemon.reap()
            if daemon.status == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        if let daemon = children["daemon"], daemon.status == nil {
            daemon.signal(SIGKILL)
            daemon.wait()
            fail("The Bluetooth log observer did not stop cleanly.")
        }
        for (name, child) in children where child.status == nil {
            child.signal(SIGTERM)
            record("HELPER_TERMINATION helper=\(name) signal=SIGTERM")
        }
        let childDeadline = DispatchTime.now() + 2
        while children.values.contains(where: { $0.status == nil }), DispatchTime.now() < childDeadline {
            for child in children.values { child.reap() }
            if children.values.contains(where: { $0.status == nil }) { Thread.sleep(forTimeInterval: 0.01) }
        }
        for (name, child) in children where child.status == nil {
            child.signal(SIGKILL)
            child.wait()
            fail("The \(name) audio helper did not stop cleanly.")
        }
        if pcmRead >= 0 { Darwin.close(pcmRead); pcmRead = -1 }
        if pcmWrite >= 0 { Darwin.close(pcmWrite); pcmWrite = -1 }
        record("COMPLETE successful=\(failure == nil)")
        let primaryFailure = capturePermissionFailure ?? attentionFailure ?? (priorityPhase != .unused && priorityPhase != .removed ? priorityRecoveryFailure : nil) ?? failure
        var message = shutdownUnverified ? (primaryFailure ?? "LDAC stopped.") + " LDAC channel closure could not be verified." : primaryFailure
        if priorityPhase != .unused && priorityPhase != .removed,
           message?.contains("Bluetooth playback priority cleanup could not be confirmed.") != true {
            message = (message ?? "LDAC stopped.") + " Bluetooth playback priority cleanup could not be confirmed."
        }
        if connectorSettlementUnverified, message?.contains("The pending Bluetooth connection could not be confirmed stopped.") != true {
            message = (message ?? "LDAC stopped.") + " The pending Bluetooth connection could not be confirmed stopped."
        }
        let safe = recoverableFailure && !hardFailure
            && !shutdownUnverified && !connectorSettlementUnverified && unverifiedAcquisitions.isEmpty
            && (priorityPhase == .unused || priorityPhase == .removed)
            && captureStoppedCleanly
            && (children["connector"] == nil || connectorSettled && [0, 4].contains(children["connector"]?.exitCode ?? -1))
            && (children["disconnect"] == nil || children["disconnect"]?.status == 0)
            && (children["restore-disconnect"] == nil || children["restore-disconnect"]?.status == 0 && restoreDisconnected)
            && !nativeAudioRestored
            && (priorityRecoveryFailure == nil || originalConnectionEnded || restoreDisconnected)
        let nativeReplacement = recoverableFailure && nativeAudioRestored && lock.withLock { recoveryRequested }
        if nativeReplacement {
            message = "Ordinary Bluetooth audio replaced the LDAC connection. Retry LDAC to take over this output."
        }
        if recoverableFailure, !safe, !nativeAudioRestored, !hardFailure {
            message = (message ?? "LDAC stopped.") + " LDAC recovery cleanup could not be confirmed."
        }
        record("RECOVERY_READY safe=\(safe)")
        if let message { record("COMPLETION_ERROR \(message)") }
        let publicMessage: String?
        if message == nil {
            publicMessage = nil
        } else if shutdownUnverified || connectorSettlementUnverified || (priorityPhase != .unused && priorityPhase != .removed) {
            publicMessage = String(localized: "音频会话未完全停止，请检查蓝牙连接和系统输出。")
        } else if nativeReplacement {
            publicMessage = String(localized: "其他蓝牙音频连接占用了耳机，当前会话已停止。请结束通话或其他占用后重新开始。")
        } else {
            publicMessage = capturePermissionFailure ?? publicFailureMessage ?? String(localized: "耳机连接中断，请重新开始播放。")
        }
        // A new attempt must never overlap unverified channel/connector cleanup
        // or a failed native-output restoration. The failure code alone is not permission.
        let restartSafe = !shutdownUnverified && !connectorSettlementUnverified
            && unverifiedAcquisitions.isEmpty && captureStoppedCleanly
            && (priorityPhase == .unused || priorityPhase == .removed)
            && (children["connector"] == nil || connectorSettled && [0, 4].contains(children["connector"]?.exitCode ?? -1))
            && capturePermissionFailure == nil && !nativeReplacement
            && nativeAudioRestored && children.values.allSatisfy { $0.status != nil }
        record("RESTART_READY safe=\(restartSafe) failureCode=\(playbackFailure?.rawValue ?? "none") nativeRestored=\(nativeAudioRestored)")
        emit(.finished(Completion(message: publicMessage, canRetry: safe,
                                  requiresAttention: hardFailure || !recoverableFailure || !safe && !nativeAudioRestored || nativeReplacement,
                                  targetDisconnected: (originalConnectionEnded || restoreDisconnected) && !nativeAudioRestored,
                                  waitForReconnect: (originalConnectionEnded || targetUnavailableBeforeRestore) && !nativeAudioRestored,
                                  playbackFailure: playbackFailure, restartSafe: restartSafe)))
    }

    static func beginDiagnostics(in directory: URL) throws -> FileHandle {
        let retention = try lockDiagnostics(at: directory.deletingLastPathComponent().appendingPathComponent("retention.lock"))
        defer { try? retention.close() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let active = try lockDiagnostics(at: directory.appendingPathComponent("active.lock"), nonblocking: true)
        try pruneDiagnostics(in: directory)
        return active
    }

    static func completeDiagnostics(in directory: URL, releasing active: FileHandle? = nil) throws {
        let retention = try lockDiagnostics(at: directory.deletingLastPathComponent().appendingPathComponent("retention.lock"))
        defer { try? retention.close() }
        try Data().write(to: directory.appendingPathComponent("completed"), options: .atomic)
        try active?.close()
        try pruneDiagnostics(in: directory)
    }

    private static func lockDiagnostics(at url: URL, nonblocking: Bool = false) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? handle.close()
            throw error
        }
        return handle
    }

    private static func pruneDiagnostics(in directory: URL) throws {
        let manager = FileManager.default
        let directories = try manager.contentsOfDirectory(at: directory.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
        let inactive = directories.compactMap { candidate -> (url: URL, date: Date)? in
            guard candidate.lastPathComponent != directory.lastPathComponent,
                  UUID(uuidString: candidate.lastPathComponent) != nil,
                  let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink == false,
                  let directoryDate = values.contentModificationDate else { return nil }
            let completedDate = try? candidate.appendingPathComponent("completed")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let activeURL = candidate.appendingPathComponent("active.lock")
            if manager.fileExists(atPath: activeURL.path) {
                guard let active = try? lockDiagnostics(at: activeURL, nonblocking: true) else { return nil }
                try? active.close()
            } else if completedDate == nil {
                return nil
            }
            let date = completedDate ?? directoryDate
            return (candidate, date)
        }.sorted { $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date }
        for candidate in inactive.dropFirst(7) {
            let activeURL = candidate.url.appendingPathComponent("active.lock")
            let active: FileHandle?
            if manager.fileExists(atPath: activeURL.path) {
                active = try? lockDiagnostics(at: activeURL, nonblocking: true)
                if active == nil { continue }
            } else {
                active = nil
            }
            defer { try? active?.close() }
            try manager.removeItem(at: candidate.url)
        }
    }

    private func record(_ line: String) {
        let data = Data("\(Date().timeIntervalSince1970) \(line)\n".utf8)
        if loggedBytes + data.count > 8 * 1024 * 1024 {
            do {
                try log?.truncate(atOffset: 0)
                try log?.seek(toOffset: 0)
                loggedBytes = 0
            } catch { return }
        }
        do {
            try log?.write(contentsOf: data)
            loggedBytes += data.count
        } catch {}
    }
}

/// Evidence gate for the missing-open-callback path; never infers closure from elapsed time.
struct LDACPendingOpenCleanup {
    private(set) var originalACLDisconnected = false
    mutating func observeConnector(_ line: String) {
        if line == "CONNECT_CANCELED callback=0 originalDisconnected=1 retired=1" ||
           line == "CONNECT_CANCELED callback=1 originalDisconnected=1 retired=1" {
            originalACLDisconnected = true
        }
    }
    func canRetire(acquiredCID: Int?, helperExited: Bool, connectorExitedCleanly: Bool) -> Bool {
        originalACLDisconnected && acquiredCID == nil && helperExited && connectorExitedCleanly
    }
}

struct LDACChannelGate {
    private struct Record {
        let kind: String
        let cid: Int
        let values: [Int]
    }

    private(set) var cid: Int?
    private(set) var opened = false
    private(set) var closed = false
    private(set) var mtu: Int?
    private var records: [Record] = []
    private var lengths: [Int] = []
    private var receivedBytes = 0

    mutating func daemon(_ line: String) throws {
        let record: Record
        if let values = Self.captures("\\bconnectedCB cid:0x([0-9a-f]+)\\b", line), let cid = Int(values[0], radix: 16) {
            let result = Self.captures("\\binMTU:([0-9]+)\\s+outMTU:([0-9]+)\\s+result:([0-9]+)\\b", line)?.compactMap(Int.init) ?? []
            record = Record(kind: "open", cid: cid, values: result)
        } else if let values = Self.captures("l2capDisconnected for CID: 0x([0-9a-f]+)\\b", line), let cid = Int(values[0], radix: 16) {
            record = Record(kind: "close", cid: cid, values: [])
        } else if let values = Self.captures("l2capDataInd for CID: 0x([0-9a-f]+), len: 0x([0-9a-f]+)\\b", line),
                  let cid = Int(values[0], radix: 16), let length = Int(values[1], radix: 16) {
            record = Record(kind: "data", cid: cid, values: [length])
        } else { return }
        if cid == nil {
            guard records.count < 8192 else { throw LDACSessionError("Bluetooth ownership evidence exceeded the startup buffer.") }
            records.append(record)
        } else { try accept(record) }
    }

    mutating func owned(_ line: String) throws {
        guard let values = Self.captures("^OWNED_CHANNEL\\b.*\\bCID=([0-9a-f]+)\\b", line) else { return }
        guard cid == nil, let value = Int(values[0], radix: 16), (1...65535).contains(value) else {
            throw LDACSessionError("The audio helper reported an invalid or repeated owned channel.")
        }
        cid = value
        for record in records { try accept(record) }
        records = []
    }

    mutating func takeLengths() -> [Int] {
        let result = lengths
        lengths = []
        return result
    }

    func reconcile(_ count: Int) throws {
        guard opened, closed, count == receivedBytes else {
            throw LDACSessionError("The received LDAC signaling bytes did not match the complete owned Bluetooth channel lifetime.")
        }
    }

    private mutating func accept(_ record: Record) throws {
        guard record.cid == cid else { return }
        switch record.kind {
        case "open":
            guard !opened, !closed, record.values.count == 3,
                  record.values[0] > 0, record.values[1] > 0, record.values[2] == 0 else {
                throw LDACSessionError("Bluetooth did not prove a unique successful owned channel with positive MTUs.")
            }
            opened = true
            mtu = record.values[1]
        case "close":
            guard opened, !closed else { throw LDACSessionError("Bluetooth reported an unordered or repeated owned channel closure.") }
            closed = true
        default:
            let length = record.values[0]
            guard opened, !closed, (2...4096).contains(length) else {
                throw LDACSessionError("Bluetooth reported an invalid signaling SDU outside its owned channel lifetime.")
            }
            lengths.append(length)
            receivedBytes += length
        }
    }

    static func addressPattern(_ address: String) -> String {
        NSRegularExpression.escapedPattern(for: address) + "(?:\\s+\"[^\"\\n]*\"(?:\\s+-\\s+\"[^\"\\n]*\")?)?"
    }

    static func captures(_ pattern: String, _ line: String) -> [String]? {
        let expression = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).map {
            Range(match.range(at: $0), in: line).map { String(line[$0]) } ?? ""
        }
    }
}

final class LDACNativeChild {
    let pid: pid_t
    let output: Int32
    private var input: Int32
    private var pending = Data()
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    private(set) var status: Int32?
    private(set) var outputEnded = false
    var finished: Bool { status != nil && outputEnded }
    var exitCode: Int32? {
        guard let status, status & 0x7F == 0 else { return nil }
        return (status >> 8) & 0xFF
    }

    init(executable: URL, arguments: [String], inheritedPCM: Int32?, blockStopSignals: Bool = false, mergeDiagnostics: Bool = true) throws {
        var incoming: [Int32] = [0, 0]
        var outgoing: [Int32] = [0, 0]
        guard pipe(&incoming) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&outgoing) == 0 else {
            for fd in incoming { Darwin.close(fd) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fcntl(incoming[1], F_SETNOSIGPIPE, 1) != -1,
              fcntl(incoming[1], F_SETFL, O_NONBLOCK) != -1,
              fcntl(outgoing[0], F_SETFL, O_NONBLOCK) != -1 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            for fd in incoming + outgoing { Darwin.close(fd) }
            throw error
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        if blockStopSignals {
            sigaddset(&signalMask, SIGINT)
            sigaddset(&signalMask, SIGTERM)
        }
        posix_spawnattr_setsigmask(&attributes, &signalMask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))
        posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, mergeDiagnostics ? outgoing[1] : STDERR_FILENO, STDERR_FILENO)
        if let inheritedPCM { posix_spawn_file_actions_adddup2(&actions, inheritedPCM, 3) }
        var strings = ([executable.path] + arguments).map { strdup($0) }
        strings.append(nil)
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        defer {
            for string in strings { free(string) }
            for string in environment { free(string) }
        }
        var identifier: pid_t = 0
        let result = posix_spawn(&identifier, executable.path, &actions, &attributes, &strings, &environment)
        Darwin.close(incoming[0])
        Darwin.close(outgoing[1])
        guard result == 0 else {
            Darwin.close(incoming[1])
            Darwin.close(outgoing[0])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        pid = identifier
        input = incoming[1]
        output = outgoing[0]
    }

    func readLines() throws -> [String] {
        guard !outputEnded else { return [] }
        let count = Darwin.read(output, &buffer, buffer.count)
        if count == 0 { outputEnded = true }
        else if count < 0 {
            if errno != EAGAIN && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else { pending.append(contentsOf: buffer.prefix(count)) }
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            guard line.count <= 8192 else { throw LDACSessionError("An audio helper returned an oversized status line.") }
            lines.append(String(decoding: line, as: UTF8.self))
        }
        if pending.count > 8192 {
            pending = Data()
            throw LDACSessionError("An audio helper returned an unterminated status line.")
        }
        if outputEnded && !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending = Data()
        }
        return lines
    }

    func send(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        let sent = data.withUnsafeBytes { Darwin.write(input, $0.baseAddress, data.count) }
        guard sent == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE) }
    }

    func reap() {
        guard status == nil else { return }
        var value: Int32 = 0
        if waitpid(pid, &value, WNOHANG) == pid {
            status = value == 0 ? 0 : value
            kill(-pid, SIGKILL)
        }
    }

    func signal(_ value: Int32) {
        if status == nil { kill(pid, value) }
    }

    func wait() {
        guard status == nil else { return }
        var value: Int32 = 0
        while waitpid(pid, &value, 0) < 0 && errno == EINTR {}
        status = value == 0 ? 0 : value
        kill(-pid, SIGKILL)
    }

    func closeInput() {
        if input >= 0 { Darwin.close(input); input = -1 }
    }

    deinit {
        closeInput()
        Darwin.close(output)
    }
}

private struct LDACSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
#endif
