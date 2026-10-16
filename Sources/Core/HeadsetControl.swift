import Foundation

// Independently implemented from Melody 17.6.3; evidence: docs/research/enco-x4-controls-20261012/.
public struct HeadsetValue<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: T
    public var updatedAt: Date
    public var stale: Bool
    public init(_ value: T, at: Date = Date(), stale: Bool = false) { self.value = value; updatedAt = at; self.stale = stale }
}
public struct HeadsetBattery: Codable, Equatable, Sendable {
    public var percent: Int?
    public var charging: Bool?
    public init(percent: Int?, charging: Bool?) { self.percent = percent; self.charging = charging }
}
public struct HeadsetEarState: Codable, Equatable, Sendable {
    public var inEar: Bool
    public var inCase: Bool
    public var caseClosed: Bool
    public init(raw: UInt8) { inEar = raw & 2 != 0; inCase = raw & 1 == 0; caseClosed = raw & 4 == 0 }
}
public struct HeadsetVersion: Codable, Equatable, Sendable, Identifiable {
    public var device: UInt8
    public var kind: UInt8
    public var version: String
    public var id: String { "\(device):\(kind)" }
}
public struct HeadsetKey: Codable, Equatable, Sendable, Identifiable {
    public var ear: UInt8
    public var button: UInt8
    public var action: UInt8
    public var function: UInt8
    public var id: String { "\(ear):\(button):\(action)" }
    public var bytes: [UInt8] { [ear, button, action, function] }
    public init(ear: UInt8, button: UInt8 = 1, action: UInt8, function: UInt8) {
        self.ear = ear; self.button = button; self.action = action; self.function = function
    }
    public var isCall: Bool { button == 6 && [1,2,3].contains(action) }
    public var isVisible: Bool { isCall || button == 1 && [1,2,3,4,5].contains(action) }
    public var actionLabel: String {
        guard isVisible else { return "未识别的操作" }
        return [1: "单次按捏", 2: "两次按捏", 3: "三次按捏", 4: "长按", 5: "滑动"][action] ?? "未识别的操作"
    }
    public static let functions: [UInt8: String] = [0: "无", 1: "播放／暂停", 5: "上一曲", 6: "下一曲", 7: "调整音量", 8: "切换降噪", 11: "增大音量", 12: "减小音量", 13: "切换设备", 29: "接听/挂断电话", 28: "拒接来电/挂断电话", 25: "AI 摘要操控"]
    public var allowedFunctions: [UInt8] {
        // X4 callControl profile: each gesture has its own function plus none, not a shared union.
        if isCall { return [[UInt8(29),0], [28,0], [25,0]][Int(action)-1] }
        guard button == 1, [1,2,3,4,5].contains(action) else { return [] }
        return action == 5 ? [7] : [0,1,5,6,8,11,12,13]
    }
    public var functionLabel: String { Self.functions[function] ?? "未识别的功能" }

}
public struct HeadsetEQ: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt8
    public var name: String
    public var selected: Bool
    public var minimum: Int
    public var maximum: Int
    public var frequencies: [Int]
    public var gains: [Int]
    public init(id: UInt8, name: String, selected: Bool = false, minimum: Int, maximum: Int, frequencies: [Int], gains: [Int]) {
        self.id = id; self.name = name; self.selected = selected; self.minimum = minimum; self.maximum = maximum
        self.frequencies = frequencies; self.gains = gains
    }
    public func validate() throws {
        guard (-128...127).contains(minimum), (-128...127).contains(maximum), minimum <= maximum,
              !frequencies.isEmpty, frequencies.count <= 32, frequencies.count == gains.count,
              frequencies.allSatisfy({ (1...65535).contains($0) }), Set(frequencies).count == frequencies.count,
              gains.allSatisfy({ (minimum...maximum).contains($0) }), name.utf8.count <= 64,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProtocolFailure("EQ 频段、增益范围或名称无效")
        }
    }
    public func settingPayload(action: UInt8 = 2) throws -> [UInt8] {
        try validate()
        // Melody actions: 1 create, 2 select/update, 3 delete; all carry the full curve.
        guard [1, 2, 3].contains(action) else { throw ProtocolFailure("EQ 操作无效") }
        var result: [UInt8] = [action, UInt8(bitPattern: Int8(minimum)), UInt8(bitPattern: Int8(maximum)), id, UInt8(name.utf8.count)]
        result += Array(name.utf8); result.append(UInt8(frequencies.count))
        for (f, g) in zip(frequencies, gains) { result += [UInt8(f & 255), UInt8(f >> 8), UInt8(bitPattern: Int8(g))] }
        return result
    }
}
public enum HeadsetFeature: UInt8, Codable, CaseIterable, Sendable {
    case wearDetection = 4, goldenSound = 11, personalANC = 12, multipoint = 17, hiRes = 24, spatialLegacy = 27, bassWave = 29
    public var title: String {
        switch self {
        case .wearDetection: return "耳机佩戴检测"
        case .goldenSound: return "黄金听感"
        case .personalANC: return "个性化降噪"
        case .multipoint: return "双设备连接"
        case .hiRes: return "HiRes 音频"
        case .spatialLegacy: return "耳机空间音频"
        case .bassWave: return "BassWave™动态低音"
        }
    }
}
public enum HeadsetSetting: Codable, Equatable, Sendable {
    case feature(HeadsetFeature, Bool)
    case noise(UInt8)
    case key(HeadsetKey)
    case preset(UInt8)
    case equalizer(HeadsetEQ, replacing: HeadsetEQ? = nil)
    case selectEqualizer(UInt8), createEqualizer(HeadsetEQ), deleteEqualizer(HeadsetEQ)
    case bassWave(Int)
    case spatial(UInt8)
    public var title: String {
        switch self {
        case .feature(let f, _): return f.title
        case .noise: return "降噪模式"
        case .key: return "操作配置"
        case .preset: return "音效预设"
        case .equalizer, .selectEqualizer: return "自定义均衡器"
        case .createEqualizer: return "新增均衡器"
        case .deleteEqualizer: return "删除均衡器"
        case .bassWave: return "BassWave 强度"
        case .spatial: return "耳机空间模式"
        }
    }
    public var query: HeadsetQuery {
        switch self {
        case .feature(let f, _): return .feature(f)
        case .noise: return .noiseCurrent
        case .key: return .keys
        case .preset: return .preset
        case .equalizer, .selectEqualizer, .createEqualizer, .deleteEqualizer: return .equalizers
        case .bassWave: return .bassWave
        case .spatial: return .spatial
        }
    }
}
public enum HeadsetQuery: Hashable, Sendable {
    case product, battery, versions, ears, keys, noiseCurrent, noiseAvailable, noiseIntelligent, preset, equalizers, bassWave, spatial, personalResult, goldenResult
    case feature(HeadsetFeature)
    public var command: UInt16 {
        switch self {
        case .product: return 0x0103
        case .versions: return 0x0105
        case .battery: return 0x0106
        case .keys: return 0x0108
        case .ears: return 0x0109
        case .noiseCurrent, .noiseAvailable, .noiseIntelligent: return 0x010c
        case .feature: return 0x010d
        case .preset: return 0x010f
        case .equalizers: return 0x0122
        case .bassWave: return 0x0124
        case .spatial: return 0x012a
        case .goldenResult: return 0x0115
        case .personalResult: return 0x011a
        }
    }
    public var key: String {
        switch self {
        case .feature(let f): return "feature.\(f.rawValue)"
        case .noiseIntelligent: return "noise.intelligent"
        case .noiseCurrent: return "noise.current"
        case .noiseAvailable: return "noise.available"
        default: return String(format: "%04X", command)
        }
    }
    public var payload: [UInt8] {
        switch self {
        case .keys: return [3, 1, 2, 3]
        case .noiseIntelligent: return [4, 1]
        case .noiseCurrent: return [1, 1]
        case .noiseAvailable: return [3, 1]
        case .feature(let f): return [1, f.rawValue]
        default: return []
        }
    }
    public func packet(sequence: UInt8) throws -> OppoControlPacket { try .init(command: command, sequence: sequence, payload: payload) }
    public func supported(by c: OppoControlCapabilities) -> Bool {
        switch self {
        case .feature(.bassWave), .bassWave: return c.hasBit(38)
        case .product, .feature: return true
        case .versions: return c.hasBit(0)
        case .battery: return c.hasBit(1)
        case .keys: return c.hasBit(3)
        case .ears: return c.hasBit(4)
        case .noiseCurrent, .noiseAvailable, .noiseIntelligent: return c.hasBit(8)
        case .preset: return c.hasBit(10)
        case .equalizers: return c.hasBit(34)
        case .spatial: return c.hasBit(47)
        case .goldenResult: return c.hasBit(19)
        case .personalResult: return c.hasBit(26)
        }
    }
    public static var initial: [Self] {
        [.product, .battery, .versions, .ears, .noiseAvailable, .noiseCurrent, .keys, .preset, .equalizers, .feature(.bassWave), .bassWave,
         .feature(.wearDetection), .feature(.multipoint), .feature(.goldenSound), .goldenResult, .feature(.hiRes)]
    }
}
public struct HeadsetSnapshot: Codable, Equatable, Sendable {
    public var address: String
    public var generation: UUID
    public var connected = false
    public var serviceUUID: String?
    public var productID: UInt32?
    public var capabilities: OppoControlCapabilities?
    public var currentCodec: UInt8?
    public var notificationIDs: [UInt8] = []
    public var battery: [UInt8: HeadsetValue<HeadsetBattery>] = [:]
    public var ears: [UInt8: HeadsetValue<HeadsetEarState>] = [:]
    public var versions: HeadsetValue<[HeadsetVersion]>?
    public var keys: HeadsetValue<[HeadsetKey]>?
    public var noiseAvailable: HeadsetValue<[UInt8]>?
    public var noise: HeadsetValue<UInt8>?
    public var noiseType: HeadsetValue<UInt8>?
    public var intelligentNoise: HeadsetValue<UInt8>?
    public var goldenResult: HeadsetValue<Bool>?
    public var preset: HeadsetValue<UInt8>?
    public var equalizers: HeadsetValue<[HeadsetEQ]>?
    public var bassWave: HeadsetValue<HeadsetBassWave>?
    public var features: [UInt8: HeadsetValue<Bool>] = [:]
    public var spatial: HeadsetValue<UInt8>?
    public var personalResult: HeadsetValue<Bool>?
    public var issues: [String: String] = [:]
    public init(address: String, generation: UUID = UUID()) { self.address = address; self.generation = generation }
    public var isX4: Bool { productID == 0x06ec10 }
    public static func earLabel(_ id: UInt8) -> String { [1: "左耳", 2: "右耳", 3: "充电盒", 4: "双耳"][id] ?? "部件 \(id)" }
    public static func noiseLabel(_ index: UInt8) -> String {
        HeadsetNoiseMode.x4[index]?.name ?? [0: "关闭", 3: "关闭", 2: "通透", 8: "通透", 1: "降噪", 11: "自适应"][index] ?? "未识别的降噪模式"
    }
    public var noiseChoices: [UInt8] {
        guard let profile, supports(.noiseCurrent) else { return [] }
        let known = isX4 ? HeadsetNoiseGroup.allCases.flatMap(\.modes) + [11] : profile.noiseModes.map(\.protocolIndex) + profile.noise.filter { $0.group == .adaptive }.map(\.protocolIndex)
        return usesNoiseProfile ? known.filter { id in !(profile.noiseModes + profile.noise).contains { $0.protocolIndex == id && $0.decideByEarDevice == true } } : known.filter { noiseAvailable?.value.contains($0) == true }
    }
    public var presetChoices: [UInt8] { supports(.preset) ? profile?.presets.map(\.id) ?? [] : [] }
    public var wearMask: UInt8? {
        guard connected, notificationIDs.contains(2), let left = ears[1], let right = ears[2], !left.stale, !right.stale else { return nil }
        return (left.value.inEar ? 1 : 0) | (right.value.inEar ? 2 : 0)
    }
    public var bothEarsUnworn: Bool {
        guard connected, let left = ears[1], let right = ears[2], !left.stale, !right.stale else { return false }
        return !left.value.inEar && !right.value.inEar
    }
    public mutating func markStale() {
        connected = false
        for key in battery.keys { battery[key]?.stale = true }
        for key in ears.keys { ears[key]?.stale = true }
        for key in features.keys { features[key]?.stale = true }
        versions?.stale = true; keys?.stale = true; noiseAvailable?.stale = true; noise?.stale = true; noiseType?.stale = true; intelligentNoise?.stale = true; goldenResult?.stale = true
        preset?.stale = true; equalizers?.stale = true; bassWave?.stale = true; spatial?.stale = true; personalResult?.stale = true
    }
    public mutating func markStale(_ query: HeadsetQuery, reason: String) {
        issues[query.key] = reason
        switch query {
        case .product: productID = nil
        case .battery: for key in battery.keys { battery[key]?.stale = true }
        case .ears: for key in ears.keys { ears[key]?.stale = true }
        case .versions: versions?.stale = true
        case .keys: keys?.stale = true
        case .noiseCurrent: noise?.stale = true; noiseType?.stale = true
        case .noiseIntelligent: intelligentNoise?.stale = true
        case .noiseAvailable: noiseAvailable?.stale = true
        case .preset: preset?.stale = true
        case .equalizers: equalizers?.stale = true
        case .bassWave: bassWave?.stale = true
        case .spatial: spatial?.stale = true
        case .goldenResult: goldenResult?.stale = true
        case .personalResult: personalResult?.stale = true
        case .feature(let f): features[f.rawValue]?.stale = true
        }
    }
    public func restriction(for setting: HeadsetSetting) -> String? {
        guard connected, let profile, let caps = capabilities, supports(setting.query) else { return "本次连接尚未确认此型号的控制接口与能力" }
        guard prerequisiteQueries(for: setting).allSatisfy({ issues[$0.key] == nil }) else { return "请先成功读取当前设置" }
        if setting.changesSoundSelection {
            guard caps.hasBit(10), preset?.stale == false, (!supports(.equalizers) || equalizers?.stale == false) else { return "请先读取内置音效和自定义均衡器" }
        }
        switch setting {
        case .feature(let f, let enabled):
            guard caps.supportsFeatureSetter, features[f.rawValue]?.stale == false else { return "尚未确认功能状态或设置能力" }
            if f == .bassWave && !caps.hasBit(38) { return "耳机未报告 BassWave 能力" }
            if f == .hiRes && ![3, 8].contains(currentCodec ?? 0) { return "HiRes 需要已确认的高清音频连接" }
            if f == .goldenSound && enabled && (!caps.hasBit(19) || goldenResult?.stale != false || goldenResult?.value != true) { return goldenResult?.value == false && goldenResult?.stale == false ? "耳机中没有已保存的黄金听感结果，请先在手机完成测试" : "尚未确认耳机中已有黄金听感结果，请刷新或前往手机设置" }
            if [.personalANC, .spatialLegacy].contains(f) { return "尚未完成已有结果与耳机独立处理验证；本版只读取状态" }
        case .noise(let n):
            if bothEarsUnworn { return "佩戴耳机以启用降噪" }
            guard canChooseNoise, noiseChoices.contains(n) else { return "耳机未报告此降噪模式" }
        case .key(let key):
            guard caps.hasBit(3), keys?.stale == false, [1, 2, 4].contains(key.ear),
                  keys?.value.contains(where: { $0.id == key.id }) == true,
                  profile.allowedFunctions(key).contains(key.function) else { return "耳机未报告此操作，或该动作不支持所选功能" }
        case .preset(let p):
            guard caps.hasBit(10), preset?.stale == false, presetChoices.contains(p) else { return "音效预设尚未确认" }
        case .equalizer(let curve, let original):
            guard caps.hasBit(34), equalizers?.stale == false, let old = equalizers?.value.first(where: { $0.id == curve.id }),
                  old.frequencies == curve.frequencies, old.minimum == curve.minimum, old.maximum == curve.maximum else { return "EQ 槽位或频段已变化，请重新读取" }
            if let original, !old.sameContent(as: original) { return "均衡器已在其他设备修改，请关闭编辑器并重新打开" }
            do { try curve.validate() } catch { return error.localizedDescription }
        case .selectEqualizer(let id):
            guard equalizers?.value.contains(where: { $0.id == id }) == true else { return "均衡器已不存在，请刷新" }
        case .createEqualizer(let curve):
            guard let template = newEqualizer else { return "此型号的均衡器容量已满或缺少空槽频段依据；请删除一个或刷新状态" }
            guard curve.id == 0, curve.minimum == template.minimum, curve.maximum == template.maximum, curve.frequencies == template.frequencies else { return "均衡器频段或范围已变化，请重新创建" }
            guard !curve.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "请输入均衡器名称" }
            do { try curve.validate() } catch { return error.localizedDescription }
        case .deleteEqualizer(let curve):
            guard let old = equalizers?.value.first(where: { $0.id == curve.id }), old.sameContent(as: curve) else { return "均衡器已变化，请刷新后再删除" }
        case .bassWave(let value):
            guard caps.hasBit(38), features[29]?.stale == false, features[29]?.value == true,
                  bassWave?.stale == false, let bass = bassWave?.value else { return "请先读取并开启 BassWave" }
            do { _ = try bass.payload(current: value) } catch { return error.localizedDescription }
        case .spatial: return "尚未完成 Mac 输入下的耳机独立空间效果验证；本版只读取状态"
        }
        return nil
    }
    public func packet(for setting: HeadsetSetting, sequence: UInt8) throws -> OppoControlPacket {
        if let reason = restriction(for: setting) { throw ProtocolFailure(reason) }
        switch setting {
        case .feature(let f, let value): return try .init(command: 0x0403, sequence: sequence, payload: [f.rawValue, value ? 1 : 0])
        case .noise(let n):
            var bits = Array(repeating: UInt8(0), count: Int(n) / 8 + 1); bits[Int(n) / 8] = 1 << (n % 8)
            return try .init(command: 0x0404, sequence: sequence, payload: [1, 1] + bits)
        case .key(let key): return try .init(command: 0x0401, sequence: sequence, payload: [1] + key.bytes)
        case .preset(let p): return try .init(command: 0x0406, sequence: sequence, payload: [p])
        case .equalizer(let curve, _): return try .init(command: 0x0418, sequence: sequence, payload: curve.settingPayload())
        case .selectEqualizer(let id):
            guard let curve = equalizers?.value.first(where: { $0.id == id }) else { throw ProtocolFailure("均衡器不存在") }
            return try .init(command: 0x0418, sequence: sequence, payload: curve.settingPayload())
        case .createEqualizer(let curve): return try .init(command: 0x0418, sequence: sequence, payload: curve.settingPayload(action: 1))
        case .deleteEqualizer(let curve): return try .init(command: 0x0418, sequence: sequence, payload: curve.settingPayload(action: 3))
        case .bassWave(let value):
            guard let bass = bassWave?.value else { throw ProtocolFailure("BassWave 范围未知") }
            return try .init(command: 0x041b, sequence: sequence, payload: bass.payload(current: value))
        case .spatial(let p): return try .init(command: 0x0422, sequence: sequence, payload: [p])
        }
    }
    public func confirms(_ setting: HeadsetSetting) -> Bool {
        switch setting {
        case .feature(let f, let value): return features[f.rawValue]?.value == value && features[f.rawValue]?.stale == false
        case .noise(let n):
            // Parent 11 enters adaptive using the earbud's remembered weighting.
            // It may report that resolved child; never substitute a default weight.
            guard let noise, !noise.stale else { return false }
            return noise.value == n || (profile?.noise.first(where: { $0.protocolIndex == n })?.childrenMode?.contains(where: { $0.protocolIndex == noise.value }) == true)
        case .key(let key): return keys?.value.contains(key) == true && keys?.stale == false
        case .preset(let p): return soundSelection == .preset(p)
        case .equalizer(let curve, _): return soundSelection == .equalizer(curve.id) && equalizers?.value.contains(where: { $0.id == curve.id && $0.sameContent(as: curve) }) == true
        case .selectEqualizer(let id): return soundSelection == .equalizer(id)
        case .createEqualizer, .deleteEqualizer: return false // Requires the correlated pre-write list.
        case .bassWave(let value): return bassWave?.stale == false && bassWave?.value.current == value
        case .spatial(let p): return spatial?.value == p && spatial?.stale == false
        }
    }
}

