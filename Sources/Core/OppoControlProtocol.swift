import Foundation

/// Experimental control protocol, separate from AVDTP codec capabilities.
/// Format references and validation limits are documented in docs/OPPO-CONTROL.md.
public struct OppoControlPacket: Equatable, Sendable {
    // ELNK service observed in this Enco X4's SDP, independent of device name.
    public static let serviceUUID = "0000079A-D102-11E1-9B23-00025B00A5A5"
    public static let serviceUUIDBytes: [UInt8] = [0,0,0x07,0x9a,0xd1,0x02,0x11,0xe1,0x9b,0x23,0,0x02,0x5b,0,0xa5,0xa5]
    public let command: UInt16
    public let sequence: UInt8
    public let payload: [UInt8]
    public init(command: UInt16, sequence: UInt8 = 0xf0, payload: [UInt8] = []) throws {
        guard payload.count <= 4096 else { throw ProtocolFailure("OPPO 控制报文超过 4096 字节上限") }
        self.command = command; self.sequence = sequence; self.payload = payload
    }
    public var bytes: [UInt8] {
        let length = payload.count + 7
        let encoded: [UInt8] = length < 128 ? [UInt8(length)] : [UInt8(length & 127) | 128, UInt8(length >> 7)]
        return [0xaa] + encoded + [0, 0, UInt8(command & 0xff), UInt8(command >> 8),
         sequence, UInt8(payload.count & 255), UInt8(payload.count >> 8)] + payload
    }
    public var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    public static func notificationQuery() -> Self { try! Self(command: 0x0200) }
    public static func notificationRegistration(_ ids: [UInt8]) throws -> Self {
        guard ids.count <= 247, Set(ids).count == ids.count else { throw ProtocolFailure("无效的 OPPO 通知订阅列表") }
        return try Self(command: 0x0205, sequence: 0xf1, payload: [UInt8(ids.count)] + ids)
    }
    /// Count-prefixed single-feature query, verified on X4 over AAC and LHDC.
    public static func hiResQuery(sequence: UInt8 = 0xf0) -> Self { try! Self(command: 0x010d, sequence: sequence, payload: [1, 0x18]) }
    /// Public diagnostic query, retained as raw bytes; no heuristic field scan.
    public static func referenceBatchQuery() -> Self {
        try! Self(command: 0x010d, sequence: 0xf3, payload: [0x0b,5,4,0x0b,0x11,0x13,0x18,6,0x1b,0x1c,0x27,0x28])
    }
    public func isReply(to request: Self) -> Bool { sequence == request.sequence && command == request.command | 0x8000 }
    public static func hiResSet(_ enabled: Bool, sequence: UInt8 = 0xf0) -> Self {
        try! Self(command: 0x0403, sequence: sequence, payload: [0x18, enabled ? 1 : 0])
    }
    public func notificationIDs() throws -> [UInt8] {
        guard command == 0x8200, payload.count >= 2, payload[0] == 0,
              Int(payload[1]) == payload.count - 2 else {
            throw ProtocolFailure("OPPO 通知能力回复被拒绝或格式未知")
        }
        let ids = Array(payload.dropFirst(2))
        guard Set(ids).count == ids.count else { throw ProtocolFailure("OPPO 通知能力包含重复编号") }
        return ids
    }
    /// X4 returns an overall result, count and (notification ID, result) pairs.
    /// A zero overall result can contain nonzero per-ID results. Keep those raw;
    /// notification registration is not evidence of any persistent feature state.
    public func notificationRegistrationResults(for request: Self) throws -> [OppoNotificationResult] {
        guard request.command == 0x0205, !request.payload.isEmpty,
              Int(request.payload[0]) == request.payload.count - 1,
              isReply(to: request), payload.count >= 2, payload[0] == 0,
              payload[1] == request.payload[0], payload.count == 2 + 2 * Int(payload[1]) else {
            throw ProtocolFailure("OPPO 会话通知订阅被拒绝或回复格式未知")
        }
        let results = stride(from: 2, to: payload.count, by: 2).map {
            OppoNotificationResult(id: payload[$0], result: payload[$0 + 1])
        }
        guard results.map(\.id) == Array(request.payload.dropFirst()),
              Set(results.map(\.id)).count == results.count else {
            throw ProtocolFailure("OPPO 会话通知订阅回复编号与请求不一致")
        }
        return results
    }
    /// Exact single-feature envelope, verified by phone on/off and Mac LHDC
    /// roundtrips. The adapter exposes it as HiRes only in a confirmed HD context.
    public func hiResCandidateValue() throws -> UInt8 {
        guard command == 0x810d, payload.count == 4, payload[0] == 0,
              payload[1] == 1, payload[2] == 0x18, payload[3] <= 1 else {
            throw ProtocolFailure("HiRes 回复不是已识别的单一开关格式；保留为未知")
        }
        return payload[3]
    }
}

