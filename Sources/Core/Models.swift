import Foundation
public enum AudioIdentifiers {
    public static let virtualOutputUID = "local.SonoFerry.ldac-output"
}

public enum CodecID: String, Codable, CaseIterable, Sendable {
    case ldac, lhdcV5
    public var title: String { self == .ldac ? "LDAC" : "LHDC V5" }
    public var sampleRates: [Int] { self == .ldac ? [44100, 48000, 88200, 96000] : [44100, 48000, 96000, 192000] }
    public func fixedBitrates(rate: Int) -> [Int] {
        guard self == .lhdcV5, sampleRates.contains(rate) else { return [] }
        return [64,160,192,rate == 44100 ? 240 : 256,320,400,rate == 44100 ? 480 : 500,900,1000]
    }

}
public enum SampleRate: Int, Codable, CaseIterable, Sendable {
    case hz44100 = 44100, hz48000 = 48000, hz88200 = 88200, hz96000 = 96000, hz192000 = 192000
    public var displayName: String { "\(Double(rawValue) / 1000) kHz" }
}
public enum Quality: String, Codable, CaseIterable, Sendable {
    case connection = "low", balanced = "mid", quality = "high", adaptive = "auto"
    public var displayName: String {
        switch self { case .connection: "稳定"; case .balanced: "均衡"; case .quality: "高码率"; case .adaptive: "自适应" }
    }
    public var encoderMode: Int { switch self { case .connection, .adaptive: 2; case .balanced: 1; case .quality: 0 } }
}
public struct AudioFormat: Codable, Equatable, Sendable {
    public let sampleRateHz: Int
    public let bitrateKbps: Int
    public let channels: Int
    public init(sampleRateHz: Int, bitrateKbps: Int, channels: Int) { self.sampleRateHz = sampleRateHz; self.bitrateKbps = bitrateKbps; self.channels = channels }
}
public struct AudioEndpointState: Codable, Equatable, Sendable {
    public var sampleRate: Double?
    public var availableRates: [Double]
    public var volumeWritable: Bool
    public init(sampleRate: Double?, availableRates: [Double], volumeWritable: Bool) {
        self.sampleRate = sampleRate; self.availableRates = availableRates; self.volumeWritable = volumeWritable
    }
}
public struct SystemAudioState: Codable, Equatable, Sendable {
    public var nativeOutput: AudioEndpointState?
    public var virtualOutput: AudioEndpointState?
    public var defaultIsVirtual: Bool
    public init(nativeOutput: AudioEndpointState?, virtualOutput: AudioEndpointState?, defaultIsVirtual: Bool) {
        self.nativeOutput = nativeOutput; self.virtualOutput = virtualOutput; self.defaultIsVirtual = defaultIsVirtual
    }
}
public enum HardwareVolumeSupport {
    // Capability of this implementation, not a device-name or brand allow-list.
    public static let available = false
    public static let unavailableReason = "当前版本尚未实现高清会话的独立硬件音量控制。系统蓝牙音量接口会在接管音频后消失；请使用软件音量，并在耳机上单独调整硬件音量。"
    public static let migratedNotice = "旧版音量绑定设置已关闭，现使用独立软件音量。"
}
public struct BufferingConfiguration: Codable, Equatable, Sendable {
    public var catchupLimitTenths: Int
    public var prefillMilliseconds: Int
    public init(catchupLimitTenths: Int = 50, prefillMilliseconds: Int = 250) {
        self.catchupLimitTenths = catchupLimitTenths; self.prefillMilliseconds = prefillMilliseconds
    }
    public func validate() throws {
        guard (1...150).contains(catchupLimitTenths), (10...1000).contains(prefillMilliseconds) else {
            throw ProtocolFailure("追赶时限须为 0.1–15.0 秒，预缓冲须为 10–1000 ms")
        }
    }
    public var catchupLimitSeconds: Double { Double(catchupLimitTenths) / 10 }
    public func prefillFrames(rate: Int) -> Int { (rate * prefillMilliseconds + 999) / 1000 }
    // Reserve the full adjustable range once, outside the real-time callback.
    // Live changes never allocate/copy the PCM ring and never discard audio.
    public func storageFrames(rate: Int) -> Int {
        let frames = rate * 18 // maximum prefill (1 s) + catch-up (15 s) + 2 s slack
        return (frames + 127) / 128 * 128
    }
}
public struct PlaybackConfiguration: Codable, Equatable, Sendable {
    public var codec: CodecID = .ldac
    public var sampleRate: SampleRate = .hz48000
    public var quality: Quality = .adaptive
    public var bits: Int = 24
    public var endpoint: Int = 0
    public var minimumBitrate: Int = 64
    public var maximumBitrate: Int = 1000
    public var probeOnly: Bool = false
    public var fixedBitrateKbps: Int?
    // Optional fields keep existing version-1 clients decodable. Only explicit
    // manual choices outside the reported capability set authorize a bypass.
    public var forceSampleRate: Bool?
    public var forceBitrate: Bool?
    public var buffering: BufferingConfiguration?
    public var bufferingSettings: BufferingConfiguration { buffering ?? BufferingConfiguration() }
    public var encoderInputDescription: String { codec == .ldac ? "Float32 PCM" : "\(bits)-bit 整数 PCM" }
    public var negotiatedBitDepthDescription: String { codec == .ldac ? "不可查询（LDAC 能力无位深字段）" : "\(bits)-bit" }
    public func requiresReconnect(from current: PlaybackConfiguration) -> Bool {
        var desired = self, previous = current
        desired.buffering = nil; previous.buffering = nil
        return desired != previous
    }
    public init() {}
    public var isForced: Bool { forceSampleRate == true || forceBitrate == true }
    public var forcedDescription: String {
        var values: [String] = []
        if forceSampleRate == true { values.append(String(format: "%g kHz", Double(sampleRate.rawValue) / 1000)) }
        if forceBitrate == true, let fixedBitrateKbps { values.append("\(fixedBitrateKbps) kbps") }
        return values.joined(separator: " / ")
    }
    public func validate() throws {
        try bufferingSettings.validate()
        guard codec.sampleRates.contains(sampleRate.rawValue), [16,24].contains(bits), (0...62).contains(endpoint) else {
            throw ProtocolFailure("所选格式超出本机编码器实现范围")
        }
        guard !isForced || (!probeOnly && endpoint > 0) else { throw ProtocolFailure("强制参数需要已检测到的编码端点") }
        guard forceBitrate != true || (codec == .lhdcV5 && quality != .adaptive && fixedBitrateKbps != nil) else {
            throw ProtocolFailure("强制码率仅适用于手动固定 LHDC 码率")
        }
        if codec == .lhdcV5 {
            guard [64,160,256,400].contains(minimumBitrate), [400,500,900,1000].contains(maximumBitrate), minimumBitrate <= maximumBitrate else {
                throw ProtocolFailure("无效的 LHDC 协商码率范围")
            }
        }
        if let fixedBitrateKbps {
            guard quality != .adaptive, codec.fixedBitrates(rate: sampleRate.rawValue).contains(fixedBitrateKbps),
                  (minimumBitrate...maximumBitrate).contains(fixedBitrateKbps) else { throw ProtocolFailure("无效的固定码率") }
        }
        guard bitrateKbps > 0 else { throw ProtocolFailure("耳机码率范围与编码器不兼容") }
    }
    public var bitrateKbps: Int {
        if codec == .lhdcV5 {
            if let fixedBitrateKbps { return fixedBitrateKbps }
            let requested = quality == .quality ? 1000 : quality == .balanced ? (sampleRate == .hz44100 ? 480 : 500) : 400
            let table = [64, 160, 192, sampleRate == .hz44100 ? 240 : 256, 320, 400, sampleRate == .hz44100 ? 480 : 500, 900, 1000]
            return table.last(where: { $0 <= min(requested, maximumBitrate) && $0 >= minimumBitrate }) ?? 0
        }
        let high = sampleRate.rawValue.isMultiple(of: 44100) ? 909 : 990
        switch quality { case .connection, .adaptive: return high / 3; case .balanced: return high * 2 / 3; case .quality: return high }
    }
    public var format: AudioFormat { .init(sampleRateHz: sampleRate.rawValue, bitrateKbps: bitrateKbps, channels: 2) }
    public var helperArguments: [String] {
        var values = ["--codec", codec.rawValue, "--sample-rate", String(sampleRate.rawValue), "--quality", quality.rawValue,
         "--bits", String(bits), "--endpoint", String(endpoint), "--min-bitrate", String(minimumBitrate), "--max-bitrate", String(maximumBitrate)]
        if let fixedBitrateKbps { values += ["--bitrate", String(fixedBitrateKbps)] }
        return values
    }
    public var signalingArguments: [String] {
        helperArguments + (forceSampleRate == true ? ["--force-sample-rate"] : []) + (forceBitrate == true ? ["--force-bitrate"] : [])
    }
    public var mediaArguments: [String] {
        helperArguments + ["--catchup-limit-ms", String(bufferingSettings.catchupLimitTenths * 100),
                           "--prefill-ms", String(bufferingSettings.prefillMilliseconds)]
    }
}
public enum BluetoothIdentity {
    public static func normalizedAddress(_ text: String) -> String? {
        let bytes = text.replacingOccurrences(of: "-", with: ":").uppercased().split(separator: ":", omittingEmptySubsequences: false)
        guard bytes.count == 6, bytes.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { return nil }
        return bytes.joined(separator: ":")
    }
}
public struct BluetoothDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: String { address }
    public let address: String
    public let name: String
    public let connected: Bool
    public let a2dpSink: Bool
    public var nativeAudioOutput: Bool?
    public var controlServices: [String]?
    public var isAudio: Bool { a2dpSink || nativeAudioOutput == true }
    public init(address: String, name: String, connected: Bool, a2dpSink: Bool, nativeAudioOutput: Bool? = nil, controlServices: [String]? = nil) {
        self.address = address; self.name = name; self.connected = connected; self.a2dpSink = a2dpSink
        self.nativeAudioOutput = nativeAudioOutput; self.controlServices = controlServices
    }
}
public struct CodecCapabilities: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(endpoint):\(codec?.rawValue ?? rawHex)" }
    public let endpoint: Int
    public let codec: CodecID?
    public let sampleRates: [Int]
    public let bitDepths: [Int]?
    public let stereo: Bool
    public let minimumBitrate: Int?
    public let maximumBitrate: Int?
    public let version: Int?
    public let frame5ms: Bool?
    public let rawHex: String
    public var playable: Bool {
        guard let codec, stereo, !Set(sampleRates).intersection(codec.sampleRates).isEmpty else { return false }
        return codec == .ldac || (version.map { $0 & 1 != 0 } == true && frame5ms == true && !(bitDepths ?? []).filter { [16, 24].contains($0) }.isEmpty)
    }
    public var bitDepthExplanation: String { codec == .ldac ? "标准 LDAC 能力报文未提供耳机位深；编码输入为 Float32" : (bitDepths ?? []).map(String.init).joined(separator: " / ") + " bit（耳机报告）" }
    public var codecLabel: String {
        if let codec { return codec.title }
        if rawHex.hasPrefix("0000") { return "SBC" }
        if rawHex.hasPrefix("0002") { return "AAC" }
        return "未知编码"
    }
    public func fixedBitrates(rate: Int) -> [Int] {
        return (codec?.fixedBitrates(rate: rate) ?? []).filter {
            $0 >= (minimumBitrate ?? 64) && $0 <= (maximumBitrate ?? 1000)
        }
    }
    public func changingSampleRate(to rate: Int, from current: PlaybackConfiguration) throws -> PlaybackConfiguration {
        guard codec == current.codec, endpoint == current.endpoint, !current.probeOnly else {
            throw ProtocolFailure("采样率请求与当前会话的编码端点不匹配")
        }
        var bitrate = current.fixedBitrateKbps
        if let fixed = bitrate, !(codec?.fixedBitrates(rate: rate) ?? []).contains(fixed) {
            // These are the same LHDC quality indices in the 44.1/48 kHz families.
            bitrate = [240: 256, 256: 240, 480: 500, 500: 480][fixed] ?? fixed
        }
        var next = try configuration(rate: rate, quality: current.quality, fixedBitrate: bitrate, allowUnreported: true)
        next.buffering = current.buffering
        return next
    }
    /// HiRes changes the advertised range. Resume only a supported configuration;
    /// a capability refresh never creates a forced-rate/bitrate attempt.
    public func supportedContinuation(from previous: PlaybackConfiguration) throws -> PlaybackConfiguration {
        guard codec == previous.codec, playable else { throw ProtocolFailure("原高清编码已不在耳机可用能力中") }
        let common = sampleRates.filter(previous.codec.sampleRates.contains)
        let rate = common.contains(previous.sampleRate.rawValue) ? previous.sampleRate.rawValue
            : common.contains(48000) ? 48000 : common.contains(44100) ? 44100 : common.sorted().first!
        var fixed = previous.fixedBitrateKbps
        if let old = fixed, !previous.codec.fixedBitrates(rate: rate).contains(old) {
            fixed = [240: 256, 256: 240, 480: 500, 500: 480][old]
        }
        if let value = fixed, !fixedBitrates(rate: rate).contains(value) { fixed = nil }
        let quality: Quality = previous.fixedBitrateKbps != nil && fixed == nil ? .adaptive : previous.quality
        var result = try configuration(rate: rate, quality: quality, fixedBitrate: fixed)
        result.buffering = previous.buffering
        return result
    }
    public func configuration(rate: Int? = nil, quality: Quality = .adaptive, fixedBitrate: Int? = nil, allowUnreported: Bool = false) throws -> PlaybackConfiguration {
        guard let codec, playable else { throw ProtocolFailure("该端点没有本机可用的立体声编码配置") }
        let common = sampleRates.filter(codec.sampleRates.contains).sorted()
        let chosen = rate ?? (common.contains(48000) ? 48000 : common.contains(44100) ? 44100 : common[0])
        guard codec.sampleRates.contains(chosen), let sampleRate = SampleRate(rawValue: chosen) else { throw ProtocolFailure("本机编码器不支持所选采样率") }
        guard common.contains(chosen) || (allowUnreported && rate != nil) else { throw ProtocolFailure("耳机未报告所选采样率") }
        var result = PlaybackConfiguration(); result.codec = codec; result.sampleRate = sampleRate; result.quality = quality; result.endpoint = endpoint
        if !common.contains(chosen) { result.forceSampleRate = true }
        result.bits = (bitDepths ?? [24]).contains(24) ? 24 : 16
        result.minimumBitrate = minimumBitrate ?? 64; result.maximumBitrate = maximumBitrate ?? 1000
        if let fixedBitrate {
            guard codec == .lhdcV5, quality != .adaptive, codec.fixedBitrates(rate: chosen).contains(fixedBitrate) else { throw ProtocolFailure("本机不支持所选固定码率或当前为自适应模式") }
            if !fixedBitrates(rate: chosen).contains(fixedBitrate) {
                guard allowUnreported else { throw ProtocolFailure("所选固定码率不在耳机与本机能力交集内") }
                result.forceBitrate = true
                // Encode an actual negotiated range, never silently clamp the encoder.
                result.minimumBitrate = min(result.minimumBitrate, [64,160,256,400].last(where: { $0 <= fixedBitrate })!)
                result.maximumBitrate = max(result.maximumBitrate, [400,500,900,1000].first(where: { $0 >= fixedBitrate })!)
            }
            result.fixedBitrateKbps = fixedBitrate
        }
        try result.validate()
        return result
    }
}
public struct ProtocolFailure: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct WireMessage: Codable, Sendable {
    public var version = 1
    public var requestID: UUID?
    public var sessionID: UUID?
    public var kind: String
    public var device: BluetoothDevice?
    public var devices: [BluetoothDevice]?
    public var configuration: PlaybackConfiguration?
    public var buffering: BufferingConfiguration?
    public var capabilities: [CodecCapabilities]?
    public var format: AudioFormat?
    public var gain: Double?
    public var message: String?
    public var stopIntent: AudioStopIntent?
    public var stopPhase: AudioStopPhase?
    public var playbackFailure: PlaybackFailureCode?
    /// True only on the terminal event, after transport and output cleanup.
    public var restartSafe: Bool?
    public var details: [String: String]?
    public var metrics: [String: Double]?
    public var linkHardwareVolume: Bool?
    public var volumeLinkState: String?
    public var audioState: SystemAudioState?
    public var environment: DeviceEnvironment?
    public var oppoReport: OppoProbeReport?
    public var hiResEnabled: Bool?
    public var controlGeneration: UUID?
    public var headsetIdentity: HeadsetIdentity?
    public var headset: HeadsetSnapshot?
    public var headsetSetting: HeadsetSetting?
    public var headsetResult: HeadsetOperationResult?
    public var wearAutomation: Bool?
    public var mediaStatus: String?
    public init(_ kind: String, requestID: UUID? = nil, sessionID: UUID? = nil) { self.kind = kind; self.requestID = requestID; self.sessionID = sessionID }
}

