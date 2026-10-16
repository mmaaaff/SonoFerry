import Foundation

public enum CapabilityParser {
    public static func codec(endpoint: Int, bytes: [UInt8]) throws -> CodecCapabilities {
        guard (1...62).contains(endpoint), bytes.count >= 2, bytes[0] == 0 else { throw ProtocolFailure("无效的音频端点能力") }
        var id: CodecID?, rates = [Int](), depths: [Int]?, stereo = false, minimum: Int?, maximum: Int?, version: Int?, frame: Bool?
        if bytes[1] == 0xff {
            guard bytes.count >= 8 else { throw ProtocolFailure("厂商编码能力被截断") }
            let vendor = UInt32(bytes[2]) | UInt32(bytes[3]) << 8 | UInt32(bytes[4]) << 16 | UInt32(bytes[5]) << 24
            let code = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
            if vendor == 0x12d && code == 0xaa {
                guard bytes.count == 10 else { throw ProtocolFailure("LDAC 能力长度错误") }
                id = .ldac
                rates = [(0x20,44100),(0x10,48000),(8,88200),(4,96000),(2,176400),(1,192000)].filter { Int(bytes[8]) & $0.0 != 0 }.map(\.1)
                stereo = bytes[9] & 1 != 0
            } else if vendor == 0x53a && code == 0x4c35 {
                guard bytes.count == 13 else { throw ProtocolFailure("不支持的 LHDC V5 能力长度") }
                id = .lhdcV5
                rates = [(0x20,44100),(0x10,48000),(4,96000),(1,192000)].filter { Int(bytes[8]) & $0.0 != 0 }.map(\.1)
                depths = [(4,16),(2,24),(1,32)].filter { Int(bytes[9]) & $0.0 != 0 }.map(\.1)
                minimum = [64,160,256,400][Int((bytes[9] >> 6) & 3)]
                maximum = [1000,400,500,900][Int((bytes[9] >> 4) & 3)]
                version = Int(bytes[10] & 15); frame = bytes[10] & 0x10 != 0; stereo = true
            }
        }
        return CodecCapabilities(endpoint: endpoint, codec: id, sampleRates: rates, bitDepths: depths, stereo: stereo,
            minimumBitrate: minimum, maximumBitrate: maximum, version: version, frame5ms: frame,
            rawHex: bytes.map { String(format: "%02X", $0) }.joined())
    }
    public static func serviceCategories(_ bytes: [UInt8]) throws -> [Int: [UInt8]] {
        var offset = 0, result: [Int: [UInt8]] = [:]
        while offset < bytes.count {
            guard bytes.count - offset >= 2 else { throw ProtocolFailure("能力 TLV 头被截断") }
            let category = Int(bytes[offset]), size = Int(bytes[offset + 1]); offset += 2
            guard category > 0, result[category] == nil, size <= bytes.count - offset else { throw ProtocolFailure("重复或被截断的能力 TLV") }
            result[category] = Array(bytes[offset..<offset+size]); offset += size
        }
        return result
    }
}

/// Reassembles AVDTP signaling fragments only after the transport has supplied exact SDUs.
public struct AVDTPReassembler {
    private var label: UInt8?, message: UInt8 = 0, signal: UInt8 = 0, remaining = 0
    private var payload: [UInt8] = []
    public init() {}
    public mutating func reset() { label = nil; payload = []; remaining = 0 }
    public mutating func accept(_ sdu: [UInt8]) throws -> [UInt8]? {
        do { return try consume(sdu) } catch { reset(); throw error }
    }
    private mutating func consume(_ bytes: [UInt8]) throws -> [UInt8]? {
        guard !bytes.isEmpty else { throw ProtocolFailure("空信令报文") }
        let kind = (bytes[0] >> 2) & 3, current = bytes[0] >> 4, msg = bytes[0] & 3
        switch kind {
        case 0:
            guard label == nil, bytes.count >= 2, bytes[1] & 0xc0 == 0 else { throw ProtocolFailure("无效的单包信令") }
            return bytes
        case 1:
            guard label == nil, bytes.count >= 3, bytes[1] >= 2, bytes[2] & 0xc0 == 0 else { throw ProtocolFailure("无效的信令分片起始包") }
            label = current; message = msg; signal = bytes[2]; remaining = Int(bytes[1]) - 1; payload = Array(bytes.dropFirst(3))
        case 2, 3:
            guard label == current, message == msg, remaining > 0, (kind == 3) == (remaining == 1) else { throw ProtocolFailure("信令分片顺序或事务号不匹配") }
            payload += bytes.dropFirst(); remaining -= 1
            guard payload.count <= 4096 else { throw ProtocolFailure("信令分片超过容量") }
            if kind == 3 { let value = [(current << 4) | msg, signal] + payload; reset(); return value }
        default: throw ProtocolFailure("无效的分片类型")
        }
        guard payload.count <= 4096 else { throw ProtocolFailure("信令分片超过容量") }
        return nil
    }
}
