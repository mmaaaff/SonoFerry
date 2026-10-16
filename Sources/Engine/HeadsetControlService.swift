import Foundation
import SonoFerryCore

/// Main-run-loop owner of one ELNK connection. Transactions serialize; notifications are independent.
@MainActor
final class HeadsetControlService {
    private(set) var snapshot: HeadsetSnapshot
    private(set) var busy = false
    private var connection: HeadsetTransport?
    private var retiredConnection: HeadsetTransport?
    private var closingTask: Task<Void, Error>?
    private var closeFailure: String?
    private let makeConnection: () -> HeadsetTransport
    private let responseTimeout: TimeInterval
    private let operationTimeout: TimeInterval
    private var sequence = 0
    private var observationRevisions: [String: UInt64] = [:]
    private var pending: (OppoControlPacket, CheckedContinuation<OppoControlPacket, Error>)?
    private var opening: CheckedContinuation<Void, Error>?
    private var timeout: Timer?
    private var operationTimer: Timer?
    private var operationID: UUID?
    private var subscribed = false
    private var transactionBytes = 0
    private var unansweredReads = 0
    private var readInterruptedByTransport = false
    private let resumeRetryDelay: UInt64
    private var deadline = Date.distantPast
    var changed: (HeadsetSnapshot) -> Void = { _ in }
    var gesture: (HeadsetGesture) -> Void = { _ in }
    var progress: (String) -> Void = { _ in }
    var trace: (String, String) -> Void = { _, _ in }
    init(address: String, responseTimeout: TimeInterval = 3, operationTimeout: TimeInterval = 18,
         resumeRetryDelay: UInt64 = 2_000_000_000,
         makeConnection: @escaping () -> HeadsetTransport = { OppoControlConnection() }) {
        snapshot = .init(address: address); self.makeConnection = makeConnection
        self.responseTimeout = responseTimeout; self.operationTimeout = operationTimeout
        self.resumeRetryDelay = resumeRetryDelay
    }

    private func beginOperation(limit: TimeInterval? = nil) {
        let id = UUID(); operationID = id
        readInterruptedByTransport = false
        deadline = Date().addingTimeInterval(limit ?? operationTimeout); transactionBytes = 0
        let timer = Timer(timeInterval: limit ?? operationTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.operationID == id else { return }
                self.readInterruptedByTransport = self.pending != nil || self.opening != nil
                self.abort("耳机控制查询总时限已到；未重试写入")
            }
        }
        operationTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func endOperation() {
        operationID = nil; operationTimer?.invalidate(); operationTimer = nil
        timeout?.invalidate(); timeout = nil
    }
    private func abort(_ reason: String) {
        // A broken/missing transport callback must not strand a continuation.
        let owned = connection
        trace("abort", reason)
        closed(reason, generation: snapshot.generation)
        owned?.close(reason)
    }

