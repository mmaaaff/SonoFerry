import Foundation
import IOBluetooth
import CoreBluetooth
import SonoFerryCore

/// Short-lived, user-initiated control connection. Never claims the HAL or opens AVDTP.
/// Writes require a fresh capability/current-codec query and exact status readback.
final class OppoControlSession: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private enum Phase: String { case idle, sdp, baseband, opening, initializing, notifications, registration, status, batch, experiment, finished }
    private var phase: Phase = .idle
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var framer = OppoControlFramer()
    private var timer: Timer?
    private var readinessTimer: Timer?
    private var writes: [NSData] = []
    private var report = OppoProbeReport()
    private var receivedBytes = 0
    private let statusQuery = OppoControlPacket.hiResQuery(sequence: 0xf2)
    private let compareBatch: Bool
    private let initializeControl: Bool
    private let integratedClient: Bool
    private var initializationRequest: OppoControlPacket?
    private var initializationQueue: [OppoControlPacket] = []
    private var registration: OppoControlPacket?
    private let progress: (String) -> Void
    private let trace: (String, String) -> Void
    private var completion: ((Result<OppoProbeReport, Error>) -> Void)?
    private var experiment: OppoHiResTransaction?
    private let requestedHiRes: Bool?
#if OPPO_EXPERIMENTAL_WRITE
    private var codecEnableExperiment = false
    private var selectLHDCExperiment = false
    func prepareCodecHiResEnableExperiment(selectLHDC: Bool = false) {
        precondition(phase == .idle && !compareBatch && initializeControl)
        codecEnableExperiment = true
        selectLHDCExperiment = selectLHDC
    }
    func prepareHiResEnableExperiment(enabled: Bool = true) {
        precondition(phase == .idle && !compareBatch)
        experiment = OppoHiResTransaction(enabled: enabled)
    }
