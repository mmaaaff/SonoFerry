import Foundation
import IOBluetooth
import CoreBluetooth
import SonoFerryCore

protocol HeadsetTransport: AnyObject {
    var opened: (() -> Void)? { get set }
    var packet: ((OppoControlPacket) -> Void)? { get set }
    var closed: ((String) -> Void)? { get set }
    var progress: (String) -> Void { get set }
    var trace: (String, String) -> Void { get set }
    var diagnosticState: String { get }
    var serviceUUID: String { get }
    func start(address: String)
    func send(_ packet: OppoControlPacket) throws
    func close(_ reason: String)
    @MainActor func shutdown() async throws
}
extension HeadsetTransport {
    var diagnosticState: String { "transport=simulated" }
    var serviceUUID: String { HeadsetDialect.elnk079A.rawValue }
}

/// One owned RFCOMM stream. Never claims HAL, opens AVDTP, or reconnects a disconnected peer.
final class OppoControlConnection: NSObject, IOBluetoothRFCOMMChannelDelegate, HeadsetTransport {
    private enum Phase: String { case idle, sdp, baseband, opening, ready, finished }
    private(set) var serviceUUID = HeadsetDialect.elnk079A.rawValue
    private var phase: Phase = .idle
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var closingChannel: IOBluetoothRFCOMMChannel?
    // Accepted asynchronous opens can finish after cancellation. Keep the
    // barrier closed until their callbacks settle, even if no channel exists yet.
    private var sdpPending = false
    private var basebandPending = false
    private var channelOpenPending = false
    private var channelID = 0
    private var framer = OppoControlFramer()
    private var timer: Timer?
    private var readinessTimer: Timer?
    private var queued: [Data] = []
    private var inFlight: NSData?
    private let transportID = UUID()
    private var started = Date()
    private var writeStarted = Date()
    private var lastManagerState: Int?
    private var windowStart = Date()
    private var windowBytes = 0
    var opened: (() -> Void)?
    var packet: ((OppoControlPacket) -> Void)?
    var closed: ((String) -> Void)?
    var progress: (String) -> Void = { _ in }
    var trace: (String, String) -> Void = { _, _ in }
    var diagnosticState: String {
        let owned = channel ?? closingChannel
        return "transport=\(transportID) phase=\(phase.rawValue) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000)) sdp=\(sdpPending) baseband=\(basebandPending) opening=\(channelOpenPending) link=\(device?.isConnected() == true) open=\(owned?.isOpen() == true) paused=\(owned?.isTransmissionPaused() == true) queued=\(queued.reduce(0) { $0 + $1.count }) inFlight=\(inFlight?.length ?? 0)"
    }
    private func record(_ event: String, _ detail: String = "") { trace(event, diagnosticState + " " + detail) }
    func start(address: String) {
        precondition(Thread.isMainThread)
        guard phase == .idle else { return }
        guard let normalized = BluetoothIdentity.normalizedAddress(address),
              let device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: {
                  BluetoothIdentity.normalizedAddress($0.addressString ?? "") == normalized
              }) else { fail("OPPO 查询只允许用户选择的已配对设备"); return }
        guard device.isConnected() else { fail("耳机未连接；后台控制不会主动连接设备"); return }
        started = Date(); self.device = device; phase = .sdp
        record("transportStart")
        progress("正在读取 RFCOMM 服务")
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.record("openTimeout")
            self?.fail("OPPO 控制操作超时（\(self?.phase.rawValue ?? "unknown")）")
        }
        sdpPending = true
        let result = device.performSDPQuery(self)
        if result != kIOReturnSuccess { sdpPending = false; fail("SDP 查询未能启动：\(result)") }
    }
    func cancel() { fail("OPPO 控制操作已取消") }
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in self?.didQuery(device, status: status) }
    }
    private func didQuery(_ device: IOBluetoothDevice?, status: IOReturn) {
        guard let device, device === self.device else { return }
        sdpPending = false
        record("sdpCallback", "status=\(status)")
        guard phase == .sdp else { return }
        guard status == kIOReturnSuccess else { fail("SDP 查询失败：\(status)"); return }
        var channelID: BluetoothRFCOMMChannelID = 0
        let dialect = HeadsetDialect.allCases.first { dialect in
            let uuid = dialect.serviceBytes.withUnsafeBytes { IOBluetoothSDPUUID(bytes: $0.baseAddress!, length: $0.count) }
            return device.getServiceRecord(for: uuid)?.getRFCOMMChannelID(&channelID) == kIOReturnSuccess && (1...30).contains(channelID)
        }
        guard let dialect else { fail("当前 SDP 未报告已识别的 OPPO 控制服务；未向其他服务发送查询"); return }
        serviceUUID = dialect.rawValue
        guard device.isConnected() else { fail("耳机已断开，未主动重连"); return }
        self.channelID = Int(channelID); 
        phase = .baseband
        progress("正在准备已配对设备的蓝牙连接")
        basebandPending = true
        let result = device.openConnection(self, withPageTimeout: 8192, authenticationRequired: true)
        trace("baseband", "return=\(result) connected=\(device.isConnected())")
        if result != kIOReturnSuccess { basebandPending = false; fail("蓝牙连接准备失败：\(result)") }
    }
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let device, device === self.device else { return }
            self.basebandPending = false
            self.record("basebandComplete", "status=\(status)")
            guard self.phase == .baseband else { return }
            self.trace("basebandCallback", "status=\(status)")
            guard status == kIOReturnSuccess else { self.fail("蓝牙连接准备失败：\(status)"); return }
            self.waitForClassicManager(device)
        }
    }
    private func waitForClassicManager(_ device: IOBluetoothDevice) {
        guard phase == .baseband else { return }
        guard device.isConnected() else { fail("耳机已断开，未主动重连"); return }
        guard device.responds(to: NSSelectorFromString("classicPeer")),
              let peer = device.perform(NSSelectorFromString("classicPeer"))?.takeUnretainedValue() as? NSObject,
              peer.responds(to: NSSelectorFromString("manager")),
              let manager = peer.perform(NSSelectorFromString("manager"))?.takeUnretainedValue() as? CBManager else {
            fail("当前 macOS 未提供可确认就绪状态的 Classic 蓝牙管理器"); return
        }
        // On macOS 27.2, SDP and even openConnection can finish while the new
        // Classic manager is still .unknown. Opening RFCOMM at that point returns
        // success but logs "No channel" and never calls the delegate.
        if lastManagerState != manager.state.rawValue {
            lastManagerState = manager.state.rawValue; record("manager", "state=\(manager.state.rawValue)")
        }
        if manager.state == .poweredOn { openControlChannel(device); return }
        guard manager.state == .unknown || manager.state == .resetting else { fail("Classic 蓝牙管理器未就绪：\(manager.state.rawValue)"); return }
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in self?.waitForClassicManager(device) }
    }
    private func openControlChannel(_ device: IOBluetoothDevice) {
        phase = .opening; progress("正在连接 OPPO ELNK 控制通道 \(channelID)")
        let receivesData = responds(to: NSSelectorFromString("rfcommChannelData:data:length:"))
        let receivesOpen = responds(to: NSSelectorFromString("rfcommChannelOpenComplete:status:"))
        trace("delegate", "data=\(receivesData) open=\(receivesOpen)")
        channelOpenPending = true
        let result = device.openRFCOMMChannelAsync(&channel, withChannelID: UInt8(channelID), delegate: self)
        record("open", "return=\(result) channel=\(channel != nil)")
        if result != kIOReturnSuccess { channelOpenPending = false; fail("RFCOMM 通道打开失败：\(result)"); return }
        if let channel {
            let delegateResult = channel.setDelegate(self)
            trace("setDelegate", "return=\(delegateResult)")
            if delegateResult != kIOReturnSuccess { fail("RFCOMM 接收监听注册失败：\(delegateResult)"); return }
            if channel.isOpen() { rfcommChannelOpenComplete(channel, status: kIOReturnSuccess) }
        }
    }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            self?.record("openCallback", "status=\(error) channel=\(channel != nil)")
            guard let self, self.phase == .opening || self.phase == .finished && self.channelOpenPending else { return }
            guard channel == nil || self.channel == nil || channel === self.channel else { return }
            self.channelOpenPending = false
            if self.phase == .finished {
                self.closingChannel = channel ?? self.closingChannel
                self.closingChannel?.setDelegate(nil); self.closingChannel?.close()
                return
            }
            guard error == kIOReturnSuccess, let channel else { self.fail("RFCOMM 打开失败：\(error)"); return }
            self.channel = channel
            self.phase = .ready; self.timer?.invalidate(); self.timer = nil; self.opened?()
        }
    }
    func send(_ packet: OppoControlPacket) throws {
        guard phase == .ready, let channel else { throw ProtocolFailure("控制通道未就绪") }
        let bytes = packet.bytes
        guard queued.reduce(0, { $0 + $1.count }) + bytes.count <= 16384 else { throw ProtocolFailure("控制发送队列超过上限") }
        let mtu = Int(channel.getMTU())
        guard mtu > 0 else { throw ProtocolFailure("RFCOMM MTU 无效") }
        for offset in stride(from: 0, to: bytes.count, by: mtu) { queued.append(Data(bytes[offset..<min(offset+mtu, bytes.count)])) }
        record("writeQueued", String(format: "command=%04X sequence=%d bytes=%d mtu=%d", packet.command, packet.sequence, bytes.count, mtu))
        pump()
    }
    private func pump() {
        guard phase == .ready, inFlight == nil, !queued.isEmpty, let channel else { return }
        let storage = queued.removeFirst() as NSData; inFlight = storage
        writeStarted = Date()
        let status = channel.writeAsync(UnsafeMutableRawPointer(mutating: storage.bytes), length: UInt16(storage.length), refcon: nil)
        record("writeSubmitted", "return=\(status) bytes=\(storage.length)")
        if status != kIOReturnSuccess { fail("控制报文未能排队：\(status)") }
    }
    func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            self?.record("writeComplete", "status=\(error) waitMs=\(Int(Date().timeIntervalSince(self?.writeStarted ?? Date()) * 1000))")
            guard let self, channel === self.channel, self.phase == .ready else { return }
            self.inFlight = nil
            if error != kIOReturnSuccess { self.fail("控制发送失败：\(error)") } else { self.pump() }
        }
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard let pointer, count > 0, count <= 8192 else { DispatchQueue.main.async { [weak self] in self?.fail("控制接收块超过上限") }; return }
        let bytes = Array(UnsafeRawBufferPointer(start: pointer, count: count))
        DispatchQueue.main.async { [weak self] in
            guard let self, channel === self.channel, self.phase == .ready else { return }
            let now = Date()
            if now.timeIntervalSince(self.windowStart) >= 1 { self.windowStart = now; self.windowBytes = 0 }
            self.windowBytes += bytes.count
            self.record("receive", "bytes=\(bytes.count)")
            guard self.windowBytes <= 65536 else { self.fail("控制通知速率超过上限"); return }
            do { for frame in try self.framer.accept(bytes) { self.packet?(frame) } }
            catch { self.fail(error.localizedDescription) }
        }
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in
            guard let self, channel === self.channel || channel === self.closingChannel else { return }
            self.record("closedCallback")
            // Closed can precede open-complete. Only the latter settles an
            // accepted async open; otherwise its late callback could reopen it.
            if self.phase == .finished {
                if !self.channelOpenPending { self.closingChannel = nil }
                return
            }
            do { try self.framer.finish(); self.fail("耳机控制连接已关闭") }
            catch { self.fail(error.localizedDescription) }
        }
    }
    private func fail(_ message: String) { close(message) }
    @MainActor func shutdown() async throws {
        close()
        record("shutdownBegin")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !sdpPending, !basebandPending, !channelOpenPending, closingChannel?.isOpen() != true {
                closingChannel = nil; device = nil
                record("shutdownConfirmed")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        record("shutdownTimeout")
        throw ProtocolFailure("耳机控制的待完成连接／RFCOMM 关闭未能确认；未启动音频连接")
    }
    func close(_ reason: String = "耳机控制已暂停") {
        guard phase != .finished else { return }
        record("closeBegin", reason)
        phase = .finished; timer?.invalidate(); timer = nil; readinessTimer?.invalidate(); readinessTimer = nil
        let owned = channel; closingChannel = owned; channel = nil
        // An opening channel still needs its completion/closed callback so a
        // late successful open cannot escape into the next audio connection.
        if !channelOpenPending { owned?.setDelegate(nil) }
        let status = owned?.close(); queued.removeAll()
        record("closeSubmitted", "return=\(status.map(String.init) ?? "no-channel")")
        let storage = inFlight; inFlight = nil
        // Retain the write storage/receiver through callbacks already queued by IOBluetooth.
        DispatchQueue.main.async { withExtendedLifetime((self, storage, owned)) {} }
        let callback = closed; closed = nil; packet = nil; opened = nil; callback?(reason)
    }
}
