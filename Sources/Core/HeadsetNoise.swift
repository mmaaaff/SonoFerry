import Foundation

/// Enco X4 profile from Melody 17.6.3; protocol IDs are distinct from phone UI modeType values.
public enum HeadsetNoiseGroup: String, CaseIterable, Sendable {
    case cancellation = "降噪", adaptive = "自适应", transparency = "通透", off = "关闭"
    public var modes: [UInt8] {
        switch self { case .cancellation: return [4,5,6,7]; case .adaptive: return [12,13,14]; case .transparency: return [8]; case .off: return [3] }
    }
    public var defaultMode: UInt8 { switch self { case .cancellation: return 7; case .adaptive: return 13; case .transparency: return 8; case .off: return 3 } }
    public static func containing(_ mode: UInt8) -> Self? {
        if mode == 1 { return .cancellation }; if mode == 11 { return .adaptive }
        if mode == 0 { return .off }; if mode == 2 { return .transparency }
        return allCases.first { $0.modes.contains(mode) }
    }
}
public struct HeadsetNoiseMode: Sendable {
    public let name: String
    public let summary: String
    public init(name: String, summary: String) { self.name = name; self.summary = summary }
    public static let x4: [UInt8: Self] = [
        4: .init(name: "深度降噪", summary: "采用实时自适应算法，带来最佳的降噪效果"),
        5: .init(name: "中度降噪", summary: "适用于街道、商场等噪声强度适中的场合"),
        6: .init(name: "轻度降噪", summary: "适用于居家、办公室等噪声强度较小的场合"),
        7: .init(name: "智能切换", summary: "根据环境噪音，自动切换深度、中度、轻度降噪"),
        12: .init(name: "更少噪音", summary: "限制更少的噪音进入，自适应模式整体的降噪效果更强"),
        13: .init(name: "标准", summary: "兼顾降噪效果与通透效果的标准权重"),
        14: .init(name: "更多噪音", summary: "允许更多的环境声进入，自适应模式整体的通透效果更强")
    ]
}
public extension HeadsetSnapshot {
    /// The phone falls back to its exact product profile when no usable support list exists.
    /// A valid, fresh support bitmap is authoritative, including an explicitly empty bitmap.
    var intelligentNoiseTitle: String? {
        guard isX4, connected, noise?.value == 7, noise?.stale == false,
              let depth = intelligentNoise, !depth.stale, [4,5,6].contains(depth.value),
              let name = HeadsetNoiseMode.x4[depth.value]?.name else { return nil }
        return "智能切换：" + name
    }
    var usesNoiseProfile: Bool { noiseAvailable == nil || noiseAvailable?.stale == true }
    var canChooseNoise: Bool { connected && supports(.noiseCurrent) && noise?.stale == false && [UInt8(1),5].contains(noiseType?.value ?? 1) }
}
