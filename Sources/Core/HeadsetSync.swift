import Foundation

public extension HeadsetSnapshot {
    // Melody HeadsetCoreService's RequestCommandManager handles these independent
    // device requests. They are not 0204 registered events and carry no status byte.
    static let syncCommands: Set<UInt16> = [0x0503, 0x0504, 0x0506, 0x0508]

    @discardableResult mutating func consumeSync(_ packet: OppoControlPacket, at date: Date = Date()) throws -> [HeadsetQuery] {
        guard connected, Self.syncCommands.contains(packet.command) else { return [] }
        var next = self
        var affected: [HeadsetQuery] = []
        func response(_ query: HeadsetQuery) throws -> OppoControlPacket {
            try .init(command: query.command | 0x8000, payload: [0] + packet.payload)
        }
        switch packet.command {
        case 0x0503:
            guard let count = packet.payload.first, count > 0, count <= 64,
                  packet.payload.count == 1 + Int(count) * 2 else { throw ProtocolFailure("功能同步长度无效") }
            var seen: Set<UInt8> = []
            for i in stride(from: 1, to: packet.payload.count, by: 2) {
                let id = packet.payload[i], value = packet.payload[i+1]
                guard seen.insert(id).inserted else { throw ProtocolFailure("功能同步包含重复项目") }
                guard let feature = HeadsetFeature(rawValue: id) else { continue }
                guard value <= 1 else { throw ProtocolFailure("功能同步开关值无效") }
                let query = HeadsetQuery.feature(feature)
                next.features[id] = .init(value == 1, at: date)
                next.issues.removeValue(forKey: query.key); affected.append(query)
            }
        case 0x0504:
            try next.consume(response(.preset), query: .preset, at: date)
            let mode = next.preset!.value
            // Built-ins and custom curves share one selection. The curve contents
            // still retain their own freshness; a selection event cannot refresh them.
            if next.presetChoices.contains(mode) || next.equalizers?.value.contains(where: { $0.id == mode }) == true {
                if var curves = next.equalizers {
                    for i in curves.value.indices { curves.value[i].selected = curves.value[i].id == mode && !next.presetChoices.contains(mode) }
                    next.equalizers = curves
                }
            } else { next.equalizers?.stale = true }
            affected = [.preset, .equalizers]
        case 0x0506:
            try next.consume(response(.equalizers), query: .equalizers, at: date)
            let selected = next.equalizers!.value.filter(\.selected)
            guard selected.count <= 1 else { throw ProtocolFailure("同步的自定义均衡器选择不唯一") }
            if let curve = selected.first { next.preset = .init(curve.id, at: date) }
            else if !next.presetChoices.contains(next.preset?.value ?? 255) { next.preset?.stale = true }
            affected = [.preset, .equalizers]
        case 0x0508:
            try next.consume(response(.bassWave), query: .bassWave, at: date); affected = [.bassWave]
        default: break
        }
        next.issues.removeValue(forKey: "sync")
        self = next
        return affected
    }
}
