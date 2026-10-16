import Foundation

/// ELNK control-command availability, not AVDTP audio-format capabilities.
/// Bit assignments verified against the user's Melody 17.6.3 protocol table.
public struct OppoControlCapabilities: Codable, Equatable, Sendable {
    public let bitmap: [UInt8]
    public init(reply: OppoControlPacket) throws {
        guard reply.command == 0x8100, reply.payload.count >= 2, reply.payload[0] == 0 else {
            throw ProtocolFailure("耳机控制能力查询被拒绝或回复不完整")
        }
        bitmap = Array(reply.payload.dropFirst())
    }
    public func hasBit(_ bit: Int) -> Bool {
        bit >= 0 && bit / 8 < bitmap.count && bitmap[bit / 8] & (1 << (bit % 8)) != 0
    }
    public var supportsFeatureSetter: Bool { hasBit(7) }
    public var supportsCodecSelection: Bool { hasBit(37) }
    public var supportsCurrentCodecQuery: Bool { hasBit(17) }
}

/// Names from Melody's control protocol, separate from AVDTP codec identifiers.
public enum OppoControlCodec {
    public static func label(_ id: UInt8) -> String {
        switch id {
        case 1: return "SBC"
        case 2: return "AAC"
        case 3: return "LDAC"
        case 4: return "aptX"
        case 5: return "aptX HD"
        case 6: return "aptX Adaptive"
        case 7, 8: return "LHDC（控制编号 \(id)）"
        default: return "未知编码（控制编号 \(id)）"
        }
    }
    public static func ids(in mask: UInt16) -> [UInt8] {
        (0..<16).filter { mask & (1 << $0) != 0 }.map { UInt8($0 + 1) }
    }
}

public extension OppoControlPacket {
    static var controlCapabilitiesQuery: Self { try! Self(command: 0x0100, sequence: 0xe0) }
    // Melody/HeyMelody exchange their receive MTU and vendor identifier after
    // command discovery. FFFF is the companion app's non-OPPO-host identifier.
    static var controlMTUExchange: Self { try! Self(command: 0x0101, sequence: 0xe1, payload: [0, 2]) }
    static var controlVendorExchange: Self { try! Self(command: 0x0102, sequence: 0xe2, payload: [0xff, 0xff]) }
    static var integratedControlVendorExchange: Self { try! Self(command: 0x0102, sequence: 0xe2, payload: [0x9a, 0x07]) }
    static var controlVersionQuery: Self { try! Self(command: 0x0104, sequence: 0xe3) }
    static var currentCodecQuery: Self { try! Self(command: 0x0114, sequence: 0xe4) }
    static var codecListQuery: Self { try! Self(command: 0x0123, sequence: 0xe5) }

    /// Melody's codec settings page uses 041A and keeps its all-capability byte
    /// zero. Preserve the queried codec; never turn AAC into LHDC implicitly.
    static func codecHiResEnable(capabilities: OppoControlCapabilities, currentCodec: UInt8?,
                                 codecListMask: UInt16?, selectLHDC: Bool = false) throws -> Self {
        guard capabilities.supportsCodecSelection, let currentCodec, let mask = codecListMask else {
            throw ProtocolFailure("耳机未报告完整的编码设置能力，未发送设置")
        }
        let codec: UInt8 = selectLHDC ? (mask & 0x80 != 0 ? 8 : 7) : currentCodec
        guard (codec == 3 || codec == 8 || (selectLHDC && codec == 7)),
              mask & (1 << (Int(codec) - 1)) != 0 else {
            throw ProtocolFailure("耳机尚未报告可保持当前编码的 HiRes 设置路径，未发送设置")
        }
        return try Self(command: 0x041a, sequence: 0xf4, payload: [codec, 1, 0])
    }

    func successfulUInt16Reply(to request: Self) throws -> UInt16 {
        guard isReply(to: request), payload.count == 3, payload[0] == 0 else {
            throw ProtocolFailure("耳机控制回复被拒绝或长度未知（\(String(format: "%04X", command))）")
        }
        return UInt16(payload[1]) | UInt16(payload[2]) << 8
    }
    func currentCodecID() throws -> UInt8 {
        guard isReply(to: .currentCodecQuery), payload.count == 2, payload[0] == 0 else {
            throw ProtocolFailure("当前耳机编码回复被拒绝或格式未知")
        }
        return payload[1]
    }
}