    private func publish() { changed(snapshot) }
    func suspend() async throws {
        if let closingTask { try await closingTask.value; return }
        if let closeFailure { trace("closeRecheck", closeFailure) }
        let old = connection ?? retiredConnection
        connection = nil; retiredConnection = nil
        let failure = ProtocolFailure("控制通道已暂停；未重发任何设置")
        timeout?.invalidate(); timeout = nil
        let p = pending; pending = nil; p?.1.resume(throwing: failure)
        let o = opening; opening = nil; o?.resume(throwing: failure)
        snapshot.markStale(); publish()
        if let old {
            let closing = Task { try await old.shutdown() }; closingTask = closing
            do { try await closing.value; closingTask = nil; closeFailure = nil; trace("closeConfirmed", "retired transport drained") }
            catch { closeFailure = error.localizedDescription; retiredConnection = old; closingTask = nil; throw error }
        }
    }
    private func closed(_ reason: String, generation: UUID) {
        guard snapshot.generation == generation else { return }
        if let connection { retiredConnection = connection }
        connection = nil; timeout?.invalidate(); timeout = nil
        snapshot.markStale(); snapshot.issues["connection"] = reason; publish()
        let p = pending; pending = nil; p?.1.resume(throwing: ProtocolFailure(reason))
        let o = opening; opening = nil; o?.resume(throwing: ProtocolFailure(reason))
    }
    private func open() async throws {
        try Task.checkCancellation()
        if let closingTask { try await closingTask.value }
        try Task.checkCancellation()
        guard deadline > Date() else { throw ProtocolFailure("耳机控制查询已超时，未再打开连接") }
        if snapshot.connected, sequence < 210 { return }
        if connection != nil || retiredConnection != nil { try await suspend() }
        try Task.checkCancellation()
        guard deadline > Date() else { throw ProtocolFailure("控制通道关闭后查询已超时，未再打开连接") }
        snapshot.markStale(); snapshot.generation = UUID(); snapshot.capabilities = nil
        snapshot.productID = nil; snapshot.currentCodec = nil; snapshot.notificationIDs = []
        subscribed = false
        let generation = snapshot.generation
        sequence = 0; unansweredReads = 0
        let transport = makeConnection(); connection = transport
        transport.progress = { [weak self] in self?.progress($0) }
        transport.trace = { [weak self] in self?.trace($0, "generation=\(generation) " + $1) }
        transport.closed = { [weak self] reason in
            guard let self, self.snapshot.generation == generation else { return }
            // abort()/suspend() retire the connection first. Only a transport
            // failure, not a malformed protocol reply or cancellation, may retry.
            if self.connection != nil { self.readInterruptedByTransport = true }
            self.closed(reason, generation: generation)
        }
        transport.opened = { [weak self] in
            guard let self, self.snapshot.generation == generation else { return }
            let o = self.opening; self.opening = nil; o?.resume()
        }
        transport.packet = { [weak self] packet in self?.receive(packet, generation: generation) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            opening = continuation; transport.start(address: snapshot.address)
        }
        let caps = try await exchange(command: 0x0100)
        snapshot.capabilities = try .init(reply: caps)
        // Match the proven 512-byte host MTU; longer logical replies are reassembled above RFCOMM.
        for request in [OppoControlPacket.controlMTUExchange, .integratedControlVendorExchange, .controlVersionQuery] {
            let response = try await exchange(command: request.command, payload: request.payload)
            guard (request.command == 0x0104 ? response.payload.count > 1 : response.payload.count == 3), response.payload.first == 0 else { throw ProtocolFailure("控制初始化回复未知") }
        }
        snapshot.serviceUUID = transport.serviceUUID
        snapshot.connected = true; snapshot.issues.removeValue(forKey: "connection")
        try await read(.product)
        publish()
    }
    /// Identity only: no notification subscription or feature queries. The coordinator
    /// must await suspend() before reporting cleanup and starting AVDTP discovery.
    func identify() async throws -> HeadsetIdentity {
        guard !busy else { throw ProtocolFailure("控制通道忙碌") }
        busy = true; beginOperation(); defer { endOperation(); busy = false }
        do {
            try await open()
            guard let identity = snapshot.identity else { throw ProtocolFailure("未读取到有效产品 ID") }
            return identity
        } catch { abort(error.localizedDescription); throw error }
    }
    private func subscribe() async throws {
        guard snapshot.profile != nil else { throw ProtocolFailure("产品 ID 未适配；未订阅专属控制") }
        guard !subscribed else { return }
        let notifications = try await exchange(command: 0x0200, optionalRead: true).notificationIDs().filter { [1, 2, 3, 241].contains($0) }
        if !notifications.isEmpty {
            let response = try await exchange(command: 0x0205, payload: [UInt8(notifications.count)] + notifications, optionalRead: true)
            let request = try OppoControlPacket(command: 0x0205, sequence: response.sequence, payload: [UInt8(notifications.count)] + notifications)
            snapshot.notificationIDs = try response.notificationRegistrationResults(for: request).filter { $0.result == 0 }.map(\.id)
        }
        subscribed = true
        snapshot.issues.removeValue(forKey: "subscription")
        publish()
    }
    private func receive(_ packet: OppoControlPacket, generation: UUID) {
        guard generation == snapshot.generation, connection != nil else { return }
        if HeadsetSnapshot.syncCommands.contains(packet.command) {
            do {
                let affected = try snapshot.consumeSync(packet)
                for query in affected { observationRevisions[query.key, default: 0] &+= 1 }
                trace("stateSync", String(format: "command=%04X bytes=%d", packet.command, packet.payload.count))
                publish()
            } catch {
                snapshot.issues["sync"] = error.localizedDescription; publish()
            }
            return
        }
        if packet.command == 0x0204 {
            do {
                if let action = try snapshot.consumeNotification(packet) { gesture(action) }
                let query: HeadsetQuery? = packet.payload.first == 1 ? .battery : packet.payload.first == 2 ? .ears :
                    packet.payload.first == 3 && packet.payload.dropFirst().first == 1 ? .noiseCurrent :
                    packet.payload.first == 3 && packet.payload.dropFirst().first == 3 ? .noiseAvailable :
                    packet.payload.first == 3 && packet.payload.dropFirst().first == 4 ? .noiseIntelligent : nil
                if let query { observationRevisions[query.key, default: 0] &+= 1 }
                publish()
            }
            catch { snapshot.issues["notification"] = error.localizedDescription; publish() }
            return
        }
        guard let p = pending, packet.isReply(to: p.0) else {
            trace("unmatchedReply", String(format: "command=%04X sequence=%d pending=%d", packet.command, packet.sequence, pending?.0.sequence ?? 0))
            return
        }
        unansweredReads = 0
        trace("reply", String(format: "command=%04X sequence=%d bytes=%d", packet.command, packet.sequence, packet.bytes.count))
        transactionBytes += packet.bytes.count
        pending = nil; timeout?.invalidate(); timeout = nil
        if transactionBytes > 16384 { p.1.resume(throwing: ProtocolFailure("单次事务接收超过上限")) }
        else { p.1.resume(returning: packet) }
    }
    private func exchange(command: UInt16, payload: [UInt8] = [], optionalRead: Bool = false) async throws -> OppoControlPacket {
        try Task.checkCancellation()
        guard deadline > Date() else { throw ProtocolFailure("耳机控制查询总时限已到；未重试写入") }
        guard pending == nil, let connection, sequence < 255 else { throw ProtocolFailure("控制事务忙碌、已过期或连接不可用") }
        sequence += 1
        let generation = snapshot.generation
        let packet = try OppoControlPacket(command: command, sequence: UInt8(sequence), payload: payload)
        let label = command == 0x0114 ? "当前编码" : command == 0x010d && payload == [1, 24] ? "HiRes 状态" : "耳机控制状态"
        progress(command >= 0x0400 ? "正在等待耳机设置响应" : "正在读取" + label)
        trace("send", String(format: "command=%04X sequence=%d", command, sequence))
        return try await withCheckedThrowingContinuation { continuation in
            pending = (packet, continuation)
            let timer = Timer(timeInterval: max(0.001, min(responseTimeout, deadline.timeIntervalSinceNow)), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.snapshot.generation == generation, self.pending?.0.sequence == packet.sequence else { return }
                    let reason = "耳机未回复" + label + "；未重试写入"
                    self.trace("replyTimeout", String(format: "command=%04X sequence=%d optional=%@ ", command, packet.sequence, String(optionalRead)) + (self.connection?.diagnosticState ?? "transport=missing"))
                    self.unansweredReads += 1
                    if optionalRead && self.unansweredReads < 2 {
                        // Unique sequence numbers isolate a late reply. A single optional
                        // query must not invalidate an otherwise confirmed HiRes read.
                        let pending = self.pending; self.pending = nil
                        self.timeout?.invalidate(); self.timeout = nil
                        pending?.1.resume(throwing: ProtocolFailure(reason))
                    } else { self.readInterruptedByTransport = true; self.abort(reason) }
                }
            }
            timeout = timer; RunLoop.main.add(timer, forMode: .common)
            do { try connection.send(packet) }
            catch { abort(error.localizedDescription) }
        }
    }
    private func read(_ query: HeadsetQuery, optional: Bool = false) async throws {
        do {
            guard query == .product || snapshot.supports(query) else { throw ProtocolFailure("此型号未适配该读取接口") }
            let revision = observationRevisions[query.key, default: 0]
            let response = try await exchange(command: query.command, payload: query.payload, optionalRead: optional)
            // A phone sync arriving during this read is newer than its requested baseline.
            if observationRevisions[query.key, default: 0] == revision { try snapshot.consume(response, query: query) }
        } catch { snapshot.markStale(query, reason: error.localizedDescription); throw error }
    }
    private func readHiRes() async throws {
        guard snapshot.profile != nil, snapshot.capabilities?.supportsCurrentCodecQuery == true else { return }
        let response = try await exchange(command: 0x0114)
        if response.payload.count == 2, response.payload[0] == 0 { snapshot.currentCodec = response.payload[1] }
        else { snapshot.currentCodec = nil; snapshot.issues["codec"] = "当前编码回复未知" }
        if snapshot.supports(.feature(.hiRes)) { try await read(.feature(.hiRes), optional: true) }
        publish()
    }
    private func readScope(_ scope: HeadsetRefreshScope, missingOnly: Bool = false, includeHiRes: Bool = false) async throws {
        guard snapshot.profile != nil, snapshot.capabilities != nil else { throw ProtocolFailure("型号或控制能力未适配") }
        do { try await subscribe() }
        catch { snapshot.issues["subscription"] = error.localizedDescription; if connection == nil { throw error } }
        // Only a new connection, an explicit refresh or the full diagnostic path
        // reads HiRes. Ordinary 60-second quick reads never poll it.
        if includeHiRes || scope == .full {
            do { try await readHiRes() }
            catch { if connection == nil { throw error } }
        }
        for query in scope.queries where query != .feature(.hiRes) && snapshot.supports(query) {
            if missingOnly && snapshot.hasFresh(query) { continue }
            do {
                try await read(query, optional: true)
                if query == .noiseCurrent, snapshot.supports(.noiseIntelligent), snapshot.noise?.value == 7 {
                    do { try await read(.noiseIntelligent, optional: true) }
                    catch { if connection == nil { throw error } }
                }
            } catch { if connection == nil { throw error } }
            publish()
        }
    }
    func refresh(liveOnly: Bool = false) async throws -> HeadsetSnapshot {
        try await refresh(scope: liveOnly ? .quick : .full)
    }
    func refresh(scope: HeadsetRefreshScope, missingOnly: Bool = false, includeHiRes: Bool = false) async throws -> HeadsetSnapshot {
        guard !busy else { throw ProtocolFailure("请等待当前耳机操作结束") }
        busy = true; beginOperation(); defer { endOperation(); busy = false; publish() }
        let oldGeneration = snapshot.generation
        do {
            try await open()
            try await readScope(scope, missingOnly: missingOnly,
                                includeHiRes: includeHiRes || snapshot.generation != oldGeneration)
            return snapshot
        } catch { abort(error.localizedDescription); throw error }
    }
    /// Subscription does not guarantee an initial state notification. After a
    /// reconnect, seed only the stale quick controls; keep the HiRes path compact.
    func listen() async throws -> HeadsetSnapshot {
        guard !busy else { throw ProtocolFailure("请等待当前耳机操作结束") }
        busy = true; beginOperation(); defer { endOperation(); busy = false; publish() }
        let oldGeneration = snapshot.generation
        do { try await open() }
        catch { abort(error.localizedDescription); throw error }
        if snapshot.generation != oldGeneration {
            do { try await readHiRes() }
            catch { if connection == nil { throw error } }
        }
        try await readListeningBaseline()
        return snapshot
    }
    private func readListeningBaseline() async throws {
        do { try await subscribe() }
        catch {
            snapshot.issues["subscription"] = error.localizedDescription
            if connection == nil { throw error }
        }
        for query in [HeadsetQuery.noiseCurrent, .ears, .battery, .noiseIntelligent] {
            guard snapshot.supports(query) else { continue }
            let needsRead: Bool
            switch query {
            case .noiseCurrent: needsRead = snapshot.noise?.stale != false || snapshot.noiseType?.stale != false
            case .ears: needsRead = !snapshot.hasFresh(.ears)
            case .battery: needsRead = !snapshot.hasFresh(.battery)
            case .noiseIntelligent: needsRead = snapshot.supports(.noiseIntelligent) && snapshot.noise?.stale == false && snapshot.noise?.value == 7 && snapshot.intelligentNoise?.stale != false
            default: needsRead = false
            }
            guard needsRead else { continue }
            do { try await read(query, optional: true); publish() }
            catch {
                // read() retains the stale flag and records the field error.
                // One missing optional field must not discard confirmed HiRes.
                if connection == nil { throw error }
            }
        }
    }
    /// HiRes and the system codec label must not wait for EQ/spatial/personalization.
    func refreshHiRes() async throws -> HeadsetSnapshot {
        guard !busy else { throw ProtocolFailure("请等待当前耳机操作结束") }
        busy = true; beginOperation(); defer { endOperation(); busy = false }
        do {
            try await open()
            try await readConfirmedHiRes()
            publish(); return snapshot
        } catch { abort(error.localizedDescription); throw error }
    }
    private func readConfirmedHiRes() async throws {
        guard snapshot.profile != nil else { throw ProtocolFailure("产品 ID 未适配；未恢复专属控制") }
        if !snapshot.supports(.feature(.hiRes)) { try await readHiRes(); return }
        guard snapshot.capabilities?.supportsCurrentCodecQuery == true else {
            throw ProtocolFailure("耳机未报告当前编码查询能力，HiRes 状态未确认")
        }
        let codec = try await exchange(command: 0x0114)
        guard codec.payload.count == 2, codec.payload[0] == 0 else { throw ProtocolFailure("当前编码回复未知") }
        snapshot.currentCodec = codec.payload[1]
        try await read(.feature(.hiRes))
        guard legacyReport.hiRes != nil else { throw ProtocolFailure("HiRes 回复未包含有效开关状态") }
        trace("hiresConfirmed", "enabled=\(legacyReport.hiRes == true)")
        publish()
    }
    /// One audio-active baseline, independent of whether the menu is visible.
    /// At most two read attempts (18 s each), one confirmed shutdown (15 s),
    /// and a 2 s backoff. No user setting, AVDTP or audio route is touched.
    func resumeAfterAudioStart() async throws -> HeadsetSnapshot {
        guard !busy else { throw ProtocolFailure("请等待当前耳机操作结束") }
        busy = true; defer { endOperation(); busy = false; publish() }
        for attempt in 1...2 {
            try Task.checkCancellation()
            beginOperation()
            trace("resumeAttempt", "attempt=\(attempt) limit=2")
            do {
                try await open()
                try await readConfirmedHiRes()
                try await readListeningBaseline()
                try Task.checkCancellation()
                endOperation()
                trace("resumeComplete", "attempt=\(attempt)")
                return snapshot
            } catch {
                endOperation()
                let retry = attempt == 1 && readInterruptedByTransport && !Task.isCancelled
                abort(error.localizedDescription)
                guard retry else { throw error }
                trace("resumeRetry", "waiting for confirmed shutdown; " + error.localizedDescription)
                progress("控制通道暂未响应，正在清理后补读一次耳机状态")
                try await suspend()
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: resumeRetryDelay)
            }
        }
        throw ProtocolFailure("耳机状态恢复未完成，请点击耳机旁的刷新按钮")
    }
    func set(_ setting: HeadsetSetting, generation: UUID) async -> HeadsetOperationResult {
        var result = HeadsetOperationResult(setting: setting, message: "未发送设置")
        guard !busy, snapshot.connected, snapshot.generation == generation else {
            result.message = "控制连接已变化或忙碌，请刷新后重试"; return result
        }
        busy = true; beginOperation(limit: 15); defer { endOperation(); busy = false; publish() }
        var sent = false
        do {
            guard snapshot.profile != nil, snapshot.supports(setting.query) else { throw ProtocolFailure("型号或接口未确认，未发送设置") }
            // A fresh baseline prevents overwriting a phone edit or a replaced EQ slot.
            for query in snapshot.prerequisiteQueries(for: setting) { try await read(query) }
            let before = snapshot
            if case .feature(.hiRes, _) = setting {
                let response = try await exchange(command: 0x0114)
                guard response.payload.count == 2, response.payload[0] == 0 else { throw ProtocolFailure("当前编码回复未知，未修改 HiRes") }
                snapshot.currentCodec = response.payload[1]
            }
            if case .noise = setting {
                // Check wearing again just before the single write; phone/ear events may race the UI.
                if snapshot.supports(.ears) { try await read(.ears) }
                // X4's phone UI also uses its product profile when the optional support list is absent.
                // Fresh current state and command capability are still required; never retry a write.
                do { try await read(.noiseAvailable) }
                catch { guard connection != nil, snapshot.canChooseNoise else { throw error } }
            }
            let packet = try snapshot.packet(for: setting, sequence: 0)
            // Invalidate the affected observations before writing; an interrupted readback
            // must not present the pre-write selection as current.
            for query in snapshot.prerequisiteQueries(for: setting) { snapshot.markStale(query, reason: "设置待读回确认") }
            sent = true
            trace("settingWrite", String(format: "command=%04X actionOrID=%d", packet.command, packet.payload.first ?? 0))
            let ack = try await exchange(command: packet.command, payload: packet.payload)
            let response = try? HeadsetWriteReply(ack, command: packet.command)
            result.acknowledged = response?.accepted == true
            trace("settingAck", "accepted=\(result.acknowledged) status=\(response.map { String($0.status) } ?? "unknown") eqID=\(response?.equalizerID.map(String.init) ?? "none") bytes=\(ack.payload.count)")
            for query in snapshot.prerequisiteQueries(for: setting) { try await read(query) }
            let matches = setting.changesSoundSelection ? snapshot.confirmsSound(setting, before: before, acknowledgedEQID: response?.equalizerID) : snapshot.confirms(setting)
            result.confirmed = result.acknowledged && matches
            trace("settingReadback", "matches=\(matches) preset=\(snapshot.preset.map { String($0.value) } ?? "unknown") selectedEQs=\(snapshot.equalizers?.value.filter(\.selected).map(\.id) ?? [])")
            if result.confirmed { result.message = "配置已确认；实际效果需实机验收" }
            else if response == nil { result.message = "耳机设置响应格式未识别；已重新读取实际状态，未重试设置" }
            else if !result.acknowledged { result.message = "耳机未接受设置；已重新读取实际状态，未重试设置" }
            else { result.message = "耳机回复与目标不一致；已重新读取实际状态，未重试设置" }
            // HiRes can reboot the Bluetooth profile immediately. Deliver its
            // correlated ACK/readback before unrelated queries; audio recovery
            // will refresh the remaining state on the new connection.
            if case .feature(.hiRes, _) = setting { return result }
            // Prerequisite readback above covers the affected settings. Do not
            // pull firmware, keys, EQ and HiRes after every unrelated write.
            if case .noise = setting, snapshot.supports(.noiseIntelligent), snapshot.noise?.value == 7 {
                do { try await read(.noiseIntelligent, optional: true) }
                catch { result.message += "；智能降噪深度未确认：" + error.localizedDescription }
            }
        } catch {
            result.message = sent ? "已尝试发送一次设置，确认未完成：\(error.localizedDescription)。待重新连接确认，未重发。" : "未发送设置：\(error.localizedDescription)"
            if sent { result.confirmed = false }
        }
        return result
    }
    var legacyReport: OppoProbeReport { snapshot.controlReport }
}