public enum PlaybackFailureCode: String, Codable, Sendable {
    case signalingUnavailable
    case deviceNotReady
    case audioHostUnavailable
    case capabilitiesChanged
    case mediaMTU
}

/// An optimization request, never permission to bypass cleanup or restore checks.
public enum AudioStopIntent: String, Codable, Sendable {
    case reconfigure
    public static func permits(_ request: WireMessage, currentID: UUID?, address: String,
                               configuration: PlaybackConfiguration, active: Bool) -> Bool {
        guard request.kind == "stop", request.stopIntent == .reconfigure, active,
              let currentID, request.sessionID == currentID, request.device?.address == address,
              !configuration.probeOnly, let next = request.configuration, !next.probeOnly,
              next.codec == configuration.codec, request.linkHardwareVolume != true,
              next.requiresReconnect(from: configuration), (try? next.validate()) != nil else { return false }
        return true
    }
}
public enum AudioStopPhase: String, Codable, Sendable {
    case control, transport, nativeOutput, disconnect, route
    public var title: String {
        switch self {
        case .control: return "正在结束耳机控制操作"
        case .transport: return "正在关闭音频捕获和蓝牙传输"
        case .nativeOutput: return "正在等待系统蓝牙输出恢复"
        case .disconnect: return "正在确认旧蓝牙连接已断开"
        case .route: return "正在恢复系统输出并释放音频设备"
        }
    }
}