private struct HeadsetReader {
    let bytes: [UInt8]; var offset = 0
    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= bytes.count else { throw ProtocolFailure("耳机回复长度不完整") }
        defer { offset += n }; return Array(bytes[offset..<offset+n])
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func signed() throws -> Int { Int(Int8(bitPattern: try byte())) }
    mutating func word() throws -> Int { let b = try take(2); return Int(b[0]) | Int(b[1]) << 8 }
    func finish() throws { guard offset == bytes.count else { throw ProtocolFailure("耳机回复含未知尾部字段") } }
}
public extension HeadsetSnapshot {
    mutating func consume(_ packet: OppoControlPacket, query: HeadsetQuery, at date: Date = Date()) throws {
        guard packet.command == query.command | 0x8000, packet.payload.first == 0 else { throw ProtocolFailure("耳机拒绝查询（\(packet.payload.first.map(String.init) ?? "无响应码")）") }
        var r = HeadsetReader(bytes: Array(packet.payload.dropFirst()))
        // Parse into a copy: a malformed suffix must not commit a partial update.
        var next = self
        switch query {
        case .product:
            let b = try r.take(3); next.productID = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16
        case .battery:
            let count = Int(try r.byte()); var seen = Set<UInt8>()
            for _ in 0..<count {
                let id = try r.byte(), raw = try r.byte()
                guard seen.insert(id).inserted else { throw ProtocolFailure("电量部件编号重复") }
                let level = Int(raw & 127)
                next.battery[id] = .init(.init(percent: level <= 100 ? level : nil, charging: level <= 100 ? raw & 128 != 0 : nil), at: date)
            }
            for id in next.battery.keys where !seen.contains(id) { next.battery[id]?.stale = true }
        case .ears:
            let count = Int(try r.byte()); var seen = Set<UInt8>()
            for _ in 0..<count {
                let id = try r.byte(), raw = try r.byte()
                guard seen.insert(id).inserted else { throw ProtocolFailure("佩戴部件编号重复") }
                next.ears[id] = .init(.init(raw: raw), at: date)
            }
            for id in next.ears.keys where !seen.contains(id) { next.ears[id]?.stale = true }
        case .versions:
            let count = Int(try r.byte()), data = try r.take(r.bytes.count - r.offset)
            guard let text = String(bytes: data, encoding: .utf8) else { throw ProtocolFailure("固件版本不是 UTF-8") }
            let fields = text.split(separator: ",", omittingEmptySubsequences: false)
            guard count > 0, fields.count == count * 3 else { throw ProtocolFailure("固件版本数量不一致") }
            var versions: [HeadsetVersion] = []
            for i in stride(from: 0, to: fields.count, by: 3) {
                guard let id = UInt8(fields[i]), let kind = UInt8(fields[i+1]), fields[i+2].count <= 128 else { throw ProtocolFailure("固件版本字段无效") }
                versions.append(.init(device: id, kind: kind, version: String(fields[i+2]).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            guard Set(versions.map(\.id)).count == versions.count else { throw ProtocolFailure("固件版本重复") }
            next.versions = .init(versions, at: date)
        case .keys:
            let count = Int(try r.byte()); var keys: [HeadsetKey] = []
            for _ in 0..<count { keys.append(try .init(ear: r.byte(), button: r.byte(), action: r.byte(), function: r.byte())) }
            guard Set(keys.map(\.id)).count == keys.count else { throw ProtocolFailure("操作映射重复") }
            next.keys = .init(keys, at: date)
        case .feature(let f):
            guard try r.byte() == 1, try r.byte() == f.rawValue else { throw ProtocolFailure("功能回复与查询不匹配") }
            let value = try r.byte(); guard value <= 1 else { throw ProtocolFailure("功能值不是已识别的开关") }
            next.features[f.rawValue] = .init(value == 1, at: date)
        case .noiseCurrent, .noiseAvailable, .noiseIntelligent:
            let action = try r.byte(), type = try r.byte()
            let types: [UInt8] = query == .noiseCurrent ? [1,5] : query == .noiseIntelligent ? [1] : [1,3,4]
            guard action == (query == .noiseCurrent ? 1 : query == .noiseIntelligent ? 4 : 3), types.contains(type) else { throw ProtocolFailure("降噪回复格式未识别（action=\(action), type=\(type)）") }
            let bytes = try r.take(r.bytes.count - r.offset)
            guard !bytes.isEmpty, bytes.count <= 4 else { throw ProtocolFailure("降噪位图长度无效") }
            let bits: [UInt8] = (0..<bytes.count*8).filter { bytes[$0/8] & (1 << ($0%8)) != 0 }.map(UInt8.init)
            if query == .noiseCurrent {
                guard bits.count == 1 else { throw ProtocolFailure("当前降噪模式不唯一") }; if next.noise?.value != bits[0] { next.intelligentNoise?.stale = true }
                next.noise = .init(bits[0], at: date); next.noiseType = .init(type, at: date)
            } else if query == .noiseIntelligent {
                guard bits.count == 1 else { throw ProtocolFailure("智能降噪实际档位不唯一") }
                next.intelligentNoise = .init(bits[0], at: date)
            } else { next.noiseAvailable = .init(bits, at: date) }
        case .bassWave:
            let bass = try HeadsetBassWave(minimum: r.signed(), maximum: r.signed(), current: r.signed())
            try bass.validate(); next.bassWave = .init(bass, at: date)
        case .preset: next.preset = .init(try r.byte(), at: date)
        case .spatial: next.spatial = .init(try r.byte(), at: date)
        case .goldenResult:
            // 0115 returns version, count, count*3 detecting tuples, 4-byte result ID and optional UTF-8 name.
            // Only retain presence. Never persist hearing measurements, the ID, or a person's name.
            _ = try r.byte()
            let count = Int(try r.byte())
            _ = try r.take(count * 3); _ = try r.take(4)
            let name = try r.take(r.bytes.count - r.offset)
            guard name.count <= 256, String(bytes: name, encoding: .utf8) != nil else { throw ProtocolFailure("黄金听感结果格式未识别") }
            next.goldenResult = .init(count > 0, at: date)
        case .personalResult:
            let value = try r.byte(); guard value <= 1 else { throw ProtocolFailure("个性化结果标志未知") }
            next.personalResult = .init(value == 1, at: date)
        case .equalizers:
            let count = Int(try r.byte()); guard count <= 32 else { throw ProtocolFailure("EQ 数量超过上限") }
            var curves: [HeadsetEQ] = []
            for _ in 0..<count {
                let selected = try r.byte(), minimum = try r.signed(), maximum = try r.signed(), id = try r.byte()
                guard selected <= 1 else { throw ProtocolFailure("EQ 选择状态未知") }
                let nameData = try r.take(Int(r.byte()))
                guard let name = String(bytes: nameData, encoding: .utf8) else { throw ProtocolFailure("EQ 名称不是 UTF-8") }
                let bands = Int(try r.byte()); guard bands > 0, bands <= 32 else { throw ProtocolFailure("EQ 频段数无效") }
                var frequencies: [Int] = [], gains: [Int] = []
                for _ in 0..<bands { frequencies.append(try r.word()); gains.append(try r.signed()) }
                let curve = HeadsetEQ(id: id, name: name, selected: selected == 1, minimum: minimum, maximum: maximum, frequencies: frequencies, gains: gains)
                try curve.validate(); curves.append(curve)
            }
            guard Set(curves.map(\.id)).count == curves.count else { throw ProtocolFailure("EQ 槽位重复") }
            next.equalizers = .init(curves, at: date)
        }
        try r.finish(); next.issues.removeValue(forKey: query.key); self = next
    }
    mutating func consumeNotification(_ packet: OppoControlPacket, at date: Date = Date()) throws -> HeadsetGesture? {
        guard packet.command == 0x0204, let id = packet.payload.first, notificationIDs.contains(id) else { return nil }
        let rest = Array(packet.payload.dropFirst())
        let query: HeadsetQuery
        switch id {
        case 1: query = .battery
        case 2: query = .ears
        case 3:
            // Noise events share ID 3: current mode, cycling preferences, support list, or intelligent status.
            // Smart depth is a separate observation and cannot change the selected mode.
            guard let action = rest.first else { throw ProtocolFailure("降噪通知缺少动作类型") }
            if action == 1 { query = .noiseCurrent }
            else if action == 3 { query = .noiseAvailable }
            else if action == 4 { query = .noiseIntelligent }
            else { return nil }
        case 0xf1: return try HeadsetGesture(payload: rest, sequence: packet.sequence, at: date)
        default: return nil
        }
        let previousBattery = battery, previousEars = ears
        try consume(.init(command: query.command | 0x8000, payload: [0] + rest), query: query, at: date)
        // Event payloads may contain only the changed ear; absence is not a disconnect notification.
        if query == .battery { for (id, old) in previousBattery where battery[id]?.updatedAt != date { battery[id] = old } }
        if query == .ears { for (id, old) in previousEars where ears[id]?.updatedAt != date { ears[id] = old } }
        return nil
    }
}
public struct HeadsetGesture: Codable, Equatable, Sendable {
    public let key: HeadsetKey
    public let scene: UInt8
    public let sequence: UInt8
    public let receivedAt: Date
    public init(payload: [UInt8], sequence: UInt8, at date: Date) throws {
        guard payload.count >= 5, payload.count <= 37, (payload.count - 5) % 2 == 0 else { throw ProtocolFailure("操作事件长度无效") }
        key = .init(ear: payload[0], button: payload[1], action: payload[2], function: payload[3]); scene = payload[4]
        self.sequence = sequence; receivedAt = date
    }
}
public struct HeadsetOperationResult: Codable, Equatable, Sendable {
    public var setting: HeadsetSetting
    public var acknowledged: Bool
    public var confirmed: Bool
    public var message: String
    public init(setting: HeadsetSetting, acknowledged: Bool = false, confirmed: Bool = false, message: String) {
        self.setting = setting; self.acknowledged = acknowledged; self.confirmed = confirmed; self.message = message
    }
}