#endif

    init(compareBatch: Bool = false, initializeControl: Bool = false, integratedClient: Bool = false, requestedHiRes: Bool? = nil, progress: @escaping (String) -> Void, trace: @escaping (String, String) -> Void = { _, _ in },
         completion: @escaping (Result<OppoProbeReport, Error>) -> Void) {
        self.compareBatch = compareBatch; self.initializeControl = initializeControl
        self.integratedClient = integratedClient
        self.requestedHiRes = requestedHiRes
        precondition(requestedHiRes == nil || initializeControl)
        self.progress = progress; self.trace = trace; self.completion = completion
    }
    func start(address: String) {
        precondition(Thread.isMainThread)
        guard phase == .idle else { return }
        guard let normalized = BluetoothIdentity.normalizedAddress(address),
              let device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: {
                  BluetoothIdentity.normalizedAddress($0.addressString ?? "") == normalized
              }) else { fail("OPPO 查询只允许用户选择的已配对设备"); return }
        self.device = device; phase = .sdp
        progress("正在读取 RFCOMM 服务")
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            if let self { self.trace("timeout", "phase=\(self.phase) channel=\(self.channel != nil) open=\(self.channel?.isOpen() == true)") }
            self?.fail("OPPO 控制操作超时（\(self?.phase.rawValue ?? "unknown")）")
        }
        let result = device.performSDPQuery(self)
        if result != kIOReturnSuccess { fail("SDP 查询未能启动：\(result)") }
    }
    func cancel() { fail("OPPO 控制操作已取消") }
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in self?.didQuery(device, status: status) }
    }
    private func didQuery(_ device: IOBluetoothDevice?, status: IOReturn) {
        guard phase == .sdp, let device, device === self.device else { return }
        guard status == kIOReturnSuccess else { fail("SDP 查询失败：\(status)"); return }
        let uuid = OppoControlPacket.serviceUUIDBytes.withUnsafeBytes {
            IOBluetoothSDPUUID(bytes: $0.baseAddress!, length: $0.count)
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard let record = device.getServiceRecord(for: uuid),
              record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess, (1...30).contains(channelID) else {
            for record in device.services as? [IOBluetoothSDPServiceRecord] ?? [] {
                var candidate: BluetoothRFCOMMChannelID = 0
                if record.getRFCOMMChannelID(&candidate) == kIOReturnSuccess {
                    let attributes = record.attributes as? [NSNumber: IOBluetoothSDPDataElement] ?? [:]
                    trace("sdp", "channel=\(candidate) class=\(String(describing: attributes[1])) id=\(String(describing: attributes[3]))")
                }
            }
            fail("当前 SDP 未报告 OPPO ELNK 控制服务；未向其他服务发送查询"); return
        }
        report.channel = Int(channelID); report.serviceUUID = OppoControlPacket.serviceUUID
        phase = .baseband
        progress("正在准备已配对设备的蓝牙连接")
        let result = device.openConnection(self, withPageTimeout: 8192, authenticationRequired: true)
        trace("baseband", "return=\(result) connected=\(device.isConnected())")
        if result != kIOReturnSuccess { fail("蓝牙连接准备失败：\(result)") }
    }
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase == .baseband, let device, device === self.device else { return }
            self.trace("basebandCallback", "status=\(status)")
            guard status == kIOReturnSuccess else { self.fail("蓝牙连接准备失败：\(status)"); return }
            self.waitForClassicManager(device)
        }
    }
    private func waitForClassicManager(_ device: IOBluetoothDevice) {
        guard phase == .baseband else { return }
        guard device.responds(to: NSSelectorFromString("classicPeer")),
              let peer = device.perform(NSSelectorFromString("classicPeer"))?.takeUnretainedValue() as? NSObject,
              peer.responds(to: NSSelectorFromString("manager")),
              let manager = peer.perform(NSSelectorFromString("manager"))?.takeUnretainedValue() as? CBManager else {
            fail("当前 macOS 未提供可确认就绪状态的 Classic 蓝牙管理器"); return
        }
        // On macOS 27.2, SDP and even openConnection can finish while the new
        // Classic manager is still .unknown. Opening RFCOMM at that point returns
        // success but logs "No channel" and never calls the delegate.
        trace("manager", "state=\(manager.state.rawValue)")
        if manager.state == .poweredOn { openControlChannel(device); return }
        guard manager.state == .unknown || manager.state == .resetting else { fail("Classic 蓝牙管理器未就绪：\(manager.state.rawValue)"); return }
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in self?.waitForClassicManager(device) }
    }
    private func openControlChannel(_ device: IOBluetoothDevice) {
        phase = .opening; progress("正在连接 OPPO ELNK 控制通道 \(report.channel)")
        let receivesData = responds(to: NSSelectorFromString("rfcommChannelData:data:length:"))
        let receivesOpen = responds(to: NSSelectorFromString("rfcommChannelOpenComplete:status:"))
        trace("delegate", "data=\(receivesData) open=\(receivesOpen)")
        let result = device.openRFCOMMChannelAsync(&channel, withChannelID: UInt8(report.channel), delegate: self)
        trace("open", "return=\(result) channel=\(channel != nil) open=\(channel?.isOpen() == true)")
        if result != kIOReturnSuccess { fail("RFCOMM 通道打开失败：\(result)"); return }
        if let channel {
            let delegateResult = channel.setDelegate(self)
            trace("setDelegate", "return=\(delegateResult)")
            if delegateResult != kIOReturnSuccess { fail("RFCOMM 接收监听注册失败：\(delegateResult)"); return }
            if channel.isOpen() { rfcommChannelOpenComplete(channel, status: kIOReturnSuccess) }
        }
    }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            self?.trace("openCallback", "status=\(error) sameChannel=\(channel === self?.channel) phase=\(self?.phase.rawValue ?? "unknown")")
            guard let self, self.phase == .opening, channel === self.channel else { return }
            guard error == kIOReturnSuccess else { self.fail("RFCOMM 连接失败：\(error)"); return }
            if self.initializeControl {
                self.phase = .initializing; self.report.initializationReplies = []
                self.initializationRequest = .controlCapabilitiesQuery
                self.progress("正在读取控制命令能力并完成伴侣协议初始化")
                self.send(.controlCapabilitiesQuery)
            } else { self.beginNotifications() }
        }
    }
    private func beginNotifications() {
        phase = .notifications; progress("正在读取控制协议通知能力")
        send(.notificationQuery())
    }
    private func receiveInitialization(_ packet: OppoControlPacket) throws {
        guard let request = initializationRequest, packet.isReply(to: request) else { return }
        report.initializationReplies?.append(packet.hex)
        switch request.command {
        case 0x0100:
            let caps = try OppoControlCapabilities(reply: packet)
            report.controlCapabilities = caps
            initializationQueue = [.controlMTUExchange, integratedClient ? .integratedControlVendorExchange : .controlVendorExchange, .controlVersionQuery]
            if caps.supportsCurrentCodecQuery { initializationQueue.append(.currentCodecQuery) }
            if caps.supportsCodecSelection { initializationQueue.append(.codecListQuery) }
        case 0x0101: report.controlReceiveMTU = try packet.successfulUInt16Reply(to: request)
        case 0x0102: report.controlVendorID = try packet.successfulUInt16Reply(to: request)
        case 0x0114: report.currentCodecID = try packet.currentCodecID()
        case 0x0123: report.codecListMask = try packet.successfulUInt16Reply(to: request)
        case 0x0104:
            guard packet.payload.count > 1, packet.payload[0] == 0 else {
                throw ProtocolFailure("耳机控制协议版本查询失败")
            }
        default: throw ProtocolFailure("未知的控制初始化阶段")
        }
        if !initializationQueue.isEmpty {
            let next = initializationQueue.removeFirst(); initializationRequest = next; send(next)
        } else { initializationRequest = nil; beginNotifications() }
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard dataLength >= 0, dataLength <= 8192, let dataPointer else {
            DispatchQueue.main.async { [weak self] in self?.fail("RFCOMM 单次接收超出诊断限额") }; return
        }
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        DispatchQueue.main.async { [weak self] in self?.received(bytes, from: channel) }
    }
    private func received(_ bytes: [UInt8], from channel: IOBluetoothRFCOMMChannel?) {
        guard phase != .finished, channel === self.channel else { return }
        receivedBytes += bytes.count
        guard receivedBytes <= 16384 else { fail("OPPO 控制回复超过诊断限额"); return }
        trace("rxChunk", bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        do {
            for packet in try framer.accept(bytes) {
                report.receivedFrames += 1; trace("rx", packet.hex)
                if phase == .initializing {
                    try receiveInitialization(packet); continue
                }
                if phase == .notifications && packet.isReply(to: .notificationQuery()) {
                    report.notificationIDs = try packet.notificationIDs()
                    let registration = try OppoControlPacket.notificationRegistration(report.notificationIDs)
                    self.registration = registration; phase = .registration
                    progress("正在订阅耳机报告的会话通知；不切换任何功能")
                    send(registration)
                } else if phase == .registration, let registration, packet.isReply(to: registration) {
                    report.notificationRegistration = try packet.notificationRegistrationResults(for: registration)
                    phase = .status; progress("正在读取 HiRes 原始状态；不会将未知字段解释为开关")
                    send(statusQuery)
                } else if phase == .status && packet.isReply(to: statusQuery) {
                    report.statusReplyHex = packet.hex
                    report.hiResCandidate = try? packet.hiResCandidateValue()
                    if [3, 8].contains(report.currentCodecID ?? 0), let raw = report.hiResCandidate { report.hiRes = raw == 1 }
                    if let enabled = requestedHiRes {
                        guard report.canSetHiRes else { throw ProtocolFailure("HiRes 切换需要耳机确认 LDAC／LHDC 高清连接及功能设置能力；请启用高清协议后重新查询") }
                        experiment = OppoHiResTransaction(enabled: enabled)
                    }
#if OPPO_EXPERIMENTAL_WRITE
                    if codecEnableExperiment {
                        guard let caps = report.controlCapabilities else { throw ProtocolFailure("未取得控制能力，不发送 HiRes 设置") }
                        experiment = try OppoHiResTransaction(capabilities: caps,
                            currentCodec: report.currentCodecID, codecListMask: report.codecListMask,
                            selectLHDC: selectLHDCExperiment)
                        codecEnableExperiment = false
                    }
#endif
                    if experiment != nil {
                        let command = try experiment!.begin(after: packet)
                        phase = .experiment
                        progress("正在设置 HiRes；随后读取耳机实际状态")
                        send(command); continue
                    }
                    report.message = report.hiRes.map { "当前高清连接的 HiRes：" + ($0 ? "开启" : "关闭") }
                        ?? "已取得控制能力；当前连接未确认可操作 HiRes，请在启用高清协议后查询"
                    if compareBatch {
                        phase = .batch; progress("正在读取公开批量查询的原始回复；不会修改功能")
                        send(.referenceBatchQuery()); continue
                    }
                    finish(.success(report)); return
                } else if phase == .batch && packet.isReply(to: .referenceBatchQuery()) {
                    report.batchReplyHex = packet.hex
                    finish(.success(report)); return
                }
                if phase == .experiment {
                    if let next = experiment?.receive(packet) {
                        progress("已捕获设置回复；只读查询写入后的候选值")
                        send(next)
                    } else if experiment?.finished == true {
                        finishExperiment(); return
                    }
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func send(_ packet: OppoControlPacket) {
        guard phase != .finished, let channel, writes.count < 11 else { fail("OPPO 控制通道不可写入"); return }
        let bytes = NSData(bytes: packet.bytes, length: packet.bytes.count)
        guard bytes.length <= Int(channel.getMTU()) else { fail("OPPO 控制报文超过 RFCOMM MTU"); return }
        if packet.command == 0x0403 || packet.command == 0x041a {
            do {
                guard experiment != nil else { throw ProtocolFailure("功能写入未明确启用") }
                try experiment!.markWriteAttempt(packet)
            } catch { fail(error.localizedDescription); return }
        }
        writes.append(bytes) // Keep async write storage alive through completion/close.
        trace("tx", packet.hex)
        let result = channel.writeAsync(UnsafeMutableRawPointer(mutating: bytes.bytes), length: UInt16(bytes.length), refcon: nil)
        if packet.command == 0x0403 || packet.command == 0x041a { experiment?.recordWriteSubmission(result) }
        if result != kIOReturnSuccess { fail("OPPO 控制报文未能排队：\(result)") }
    }
    func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase != .finished, channel === self.channel else { return }
            if error != kIOReturnSuccess { self.fail("OPPO 控制发送失败：\(error)") }
        }
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase != .finished, channel === self.channel else { return }
            do { try self.framer.finish(); self.fail("OPPO 控制通道在状态确认前关闭") }
            catch { self.fail(error.localizedDescription) }
        }
    }
    private func fail(_ message: String) {
        if experiment?.report.writeAttempts == 1 {
            experiment?.interrupt(message); finishExperiment(); return
        }
        finish(.failure(ProtocolFailure(message)))
    }
    private func finishExperiment() {
        report.experiment = experiment?.report
        if let result = experiment?.report, result.verified {
            report.hiRes = result.requestedHiRes
            report.message = "HiRes 已" + (result.requestedHiRes == true ? "开启" : "关闭") + "，耳机读回已确认。切换可能使耳机重连；如高清会话结束，请重新启用。"
        } else {
            report.hiRes = nil
            report.message = "HiRes 设置未确认：" + (experiment?.report.terminationReason ?? experiment?.report.acknowledgementCode.map { "耳机返回码 \($0)，读回未匹配" } ?? "未取得有效确认") + "。请重新查询，未自动重试。"
        }
        finish(.success(report))
    }
    private func finish(_ result: Result<OppoProbeReport, Error>) {
        guard phase != .finished else { return }
        phase = .finished; timer?.invalidate(); timer = nil
        readinessTimer?.invalidate(); readinessTimer = nil
        // Close only our RFCOMM channel; leave the shared baseband/audio connection alone.
        let closing = channel; channel = nil
        closing?.setDelegate(nil); closing?.close()
        // IOBluetooth can already have queued a callback when its delegate is
        // cleared. Keep this receiver alive across the next main-loop turn.
        DispatchQueue.main.async { withExtendedLifetime(self) {} }
        let callback = completion; completion = nil; callback?(result)
    }
}
