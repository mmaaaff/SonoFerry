import Foundation
import SonoFerryCore

@MainActor
final class Harness {
    var commands: [WireMessage] = []
    let suite = "local.SonoFerry.Tests." + UUID().uuidString
    let prefs: UserDefaults
    var client: EngineClient!
    let device = BluetoothDevice(address: "00:11:22:33:44:55", name: "Offline A", connected: true, a2dpSink: true)
    let other = BluetoothDevice(address: "00:11:22:33:44:66", name: "Offline B", connected: true, a2dpSink: true)
    var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    var controlTimeouts: [(TimeInterval, @MainActor () -> Void)] = []
    var clock = Date(timeIntervalSince1970: 0)
    func advance() { let (delay, action) = scheduled.removeFirst(); clock += delay; action() }
    var id: UUID { commands.last(where: { $0.kind == "start" || $0.kind == "probe" })!.sessionID! }
    init(settleHiRes: Bool = true, softwareVolume: Bool = true) throws {
        prefs = UserDefaults(suiteName: suite)!
        if softwareVolume { prefs.set(true, forKey: "softwareVolumeEnabled") }
        prefs.set(try! JSONEncoder().encode([RegisteredHeadphone(address: device.address, model: .encoX4)]), forKey: "headphoneLibrary.v1")
        client = EngineClient(previewMode: false, preferences: prefs, messageSink: { [weak self] in self?.commands.append($0) },
                              recoveryScheduler: { [weak self] delay, action in self?.scheduled.append((delay, action)) },
                              controlScheduler: { [weak self] delay, action in self?.controlTimeouts.append((delay, action)) },
                              now: { [weak self] in self?.clock ?? Date() }, preferencesDomain: suite)
        client.devices = [device,other]; client.selectedAddress = device.address
        client.capabilities = [try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x06,0x11,0,0])]
        client.selectedCapability = client.capabilities[0].id; client.probeComplete = true; client.gain = 0.2
        client.parametersChanged(userInitiated: false); client.start()
        activate()
        if settleHiRes { answerHiResQuery() }
    }
    func activate() {
        let start = commands.last(where: { $0.kind == "start" })!
        var active = WireMessage("active", sessionID: start.sessionID)
        active.configuration = start.configuration; active.format = start.configuration!.format
        client.receive(active)
    }
    // Production control replies include the authoritative snapshot and generation.
    func receive(_ source: WireMessage) {
        var event = source
        if event.kind == "oppoResult", event.headset == nil, let address = event.device?.address {
            var state = client.headset ?? HeadsetSnapshot(address: address)
            if event.oppoReport?.hiRes != nil { state.productID = 0x06ec10 }
            state.connected = true; state.currentCodec = event.oppoReport?.currentCodecID
            state.capabilities = event.oppoReport?.controlCapabilities ?? (try! .init(reply: .init(command: 0x8100, payload: [0,0x9b,1,2,0,0,0])))
            if let value = event.oppoReport?.hiRes { state.features[24] = .init(value) }
            else { state.features.removeValue(forKey: 24) }
            event.headset = state; event.controlGeneration = state.generation
        }
        client.receive(event)
    }
    func answerHiResQuery() {
        guard client.oppoQueryInProgress, let query = commands.last(where: { $0.kind == "oppoQuery" }) else { return }
        var result = WireMessage("oppoResult", requestID: query.requestID, sessionID: query.sessionID)
        result.device = query.device; result.oppoReport = OppoProbeReport()
        receive(result)
    }
    func end(_ kind: String = "stopped", message: String? = nil) {
        var event = WireMessage(kind, sessionID: id); event.message = message; client.receive(event)
    }
    func cleanup() { prefs.removePersistentDomain(forName: suite) }
}
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() { fatalError(name) }
}
@main struct EngineClientTests {
    @MainActor static func main() throws {
        for bitrate in [900, 1000] {
            let h = try Harness(); defer { h.cleanup() }
            let full = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])
            h.client.capabilities = [full]; h.client.selectedCapability = full.id
            h.client.rate = 96000; h.client.quality = .connection; h.client.fixedBitrate = bitrate
            h.client.parametersChanged()
            let before = h.commands.count
            var prompts = 0
            h.client.requestApplySettings { prompts += 1; return (false, true) }
            check(prompts == 1 && h.commands.count == before && h.client.active && h.client.highBitrateWarningEnabled,
                  "cancel high bitrate leaves playback and warning preference unchanged")
            h.client.requestApplySettings { prompts += 1; return (true, false) }
            check(prompts == 2 && h.commands.last?.kind == "stop" && h.client.highBitrateWarningEnabled,
                  "confirm high bitrate without suppression starts ordered reconnect and retains warning")
            h.end()
            check(h.commands.last?.configuration?.fixedBitrateKbps == bitrate, "confirmed bitrate reaches reconnect")
        }
        do {
            let h = try Harness(); defer { h.cleanup() }
            let full = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])
            h.client.capabilities = [full]; h.client.selectedCapability = full.id
            h.client.rate = 96000; h.client.quality = .connection; h.client.fixedBitrate = 900
            h.client.parametersChanged()
            h.client.requestApplySettings { (true, true) }
            check(!h.client.highBitrateWarningEnabled, "apply persists suppression")
            h.end(); h.activate(); h.answerHiResQuery()
            h.client.fixedBitrate = 1000; h.client.parametersChanged()
            h.client.requestApplySettings { fatalError("suppressed warning must not be shown") }
            h.end()
            check(h.commands.last?.configuration?.fixedBitrateKbps == 1000, "suppression covers both high bitrates")
            let restored = EngineClient(previewMode: false, preferences: h.prefs, messageSink: { _ in })
            check(!restored.highBitrateWarningEnabled, "suppression survives a new client")
        }
        for adaptive in [false, true] {
            let h = try Harness(); defer { h.cleanup() }
            h.client.rate = 96000; h.client.quality = adaptive ? .adaptive : .connection
            h.client.fixedBitrate = adaptive ? 1000 : 400; h.client.parametersChanged()
            h.client.requestApplySettings { fatalError("adaptive and lower bitrate must not prompt") }
            check(h.commands.last?.kind == "stop", "ordinary apply remains available")
        }
        do {
            let h = try Harness(); defer { h.cleanup() }
            let full = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])
            h.client.capabilities = [full]; h.client.selectedCapability = full.id
            h.client.rate = 96000; h.client.quality = .connection; h.client.fixedBitrate = 900; h.client.parametersChanged()
            let before = h.commands.count
            h.client.requestApplySettings { h.client.fixedBitrate = 1000; return (true, true) }
            check(h.commands.count == before && h.client.highBitrateWarningEnabled,
                  "draft changed during modal is not applied or suppressed by stale confirmation")
        }
        print("HIGH_BITRATE_WARNING PASS: cancel, confirm, suppression, relaunch, adaptive/lower bypass, stale confirmation")
        do {
            let h = try Harness(softwareVolume: false); defer { h.cleanup() }
            let key = "volume.v2.software." + h.device.address
            check(!h.client.softwareVolumeEnabled && h.client.gain == 1, "fresh product defaults to disabled software volume at unity")
            h.client.setGain(0.3)
            check(h.client.gain == 1 && h.prefs.object(forKey: key) == nil, "disabled slider cannot change gain or overwrite stored volume")
            h.client.setSoftwareVolumeEnabled(true); h.client.setGain(0.3)
            check(h.client.gain == 0.3 && h.prefs.double(forKey: key) == 0.3, "enabled volume remembers an explicit adjustment")
            h.client.setSoftwareVolumeEnabled(false)
            var late = WireMessage("gain", sessionID: h.id); late.gain = 0.2; h.client.receive(late)
            check(h.client.gain == 1 && h.prefs.double(forKey: key) == 0.3, "late feedback while disabled preserves unity and remembered adjustment")
            h.client.setSoftwareVolumeEnabled(true)
            check(h.client.gain == 0.3 && h.prefs.bool(forKey: "softwareVolumeEnabled"), "reenabling restores and persists remembered software volume")
        }
        do {
            let h = try Harness(); defer { h.cleanup() }
            h.client.watchHeadset()
            let watch = h.commands.last!
            var state = HeadsetSnapshot(address: h.device.address); state.connected = true; state.productID = 0x06ec10
            state.currentCodec = 8
            state.capabilities = try .init(reply: .init(command: 0x8100, payload: [0,0x9b,1,2,0,0,0]))
            state.noise = .init(3); state.noiseType = .init(1); state.features[24] = .init(true)
            state.ears[1] = .init(.init(raw: 3)); state.ears[2] = .init(.init(raw: 3))
            var ready = WireMessage("headsetResult", requestID: watch.requestID)
            ready.device = h.device; ready.headset = state; ready.controlGeneration = state.generation
            h.receive(ready)
            h.client.refreshHeadset(page: "操作")
            let oldRead = h.commands.last!
            h.client.setHeadset(.noise(8)); let oldWrite = h.commands.last!
            check(h.client.canRefreshAllHeadset, "recovery available while read and write wait")
            h.client.refreshAllHeadset(); let recovery = h.commands.last!
            check(recovery.kind == "headsetRecover" && !h.client.canRefreshAllHeadset && !h.client.canControlHeadset,
                  "recovery bypasses old busy but locks settings until engine quiescence")
            ready.requestID = oldRead.requestID; h.receive(ready)
            ready.requestID = oldWrite.requestID; h.receive(ready)
            check(h.client.headsetBusy && !h.client.canControlHeadset, "old terminals cannot unlock recovery")
            ready.requestID = recovery.requestID; h.receive(ready)
            check(!h.client.headsetBusy && h.client.canControlHeadset && h.client.hiResValue == true,
                  "new full snapshot unlocks and restores all controls")
            h.client.refreshAllHeadset(); let timed = h.commands.last!
            h.controlTimeouts.last!.1()
            check(h.client.canRefreshAllHeadset && !h.client.canControlHeadset && !h.client.headsetBusy,
                  "manual recovery timeout allows retry while stale settings stay protected")
            check(h.commands.last?.kind == "headsetCancel" && h.commands.last?.requestID == timed.requestID,
                  "timeout cancels exact recovery, no write replay")
            h.client.refreshAllHeadset(); ready.requestID = h.commands.last!.requestID; h.receive(ready)
            let count = h.commands.count
            h.client.watchHeadset(); h.client.watchHeadset()
            check(h.commands.count == count, "reopening/concurrent quick views never refresh fresh watch")
            check(h.client.hiResValue == true && h.client.canSetOppoHiRes, "ordinary authoritative snapshot restores HiRes without legacy result")
            h.client.loadHeadsetPage("操作")
            let page = h.commands.last!
            check(page.details?["refreshScope"] == "keys" && page.details?["missingOnly"] == "true", "settings read current page only")
            check(h.client.canControlHeadset, "read does not disable ANC controls")
            h.client.setHeadset(.noise(8)); let write = h.commands.last!
            check(write.kind == "headsetSet" && write.details?["waitForRead"] == "true" && h.client.headsetWriting,
                  "user action can wait once behind read without losing either request")
            ready.requestID = page.requestID; h.receive(ready)
            check(h.client.headsetWriting && !h.client.canControlHeadset, "read completion cannot unlock pending write")
            ready.requestID = write.requestID; h.receive(ready)
            check(!h.client.headsetWriting && h.client.canControlHeadset, "write completion unlocks controls")
            h.client.setHeadset(.noise(8)); let rejected = h.commands.last!
            var rejection = WireMessage("headsetResult", requestID: rejected.requestID)
            rejection.device = h.device; rejection.message = "等待耳机控制通道超时；未发送排队操作"
            h.receive(rejection)
            check(h.client.lastHeadsetResult?.confirmed == false && h.client.lastHeadsetResult?.message == rejection.message,
                  "queue failure remains visible as failed setting, not a silently dropped click")
            let loaded = h.commands.count; h.client.loadHeadsetPage("操作")
            check(h.commands.count == loaded, "reopening same page reuses generation cache")
            h.client.refreshHeadset(page: "操作"); let manual = h.commands.last!
            check(h.client.hiResDisplayedValue && h.client.isDetectingHiRes && !h.client.canSetOppoHiRes && h.client.canControlHeadset,
                  "manual HiRes refresh retains ON while disabling switch, not ANC")
            state.features[24] = .init(false); ready.headset = state; ready.requestID = manual.requestID; h.receive(ready)
            check(!h.client.hiResDisplayedValue && h.client.hiResValue == false && h.client.canSetOppoHiRes, "manual read shows actual OFF on completion")
            h.client.queryOppo()
            check(!h.client.hiResDisplayedValue && !h.client.canSetOppoHiRes, "compact query retains OFF and disables switch")
            h.client.cancelOppo()
            var newState = state; newState.generation = UUID(); newState.features[24] = .init(true)
            ready.kind = "headsetConnection"; ready.headset = newState; ready.controlGeneration = newState.generation
            h.receive(ready)
            check(h.client.hiResValue == true && h.client.canSetOppoHiRes, "new-generation notification recovers HiRes without report dependency")
            ready.headset = state; ready.controlGeneration = state.generation; h.receive(ready)
            check(h.client.hiResValue == true, "retired generation cannot replace current HiRes")
            h.client.queryOppo()
            check(h.client.hiResDisplayedValue && !h.client.canSetOppoHiRes, "compact query retains ON instead of flashing OFF")
            h.client.cancelOppo()
            check(h.client.hiResDisplayedValue && h.client.hiResValue == nil && !h.client.canSetOppoHiRes, "canceled read keeps position but never authorizes stale value")
            print("APP_REFRESH_SCOPES PASS: idempotent open, lazy pages, read/write separation, HiRes retained visual state and generation recovery")
        }

        do {
            let h = try Harness(); defer { h.cleanup() }
            check(h.client.transportSettingsNotice == nil, "active unchanged transport has no inactive notice")
            h.client.rate = h.client.negotiated!.sampleRate.rawValue == 48000 ? 44100 : 48000
            h.client.parametersChanged()
            check(h.client.transportSettingsNotice == "修改尚未应用", "active draft has unapplied notice")
            let count = h.commands.count; h.client.addHeadphone(h.other)
            check(h.commands.count == count, "click explanation cannot start device detection during HD playback")
            h.client.applySettings()
            check(h.client.transportSettingsNotice == nil, "reconnect never displays inactive codec notice")
            h.client.headsetMessage = "配置已确认；实际效果需实机验收"
            check(h.client.visibleHeadsetMessage.isEmpty, "generic acceptance copy hidden")
            h.client.headsetMessage += "；后续状态刷新未完成：timeout"
            check(h.client.visibleHeadsetMessage == "后续状态刷新未完成：timeout", "partial failure remains visible")
            check(HeadphoneModel.wh1000xm5.displayTitle == "WH-1000XM5（实验性）", "experimental device catalogue name")
            h.client.devices = [.init(address: h.device.address, name: "WH-1000XM5", connected: true, a2dpSink: true)]
            check(h.client.selectedDeviceTitle == "WH-1000XM5（实验性）", "experimental selected device name")
        }

        do {
            let h = try Harness(settleHiRes: false); defer { h.cleanup() }
            let request = h.commands.last!
            var success = WireMessage("oppoResult", requestID: request.requestID, sessionID: request.sessionID)
            success.device = request.device; success.message = "耳机状态已刷新"
            var report = OppoProbeReport(); report.hiRes = true; success.oppoReport = report
            h.receive(success)
            check(h.client.hiResRefreshedAt != nil && h.client.visibleOppoMessage.isEmpty, "fresh correlated HiRes read emits only transient success")
            h.client.headsetMessage = "耳机状态已刷新"
            check(h.client.visibleHeadsetMessage.isEmpty, "subscription/full-read success does not duplicate the toast")
            h.client.queryOppo(); check(h.client.hiResRefreshedAt == nil, "next read clears old success")
            check(h.client.isDetectingHiRes && h.client.visibleOppoMessage.isEmpty, "refresh has no text below HiRes controls")
            let pending = h.commands.last!
            h.receive(success)
            check(h.client.hiResRefreshedAt == nil && h.client.oppoBusy, "late success cannot flash or finish another request")
            var failed = WireMessage("oppoFailed", requestID: pending.requestID, sessionID: pending.sessionID)
            failed.device = pending.device; failed.message = "读取失败"; h.receive(failed)
            check(h.client.hiResRefreshedAt == nil && h.client.visibleOppoMessage == "读取失败", "failed read keeps error and never flashes success")
        }
        do {
            let h = try Harness(settleHiRes: false); defer { h.cleanup() }
            let query = h.commands.last!
            check(query.details?["source"] == "audio-resume" && h.client.headsetResumeInProgress,
                  "active explicitly requests bounded compact status restoration")
            check(query.kind == "oppoQuery" && query.sessionID == h.id && query.device == h.device,
                  "direct start automatically reads HiRes only after correlated active event")
            check(h.client.isDetectingHiRes && !h.client.canSetOppoHiRes && h.client.oppoReport == nil,
                  "automatic read exposes loading and keeps the unknown switch disabled")
            h.activate()
            check(h.commands.filter { $0.kind == "oppoQuery" }.count == 1, "duplicate active cannot duplicate an in-flight read")
            var wrong = WireMessage("oppoResult", requestID: query.requestID, sessionID: UUID())
            wrong.device = h.device; wrong.oppoReport = OppoProbeReport()
            h.receive(wrong)
            check(h.client.isDetectingHiRes, "wrong-session result cannot finish detection")
            var failed = WireMessage("oppoFailed", requestID: query.requestID, sessionID: h.id)
            failed.device = h.device; failed.message = "timeout"; h.receive(failed)
            h.activate()
            check(!h.client.isDetectingHiRes && h.client.oppoReport == nil && h.commands.filter { $0.kind == "oppoQuery" }.count == 1,
                  "failed read ends loading, stays unknown and does not loop on duplicate active")
            check(!h.client.headsetResumeInProgress, "exhausted engine retry ends restoring UI")
            h.client.queryOppo(); check(h.client.isDetectingHiRes, "manual retry remains available")
            h.answerHiResQuery()
            let oldID = h.id
            h.client.rate = 96000; h.client.parametersChanged(); h.client.applySettings(); h.end()
            check(h.id != oldID && !h.client.isDetectingHiRes && h.commands.last!.kind == "start", "no read during reconnection")
            h.receive(WireMessage("active", sessionID: oldID))
            check(!h.client.isDetectingHiRes, "old connection cannot start automatic detection")
            h.activate()
            let newQuery = h.commands.last!
            check(newQuery.kind == "oppoQuery" && newQuery.sessionID == h.id && h.client.isDetectingHiRes,
                  "parameter reconnect gets its own one-shot read")
            h.client.stop(); h.activate()
            check(!h.client.isDetectingHiRes && !h.client.active, "stop cancels detection and rejects late active")
            var late = WireMessage("oppoResult", requestID: newQuery.requestID, sessionID: newQuery.sessionID)
            late.device = h.device; var report = OppoProbeReport(); report.hiRes = true; late.oppoReport = report
            h.receive(late)
            check(h.client.oppoReport == nil, "canceled detection cannot publish a late HiRes value")
        }
        do {
            let h = try Harness(settleHiRes: false); defer { h.cleanup() }
            let query = h.commands.last!
            var state = HeadsetSnapshot(address: h.device.address)
            state.connected = true; state.productID = 0x06ec10; state.currentCodec = 8
            state.capabilities = try .init(reply: .init(command: 0x8100, payload: [0,0x9b,1,2,0,0,0]))
            state.features[24] = .init(true); state.noise = .init(3); state.noiseType = .init(1)
            state.ears[1] = .init(.init(raw: 3)); state.ears[2] = .init(.init(raw: 3))
            state.markStale()
            var stale = WireMessage("headsetConnection", sessionID: h.id)
            stale.device = h.device; stale.headset = state; stale.controlGeneration = state.generation
            h.receive(stale)
            check(h.client.hiResDisplayedValue && h.client.hiResValue == nil && h.client.headsetResumeInProgress,
                  "retained ON stays disabled during first-attempt failure, not falsely OFF or final-unknown")
            var progress = WireMessage("oppoProgress", requestID: query.requestID, sessionID: h.id)
            progress.device = h.device; progress.message = "控制通道暂未响应，正在清理后补读一次耳机状态"
            h.receive(progress)
            h.client.watchHeadset()
            check(h.client.isDetectingHiRes && h.client.visibleOppoMessage.isEmpty && h.commands.last!.requestID == query.requestID,
                  "reopening menu during recovery cannot duplicate or interrupt it")
            state.generation = UUID(); state.connected = true; state.features[24] = .init(false)
            state.noise = .init(8); state.noiseType = .init(1)
            state.ears[1] = .init(.init(raw: 3)); state.ears[2] = .init(.init(raw: 3))
            var ready = WireMessage("oppoResult", requestID: query.requestID, sessionID: h.id)
            ready.device = h.device; ready.headset = state; ready.controlGeneration = state.generation; ready.oppoReport = state.controlReport
            h.receive(ready)
            check(!h.client.headsetResumeInProgress && h.client.hiResValue == false && h.client.canControlHeadset,
                  "one terminal restores actual HiRes OFF and ANC without another menu read")
            check(!h.commands.contains { $0.kind == "headsetListen" }, "combined resume does not send a duplicate subscription query")
            state.noise = .init(3)
            var notification = WireMessage("headsetSnapshot", requestID: query.requestID, sessionID: h.id)
            notification.device = h.device; notification.headset = state
            h.receive(notification)
            check(h.client.headset?.noise?.value == 3, "resume ID owns subsequent background notifications")
        }
        for cancel in [false, true] {
            let h = try Harness(); defer { h.cleanup() }; h.end()
            h.client.watchHeadset(); let watch = h.commands.last!
            h.client.start(); h.activate()
            let count = h.commands.filter { $0.kind == "oppoQuery" }.count
            check(h.client.isDetectingHiRes && h.client.oppoBusy && count == 2,
                  "read is sent for engine serialization even while a visible headset query is busy")
            if cancel { h.client.stop() }
            var done = WireMessage("headsetResult", requestID: watch.requestID)
            done.device = h.device; h.receive(done)
            check(h.commands.filter { $0.kind == "oppoQuery" }.count == count,
                  "headset completion never duplicates the already queued read")
            if !cancel { h.answerHiResQuery(); check(!h.client.isDetectingHiRes, "successful read clears loading") }
        }
        do {
            let h = try Harness(settleHiRes: false); defer { h.cleanup() }
            let expired = h.commands.last!
            check(h.controlTimeouts.last!.0 == 80, "resume bounds queue, two read attempts, confirmed close and backoff")
            h.controlTimeouts.last!.1()
            check(!h.client.isDetectingHiRes && !h.client.oppoBusy && h.client.canQueryOppo && h.client.oppoMessage.contains("80 秒"),
                  "missing terminal reply ends spinner and leaves manual refresh available")
            check(h.commands.last!.kind == "oppoCancel" && h.commands.last!.requestID == expired.requestID, "timed-out read is canceled once")
            h.client.queryOppo(); let current = h.commands.last!
            check(h.controlTimeouts.last!.0 == 40 && !h.client.headsetResumeInProgress,
                  "ordinary manual query retains its shorter one-attempt timeout")
            var late = WireMessage("oppoResult", requestID: expired.requestID, sessionID: expired.sessionID)
            late.device = h.device; late.oppoReport = OppoProbeReport(); h.receive(late)
            h.controlTimeouts.first!.1()
            check(h.client.isDetectingHiRes && h.commands.last!.requestID == current.requestID, "old reply and watchdog cannot finish a new query")
            h.answerHiResQuery(); h.controlTimeouts.last!.1()
            check(!h.client.isDetectingHiRes && !h.client.oppoMessage.contains("40 秒"), "finished query invalidates its watchdog")
        }
        print("APP_HIRES_AUTO_READ PASS: direct start, per-session read, reconnect, busy control deferral, duplicate/stale events, loading, failure, manual retry and cancellation.")
        let live = try Harness(); defer { live.cleanup() }
        check(live.client.canEditSettings && !live.client.canApplySettings, "active controls editable")
        let initial = live.client.negotiated
        live.client.catchupLimitTenths = 150; live.client.prefillMilliseconds = 1000; live.client.bufferingChanged()
        let update = live.commands.last!
        check(update.kind == "buffering" && update.buffering == live.client.bufferingSettings, "edit sends immediately without manual apply")
        check(live.client.negotiated == initial && live.client.applyingBuffering, "wait for sender acknowledgment")
        live.client.prefillMilliseconds = 800; live.client.bufferingChanged()
        live.client.prefillMilliseconds = 600; live.client.bufferingChanged()
        check(live.commands.last!.requestID == update.requestID, "latest edits coalesced while one request is in flight")
        var ack = WireMessage("bufferingApplied", requestID: UUID(), sessionID: live.id); ack.buffering = update.buffering
        live.receive(ack); check(live.client.negotiated == initial, "stale request ignored")
        ack.requestID = update.requestID; ack.sessionID = UUID(); live.receive(ack)
        check(live.client.negotiated == initial, "stale session ignored")
        ack.sessionID = live.id; ack.buffering = live.client.bufferingSettings; live.receive(ack)
        check(live.client.negotiated == initial, "mismatched confirmation ignored")
        ack.buffering = update.buffering; live.receive(ack)
        let latest = live.commands.last!
        check(live.client.negotiated!.bufferingSettings == update.buffering && latest.buffering!.prefillMilliseconds == 600, "confirmation automatically submits latest edit")
        check(live.commands.filter { $0.kind == "buffering" }.count == 2, "no intermediate-value queue")
        ack.requestID = latest.requestID; ack.buffering = latest.buffering; live.receive(ack)
        check(!live.client.applyingBuffering && !live.client.canApplySettings, "latest buffer setting confirmed")
        check(live.commands.filter { $0.kind == "stop" }.isEmpty, "buffer change uninterrupted")
        let oldID = live.id
        live.client.rate = 96000; live.client.parametersChanged()
        check(live.client.format!.sampleRateHz == 48000, "draft doesn't falsify actual format")
        check(live.client.active && live.client.canApplySettings && live.client.showsApplySettings && live.client.applySettingsTitle == "应用修改", "format edit exposes explicit apply without interrupting playback")
        live.client.applySettings()
        check(live.commands.last!.kind == "stop" && live.client.hasPendingStart && !live.client.canEditSettings, "apply starts ordered teardown")
        check(live.commands.last!.stopIntent == .reconfigure && live.commands.last!.device?.address == live.device.address,
              "parameter restart has explicit device/session/next-configuration intent")
        var progress = WireMessage("stopProgress", sessionID: oldID); progress.stopPhase = .disconnect
        live.receive(progress); check(live.client.status == AudioStopPhase.disconnect.title, "stop phase shown while stopping")
        progress.sessionID = UUID(); progress.stopPhase = .nativeOutput; live.receive(progress)
        check(live.client.status == AudioStopPhase.disconnect.title, "stale phase cannot replace current teardown stage")
        live.receive(WireMessage("stopped", sessionID: UUID()))
        check(live.commands.last!.kind == "stop", "stale stopped cannot start")
        live.client.setGain(0.7)
        check(live.commands.last!.kind == "stop", "volume edit during teardown never unmutes stopping session")
        var lateGain = WireMessage("gain", sessionID: oldID); lateGain.gain = 0
        live.receive(lateGain)
        check(live.client.gain == 0.7, "stopping-session volume feedback cannot overwrite the reconnect preference")
        live.receive(WireMessage("stopped", sessionID: oldID))
        check(live.commands.last!.kind == "start" && live.id != oldID && live.commands.last!.configuration!.sampleRate == .hz96000, "restart after clean stop")
        check(live.commands.last!.configuration!.isForced && live.commands.last!.gain == 0.7, "automatic forced-format reconnect retains latest software volume")
        do {
            let unsafe = try Harness(); defer { unsafe.cleanup() }
            unsafe.client.rate = 96000; unsafe.client.parametersChanged(); unsafe.client.applySettings()
            var terminal = WireMessage("stopped", sessionID: unsafe.id); terminal.restartSafe = false
            unsafe.receive(terminal)
            check(unsafe.commands.filter { $0.kind == "start" }.count == 1, "explicit unsafe cleanup cannot restart even without an error string")
        }
        for reason in ["cancel", "failed", "error", "quit"] {
            let h = try Harness(); defer { h.cleanup() }
            h.client.rate = 96000; h.client.parametersChanged(); h.client.applySettings()
            if reason == "cancel" { h.client.stop(); check(h.commands.last?.stopIntent == nil, "user stop revokes reconfigure intent") }
            if reason == "quit" { h.client.quit() }
            if reason == "error" { var error = WireMessage("error", sessionID: h.id); error.message = "route changed"; h.receive(error) }
            h.end(reason == "failed" ? "failed" : "stopped")
            check(h.commands.filter { $0.kind == "start" }.count == 1 && !h.client.busy, "no reconnect after \(reason)")
        }
        let devices = try Harness(); defer { devices.cleanup() }
        let playing = devices.client.negotiated
        devices.client.selectedAddress = devices.other.address; devices.client.deviceChanged()
        check(devices.client.active && devices.client.negotiated == playing, "undetected device doesn't silently interrupt current session")
        devices.client.setGain(0.3)
        check(devices.prefs.double(forKey: "volume.v2.software." + devices.device.address) == 0.3 && devices.prefs.object(forKey: "volume.v2.software." + devices.other.address) == nil, "volume belongs to playing device")
        devices.client.capabilities = [try CapabilityParser.codec(endpoint: 1, bytes: [0,255,0x2d,1,0,0,0xaa,0,0x3c,7])]
        devices.client.selectedCapability = devices.client.capabilities[0].id; devices.client.probeComplete = true; devices.client.parametersChanged()
        check(devices.client.active && !devices.client.hasPendingStart, "editing an inactive selected device does not replace another device's playback")
        devices.client.chooseCodec(CodecID.ldac.rawValue)
        devices.end()
        check(devices.commands.last!.device == devices.other && devices.commands.last!.gain == 1, "new device starts at unlinked default")
        let probe = try Harness(); defer { probe.cleanup() }
        probe.client.probe(); check(probe.commands.last!.kind == "stop" && probe.commands.last!.stopIntent == nil, "probe keeps ordinary restoration")
        probe.end(); check(probe.commands.last!.kind == "probe" && probe.commands.last!.gain == 0, "probe remains silent")
        check(probe.client.gain == 1, "silent probe preserves playback default in the interface")
        var probeMute = WireMessage("gain", sessionID: probe.id); probeMute.gain = 0
        probe.receive(probeMute)
        check(probe.client.gain == 1, "probe mute never overwrites playback volume")
        probe.client.setGain(0.6)
        check(probe.commands.last!.kind == "probe", "volume preference change does not unmute a probe")

        let queued = try Harness(); defer { queued.cleanup() }
        queued.client.prefillMilliseconds = 300; queued.client.bufferingChanged()
        let request = queued.commands.last!
        queued.client.rate = 96000; queued.client.parametersChanged()
        check(queued.commands.last!.kind == "buffering", "format change waits for current buffering request")
        var reply = WireMessage("bufferingApplied", requestID: request.requestID, sessionID: queued.id); reply.buffering = request.buffering
        queued.receive(reply)
        check(queued.commands.last!.kind == "buffering" && queued.client.active && queued.client.canApplySettings, "buffer confirmation cannot submit an uncommitted transport draft")
        queued.client.applySettings()
        check(queued.commands.last!.kind == "stop", "explicit apply continues after buffer confirmation")

        for codec in [CodecID.lhdcV5, .ldac] {
            let h = try Harness(); defer { h.cleanup() }
            h.end(); h.client.cancelOppo()
            let cap = codec == .lhdcV5
                ? try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])
                : try CapabilityParser.codec(endpoint: 1, bytes: [0,255,0x2d,1,0,0,0xaa,0,0x3c,7])
            h.client.capabilities = [cap]; h.client.selectedCapability = cap.id
            let before = h.commands.count
            h.client.rate = 96000; h.client.quality = .connection; h.client.fixedBitrate = codec == .lhdcV5 ? 500 : 0
            h.client.parametersChanged()
            check(h.commands.count == before && !h.client.active && h.client.canApplySettings,
                  "inactive draft never starts " + codec.title)
            check(h.client.applySettingsTitle == "启用 " + codec.title + " 并应用", "codec-specific activation label")
            h.client.applySettings(); let committed = h.commands.last!
            check(committed.kind == "start" && committed.configuration?.sampleRate == .hz96000 && committed.configuration?.quality == .connection,
                  "activation applies exact edited settings rather than defaults")
            check(committed.configuration?.fixedBitrateKbps == (codec == .lhdcV5 ? 500 : nil), "fixed bitrate survives activation")
            h.client.applySettings()
            check(h.commands.last!.sessionID == committed.sessionID, "double click cannot start another session")
            h.activate(); h.answerHiResQuery()
            check(!h.client.showsApplySettings && !h.client.canApplySettings, "confirmed transport has no apply button")
            let activeCount = h.commands.count
            h.client.rate = 48000; h.client.parametersChanged()
            h.client.quality = .adaptive; h.client.parametersChanged()
            check(h.commands.count == activeCount && h.client.hasTransportEdits && h.client.active, "multiple draft edits do not reconnect")
            h.client.rate = 96000; h.client.quality = .connection; h.client.parametersChanged()
            check(!h.client.hasTransportEdits && !h.client.showsApplySettings, "reverting draft removes apply button")
            h.client.rate = 48000; h.client.parametersChanged()
            h.client.prefillMilliseconds = 350; h.client.bufferingChanged()
            let buffer = h.commands.last!
            check(buffer.kind == "buffering" && !h.client.canApplySettings, "buffer update is independent of draft and temporarily gates apply")
            var ack = WireMessage("bufferingRejected", requestID: buffer.requestID, sessionID: h.id); ack.message = "fixture"
            h.receive(ack)
            check(h.client.active && h.client.canApplySettings && h.commands.last!.kind == "buffering", "buffer rejection never commits draft")
            h.client.applySettings(); h.end()
            check(h.commands.last!.configuration?.sampleRate == .hz48000 && h.commands.last!.configuration?.bufferingSettings.prefillMilliseconds == 350,
                  "single committed reconnect includes latest parameters and buffer")
            h.end("failed", message: "fixture output unavailable"); h.client.cancelOppo()
            check(h.client.showsApplySettings && h.client.canApplySettings && h.client.rate == 48000,
                  "failure leaves exact draft available through enable/apply button")
        }
        print("APP_EXPLICIT_APPLY PASS: LHDC/LDAC draft isolation, batching, reversion, inactive activation, fixed bitrate, double click, buffering and failure retry.")
        let stopped = try Harness(); defer { stopped.cleanup() }
        stopped.client.prefillMilliseconds = 300; stopped.client.bufferingChanged()
        let inFlight = stopped.commands.last!
        stopped.client.prefillMilliseconds = 400; stopped.client.bufferingChanged(); stopped.client.stop()
        var stale = WireMessage("bufferingApplied", requestID: inFlight.requestID, sessionID: stopped.id); stale.buffering = inFlight.buffering
        stopped.receive(stale)
        check(stopped.commands.last!.kind == "stop" && !stopped.client.canEditSettings, "stop cancels queued edits and late acknowledgment")

        let rejected = try Harness(); defer { rejected.cleanup() }
        rejected.client.prefillMilliseconds = 300; rejected.client.bufferingChanged()
        let rejectedRequest = rejected.commands.last!
        var rejection = WireMessage("bufferingRejected", requestID: rejectedRequest.requestID, sessionID: rejected.id)
        rejection.message = "test rejection"; rejected.receive(rejection)
        check(rejected.commands.filter { $0.kind == "buffering" }.count == 1 && rejected.client.settingsMessage == "test rejection", "rejected setting is not retried in a loop")
        rejected.client.prefillMilliseconds = 400; rejected.client.bufferingChanged()
        check(rejected.commands.last!.buffering!.prefillMilliseconds == 400, "later edit remains automatic after rejection")

        let volume = try Harness(); defer { volume.cleanup() }
        volume.end()
        volume.prefs.set(0.0, forKey: "volume." + volume.device.address)
        volume.client.deviceChanged()
        check(volume.client.gain == 1, "new unlinked policy replaces legacy muted default")
        volume.client.setGain(0.65); volume.client.deviceChanged()
        check(volume.client.gain == 0.65, "later manual volume remembered")
        volume.client.setGain(0); volume.client.deviceChanged()
        check(volume.client.gain == 0, "explicit mute is remembered")
        check(EngineClient.defaultGain(linked: true) == 0.4 && EngineClient.defaultGain(linked: false) == 1, "mode defaults are 40 and 100 percent")
        volume.client.setVolumeLink(true)
        check(!volume.client.linkHardwareVolume && volume.client.gain == 0, "unimplemented hardware binding remains unavailable")
        let midi = try Harness(); defer { midi.cleanup() }
        let cap = midi.client.capability!
        var change = WireMessage("sampleRateRequested", sessionID: midi.id)
        change.configuration = try cap.changingSampleRate(to: 96000, from: midi.client.negotiated!)
        change.capabilities = [cap]
        let commandCount = midi.commands.count
        change.sessionID = UUID(); midi.receive(change)
        change.sessionID = nil; midi.receive(change)
        check(midi.commands.count == commandCount && midi.client.rate == 0, "MIDI change requires the exact live session")
        midi.client.selectedAddress = midi.other.address; midi.client.deviceChanged()
        change.sessionID = midi.id; midi.receive(change)
        check(midi.client.selectedAddress == midi.device.address && midi.client.rate == 96000 && midi.commands.last!.kind == "stop", "MIDI request targets the playing device and starts automatic reconnect")
        check(midi.client.format!.sampleRateHz == 48000 && midi.client.configuration!.isForced, "actual display and capability provenance retained until reconnect")
        midi.end()
        check(midi.commands.last!.configuration!.sampleRate == .hz96000 && midi.commands.last!.gain == 0.2, "MIDI reconnect preserves software volume")

        let midiBuffer = try Harness(); defer { midiBuffer.cleanup() }
        midiBuffer.client.prefillMilliseconds = 333; midiBuffer.client.bufferingChanged()
        let bufferCommand = midiBuffer.commands.last!
        change.sessionID = midiBuffer.id; midiBuffer.receive(change)
        check(midiBuffer.commands.last!.kind == "buffering" && midiBuffer.client.prefillMilliseconds == 333, "MIDI change preserves the newest unconfirmed buffer edit")
        midiBuffer.client.rate = 44100; midiBuffer.client.parametersChanged()
        var bufferAck = WireMessage("bufferingApplied", requestID: bufferCommand.requestID, sessionID: midiBuffer.id)
        bufferAck.buffering = bufferCommand.buffering; midiBuffer.receive(bufferAck)
        check(midiBuffer.commands.last!.kind == "stop", "MIDI change continues after in-flight control acknowledgment")
        midiBuffer.end()
        check(midiBuffer.commands.last!.configuration?.sampleRate == .hz96000, "queued MIDI request cannot commit a later UI draft")
        midiBuffer.client.stop(); midiBuffer.end()
        check(midiBuffer.commands.filter { $0.kind == "start" }.count == 2, "explicit stop cannot restart MIDI session")
        print("APP_MIDI_RATE PASS: session filtering, current-device targeting, automatic reconnect, truthful format/force display, volume and pending buffer preservation, cancellation.")
        do {
        let oppo = try Harness(); defer { oppo.cleanup() }
        let playingCommands = oppo.commands.count
        oppo.client.queryOppo()
        check(oppo.commands.count == playingCommands + 1 && oppo.client.oppoBusy, "OPPO query can use the current stable HD connection")
        var liveControl = WireMessage("oppoResult", requestID: oppo.commands.last!.requestID)
        liveControl.device = oppo.device
        var liveReport = OppoProbeReport(); liveReport.currentCodecID = 8; liveReport.hiRes = false
        liveReport.controlCapabilities = try OppoControlCapabilities(reply: .init(command: 0x8100, payload: [0,0x80]))
        liveControl.oppoReport = liveReport; oppo.receive(liveControl)
        check(oppo.client.canSetOppoHiRes, "HiRes becomes editable only with confirmed control capability")
        let liveGeneration = oppo.client.headset!.generation
        oppo.client.setOppoHiRes(true)
        let setting = oppo.commands.last!
        check(setting.kind == "oppoSetHiRes" && setting.sessionID != nil && setting.hiResEnabled == true && setting.controlGeneration == liveGeneration, "HiRes write is scoped to current audio session and confirmed control generation")
        check(oppo.client.oppoReport?.hiRes == false && oppo.client.oppoBusy, "toggle does not optimistically claim success")
        oppo.client.cancelOppo()
        oppo.end(); oppo.client.queryOppo()
        let query = oppo.commands.last!
        check(query.kind == "oppoQuery" && query.requestID != nil && oppo.client.oppoBusy, "explicit idle query owns a request ID")
        oppo.client.start(); oppo.client.probe()
        check(oppo.commands.last!.requestID == query.requestID && !oppo.client.canStart && !oppo.client.canEditSettings, "audio start and device changes wait for control query")
        var reply = WireMessage("oppoResult", requestID: UUID()); reply.device = oppo.device
        reply.oppoReport = OppoProbeReport(); reply.message = "offline fixture"
        oppo.receive(reply); check(oppo.client.oppoBusy, "stale OPPO reply ignored")
        reply.requestID = query.requestID; reply.device = oppo.other
        oppo.receive(reply); check(oppo.client.oppoBusy, "wrong-device OPPO reply ignored")
        reply.device = oppo.device; oppo.receive(reply)
        check(!oppo.client.oppoBusy && oppo.client.oppoReport?.hiRes == nil && oppo.client.capabilities.count == 1, "unknown control status never upgrades codec capabilities")
        oppo.client.queryOppo(); let canceled = oppo.commands.last!
        oppo.client.cancelOppo(); reply.requestID = canceled.requestID; oppo.receive(reply)
        check(!oppo.client.oppoBusy && oppo.client.oppoReport == nil && oppo.commands.last!.kind == "oppoCancel", "cancel invalidates late control replies")
        oppo.client.queryOppo(); let retried = oppo.commands.last!
        reply.kind = "oppoFailed"; reply.requestID = retried.requestID; reply.message = "timeout"
        oppo.receive(reply)
        check(!oppo.client.oppoBusy && oppo.client.oppoReport == nil && oppo.client.oppoMessage == "timeout", "failure leaves query retryable with unknown state")
        do {
            let h = try Harness(settleHiRes: false); defer { h.cleanup() }
            h.client.watchHeadset() // Records demand while the compact read is in flight.
            var reply = WireMessage("oppoResult", requestID: h.commands.last!.requestID, sessionID: h.id)
            reply.device = h.device; reply.oppoReport = liveReport; h.receive(reply)
            check(h.commands.last!.kind == "oppoQuery" && h.commands.last!.details?["source"] == "audio-resume",
                  "automatic baseline already includes listen, without another request")
            h.client.queryOppo(); reply.requestID = h.commands.last!.requestID; h.receive(reply)
            check(h.commands.last!.kind == "headsetListen" && !h.commands.contains { $0.kind == "headsetRefresh" },
                  "ordinary compact success restores listen only, never immediate full refresh")
            var ready = WireMessage("headsetResult", requestID: h.commands.last!.requestID, sessionID: h.id)
            ready.device = h.device; ready.headset = h.client.headset; ready.controlGeneration = ready.headset!.generation
            h.receive(ready)
            check(h.client.canSetOppoHiRes, "listen completion preserves HiRes switch")
            var lost = WireMessage("headsetConnection", sessionID: h.id)
            lost.device = h.device; lost.headset = h.client.headset; lost.headset!.markStale()
            lost.controlGeneration = lost.headset!.generation
            h.receive(lost)
            check(!h.client.canSetOppoHiRes && h.client.oppoReport == nil, "connection failure invalidates report without requiring a settings watch reply")
            let count = h.commands.count; h.client.setOppoHiRes(true)
            check(h.commands.count == count, "stale report cannot submit HiRes write")
            var fresh = ready; fresh.kind = "headsetConnection"; fresh.headset!.generation = UUID()
            fresh.controlGeneration = fresh.headset!.generation; h.receive(fresh)
            h.receive(lost)
            check(h.client.headset?.generation == fresh.controlGeneration, "late retired connection event cannot retire the new connection")
        }
        let hires = try Harness(); defer { hires.cleanup() }
        hires.client.queryOppo()
        var state = WireMessage("oppoResult", requestID: hires.commands.last!.requestID)
        state.device = hires.device; state.oppoReport = liveReport; hires.receive(state)
        hires.client.setOppoHiRes(true)
        var confirmed = liveReport
        var write = OppoHiResTransaction()
        let request = try write.begin(after: .init(command: 0x810d, sequence: 0xf2, payload: [0,1,0x18,0]))
        try write.markWriteAttempt(request); write.recordWriteSubmission(0)
        _ = write.receive(try .init(command: 0x8403, sequence: 0xf4, payload: [0]))
        _ = write.receive(try .init(command: 0x810d, sequence: 0xf5, payload: [0,1,0x18,1]))
        confirmed.experiment = write.report; confirmed.hiRes = true
        state.requestID = hires.commands.last!.requestID; state.oppoReport = confirmed
        hires.receive(state)
        check(hires.commands.last!.kind == "stop" && hires.commands.last!.stopIntent == nil && hires.client.hasPendingStart, "HiRes change keeps ordinary restoration before refreshing capabilities")
        hires.end()
        check(hires.scheduled.count == 1 && !hires.commands.contains { $0.kind == "probe" }, "HiRes waits after teardown before probing")
        hires.advance()
        check(hires.commands.last!.kind == "probe" && hires.client.oppoReport == nil, "HiRes refresh opens only a fresh capability query and invalidates old connection state")
        var refreshed = WireMessage("stopped", sessionID: hires.id)
        refreshed.details = ["probeComplete":"true"]
        refreshed.capabilities = [try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])]
        hires.client.setGain(0.6)
        hires.receive(refreshed)
        check(hires.scheduled.count == 1, "successful refresh allows native connection to settle before playback")
        hires.advance()
        check(hires.client.busy && hires.commands.filter { $0.kind == "start" }.count == 2 && hires.commands.last!.gain == 0.6, "confirmed HiRes refresh resumes once using latest volume and supported parameters")
        let resumedID = hires.id
        hires.receive(refreshed)
        check(hires.id == resumedID && hires.commands.filter { $0.kind == "start" }.count == 2, "late capability completion cannot start a second playback")
        hires.end("failed", message: "fixture resume failure")
        check(hires.commands.filter { $0.kind == "start" }.count == 2, "HiRes recovery failure never loops")
        for outcome in ["cancel-before-probe", "cancel-probe", "quit", "failed", "missing-capability"] {
            let h = try Harness(); defer { h.cleanup() }
            h.client.queryOppo()
            var report = WireMessage("oppoResult", requestID: h.commands.last!.requestID)
            report.device = h.device; report.oppoReport = liveReport; h.receive(report)
            h.client.setOppoHiRes(true)
            report.requestID = h.commands.last!.requestID; report.oppoReport = confirmed; h.receive(report)
            if outcome == "cancel-before-probe" { h.client.stop(); h.end() }
            else {
                h.end(); h.advance()
                if outcome == "cancel-probe" { h.client.stop() }
                if outcome == "quit" { h.client.quit() }
                var done = WireMessage(outcome == "failed" ? "failed" : "stopped", sessionID: h.id)
                done.details = ["probeComplete":"true"]
                done.capabilities = outcome == "missing-capability" ? [] : refreshed.capabilities
                h.receive(done)
            }
            check(h.commands.filter { $0.kind == "start" }.count == 1, "HiRes continuation revoked for \(outcome)")
        }
        func switched() throws -> Harness {
            let h = try Harness()
            h.client.queryOppo()
            var reply = WireMessage("oppoResult", requestID: h.commands.last!.requestID)
            reply.device = h.device; reply.oppoReport = liveReport; h.receive(reply)
            h.client.setOppoHiRes(true)
            reply.requestID = h.commands.last!.requestID; reply.oppoReport = confirmed; h.receive(reply)
            h.end()
            return h
        }
        func temporaryFailure(_ h: Harness, safe: Bool? = true, code: PlaybackFailureCode = .signalingUnavailable) {
            var early = WireMessage("error", sessionID: h.id); early.message = "fixture signal not ready"
            h.receive(early)
            check(!h.client.showsReconnectAdvice, "early session errors do not advise manual intervention before cleanup and retry decisions")
            var terminal = WireMessage("failed", sessionID: h.id)
            terminal.playbackFailure = code; terminal.restartSafe = safe
            terminal.message = early.message; h.receive(terminal)
        }
        let retry = try switched(); defer { retry.cleanup() }
        retry.advance(); let firstProbe = retry.id
        temporaryFailure(retry)
        check(retry.client.busy && retry.scheduled.count == 1, "transient probe failure waits after confirmed cleanup")
        check(!retry.client.showsReconnectAdvice && retry.client.error == nil, "retry wait hides manual advice and clears the recovered attempt's error")
        retry.advance()
        check(retry.id != firstProbe && retry.commands.filter { $0.kind == "probe" }.count == 2, "probe retry has a fresh session ID")
        var done = refreshed; done.sessionID = firstProbe; retry.receive(done)
        check(retry.scheduled.isEmpty, "late old probe cannot advance recovery")
        done.sessionID = retry.id; retry.receive(done); retry.client.setGain(0.8); retry.advance()
        check(retry.commands.last!.kind == "start" && retry.commands.last!.gain == 0.8, "delayed resume uses latest gain")
        temporaryFailure(retry, code: .deviceNotReady); retry.advance()
        temporaryFailure(retry)
        check(retry.scheduled.isEmpty && !retry.client.busy, "two retries shared across probe and resume; third failure stops")
        check(retry.client.showsReconnectAdvice, "exhausted retries display the final failure advice")
        check(retry.commands.filter { $0.kind == "oppoSetHiRes" }.count == 1, "recovery never rewrites HiRes")
        for safe in [false, nil] as [Bool?] {
            let h = try switched(); defer { h.cleanup() }; h.advance(); temporaryFailure(h, safe: safe)
            check(h.scheduled.isEmpty && !h.client.busy, "missing or failed cleanup confirmation prevents recovery")
            check(h.client.showsReconnectAdvice, "unsafe final failure requires user intervention")
        }
        for cancel in ["stop", "system", "quit", "sleep"] {
            let h = try switched(); defer { h.cleanup() }
            switch cancel {
            case "stop": h.client.stop()
            case "system": h.client.chooseCodec("system")
            case "quit": h.client.quit()
            default: h.receive(WireMessage("systemSleep"))
            }
            h.advance()
            check(!h.commands.contains { $0.kind == "probe" }, "\(cancel) invalidates delayed work")
            check(!h.client.busy, "\(cancel) releases wait-state UI")
        }
        let expired = try switched(); defer { expired.cleanup() }
        expired.clock += 91; expired.advance()
        check(!expired.commands.contains { $0.kind == "probe" } && !expired.client.busy, "sleeping scheduler cannot start after 90-second recovery window")
        check(expired.client.showsReconnectAdvice, "expired automatic recovery is a final failure")
        for safe in [true, false] {
            let h = try Harness(); defer { h.cleanup() }
            temporaryFailure(h, safe: safe, code: .audioHostUnavailable)
            if safe {
                check(h.scheduled.count == 1 && !h.client.showsReconnectAdvice, "audio-host publication failure retries only after safe cleanup")
                h.advance(); check(!h.client.showsReconnectAdvice, "advice stays hidden while reconnecting")
                h.activate(); check(h.client.error == nil && !h.client.showsReconnectAdvice, "successful recovery clears stale failure advice")
            } else { check(h.scheduled.isEmpty && h.client.showsReconnectAdvice, "audio-host error cannot bypass cleanup gates") }
        }
        let canceledAdvice = try Harness(); defer { canceledAdvice.cleanup() }
        temporaryFailure(canceledAdvice); canceledAdvice.client.stop(); canceledAdvice.advance()
        check(!canceledAdvice.client.showsReconnectAdvice, "user cancellation is not a query or playback failure")
        check(EngineClient.reconnectAdvice == "请尝试重新检测并连接，若依旧失败则尝试重启应用并重新连接耳机蓝牙", "manual advice matches requested text")
        print("APP_HIRES_SETTLEMENT PASS: delays, typed retries, total retry budget, cleanup gates, deadline, cancellation, stale sessions and no repeated writes.")
        print("APP_OPPO_CONTROL PASS: scoped writes, readback, one supported continuation, latest gain, cancellation/failure and stale-response filtering.")
        }
        do {
            func answerControl(_ h: Harness, codec: UInt8?, hiRes: Bool? = nil) throws {
                let query = h.commands.last(where: { $0.kind == "oppoQuery" })!
                var reply = WireMessage("oppoResult", requestID: query.requestID)
                reply.device = h.device
                var report = OppoProbeReport(); report.currentCodecID = codec; report.hiRes = hiRes
                report.controlCapabilities = try .init(reply: .init(command: 0x8100, payload: [0,0x80]))
                reply.oppoReport = report
                h.receive(reply)
            }
            func finishProbe(_ h: Harness, caps: [CodecCapabilities]) {
                var done = WireMessage("stopped", sessionID: h.id)
                done.details = ["probeComplete":"true"]; done.capabilities = caps
                h.receive(done)
            }
            let h = try Harness(); defer { h.cleanup() }; h.end()
            check(h.client.transportChoice == "system" && h.client.showsHDSettings && !h.client.showsLiveFormat, "idle presents editable targets without claiming a live HD format")
            check(!h.client.systemCodecLabel.contains("AAC"), "unknown system codec must not default to AAC")
            h.client.chooseCodec("system")
            check(h.client.oppoBusy && h.client.systemCodecLabel.contains("识别"), "current native codec is queried")
            try answerControl(h, codec: 2)
            check(h.client.systemCodecLabel == "AAC · 系统", "native AAC comes from correlated device reply")
            h.client.rate = 192000; h.client.fixedBitrate = 1000; h.client.quality = .connection
            var audio = WireMessage("audioState")
            audio.audioState = .init(nativeOutput: .init(sampleRate: 44100, availableRates: [44100], volumeWritable: true), virtualOutput: nil, defaultIsVirtual: false)
            h.receive(audio)
            let fresh = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x16,0x11,0x40,0])
            h.client.capabilities = [fresh]
            h.client.chooseCodec(CodecID.lhdcV5.rawValue)
            check(h.commands.last!.kind == "start" && h.client.showsHDSettings && !h.client.showsLiveFormat, "codec choice uses the playback handshake without a separate probe/reconnect")
            check(!h.commands.contains { $0.kind == "probe" }, "activation must never insert the failing probe-to-playback transition")
            let started = h.commands.last!
            check(started.configuration!.sampleRate == .hz44100, "initial rate uses measured system format within detected capability intersection")
            check(started.configuration!.maximumBitrate == 400 && !started.configuration!.isForced && started.configuration!.fixedBitrateKbps == nil, "old forced 192k/1000k values cannot become initial selections")
            var partial = WireMessage("capabilities", sessionID: h.id); partial.capabilities = []
            h.receive(partial)
            check(h.client.codecChoices == [.lhdcV5], "in-flight choice survives partial endpoint replies without adding LDAC")
            partial.capabilities = [fresh]; h.receive(partial)
            h.activate()
            check(h.client.showsHDSettings && h.client.rate == 44100 && h.client.oppoBusy && h.client.oppoReport?.hiRes == nil, "negotiated fields shown; HiRes automatically queried and initially unknown")
            try answerControl(h, codec: 8, hiRes: false)
            check(h.client.oppoReport?.hiRes == false && h.client.canSetOppoHiRes, "HiRes starts from actual off readback")
            h.client.chooseCodec("system")
            check(h.commands.last!.kind == "stop" && h.client.showsHDSettings && !h.client.showsLiveFormat, "system codec choice stops HD and keeps target settings")
            h.end()
            check(h.client.nativeCodecID == nil && h.client.oppoBusy, "stopped HD codec is not reused as native codec")
            try answerControl(h, codec: 2)
            check(h.client.systemCodecLabel == "AAC · 系统" && h.commands.filter { $0.kind == "start" }.count == 2, "return to AAC doesn't autoplay")
            for failure in ["cancel", "failed", "error"] {
                let h = try Harness(); defer { h.cleanup() }; h.end()
                h.client.chooseCodec(CodecID.lhdcV5.rawValue)
                if failure == "cancel" { h.client.chooseCodec("system") }
                if failure == "error" { h.receive(WireMessage("error", sessionID: h.id)) }
                h.end(failure == "failed" ? "failed" : "stopped", message: failure == "failed" ? "offline failure" : nil)
                check(h.commands.filter { $0.kind == "start" }.count == 2 && h.client.transportChoice == "system", "no implicit retry after \(failure)")
            }
            let filtered = try Harness(); defer { filtered.cleanup() }; filtered.end()
            check(filtered.client.availableHDCodecs == [.lhdcV5], "LHDC-only AVDTP endpoints exclude LDAC")
            let beforeUnsupported = filtered.commands.count
            filtered.client.chooseCodec(CodecID.ldac.rawValue)
            check(filtered.commands.count == beforeUnsupported && filtered.client.transportChoice == "system", "unavailable codec rejected by model, not merely hidden")
            filtered.client.capabilities.append(fresh)
            check(filtered.client.codecChoices == [.lhdcV5], "duplicate endpoints do not duplicate codecs")
            filtered.client.capabilities = [try CapabilityParser.codec(endpoint: 1, bytes: [0,0,0x3f,0xff,2,0x27])]
            check(filtered.client.codecChoices.isEmpty, "SBC is native only; unknown HD support is not invented")
            filtered.client.capabilities = [try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x30,1,1,0,0])]
            check(filtered.client.codecChoices.isEmpty, "unsupported LHDC frame/bit-depth capabilities are not playable choices")

            let cancelQuery = try Harness(); defer { cancelQuery.cleanup() }; cancelQuery.end()
            let ldac = try CapabilityParser.codec(endpoint: 1, bytes: [0,255,0x2d,1,0,0,0xaa,0,0x3c,7])
            cancelQuery.client.capabilities = [ldac]
            cancelQuery.client.chooseCodec("system")
            let oldQuery = cancelQuery.commands.last!
            cancelQuery.client.chooseCodec(CodecID.ldac.rawValue)
            check(cancelQuery.commands.last!.kind == "oppoCancel" && !cancelQuery.client.canChooseHDCodec, "HD selection waits for control-channel cancellation")
            var oldReply = WireMessage("oppoResult", requestID: UUID()); oldReply.device = cancelQuery.device
            var oldReport = OppoProbeReport(); oldReport.currentCodecID = 2; oldReply.oppoReport = oldReport
            cancelQuery.receive(oldReply)
            check(cancelQuery.commands.last!.kind == "oppoCancel", "unrelated reply cannot release the pending activation")
            oldReply.requestID = oldQuery.requestID; cancelQuery.receive(oldReply)
            check(cancelQuery.commands.last!.kind == "start" && cancelQuery.commands.last!.configuration?.codec == .ldac, "LDAC starts after matching control completion")
            check(cancelQuery.client.oppoReport == nil, "canceled native read cannot populate a new HD connection")

            let cancelPending = try Harness(); defer { cancelPending.cleanup() }; cancelPending.end()
            cancelPending.client.chooseCodec("system")
            let queryID = cancelPending.commands.last!.requestID
            cancelPending.client.chooseCodec(CodecID.lhdcV5.rawValue)
            cancelPending.client.chooseCodec("system")
            var canceled = WireMessage("oppoFailed", requestID: queryID); canceled.device = cancelPending.device
            cancelPending.receive(canceled)
            check(cancelPending.commands.filter { $0.kind == "start" }.count == 1, "return to system cancels activation while control channel is closing")
            print("APP_CODEC_SELECTION PASS: measured native codec, one-connection activation, capability-filtered choices, negotiated initial values, automatic HiRes query, return to system, cancellation and failures.")
        }
        do {
            let h = try Harness(); defer { h.cleanup() }; h.end()
            let full = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])
            h.client.capabilities = [full]; h.client.selectedCapability = full.id
            h.client.chooseCodec(CodecID.lhdcV5.rawValue); h.activate(); h.client.cancelOppo()
            h.client.rate = 96000; h.client.quality = .connection; h.client.fixedBitrate = 900
            h.client.parametersChanged(); h.client.applySettings()
            let stoppingID = h.id
            h.end()
            check(h.commands.last!.kind == "start" && h.id != stoppingID, "parameter change schedules one reconnect")
            check(h.commands.last!.configuration?.sampleRate == .hz96000 && h.commands.last!.configuration?.fixedBitrateKbps == 900, "automatic reconnect contains intended settings")
            h.end("failed", message: "simulated disconnect failed")
            h.client.cancelOppo()
            h.client.chooseCodec(CodecID.lhdcV5.rawValue)
            check(h.commands.last!.kind == "start" && h.commands.last!.configuration?.sampleRate == .hz96000 && h.commands.last!.configuration?.fixedBitrateKbps == 900, "manual retry must retain explicit sample rate and fixed bitrate after failure")
            // The desired value, not the last successful negotiated value, must
            // survive an application relaunch and remain scoped to this device.
            var restoredCommands: [WireMessage] = []
            let restored = EngineClient(previewMode: false, preferences: h.prefs) { restoredCommands.append($0) }
            restored.devices = [h.device, h.other]; restored.selectedAddress = h.device.address; restored.deviceChanged()
            restored.chooseCodec(CodecID.lhdcV5.rawValue)
            check(restoredCommands.last!.configuration?.sampleRate == .hz96000 && restoredCommands.last!.configuration?.fixedBitrateKbps == 900, "explicit desired configuration survives app relaunch")
            var ended = WireMessage("failed", sessionID: restoredCommands.last!.sessionID); ended.message = "fixture"
            restored.receive(ended); restored.cancelOppo()
            let reduced = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x16,0x11,0x40,0])
            restored.capabilities = [reduced]
            let starts = restoredCommands.filter { $0.kind == "start" }.count
            restored.chooseCodec(CodecID.lhdcV5.rawValue)
            check(restoredCommands.filter { $0.kind == "start" }.count == starts + 1 && restored.initialSettingsSource.contains("超出范围"), "fresh capability shrink automatically repairs unsupported saved settings with an explanation")
            check(restoredCommands.last!.kind == "start" && restoredCommands.last!.configuration?.sampleRate == .hz48000 && restoredCommands.last!.configuration?.quality == .adaptive, "repaired capability preference connects without another manual detection")
            ended.sessionID = restoredCommands.last!.sessionID; restored.receive(ended); restored.cancelOppo()
            restored.selectedAddress = h.other.address; restored.deviceChanged()
            restored.capabilities = [full]; restored.selectedCapability = full.id; restored.probeComplete = true
            restored.chooseCodec(CodecID.lhdcV5.rawValue)
            check(restoredCommands.last!.configuration?.sampleRate == .hz48000 && restoredCommands.last!.configuration?.fixedBitrateKbps == nil, "another headset does not inherit requested settings")
            let family = try Harness(); defer { family.cleanup() }
            family.client.capabilities = [full]; family.client.selectedCapability = full.id
            family.client.fixedBitrate = 500; family.client.quality = .connection; family.client.rate = 44100
            family.client.parametersChanged(); family.client.applySettings(); family.end()
            check(family.commands.last!.configuration?.sampleRate == .hz44100 && family.commands.last!.configuration?.fixedBitrateKbps == 480, "sample-rate edit preserves LHDC quality index instead of resetting bitrate")
            print("APP_RECONNECT_INTENT PASS: failed retry, persistence, device isolation and explicit fallback after capability shrink.")
        }
        do {
            let full = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])
            func mtuFailure(_ h: Harness, safe: Bool?) {
                var terminal = WireMessage("failed", sessionID: h.id)
                terminal.playbackFailure = .mediaMTU; terminal.restartSafe = safe
                terminal.message = "required=696 actual=679"; h.receive(terminal)
            }
            for safe in [true, false, nil] as [Bool?] {
                let h = try Harness(); defer { h.cleanup() }
                h.client.capabilities = [full]; h.client.selectedCapability = full.id
                h.client.rate = 44100; h.client.fixedBitrate = 1000; h.client.quality = .connection
                h.client.parametersChanged(); h.client.applySettings(); h.end()
                mtuFailure(h, safe: safe)
                check(h.client.rate == 48000 && h.client.quality == .adaptive && h.client.fixedBitrate == 0, "MTU failure resets rejected values even if cleanup unsafe")
                check(h.client.showsHDSettings && !h.client.showsLiveFormat, "MTU failure retains parameter editor without live format")
                if safe == true {
                    check(h.scheduled.count == 1, "MTU fallback waits until after cleanup")
                    h.client.setGain(0.65); h.advance()
                    let fallback = h.commands.last!
                    check(fallback.configuration?.sampleRate == .hz48000 && fallback.configuration?.quality == .adaptive && fallback.configuration?.fixedBitrateKbps == nil && fallback.gain == 0.65, "safe defaults and current gain sent on fallback")
                    check(fallback.configuration?.isForced == false, "fallback never forces parameters")
                    mtuFailure(h, safe: true)
                    check(h.scheduled.isEmpty && !h.client.busy, "fallback failure cannot loop")
                } else { check(h.scheduled.isEmpty && !h.client.busy, "uncertain cleanup leaves default targets editable without automatic playback") }
                var persistedCommands: [WireMessage] = []
                let persisted = EngineClient(previewMode: false, preferences: h.prefs, messageSink: { persistedCommands.append($0) })
                persisted.devices = [h.device]; persisted.selectedAddress = h.device.address; persisted.deviceChanged()
                persisted.chooseCodec(CodecID.lhdcV5.rawValue)
                check(persistedCommands.last!.configuration?.sampleRate == .hz48000 && persistedCommands.last!.configuration?.quality == .adaptive && persistedCommands.last!.configuration?.fixedBitrateKbps == nil, "relaunch cannot resurrect rejected MTU settings")
                h.client.cancelOppo()
                h.client.rate = 96000; h.client.quality = .connection; h.client.fixedBitrate = 400
                h.client.parametersChanged()
                let starts = h.commands.filter { $0.kind == "start" }.count
                check(h.client.canEditSettings && !h.client.active, "inactive parameter edits are available")
                var commands: [WireMessage] = []
                let restored = EngineClient(previewMode: false, preferences: h.prefs, messageSink: { commands.append($0) })
                restored.devices = [h.device]; restored.selectedAddress = h.device.address; restored.deviceChanged()
                restored.chooseCodec(CodecID.lhdcV5.rawValue)
                check(commands.last!.configuration?.sampleRate == .hz96000 && commands.last!.configuration?.fixedBitrateKbps == 400, "inactive edits persist and take effect on next enable")
                check(h.commands.filter { $0.kind == "start" }.count == starts, "inactive edits never autoplay")
            }
            let h = try Harness(); defer { h.cleanup() }
            h.client.capabilities = [full]; h.client.selectedCapability = full.id
            h.client.rate = 44100; h.client.fixedBitrate = 1000; h.client.quality = .connection
            h.client.parametersChanged(); h.client.applySettings(); h.end()
            var wrong = WireMessage("failed", sessionID: UUID()); wrong.playbackFailure = .mediaMTU; wrong.restartSafe = true
            h.receive(wrong)
            check(h.client.fixedBitrate == 1000 && h.scheduled.isEmpty, "old session's MTU failure cannot reset current parameters")
            h.client.stop(); mtuFailure(h, safe: true)
            check(h.scheduled.isEmpty, "explicit stop cancels MTU auto-recovery")
            print("APP_MTU_FALLBACK PASS: defaults, one attempt, safe cleanup, no forced values, stale isolation, cancellation and editable persistent offline targets.")
        }
        do {
            let h = try Harness(); defer { h.cleanup() }
            // Audio resume already owns a watch; an actual disconnection is
            // required to establish a separate one on the next menu opening.
            h.client.headset?.markStale()
            h.client.cancelOppo(); h.client.watchHeadset()
            let watch = h.commands.last!
            check(watch.kind == "headsetWatch", "headset independent watch request")
            var state = HeadsetSnapshot(address: h.device.address); state.connected = true
            state.battery[3] = .init(.init(percent: 37, charging: false))
            var update = WireMessage("headsetResult", requestID: watch.requestID)
            update.device = h.device; update.headset = state; update.controlGeneration = state.generation
            h.receive(update)
            check(h.client.headset?.battery[3]?.value.percent == 37 && !h.client.headsetBusy, "correlated snapshot")
            var newer = state; newer.generation = UUID(); newer.battery[3] = .init(.init(percent: 36, charging: false))
            update.kind = "headsetSnapshot"; update.headset = newer; update.controlGeneration = newer.generation
            h.receive(update)
            update.headset = state; update.controlGeneration = state.generation; h.receive(update)
            check(h.client.headset?.generation == newer.generation, "retired control generation ignored")
            update.headset = newer; update.device = h.other; h.receive(update)
            check(h.client.headset?.address == h.device.address, "other device reply ignored")
            var offline = newer; offline.markStale(); update.device = h.device; update.headset = offline
            h.receive(update)
            check(h.client.headset?.battery[3]?.value.percent == 36 && h.client.headset?.battery[3]?.stale == true, "offline history retains value")
            check(!h.client.canControlHeadset && !h.client.wearAutomation, "offline writes blocked and wear defaults off")
            print("APP_HEADSET PASS: watch IDs, generations, device isolation, offline cache, writes and wear defaults.")
        }
        do {
            let off = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x16,0x11,0x40,0])
            let on = try CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x35,0x06,0x11,0x40,0])
            for interruptedBeforeReply in [false, true] {
                for safe in [true, false] {
                  for controlClosed in [false, true] {
                    let h = try Harness(); defer { h.cleanup() }
                    h.client.queryOppo()
                    var report = OppoProbeReport(); report.currentCodecID = 8; report.hiRes = false
                    report.controlCapabilities = try .init(reply: .init(command: 0x8100, payload: [0,0x80]))
                    var reply = WireMessage("oppoResult", requestID: h.commands.last!.requestID)
                    reply.device = h.device; reply.oppoReport = report; h.receive(reply)
                    h.client.setOppoHiRes(true)
                    reply.requestID = h.commands.last!.requestID; reply.sessionID = h.id
                    reply.controlGeneration = h.commands.last!.controlGeneration
                    if interruptedBeforeReply {
                        var stopping = WireMessage("stopping", sessionID: h.id); stopping.message = "profile restarting"
                        h.receive(stopping)
                    }
                    var experiment = OppoHiResExperimentReport()
                    experiment.requestedHiRes = true; experiment.writeAttempts = 1; experiment.writeSubmissionStatus = 0
                    experiment.acknowledgementCode = 0; experiment.readbackCandidate = 1
                    report.hiRes = true; report.experiment = experiment; reply.oppoReport = report
                    if controlClosed {
                        var state = h.client.headset!; state.markStale(); reply.headset = state
                        var closed = WireMessage("headsetConnection", sessionID: h.id)
                        closed.device = h.device; closed.headset = state; closed.controlGeneration = state.generation
                        h.receive(closed)
                    }
                    h.receive(reply)
                    if controlClosed { check(!h.client.canSetOppoHiRes, "completed transaction never makes a disconnected control switch writable") }
                    var terminal = WireMessage("failed", sessionID: h.id)
                    terminal.message = "intermediate priority cleanup observation"; terminal.restartSafe = safe
                    h.receive(terminal)
                    check(h.scheduled.count == (safe ? 1 : 0), "confirmed HiRes continues after final safe cleanup, regardless of earlier stopping/error order")
                    if safe {
                        h.advance(); check(h.commands.last!.kind == "probe", "profile restart automatically refreshes capabilities")
                    }
                    check(h.commands.filter { $0.kind == "oppoSetHiRes" }.count == 1, "profile recovery never repeats the write")
                  }
                }
            }
            let changed = try Harness(); defer { changed.cleanup() }
            changed.client.quality = .connection; changed.client.fixedBitrate = 400; changed.client.parametersChanged(); changed.client.applySettings(); changed.end()
            var mismatch = WireMessage("failed", sessionID: changed.id)
            mismatch.playbackFailure = .capabilitiesChanged; mismatch.restartSafe = true; mismatch.capabilities = [off]
            changed.receive(mismatch); changed.advance()
            let repaired = changed.commands.last!.configuration!
            check(repaired.maximumBitrate == 400 && repaired.fixedBitrateKbps == 400 && !repaired.isForced,
                  "fresh advertised range replaces stale 1000 ceiling while retaining supported 400 target")
            mismatch.sessionID = changed.id; changed.receive(mismatch)
            check(changed.scheduled.isEmpty, "capability correction retries only once")
            let bounded = try Harness(); defer { bounded.cleanup() }; bounded.client.probe(); bounded.end()
            for attempt in 0...2 {
                var failure = WireMessage("failed", sessionID: bounded.id)
                failure.playbackFailure = .signalingUnavailable; failure.restartSafe = true; bounded.receive(failure)
                if attempt < 2 { check(bounded.scheduled.count == 1, "manual detection includes bounded transient retries"); bounded.advance() }
            }
            check(bounded.scheduled.isEmpty && !bounded.client.busy, "detection stops after two safe retries")
            let x4 = try Harness(); defer { x4.cleanup() }; x4.end()
            var snapshot = HeadsetSnapshot(address: x4.device.address); snapshot.productID = 0x06ec10
            x4.client.headset = snapshot; x4.client.capabilities = [off]; x4.client.selectedCapability = off.id
            check(x4.client.availableRates == [44100,48000] && x4.client.bitrates.allSatisfy { $0 <= 400 }, "identified X4 hides nonadvertised rates and bitrates even with stale HiRes state")
            check(x4.client.transportSettingsTitle == "LHDC V5 传输设置" && x4.client.transportSettingsNotice == "选择 LHDC V5 编码后生效", "inactive codec title and prominent notice are codec specific")
            x4.client.rate = 96000; x4.client.fixedBitrate = 1000; x4.client.quality = .connection
            check(x4.client.configuration == nil, "hidden X4 targets cannot bypass configuration validation")
            x4.client.parametersChanged(); check(x4.client.rate == 0 && x4.client.fixedBitrate == 0, "invalid hidden draft resets to supported choices")
            x4.client.capabilities = [on]
            check(x4.client.availableRates.contains(192000) && x4.client.bitrates.contains(1000), "X4 HiRes advertised high settings stay available")
            x4.client.headset = nil; x4.client.capabilities = [off]
            check(x4.client.availableRates.contains(192000) && x4.client.bitrates.contains(1000), "generic forced parameter implementation is retained for other devices")
            let ldac = try CapabilityParser.codec(endpoint: 1, bytes: [0,255,0x2d,1,0,0,0xaa,0,0x3c,7])
            x4.client.capabilities = [ldac]; x4.client.selectedCapability = ldac.id
            check(x4.client.transportSettingsTitle == "LDAC 传输设置" && x4.client.transportSettingsNotice == "选择 LDAC 编码后生效", "LDAC inactive title uses its own codec")
            print("APP_PROFILE_RECOVERY PASS: real trace replay, early link loss, safe terminal gate, stale capability repair, bounded detection retries and X4 option policy.")
        }
        print("APP_SETTINGS PASS: explicit transport application, immediate/coalesced buffering, strict ACKs, ordered reconnection, cancellation, device/volume ownership, and mode defaults.")
    }
}
