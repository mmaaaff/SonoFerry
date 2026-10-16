import Foundation

/// X4 metadata from Melody's bundled 06EC10 profile and the user's phone UI.
/// Other devices must provide their own profile; reported EQ bands always take priority.
public struct HeadsetSoundPreset: Codable, Equatable, Sendable, Identifiable {
    public let id: UInt8
    public let name: String
    public let summary: String
    public var brand: String? = nil
    public static let x4: [Self] = [
        .init(id: 0, name: "丹拿原声", summary: "丹拿原声，经久耐听，兼容多种音乐风格"),
        .init(id: 7, name: "丹拿高解析", summary: "丹拿经典，还原经典丹拿音响的原生音色"),
        .init(id: 2, name: "纯享人声", summary: "专门为表现人声所调制，适合经典流行歌曲"),
        .init(id: 1, name: "清亮高音", summary: "清晰还原每一个乐器的细节，适合交响乐与钢琴曲"),
        .init(id: 3, name: "澎湃低音", summary: "领略低音的量感和质感，适合电子乐与摇滚乐")
    ]
}
public enum HeadsetSoundSelection: Equatable, Sendable {
    case preset(UInt8), equalizer(UInt8)
}
public struct HeadsetBassWave: Codable, Equatable, Sendable {
    public var minimum: Int
    public var maximum: Int
    public var current: Int
    public init(minimum: Int, maximum: Int, current: Int) {
        self.minimum = minimum; self.maximum = maximum; self.current = current
    }
    public func validate() throws {
        guard (-128...127).contains(minimum), (-128...127).contains(maximum), minimum <= maximum,
              (minimum...maximum).contains(current) else { throw ProtocolFailure("BassWave 强度或范围无效") }
    }
    public func payload(current: Int) throws -> [UInt8] {
        var next = self; next.current = current; try next.validate()
        return [minimum, maximum, current].map { UInt8(bitPattern: Int8($0)) }
    }
}
/// 0x8418 returns [status, eqID]; other implemented setters return [status].
/// The ID is allocated by the headset on create, and identifies the affected slot otherwise.
public struct HeadsetWriteReply: Equatable, Sendable {
    public let status: UInt8
    public let equalizerID: UInt8?
    public var accepted: Bool { status == 0 }
    public init(_ reply: OppoControlPacket, command: UInt16) throws {
        guard reply.command == command | 0x8000, reply.payload.count == (command == 0x0418 ? 2 : 1) else {
            throw ProtocolFailure("耳机设置响应格式未识别")
        }
        status = reply.payload[0]; equalizerID = command == 0x0418 ? reply.payload[1] : nil
    }
}
public extension HeadsetEQ {
    func sameContent(as other: Self) -> Bool {
        name == other.name && minimum == other.minimum && maximum == other.maximum && frequencies == other.frequencies && gains == other.gains
    }
}
public extension HeadsetSetting {
    var changesSoundSelection: Bool {
        switch self {
        case .preset, .equalizer, .selectEqualizer, .createEqualizer, .deleteEqualizer: return true
        default: return false
        }
    }
    var prerequisiteQueries: [HeadsetQuery] {
        if changesSoundSelection { return [.preset, .equalizers] }
        if case .bassWave = self { return [.feature(.bassWave), .bassWave] }
        if case .feature(.goldenSound, true) = self { return [.feature(.goldenSound), .goldenResult] }
        return [query]
    }
}
public extension HeadsetSnapshot {
    var soundSelection: HeadsetSoundSelection? {
        guard supports(.preset), preset?.stale == false else { return nil }
        if !supports(.equalizers) { return preset.flatMap { presetChoices.contains($0.value) ? .preset($0.value) : nil } }
        guard equalizers?.stale == false,
              let mode = preset?.value, let curves = equalizers?.value else { return nil }
        let selected = curves.filter(\.selected)
        // The phone re-queries when these two sources disagree. Never display two radio selections.
        if presetChoices.contains(mode) { return selected.isEmpty ? .preset(mode) : nil }
        return selected.count == 1 ? .equalizer(selected[0].id) : nil
    }
    var customEQLimit: Int { supports(.equalizers) ? profile?.eqLimit ?? 0 : 0 }
    var newEqualizer: HeadsetEQ? {
        guard supports(.equalizers), equalizers?.stale == false, let curves = equalizers?.value, curves.count < customEQLimit else { return nil }
        var draft: HeadsetEQ
        if let template = curves.first {
            guard curves.allSatisfy({ $0.frequencies == template.frequencies && $0.minimum == template.minimum && $0.maximum == template.maximum }) else { return nil }
            draft = template; draft.id = 0; draft.selected = false
            draft.gains = Array(repeating: min(template.maximum, max(template.minimum, 0)), count: template.frequencies.count)
        } else {
            // Melody UI uses ±6 for an empty slot; bands must be explicit in this product profile.
            guard let bands = profile?.eqFrequencies, !bands.isEmpty else { return nil }
            draft = .init(id: 0, name: "", minimum: -6, maximum: 6,
                          frequencies: bands, gains: Array(repeating: 0, count: bands.count))
        }
        var index = 1
        while curves.contains(where: { $0.name == "自定义 \(index)" }) { index += 1 }
        draft.name = "自定义 \(index)"; return draft
    }
    /// Confirm against the pre-write list, including untouched slots. ACK alone never confirms CRUD.
    func confirmsSound(_ setting: HeadsetSetting, before: HeadsetSnapshot, acknowledgedEQID: UInt8? = nil) -> Bool {
        if case .preset(let id) = setting, !supports(.equalizers) { return connected && soundSelection == .preset(id) }
        guard changesAreFresh, let old = before.equalizers?.value, let now = equalizers?.value else { return false }
        func othersUnchanged(except id: UInt8? = nil) -> Bool {
            let expected = old.filter { $0.id != id }, actual = now.filter { $0.id != id }
            return expected.count == actual.count && expected.allSatisfy { a in actual.contains { $0.id == a.id && $0.sameContent(as: a) } }
        }
        switch setting {
        case .preset(let id): return soundSelection == .preset(id) && othersUnchanged()
        case .selectEqualizer(let id): return (acknowledgedEQID == nil || acknowledgedEQID == id) && soundSelection == .equalizer(id) && othersUnchanged()
        case .equalizer(let curve, _):
            return (acknowledgedEQID == nil || acknowledgedEQID == curve.id) && soundSelection == .equalizer(curve.id) && now.contains { $0.id == curve.id && $0.sameContent(as: curve) } && othersUnchanged(except: curve.id)
        case .createEqualizer(let curve):
            let added = now.filter { candidate in !old.contains { $0.id == candidate.id } }
            return now.count == old.count + 1 && now.count <= customEQLimit && added.count == 1 && added[0].sameContent(as: curve)
                && (acknowledgedEQID == nil || acknowledgedEQID == added[0].id)
                && old.allSatisfy { a in now.contains { $0.id == a.id && $0.sameContent(as: a) } } && soundSelection != nil
        case .deleteEqualizer(let curve):
            return (acknowledgedEQID == nil || acknowledgedEQID == curve.id) && old.contains { $0.id == curve.id } && !now.contains { $0.id == curve.id }
                && now.count == old.count - 1 && othersUnchanged(except: curve.id) && soundSelection != nil
        default: return false
        }
    }
    private var changesAreFresh: Bool { connected && preset?.stale == false && equalizers?.stale == false }
}

