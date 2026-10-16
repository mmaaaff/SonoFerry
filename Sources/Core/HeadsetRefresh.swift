import Foundation

/// Explicit wire scopes keep periodic reads independent of settings pages.
public enum HeadsetRefreshScope: String, CaseIterable, Sendable {
    case quick, status, keys, sound, golden, connection, full
    public var queries: [HeadsetQuery] {
        switch self {
        case .quick: return [.battery, .ears, .noiseCurrent]
        case .status: return [.battery, .versions]
        case .keys: return [.keys]
        case .sound: return [.preset, .equalizers, .feature(.bassWave), .bassWave]
        case .golden: return [.feature(.goldenSound), .goldenResult]
        case .connection: return [.ears, .feature(.wearDetection), .feature(.multipoint)]
        case .full: return HeadsetQuery.initial
        }
    }
    public static func page(_ title: String) -> Self {
        switch title {
        case "操作": return .keys
        case "大师调音": return .sound
        case "黄金听感": return .golden
        case "连接与佩戴": return .connection
        default: return .status
        }
    }
}

extension HeadsetSnapshot {
    /// One authority for both legacy wire reports and the UI. Stale values are
    /// retained in features for presentation, never used as write permission.
    public var controlReport: OppoProbeReport {
        var report = OppoProbeReport()
        report.controlCapabilities = capabilities; report.currentCodecID = currentCodec
        report.hiRes = connected && supports(.feature(.hiRes)) ? features[24].flatMap { $0.stale ? nil : $0.value } : nil
        report.notificationIDs = notificationIDs; report.serviceUUID = serviceUUID ?? OppoControlPacket.serviceUUID
        report.message = connected ? "已读取耳机状态" : "耳机控制未连接"
        return report
    }
    public func hasFresh(_ query: HeadsetQuery) -> Bool {
        guard connected else { return false }
        switch query {
        case .product: return productID != nil
        case .battery: return !battery.isEmpty && (isX4 ? [UInt8(1),2] : batteryParts).allSatisfy { battery[$0]?.stale == false }
        case .ears: return !ears.isEmpty && (isX4 ? [UInt8(1),2] : earParts).allSatisfy { ears[$0]?.stale == false }
        case .versions: return versions?.stale == false
        case .keys: return keys?.stale == false
        case .noiseCurrent: return noise?.stale == false && noiseType?.stale == false
        case .noiseAvailable: return noiseAvailable?.stale == false
        case .noiseIntelligent: return intelligentNoise?.stale == false
        case .preset: return preset?.stale == false
        case .equalizers: return equalizers?.stale == false
        case .bassWave: return bassWave?.stale == false
        case .spatial: return spatial?.stale == false
        case .personalResult: return personalResult?.stale == false
        case .goldenResult: return goldenResult?.stale == false
        case .feature(let feature): return features[feature.rawValue]?.stale == false
        }
    }
}