public struct OppoNotificationResult: Codable, Equatable, Sendable {
    public let id: UInt8
    public let result: UInt8
}

/// RFCOMM is a stream: callbacks may contain a fraction of a frame or many frames.
/// Do not scan for AA after corrupt data; it can also occur inside a payload.
public struct OppoControlFramer: Sendable {
    private var pending: [UInt8] = []
    private var fragments: [UInt8] = []
    private var nextFragment: UInt8?
    private var failed = false
    public init() {}
    public var bufferedBytes: Int { pending.count + fragments.count }
    public mutating func accept(_ bytes: [UInt8]) throws -> [OppoControlPacket] {
        guard !failed else { throw ProtocolFailure("OPPO 控制报文边界已失效，请重新连接") }
        var result: [OppoControlPacket] = []
        do {
            for byte in bytes {
                pending.append(byte)
                if pending.count == 1 && pending[0] != 0xaa { throw ProtocolFailure("未知 OPPO 控制报文起始字节") }
                guard pending.count >= 2 else { continue }
                let width = pending[1] & 128 == 0 ? 1 : 2
                guard pending.count >= width + 1 else { continue }
                let length = Int(pending[1] & 127) | (width == 2 ? Int(pending[2]) << 7 : 0)
                guard length >= 3, length <= 4104, width == 1 || (pending[2] & 128 == 0 && length >= 128) else {
                    throw ProtocolFailure("OPPO 控制报文长度无效")
                }
                let start = 1 + width
                if pending.count >= start + 2 {
                    guard pending[start] <= 3, pending[start + 1] == 0 else { throw ProtocolFailure("未知 OPPO 控制头部") }
                    if pending[start] == 0 && length < 7 { throw ProtocolFailure("OPPO 控制报文过短") }
                }
                if pending.count == length + start {
                    let type = pending[start]
                    var body = Array(pending.dropFirst(start + 2))
                    if type == 0 {
                        guard nextFragment == nil else { throw ProtocolFailure("OPPO 分片尚未结束") }
                    } else {
                        guard let index = body.first else { throw ProtocolFailure("OPPO 分片缺少序号") }
                        body.removeFirst()
                        if type == 1 {
                            guard nextFragment == nil, index == 0 else { throw ProtocolFailure("OPPO 分片起点无效") }
                            fragments = []
                        } else { guard index == nextFragment else { throw ProtocolFailure("OPPO 分片序号不连续") } }
                        guard fragments.count + body.count <= 4101, index < 255 else { throw ProtocolFailure("OPPO 分片超过上限") }
                        fragments += body; nextFragment = index + 1
                        if type == 3 { body = fragments; fragments = []; nextFragment = nil }
                    }
                    if type == 0 || type == 3 {
                        guard body.count >= 5, Int(body[3]) | (Int(body[4]) << 8) == body.count - 5 else {
                            throw ProtocolFailure("OPPO 控制报文长度字段不一致")
                        }
                        result.append(try OppoControlPacket(command: UInt16(body[0]) | UInt16(body[1]) << 8,
                            sequence: body[2], payload: Array(body.dropFirst(5))))
                    }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            return result
        } catch { failed = true; pending.removeAll(); fragments.removeAll(); nextFragment = nil; throw error }
    }
    public func finish() throws {
        guard !failed && pending.isEmpty && nextFragment == nil else { throw ProtocolFailure("OPPO 控制通道在完整报文到达前关闭") }
    }
}

public struct OppoProbeReport: Codable, Equatable, Sendable {
    public var controlCapabilities: OppoControlCapabilities?
    public var initializationReplies: [String]?
    public var controlReceiveMTU: UInt16?
    public var controlVendorID: UInt16?
    public var currentCodecID: UInt8?
    public var codecListMask: UInt16?
    public var channel = 15
    public var notificationIDs: [UInt8] = []
    public var notificationRegistration: [OppoNotificationResult]?
    public var statusReplyHex: String?
    public var batchReplyHex: String?
    public var receivedFrames = 0
    public var hiRes: Bool?
    public var hiResCandidate: UInt8?
    public var serviceUUID: String?
    public var experiment: OppoHiResExperimentReport?
    public var canSetHiRes: Bool { controlCapabilities?.supportsFeatureSetter == true && [3, 8].contains(currentCodecID ?? 0) && hiRes != nil }
    public var message = "未查询"
    public init() {}
}

/// Peer acknowledgement and exact feature readback, tied to the requested value.
public struct OppoHiResExperimentReport: Codable, Equatable, Sendable {
    public init() {}
    public var requestedHiRes: Bool?
    public var command: UInt16?
    public var preservedCodecID: UInt8?
    public var baselineCodecID: UInt8?
    public var requestedCodecID: UInt8?
    public var baselineCandidate: UInt8?
    public var writeAttempts = 0
    public var writeSubmissionStatus: Int32?
    public var acknowledgementHex: String?
    public var acknowledgementCode: UInt8?
    public var readbackHex: String?
    public var readbackCandidate: UInt8?
    public var terminationReason: String?
    public var verified: Bool {
        guard let requestedHiRes else { return false }
        return writeAttempts == 1 && writeSubmissionStatus == 0 && acknowledgementCode == 0
            && readbackCandidate == (requestedHiRes ? 1 : 0) && terminationReason == nil
    }
}

/// One feature write followed by correlated readback; no retry or inferred rollback.
public struct OppoHiResTransaction {
    private enum Phase { case baseline, acknowledgement, readback, finished }
    private var phase = Phase.baseline
    public private(set) var report = OppoHiResExperimentReport()
    private let writeRequest: OppoControlPacket
    public var finished: Bool { phase == .finished }
    public static var baselineQuery: OppoControlPacket { .hiResQuery(sequence: 0xf2) }
    public static var enableRequest: OppoControlPacket { .hiResSet(true, sequence: 0xf4) }
    public static var readbackQuery: OppoControlPacket { .hiResQuery(sequence: 0xf5) }
    public init(enabled: Bool = true) {
        writeRequest = .hiResSet(enabled, sequence: 0xf4); report.requestedHiRes = enabled
    }
    public init(capabilities: OppoControlCapabilities, currentCodec: UInt8?, codecListMask: UInt16?, selectLHDC: Bool = false) throws {
        writeRequest = try .codecHiResEnable(capabilities: capabilities, currentCodec: currentCodec, codecListMask: codecListMask, selectLHDC: selectLHDC)
        report.requestedHiRes = true
        report.baselineCodecID = currentCodec; report.requestedCodecID = writeRequest.payload[0]
        report.preservedCodecID = currentCodec == writeRequest.payload[0] ? currentCodec : nil
    }
    public mutating func begin(after baseline: OppoControlPacket) throws -> OppoControlPacket {
        guard phase == .baseline, baseline.isReply(to: Self.baselineQuery) else {
            throw ProtocolFailure("实验写入需要本次查询的完整基线回复，且只能执行一次")
        }
        report.baselineCandidate = try baseline.hiResCandidateValue()
        report.command = writeRequest.command
        phase = .acknowledgement
        return writeRequest
    }
    public mutating func markWriteAttempt(_ packet: OppoControlPacket) throws {
        guard phase == .acknowledgement, report.writeAttempts == 0, packet == writeRequest else {
            throw ProtocolFailure("实验只允许发送一次 HiRes 开启请求")
        }
        report.writeAttempts = 1
    }
    public mutating func recordWriteSubmission(_ status: Int32) { report.writeSubmissionStatus = status }
    public mutating func receive(_ packet: OppoControlPacket) -> OppoControlPacket? {
        guard report.writeAttempts == 1 else { return nil }
        if phase == .acknowledgement, packet.isReply(to: writeRequest) {
            report.acknowledgementHex = packet.hex
            // Preserve unfamiliar ACK layouts; never scan for a success byte.
            report.acknowledgementCode = packet.payload.count == 1 ? packet.payload[0] : nil
            phase = .readback
            return Self.readbackQuery
        }
        if phase == .readback, packet.isReply(to: Self.readbackQuery) {
            report.readbackHex = packet.hex
            report.readbackCandidate = try? packet.hiResCandidateValue()
            phase = .finished
        }
        return nil
    }
    public mutating func interrupt(_ reason: String) {
        report.terminationReason = reason; phase = .finished
    }
}