/// Melody share code: radix-13 gains (-6…6), Crockford base-32, weighted checksum.
/// Digit arrays avoid overflow at the protocol's maximum of 32 bands.
public enum HeadsetEQShareCode {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static func convert(_ digits: [Int], from: Int, to: Int) -> [Int] {
        var output = [0]
        for digit in digits {
            var carry = digit
            for i in output.indices.reversed() { let value = output[i] * from + carry; output[i] = value % to; carry = value / to }
            while carry > 0 { output.insert(carry % to, at: 0); carry /= to }
        }
        return output
    }
    public static func encode(_ gains: [Int]) throws -> String {
        guard (1...32).contains(gains.count), gains.allSatisfy({ (-6...6).contains($0) }) else { throw ProtocolFailure("分享码仅支持 −6…6 的均衡器") }
        let width = convert(Array(repeating: 12, count: gains.count), from: 13, to: 32).count
        var digits = convert(gains.map { $0 + 6 }, from: 13, to: 32)
        digits = Array(repeating: 0, count: width - digits.count) + digits
        let checksum = digits.enumerated().reduce(0) { $0 + ($1.offset + 1) * $1.element } % 32
        return String((digits + [checksum]).map { alphabet[$0] })
    }
    public static func decode(_ text: String, bands: Int) throws -> [Int] {
        guard (1...32).contains(bands), text.utf8.count <= 128 else { throw ProtocolFailure("均衡器分享码长度无效") }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().map { char -> Character in
            switch char { case "I", "L": return "1"; case "O": return "0"; default: return char }
        }
        let digits = normalized.compactMap { alphabet.firstIndex(of: $0) }
        let width = convert(Array(repeating: 12, count: bands), from: 13, to: 32).count
        guard digits.count == normalized.count, digits.count == width + 1,
              digits.dropLast().enumerated().reduce(0, { $0 + ($1.offset + 1) * $1.element }) % 32 == digits.last else { throw ProtocolFailure("分享码不完整、校验失败或频段数量不匹配") }
        var gains = convert(Array(digits.dropLast()), from: 32, to: 13)
        guard gains.count <= bands else { throw ProtocolFailure("分享码超出均衡器范围") }
        gains = Array(repeating: 0, count: bands - gains.count) + gains
        return gains.map { $0 - 6 }
    }
}
