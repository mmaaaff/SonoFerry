import Foundation

/// Only the two audited ELNK transports. Codec negotiation is independent of this catalogue.
public enum HeadsetDialect: String, Codable, Sendable, CaseIterable {
    case elnk079A = "0000079A-D102-11E1-9B23-00025B00A5A5"
    case elnk1107 = "00001107-D102-11E1-9B23-00025B00A5A5"
    public var serviceBytes: [UInt8] {
        let hex = rawValue.replacingOccurrences(of: "-", with: "")
        return stride(from: 0, to: hex.count, by: 2).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}
public struct HeadsetIdentity: Codable, Equatable, Sendable {
    public let address: String
    public let productID: UInt32
    public let serviceUUID: String
    public let confirmedAt: Date
    public let generation: UUID
    public var source: String? = "controlProductID"
    public var profile: HeadphoneProfile? {
        guard let profile = HeadphoneProfile.find(productID), profile.dialect?.rawValue == serviceUUID else { return nil }
        return profile
    }
    public init(address: String, productID: UInt32, serviceUUID: String, generation: UUID, confirmedAt: Date = Date()) {
        self.address = address; self.productID = productID; self.serviceUUID = serviceUUID
        self.generation = generation; self.confirmedAt = confirmedAt
    }
}
public struct CodecProbeState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case notProbed, complete, failed }
    public var status: Status
    public var date: Date?
    public var error: String?
    public init(_ status: Status, date: Date? = nil, error: String? = nil) { self.status = status; self.date = date; self.error = error }
}
public struct HeadphoneProfile: Codable, Equatable, Identifiable, Sendable {
    public struct Noise: Codable, Equatable, Sendable {
        public let protocolIndex: UInt8
        public let modeType: Int
        public let childrenMode: [Noise]?
        public let decideByEarDevice: Bool?
        public var group: HeadsetNoiseGroup {
            switch modeType { case 1: return .off; case 2,6: return .transparency; case 10...13: return .adaptive; default: return .cancellation }
        }
        public var name: String {
            [1:"关闭",2:"通透",3:"轻度降噪",4:"深度降噪",5:"降噪",6:"增强通透",7:"智能切换",8:"中度降噪",10:"自适应",11:"更少噪音",12:"标准",13:"更多噪音"][modeType] ?? "模式 \(protocolIndex)"
        }
    }
    public struct KeyRule: Codable, Equatable, Sendable {
        public let ear: Int
        public let support: UInt64?
        public let showEar: Int?
        public let action: Int
        public var button: UInt8 { (28...37).contains(action) ? 6 : 1 }
        public var wireAction: UInt8 {
            let map = [11:4,16:1,17:2,18:3,19:4,20:4,22:6,26:2,27:4,28:1,29:2,30:3,31:6,32:1,33:2,34:3,35:6,36:2]
            return UInt8(map[action] ?? action)
        }
        public func matches(_ key: HeadsetKey) -> Bool {
            button == key.button && wireAction == key.action && (ear == 2 || key.ear == UInt8(ear + 1))
        }
        public var functions: [UInt8] {
            // F9/a maps functions to whitelist bits; OnePlus legacy mapping is out of scope.
            let bits: [(UInt8,UInt64)] = [(0,512),(1,4),(5,32),(6,64),(7,1024),(8,128),(11,8),(12,16),(13,4096),(25,131072),(28,262144),(29,524288)]
            return bits.filter { (support ?? 0) & $0.1 != 0 }.map(\.0)
        }
        public var label: String {
            if (16...20).contains(action) || (32...35).contains(action) {
                return [1:"单次按捏",2:"两次按捏",3:"三次按捏",4:"长按",6:"长按"][wireAction] ?? "操作"
            }
            return [1:"单击",2:"双击",3:"三击",4:"长按",5:"滑动",6:"长按住",7:"向上滑动",8:"向下滑动"][wireAction] ?? "操作 \(wireAction)"
        }
    }
    public let id: String
    public let name: String
    public let aliases: [String]
    public let type: String
    public let serviceUUID: String?
    public let supportSpp: Bool
    public let features: [String]
    public let noise: [Noise]
    public let presets: [HeadsetSoundPreset]
    public let eqLimit: Int
    public let eqFrequencies: [Int]
    public let keys: [KeyRule]
    public let pinch: Bool
    public var productID: UInt32 { UInt32(id, radix: 16)! }
    public var dialect: HeadsetDialect? { supportSpp ? serviceUUID.flatMap(HeadsetDialect.init(rawValue:)) : nil }
    public var isX4: Bool { id == "06EC10" }
    public var status: String { dialect == nil ? "未适配" : isX4 ? "已适配" : "部分适配 · 待实测" }
    public var noiseModes: [Noise] { noise.flatMap { ($0.childrenMode?.isEmpty == false ? $0.childrenMode! : [$0]) } }
    public var noiseGroups: [HeadsetNoiseGroup] { HeadsetNoiseGroup.allCases.filter { g in noise.contains { $0.group == g } } }
    public func modes(in group: HeadsetNoiseGroup) -> [UInt8] { if isX4 { return group.modes }; return noiseModes.filter { $0.group == group }.map(\.protocolIndex) }
    public func noiseLabel(_ mode: UInt8) -> String {
        (noiseModes + noise).first { $0.protocolIndex == mode }?.name ?? "未识别的模式 \(mode)"
    }
    public var soundPresets: [HeadsetSoundPreset] { isX4 ? HeadsetSoundPreset.x4 : presets }
    public func noiseDetail(_ mode: UInt8) -> HeadsetNoiseMode {
        if isX4, let detail = HeadsetNoiseMode.x4[mode] { return detail }
        return .init(name: noiseLabel(mode), summary: "")
    }
    public func realtimeNoiseBadge(_ mode: UInt8) -> Bool { isX4 && mode == 4 }
    public func batteryComponents(reported: [UInt8]) -> [UInt8] { isX4 ? [1,2,3] : reported.sorted() }
    public func componentLabel(_ id: UInt8) -> String { type == "N" && [1,4].contains(id) ? "耳机" : HeadsetSnapshot.earLabel(id) }
    public func keyRule(_ key: HeadsetKey) -> KeyRule? { keys.first { $0.matches(key) } }
    public func allowedFunctions(_ key: HeadsetKey) -> [UInt8] {
        // Preserve the accepted X4 controls and wire semantics exactly.
        if isX4 { return key.allowedFunctions }
        return keyRule(key)?.functions ?? []
    }
    public func keyLabel(_ key: HeadsetKey) -> String { isX4 ? key.actionLabel : keyRule(key)?.label ?? "未识别的操作" }
    public func supports(_ query: HeadsetQuery) -> Bool {
        guard dialect != nil else { return false }
        let flag: String
        switch query {
        case .product: return true
        case .versions: flag = "versions"
        case .battery: flag = "battery"
        case .ears: flag = "ears"
        case .keys: flag = "keys"
        case .noiseCurrent, .noiseAvailable: flag = "noise"
        case .noiseIntelligent: return noiseModes.contains { $0.modeType == 7 }
        case .preset: flag = "preset"
        case .equalizers: flag = "equalizers"
        case .bassWave, .feature(.bassWave): flag = "bassWave"
        case .goldenResult, .feature(.goldenSound): flag = "goldenSound"
        case .feature(.wearDetection): flag = "wearDetection"
        case .feature(.multipoint): flag = "multipoint"
        case .feature(.hiRes): flag = "hiRes"
        default: return false
        }
        return features.contains(flag)
    }
    public static let all: [HeadphoneProfile] = {
        let data = Data(HeadphoneCatalogData.json.utf8)
        let profiles = try! JSONDecoder().decode([HeadphoneProfile].self, from: data)
        precondition(profiles.count == 58 && Set(profiles.map(\.id)).count == 58)
        return profiles
    }()
    public static func find(_ productID: UInt32) -> Self? { all.first { $0.productID == productID } }
    /// A name is a discovery hint, never an identity or write authorization.
    public static func hint(name: String) -> Self? {
        let canonical = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return all.first { p in ([p.name] + p.aliases).contains { canonical($0) == canonical(name) } }
    }
}
public extension HeadsetSnapshot {
    var profile: HeadphoneProfile? {
        guard let productID, let profile = HeadphoneProfile.find(productID), profile.dialect != nil,
              serviceUUID == nil || serviceUUID == profile.serviceUUID else { return nil }
        return profile
    }
    func supports(_ query: HeadsetQuery) -> Bool {
        guard let profile, let capabilities else { return false }
        return profile.supports(query) && query.supported(by: capabilities)
    }
    var identity: HeadsetIdentity? {
        guard connected, let productID else { return nil }
        return .init(address: address, productID: productID, serviceUUID: serviceUUID ?? HeadsetDialect.elnk079A.rawValue, generation: generation)
    }
    var batteryParts: [UInt8] { profile?.batteryComponents(reported: Array(battery.keys)) ?? [] }
    var earParts: [UInt8] { isX4 ? [1,2] : ears.keys.sorted() }
    func prerequisiteQueries(for setting: HeadsetSetting) -> [HeadsetQuery] {
        setting.prerequisiteQueries.filter { supports($0) }
    }
}
