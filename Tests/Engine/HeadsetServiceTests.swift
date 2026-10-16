import Foundation
import SonoFerryCore

final class SimulatedHeadset: HeadsetTransport {
    var opened: (() -> Void)?
    var packet: ((OppoControlPacket) -> Void)?
    var closed: ((String) -> Void)?
    var progress: (String) -> Void = { _ in }
    var trace: (String, String) -> Void = { _, _ in }
    var sent: [OppoControlPacket] = []
    var productID: UInt32 = 0x06ec10
    var serviceUUID = HeadsetDialect.elnk079A.rawValue
    var features: [UInt8: UInt8] = [4: 1,17: 0,11: 0,12: 0,24: 1]
    var earState: UInt8 = 3
    var syncBeforeReply: ((OppoControlPacket) -> OppoControlPacket?)?
    var noiseMode: UInt8 = 3
    var noiseType: UInt8 = 1
    var adaptiveReadback: UInt8?
    var supportReply: [UInt8] = [0,3,1,248,113]
    var goldenReply: [UInt8] = [0,1,1,1,2,3,0,0,0,1]
    var keys: [HeadsetKey] = [.init(ear: 1, action: 2, function: 6), .init(ear: 2, action: 2, function: 5)]
    var soundPreset: UInt8 = 0
    var curves: [HeadsetEQ] = []
    var bass: [UInt8] = [251,5,0]
    var leaveCustomSelected = false
    var dropOtherCurve = false
    var dropAfterWrite = false
    var loseACK = false
    var rejectWrite = false
    var mismatchReadback = false
    var wrongSequenceFirst = false
    var shutdownCount = 0
    var shutdownCompleted = 0
    var startCount = 0
    var shutdownDelay: UInt64 = 0
    var failShutdown = false
    var isOpen = false
    var silence = false
    var suppressOpen = false
    var suppressCloseCallback = false
    var dropCommands: Set<UInt16> = []
    var responseDelay: TimeInterval = 0
    var eqReplyOverride: [UInt8]?
    var capabilities: [UInt8] = [0,0x9b,1,2,0,0,0]
    func start(address: String) { startCount += 1; isOpen = true; if !suppressOpen { opened?() } }
    func send(_ request: OppoControlPacket) throws {
        guard isOpen else { throw ProtocolFailure("closed") }; sent.append(request)
        if silence || dropCommands.contains(request.command) { return }
        var payload: [UInt8]
        switch request.command {
        case 0x0100: payload = capabilities
        case 0x0101: payload = [0,0,18]
        case 0x0102: payload = [0,0x9a,7]
        case 0x0104: payload = [0,1]
        case 0x0103: payload = [0,UInt8(productID & 255),UInt8((productID >> 8) & 255),UInt8((productID >> 16) & 255)]
        case 0x0200: payload = [0,3,1,2,3]
        case 0x0205: payload = [0,3,1,0,2,0,3,0]
        case 0x0114: payload = [0,8]
        case 0x0105: payload = [0,1] + Array("1,2,116".utf8)
        case 0x0106: payload = [0,3,1,90,2,80,3,60]
        case 0x0108: payload = [0,UInt8(keys.count)] + keys.flatMap(\.bytes)
        case 0x0109: payload = [0,2,1,earState,2,earState]
        case 0x010c:
            let bits = UInt32(1) << noiseMode
            payload = request.payload[0] == 4 ? [0,4,1,32] : request.payload[0] == 1 ? [0,1,noiseType,UInt8(bits & 255),UInt8((bits >> 8) & 255)] : supportReply
        case 0x0115: payload = goldenReply
        case 0x0404:
            if !rejectWrite && !mismatchReadback {
                let bits = request.payload.dropFirst(2).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                noiseMode = UInt8(bits.trailingZeroBitCount); noiseType = request.payload[1]
                if noiseMode == 11, let adaptiveReadback { noiseMode = adaptiveReadback }
            }
            if dropAfterWrite { close("simulated disconnect"); return }
            if loseACK { return }; payload = [rejectWrite ? 1 : 0]
        case 0x0401:
            if !rejectWrite && !mismatchReadback {
                let key = HeadsetKey(ear: request.payload[1], button: request.payload[2], action: request.payload[3], function: request.payload[4])
                if let i = keys.firstIndex(where: { $0.id == key.id }) { keys[i] = key }
            }
            if dropAfterWrite { close("simulated disconnect"); return }
            if loseACK { return }; payload = [rejectWrite ? 1 : 0]
        case 0x010d: payload = [0,1,request.payload[1],features[request.payload[1]] ?? 0]
        case 0x010f: payload = [0,soundPreset]
        case 0x0122:
            payload = [0,UInt8(curves.count)]
            for curve in curves { payload += [curve.selected ? 1 : 0] + Array(try curve.settingPayload().dropFirst()) }
        case 0x0124: payload = [0] + bass
        case 0x0406:
            if !rejectWrite && !mismatchReadback {
                soundPreset = request.payload[0]
                if !leaveCustomSelected { for i in curves.indices { curves[i].selected = false } }
            }
            if dropAfterWrite { close("simulated disconnect"); return }
            if loseACK { return }; payload = [rejectWrite ? 1 : 0]
        case 0x0418:
            var responseID = request.payload[3]
            if !rejectWrite && !mismatchReadback {
                var parsed = HeadsetSnapshot(address: "fixture")
                try parsed.consume(.init(command: 0x8122, payload: [0,1,1] + Array(request.payload.dropFirst())), query: .equalizers)
                var curve = parsed.equalizers!.value[0]
                let action = request.payload[0]
                if action == 3 {
                    curves.removeAll { $0.id == curve.id }
                    if !curves.contains(where: \.selected) { soundPreset = 0 }
                } else {
                    if action == 1 { curve.id = (curves.map(\.id).max() ?? 30) + 1 }
                    else { curves.removeAll { $0.id == curve.id } }
                    for i in curves.indices { curves[i].selected = false }
                    curves.append(curve); soundPreset = curve.id
                }
                responseID = curve.id
                if dropOtherCurve && curves.count > 1 { curves.removeFirst() }
            }
            if dropAfterWrite { close("simulated disconnect"); return }
            if loseACK { return }; payload = eqReplyOverride ?? [rejectWrite ? 1 : 0, responseID]
        case 0x041b:
            if !rejectWrite && !mismatchReadback { bass = request.payload }
            if dropAfterWrite { close("simulated disconnect"); return }
            if loseACK { return }; payload = [rejectWrite ? 1 : 0]
        case 0x0403:
            if !rejectWrite && !mismatchReadback { features[request.payload[0]] = request.payload[1] }
            if dropAfterWrite { close("simulated disconnect"); return }
            if loseACK { return }
            payload = [rejectWrite ? 1 : 0]
        default: payload = [2]
        }
        if let sync = syncBeforeReply?(request) { packet?(sync) }
        if wrongSequenceFirst { packet?(try .init(command: request.command | 0x8000, sequence: request.sequence &+ 1, payload: payload)) }
        let reply = try OppoControlPacket(command: request.command | 0x8000, sequence: request.sequence, payload: payload)
        if responseDelay > 0 {
            let receiver = packet
            DispatchQueue.main.asyncAfter(deadline: .now() + responseDelay) { receiver?(reply) }
        } else { packet?(reply) }
    }
    func close(_ reason: String) { guard isOpen else { return }; isOpen = false; if !suppressCloseCallback { closed?(reason) } }
    @MainActor func shutdown() async throws {
        shutdownCount += 1
        if shutdownDelay > 0 { try await Task.sleep(nanoseconds: shutdownDelay) }
        if failShutdown { throw ProtocolFailure("simulated close failure") }
        close("suspended")
        shutdownCompleted += 1
    }
}
#if !CONTROL_COORDINATOR_TESTS
@main struct HeadsetServiceTests {
    @MainActor static func main() {
        Task { @MainActor in
            do { try await run(); print("Headset service integration: all checks passed"); exit(0) }
            catch { fputs("Headset service failure: \(error)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw ProtocolFailure(message) } }
    @MainActor static func runControls() async throws {
        let peer = SimulatedHeadset(); peer.capabilities[3] |= 8
        peer.noiseType = 5; peer.supportReply = [0,3,2,1]
        peer.keys += [HeadsetKey(ear: 1, button: 6, action: 1, function: 29), HeadsetKey(ear: 2, button: 6, action: 1, function: 29)]
        let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.03, makeConnection: { peer })
        let initial = try await service.refresh()
        try check(initial.usesNoiseProfile && initial.issues["noise.available"] != nil, "optional malformed support remains diagnostic, exact X4 fallback usable")
        for mode: UInt8 in [4,5,6,7,12,13,14,8,3] {
            let result = await service.set(.noise(mode), generation: initial.generation)
            try check(result.confirmed && service.snapshot.noise?.value == mode, "noise setting and type 5 readback")
            if mode == 7 {
                try check(service.snapshot.intelligentNoiseTitle == "智能切换：中度降噪", "smart mode reads independent actual depth")
                try check(peer.sent.contains { $0.command == 0x010c && $0.payload == [4,1] }, "exact APK intelligent query")
                peer.packet?(try .init(command: 0x0204, payload: [3,4,1,64]))
                try check(service.snapshot.intelligentNoiseTitle == "智能切换：轻度降噪" && service.snapshot.noise?.value == 7, "phone notification synchronizes actual depth without writing")
            }
        }
        try check(peer.sent.filter { $0.command == 0x0404 }.count == 9, "one write per requested mode")
        peer.adaptiveReadback = 14
        let enterAdaptive = await service.set(.noise(11), generation: initial.generation)
        try check(enterAdaptive.confirmed && service.snapshot.noise?.value == 14, "parent activation accepts earbud remembered child")
        try check(peer.sent.last { $0.command == 0x0404 }?.payload == [1,1,0,8], "phone manual adaptive activation bytes")
        try check(peer.sent.filter { $0.command == 0x0404 }.count == 10, "no extra child write after adaptive entry")
        let oldKeys = peer.keys
        let call = HeadsetKey(ear: 1, button: 6, action: 1, function: 0)
        let callResult = await service.set(.key(call), generation: initial.generation)
        try check(callResult.confirmed && peer.keys.filter { $0.id != call.id } == oldKeys.filter { $0.id != call.id }, "call delta preserves other ear and ordinary gestures")
        let before = peer.sent.count
        let golden = await service.set(.feature(.goldenSound, true), generation: initial.generation)
        try check(golden.confirmed, "saved golden result allows standalone feature 11")
        try check(Array(peer.sent.dropFirst(before).prefix(5).map(\.command)) == [0x010d,0x0115,0x0403,0x010d,0x0115], "golden fresh result check before single write and readback")
        peer.goldenReply = [0,1,0,0,0,0,0]
        let writes = peer.sent.filter { $0.command == 0x0403 }.count
        let missing = await service.set(.feature(.goldenSound, true), generation: initial.generation)
        try check(!missing.confirmed && peer.sent.filter { $0.command == 0x0403 }.count == writes, "missing golden result never writes")
        let off = await service.set(.feature(.goldenSound, false), generation: initial.generation)
        try check(off.confirmed, "disable does not require a saved result")
        // Start the failure scenarios with a fresh query budget after the exhaustive mode matrix.
        _ = try await service.refresh()
        peer.mismatchReadback = true
        let mismatch = await service.set(.noise(4), generation: service.snapshot.generation)
        try check(!mismatch.confirmed && service.snapshot.noise?.value == 14, "noise mismatch shows actual value")
        peer.mismatchReadback = false; peer.dropAfterWrite = true
        let dropped = await service.set(.noise(4), generation: service.snapshot.generation)
        try check(!dropped.confirmed && service.snapshot.noise?.stale == true, "noise disconnect leaves stale state and never replays")
        try check(peer.sent.filter { $0.command == 0x0404 }.count == 12, "mismatch/disconnect each sent once")
        try await service.suspend()
        print("HEADSET_CONTROLS PASS: profile fallback, all noise modes, call delta, golden prerequisite, mismatch and disconnect")
    }
    @MainActor static func runSound() async throws {
        func peer() -> SimulatedHeadset {
            let p = SimulatedHeadset(); p.capabilities[2] |= 4; p.capabilities[5] |= 0x44; p.features[29] = 0
            p.curves = [.init(id: 10, name: "Phone EQ", minimum: -6, maximum: 6, frequencies: [80,900,12000], gains: [0,1,2])]
            return p
        }
        let p = peer()
        let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.03, makeConnection: { p })
        let initial = try await service.refresh()
        // Selecting a slot must copy the phone's most recent curve, never the UI's old curve.
        p.curves[0].gains = [-6,0,6]
        let start = p.sent.count
        let selected = await service.set(.selectEqualizer(10), generation: initial.generation)
        try check(selected.confirmed && p.curves[0].gains == [-6,0,6], "select preserves latest phone edit")
        try check(Array(p.sent.dropFirst(start).prefix(5).map(\.command)) == [0x010f,0x0122,0x0418,0x010f,0x0122], "sound selection reads both sources before and after exactly one write")
        let newCurve = service.snapshot.newEqualizer!
        let added = await service.set(.createEqualizer(newCurve), generation: initial.generation)
        try check(added.confirmed && p.curves.count == 2, "create confirms firmware-assigned slot")
        try check(added.acknowledged, "two-byte EQ ACK is success, not a false target mismatch")
        let deleted = await service.set(.deleteEqualizer(p.curves.last!), generation: initial.generation)
        try check(deleted.confirmed && p.curves.count == 1 && service.snapshot.soundSelection == .preset(0), "active curve deletion reads actual fallback")
        _ = await service.set(.selectEqualizer(10), generation: initial.generation)
        p.leaveCustomSelected = true
        let contradictory = await service.set(.preset(7), generation: initial.generation)
        try check(!contradictory.confirmed && service.snapshot.soundSelection == nil, "preset ACK cannot hide custom still selected")
        p.leaveCustomSelected = false
        let fixed = await service.set(.preset(7), generation: initial.generation)
        try check(fixed.confirmed, "built-in and custom selection mutually exclusive")
        let bassEnabled = await service.set(.feature(.bassWave, true), generation: initial.generation)
        try check(bassEnabled.confirmed && service.snapshot.bassWave?.value.minimum == -5, "BassWave enable and signed range read")
        let bassSet = await service.set(.bassWave(-3), generation: initial.generation)
        try check(bassSet.confirmed && p.bass == [251,5,253], "BassWave sends actual bounds and signed strength")
        let old = p.curves[0]; p.curves[0].name = "Changed on phone"
        let writes = p.sent.filter { $0.command == 0x0418 }.count
        let conflict = await service.set(.deleteEqualizer(old), generation: initial.generation)
        try check(!conflict.confirmed && writes == p.sent.filter { $0.command == 0x0418 }.count, "changed curve cannot be deleted by stale UI")
        try await service.suspend()
        for ack: [UInt8] in [[0], [0,1,2], [0,99], [2,31]] {
            let p = peer(); p.eqReplyOverride = ack
            let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.03, makeConnection: { p })
            let initial = try await service.refresh()
            let result = await service.set(.createEqualizer(initial.newEqualizer!), generation: initial.generation)
            try check(!result.confirmed && p.curves.count == 2, "malformed/rejected/wrong-slot ACK cannot confirm even when create took effect")
            try check(service.snapshot.equalizers?.value.count == 2 && p.sent.filter { $0.command == 0x0418 }.count == 1, "failed confirmation preserves actual readback and never repeats create")
            try await service.suspend()
        }
        for failure in 0..<4 {
            let p = peer()
            let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.025, makeConnection: { p })
            let initial = try await service.refresh()
            switch failure {
            case 0: p.rejectWrite = true
            case 1: p.mismatchReadback = true
            case 2: p.dropAfterWrite = true
            default: p.loseACK = true
            }
            let result = await service.set(.createEqualizer(initial.newEqualizer!), generation: initial.generation)
            try check(!result.confirmed && p.sent.filter { $0.command == 0x0418 }.count == 1, "create failure never replays \(failure)")
            if failure >= 2 { try check(service.snapshot.equalizers?.stale == true, "ambiguous create cannot leave an apparently fresh list") }
            try await service.suspend()
        }
        print("HEADSET_SOUND PASS: fresh selection, CRUD, paired readback, conflict, BassWave, one-shot failure handling")
    }
    @MainActor static func runSync() async throws {
        let peer = SimulatedHeadset(); peer.capabilities[2] |= 4; peer.capabilities[5] |= 0x44
        let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.05, makeConnection: { peer })
        _ = try await service.refresh()
        var publishes = 0; service.changed = { _ in publishes += 1 }
        peer.packet?(try .init(command: 0x0504, sequence: 250, payload: [7]))
        try check(service.snapshot.preset?.value == 7 && publishes == 1, "phone sound sync publishes immediately")
        peer.packet?(try .init(command: 0x0503, payload: [1,29,1]))
        peer.packet?(try .init(command: 0x0508, payload: [251,5,4]))
        try check(service.snapshot.features[29]?.value == true && service.snapshot.bassWave?.value.current == 4, "BassWave sync is independent of subscribed events")
        peer.syncBeforeReply = { request in request.command == 0x010f ? try! .init(command: 0x0504, sequence: request.sequence, payload: [2]) : nil }
        _ = try await service.refresh()
        try check(service.snapshot.preset?.value == 2, "old baseline cannot overwrite new phone sync or complete wrong pending request")
        peer.syncBeforeReply = { request in request.command == 0x0109 ? try! .init(command: 0x0204, payload: [2,2,1,1,2,1]) : nil }
        _ = try await service.refresh()
        try check(service.snapshot.bothEarsUnworn, "late ears query cannot override an unworn notification")
        peer.syncBeforeReply = nil; peer.earState = 1
        let writes = peer.sent.filter { $0.command == 0x0404 }.count
        let result = await service.set(.noise(4), generation: service.snapshot.generation)
        try check(!result.confirmed && result.message.contains("佩戴耳机") && peer.sent.filter { $0.command == 0x0404 }.count == writes, "fresh wearing check blocks the write after a UI race")
        let oldReceiver = peer.packet
        try await service.suspend()
        oldReceiver?(try .init(command: 0x0504, payload: [3]))
        try check(service.snapshot.preset?.value != 3, "suspended connection sync ignored")
        print("SYNC PASS: phone pushes, pending read ordering, wearing, late packets")
    }
    @MainActor static func runReconnectBaseline() async throws {
        let peer = SimulatedHeadset(); peer.noiseMode = 4
        let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.025, makeConnection: { peer })
        _ = try await service.refresh()
        let oldGeneration = service.snapshot.generation
        let oldReceiver = peer.packet
        try await service.suspend()
        try check(service.snapshot.noise?.stale == true, "reconfiguration invalidates previous noise state")
        peer.noiseMode = 7; peer.noiseType = 5
        _ = try await service.refreshHiRes()
        let before = peer.sent.count
        let ready = try await service.listen()
        try check(ready.generation != oldGeneration && ready.noise?.value == 7 && ready.noise?.stale == false && ready.canChooseNoise,
                  "compact reconnect restores actual noise state without waiting for notifications")
        try check(ready.ears[1]?.stale == false && ready.ears[2]?.stale == false && ready.battery[1]?.stale == false,
                  "reconnect restores fresh wear and battery baseline")
        try check(ready.intelligentNoise?.stale == false && ready.intelligentNoiseTitle != nil, "intelligent ANC depth is refreshed")
        let commands = peer.sent.dropFirst(before).map(\.command)
        try check(commands.allSatisfy { [UInt16(0x0200),0x0205,0x010c,0x0109,0x0106].contains($0) },
                  "reconnect only reads quick controls, no EQ firmware or setting writes")
        oldReceiver?(try .init(command: 0x0204, payload: [3,1,1,8]))
        try check(service.snapshot.noise?.value == 7, "old connection notification cannot overwrite new baseline")
        let after = peer.sent.count; _ = try await service.listen()
        try check(peer.sent.count == after, "fresh baseline and subscription are not repeated")
        try await service.suspend()
        _ = try await service.refreshHiRes(); peer.dropCommands = [0x010c]
        _ = try await service.listen()
        try check(service.snapshot.connected && service.legacyReport.canSetHiRes && service.snapshot.noise?.stale == true && !service.snapshot.canChooseNoise,
                  "one rejected/missing noise read keeps HiRes but never marks cached noise fresh")
        try check(service.snapshot.issues[HeadsetQuery.noiseCurrent.key] != nil, "read failure stays actionable")
        peer.dropCommands = []; peer.noiseMode = 4
        _ = try await service.listen()
        try check(service.snapshot.canChooseNoise && service.snapshot.issues[HeadsetQuery.noiseCurrent.key] == nil, "later explicit listen retries stale baseline")
        try await service.suspend()
        peer.capabilities[2] &= ~1 // No noise capability in this connection.
        _ = try await service.refreshHiRes(); let unsupported = peer.sent.count
        _ = try await service.listen()
        try check(!peer.sent.dropFirst(unsupported).contains { $0.command == 0x010c }, "unadvertised query is not sent")
        try await service.suspend()
        print("HEADSET_RECONNECT_BASELINE PASS: fresh ANC/wear/battery, intelligent depth, no notification dependence, bounded failures, capability gate and old-generation isolation")
    }
    @MainActor static func runAudioResumeRecovery() async throws {
        // Reproduce the observed old flow: 0100 times out, audio remains active,
        // and only a later menu-triggered listen recovers the control state.
        do {
            let first = SimulatedHeadset(); first.dropCommands = [0x0100]
            let next = SimulatedHeadset(); var made = 0
            let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.01,
                makeConnection: { made += 1; return made == 1 ? first : next })
            do { _ = try await service.refreshHiRes(); throw ProtocolFailure("missing reply accepted") }
            catch { try check(!service.snapshot.connected && made == 1, "old compact query ends unknown without a recovery") }
            _ = try await service.listen()
            try check(made == 2 && service.snapshot.controlReport.hiRes == true && service.snapshot.canChooseNoise,
                      "later menu listen accounts for apparent spontaneous recovery")
            try await service.suspend()
            print("RESUME_OLD_FAILURE REPRODUCED: 0100 timeout -> unknown -> later listen recovers")
        }
        for scenario in ["no-response", "opening", "twice", "close-failed", "malformed", "cancel", "late-reply"] {
            let first = SimulatedHeadset(); first.shutdownDelay = 8_000_000
            let next = SimulatedHeadset(); next.noiseMode = 8; next.features[24] = 0
            if scenario == "opening" { first.suppressOpen = true }
            else if scenario == "malformed" { first.capabilities = [0] }
            else { first.dropCommands = [0x0100] }
            if scenario == "close-failed" { first.failShutdown = true }
            if scenario == "twice" { next.dropCommands = [0x0100] }
            var made = 0, trace: [String] = [], overlaps = false
            let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.01,
                operationTimeout: 0.045, resumeRetryDelay: 5_000_000, makeConnection: {
                    made += 1
                    if made > 1 && (first.isOpen || first.shutdownCompleted == 0) { overlaps = true }
                    return made == 1 ? first : next
                })
            service.trace = { trace.append($0 + " " + $1) }
            let task = Task { @MainActor in try await service.resumeAfterAudioStart() }
            if scenario == "cancel" {
                while !trace.contains(where: { $0.hasPrefix("resumeRetry") }) { try await Task.sleep(nanoseconds: 1_000_000) }
                task.cancel()
            }
            let shouldSucceed = ["no-response", "opening", "late-reply"].contains(scenario)
            var succeeded = false
            do {
                let restored = try await task.value
                succeeded = true
                try check(restored.controlReport.hiRes == false && restored.noise?.value == 8 && restored.canChooseNoise,
                          "fresh actual HiRes OFF and ANC are restored without menu interaction")
                try check(restored.ears[1]?.stale == false && made == 2 && first.shutdownCount == 1 && !overlaps,
                          "exactly one retry after confirmed old shutdown")
                if scenario == "late-reply" {
                    first.packet?(try .init(command: 0x8100, sequence: 1, payload: first.capabilities))
                    first.closed?("old transport callback")
                    try check(service.snapshot.generation == restored.generation && service.snapshot.connected,
                              "retired connection callbacks cannot stale recovered generation")
                }
            } catch {
                try check(!shouldSucceed, "recovery unexpectedly failed: " + scenario + " " + error.localizedDescription)
                try check(made == (scenario == "twice" ? 2 : 1), "no third attempt, no reopen after bad shutdown/protocol/cancel")
                try check(!service.snapshot.connected && !service.busy, "failed recovery is stale and terminal, not a permanent spinner")
            }
            try check(succeeded == shouldSucceed, "expected terminal outcome: " + scenario)
            try check((first.sent + next.sent).allSatisfy { $0.command < 0x0400 }, "read recovery never writes settings")
            try check(!(first.sent + next.sent).contains { [0x0105,0x010f,0x0122].contains($0.command) },
                      "no firmware/EQ/full query in audio resume")
            first.failShutdown = false
            try await service.suspend()
        }
        print("AUDIO_RESUME_RECOVERY PASS: opening/0100 timeout, single drained retry, real OFF/ANC baseline, shutdown failure, malformed reply, cancellation, stale callbacks, bounded final failure, no setting replay")
    }
    @MainActor static func runRefreshScopes() async throws {
        let peer = SimulatedHeadset(); peer.capabilities[2] |= 4; peer.capabilities[5] |= 4
        let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.03, makeConnection: { peer })
        _ = try await service.listen()
        try check(service.snapshot.controlReport.hiRes == true && service.snapshot.canChooseNoise,
                  "initial minimal watch seeds HiRes and quick controls")
        try check(!peer.sent.contains { [0x0105, 0x0108, 0x010f, 0x0122, 0x0115].contains($0.command) },
                  "opening quick controls never loads settings pages")
        var n = peer.sent.count
        _ = try await service.listen()
        try check(peer.sent.count == n, "idempotent listen sends zero packets on fresh connection")
        _ = try await service.refresh(scope: .quick)
        try check(Array(peer.sent.dropFirst(n).map(\.command)) == [0x0106, 0x0109, 0x010c],
                  "periodic scope strictly battery/wear/noise, no HiRes or codec")
        n = peer.sent.count
        _ = try await service.refresh(scope: .keys, missingOnly: true)
        try check(Array(peer.sent.dropFirst(n).map(\.command)) == [0x0108], "keys page only reads keys")
        n = peer.sent.count
        _ = try await service.refresh(scope: .keys, missingOnly: true)
        try check(peer.sent.count == n, "fresh page reads coalesce without I/O")
        peer.features[24] = 0
        _ = try await service.refresh(scope: .quick)
        try check(service.snapshot.controlReport.hiRes == true, "periodic quick read deliberately does not poll HiRes")
        n = peer.sent.count
        _ = try await service.refresh(scope: .status, includeHiRes: true)
        try check(service.snapshot.controlReport.hiRes == false &&
                  Array(peer.sent.dropFirst(n).map(\.command)) == [0x0114, 0x010d, 0x0106, 0x0105],
                  "manual page refresh includes actual HiRes but no unrelated pages")
        peer.dropCommands = [0x0105]
        _ = try await service.refresh(scope: .status)
        try check(service.snapshot.canChooseNoise && service.snapshot.versions?.stale == true,
                  "unrelated field failure does not disable fresh ANC")
        peer.dropCommands = []
        // Exhaust sequence reserve via quick reads; rollover must re-baseline
        // HiRes exactly once for the new connection, not at every timer tick.
        let first = service.snapshot.generation
        for _ in 0..<80 {
            if service.snapshot.generation != first { break }
            _ = try await service.refresh(scope: .quick)
        }
        try check(service.snapshot.generation != first && service.snapshot.controlReport.hiRes == false,
                  "sequence rollover restores HiRes for new generation")
        n = peer.sent.count
        _ = try await service.refresh(scope: .quick)
        try check(!peer.sent.dropFirst(n).contains { [0x010d, 0x0114].contains($0.command) },
                  "new connection baseline does not turn into periodic HiRes polling")
        n = peer.sent.count
        _ = await service.set(.noise(8), generation: service.snapshot.generation)
        try check(!peer.sent.dropFirst(n).contains { [0x0105,0x0108,0x010f,0x0122,0x0114,0x010d].contains($0.command) },
                  "ANC write reads back affected state without full refresh")
        try await service.suspend()
        print("HEADSET_SCOPES PASS: minimal watch, idempotence, exact quick packets, lazy pages, manual HiRes, partial failure and rollover")
    }
    @MainActor static func runProfiles() async throws {
        for profile in HeadphoneProfile.all where profile.dialect != nil {
            let peer = SimulatedHeadset(); peer.productID = profile.productID; peer.serviceUUID = profile.serviceUUID!
            peer.capabilities = [0] + Array(repeating: 255, count: 9)
            let service = HeadsetControlService(address: "00:11:22:33:44:55", makeConnection: { peer })
            let state = try await service.refresh(scope: .full)
            try check(state.profile?.id == profile.id, "profile identity survives matching transport")
            try check(!peer.sent.contains { $0.command == 0x012a || $0.command == 0x011a || $0.command >= 0x0400 }, "full read never expands feature ceiling or writes")
            if !profile.supports(.equalizers) { try check(!peer.sent.contains { $0.command == 0x0122 }, "preset-only skips EQ") }
            if !profile.supports(.noiseCurrent) { try check(!peer.sent.contains { $0.command == 0x010c }, "no-ANC profile skips ANC") }
            if profile.supports(.preset), !profile.supports(.equalizers), let preset = profile.presets.first {
                let result = await service.set(.preset(preset.id), generation: state.generation)
                try check(result.confirmed, "preset-only write confirms without EQ capability")
            }
            try await service.suspend()
        }
        for id: UInt32 in [0xabcdef, 0x061010] {
            let peer = SimulatedHeadset(); peer.productID = id
            let service = HeadsetControlService(address: "00:11:22:33:44:55", makeConnection: { peer })
            let identity = try await service.identify()
            try check(identity.productID == id && peer.sent.map(\.command) == [0x0100,0x0101,0x0102,0x0104,0x0103], "unknown identity is bounded initialization only")
            let result = await service.set(.feature(.multipoint, true), generation: service.snapshot.generation)
            try check(!result.confirmed && !peer.sent.contains { $0.command >= 0x0400 }, "unknown or non-SPP product cannot authorize write")
            try await service.suspend()
        }
        print("HEADSET_PROFILES PASS: 53 matching SPP profiles, preset-only confirmation, unknown/non-SPP identity isolation")
    }
    @MainActor static func run() async throws {
        try await runProfiles()
        try await runAudioResumeRecovery()
        try await runRefreshScopes()
        try await runReconnectBaseline()
        try await runSync()
        try await runControls()
        try await runSound()
        do {
            let peer = SimulatedHeadset(); peer.dropCommands = [0x0200]
            let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.025, makeConnection: { peer })
            var traces: [String] = []; service.trace = { traces.append($0 + " " + $1) }
            let initial = try await service.refreshHiRes()
            let count = peer.sent.count
            _ = try await service.listen()
            try check(Array(peer.sent.dropFirst(count).map(\.command)) == [0x0200, 0x010c, 0x0109, 0x0106] && service.snapshot.connected &&
                      service.legacyReport.canSetHiRes, "missing notification list cannot discard successful HiRes read or run full refresh")
            try check(service.snapshot.issues["subscription"] != nil && traces.contains { $0.contains("replyTimeout") }, "partial subscription and timeout are diagnosed")
            let late = peer.sent.first(where: { $0.command == 0x0200 })!
            peer.packet?(try .init(command: 0x8200, sequence: late.sequence, payload: [0,3,1,2,3]))
            try check(traces.contains { $0.contains("unmatchedReply") }, "late optional response is ignored and diagnosed")
            peer.dropCommands = []
            _ = try await service.listen()
            let after = peer.sent.count
            _ = try await service.listen()
            try check(peer.sent.count == after && service.snapshot.notificationIDs == [1,2,3] &&
                      service.snapshot.generation == initial.generation, "subscription can recover on same channel and is idempotent")
            peer.dropCommands = [0x0105]
            _ = try await service.refresh()
            try check(service.snapshot.connected && service.legacyReport.canSetHiRes, "firmware timeout preserves live HiRes")
            let live = peer.sent.count
            _ = try await service.refresh(liveOnly: true)
            try check(!peer.sent.dropFirst(live).contains { $0.command == 0x0105 || $0.command == 0x0103 }, "periodic update excludes static firmware/product queries")
            // Once the peer is silent twice in a row, this is no longer one unsupported field.
            peer.dropCommands = [0x0106,0x0105]
            do { _ = try await service.refresh(); throw ProtocolFailure("silent peer falsely live") }
            catch { try check(!service.snapshot.connected && !service.busy, "silent transport still fails within its bound") }
            try await service.suspend()
        }
        do {
            let peer = SimulatedHeadset(); peer.capabilities[5] = 4; peer.dropCommands = [0x0122]
            let focused = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.04, makeConnection: { peer })
            let result = try await focused.refreshHiRes()
            try check(result.features[24]?.value == true && focused.legacyReport.canSetHiRes,
                      "targeted read returns confirmed HiRes and current codec")
            try check(!peer.sent.contains { [0x0122,0x011a,0x012a,0x0200,0x0205].contains($0.command) },
                      "HiRes query never waits for EQ, personalized or notification discovery")
            let start = peer.sent.count
            _ = try await focused.refreshHiRes()
            try check(Array(peer.sent.dropFirst(start).map(\.command)) == [0x0114,0x010d], "repeat read needs only codec and HiRes")
            _ = try await focused.refresh()
            try check(!focused.busy && focused.snapshot.connected && focused.legacyReport.hiRes == true,
                      "one optional EQ timeout preserves confirmed HiRes and connected transport")
            try check(focused.snapshot.issues[HeadsetQuery.equalizers.key] != nil, "failed optional field remains diagnostic")
            try await focused.suspend()
        }
        for opening in [true, false] {
            let peer = SimulatedHeadset(); peer.suppressOpen = opening; peer.silence = !opening; peer.suppressCloseCallback = true
            let bounded = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.025,
                                                operationTimeout: 0.07, makeConnection: { peer })
            let started = Date()
            do { _ = try await bounded.refreshHiRes(); throw ProtocolFailure("missing callback unexpectedly succeeded") }
            catch {
                try check(error.localizedDescription != "missing callback unexpectedly succeeded", "missing callback must fail explicitly")
                try check(!bounded.busy && Date().timeIntervalSince(started) < 0.5, "missing open/close callback cannot strand a read")
            }
            peer.suppressOpen = false; peer.silence = false; peer.suppressCloseCallback = false
            _ = try await bounded.refreshHiRes()
            try check(bounded.legacyReport.hiRes == true, "timeout permits a fresh correlated read after close barrier")
            try await bounded.suspend()
        }
        do {
            let peer = SimulatedHeadset(); peer.responseDelay = 0.012
            let bounded = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.04,
                                                operationTimeout: 0.05, makeConnection: { peer })
            do { _ = try await bounded.refreshHiRes(); throw ProtocolFailure("cumulative initialization unexpectedly succeeded") }
            catch {
                try check(error.localizedDescription.contains("总时限") || error.localizedDescription.contains("未回复"), "initialization and reads share one overall deadline")
                try check(peer.sent.count < 7 && !bounded.snapshot.connected, "cumulative deadline expires before a falsely confirmed HiRes result")
            }
            peer.responseDelay = 0; peer.features[24] = 0
            _ = try await bounded.refreshHiRes()
            try await Task.sleep(nanoseconds: 25_000_000)
            try check(bounded.legacyReport.hiRes == false && bounded.snapshot.connected, "late old-generation reply cannot overwrite the fresh read")
            try await bounded.suspend()
        }
        do {
            let peer = SimulatedHeadset()
            let bounded = HeadsetControlService(address: "00:11:22:33:44:55", operationTimeout: 0.025, makeConnection: { peer })
            _ = try await bounded.refreshHiRes()
            peer.close("remote closed"); peer.shutdownDelay = 60_000_000
            do { _ = try await bounded.refreshHiRes(); throw ProtocolFailure("expired close wait unexpectedly reopened") }
            catch { try check(error.localizedDescription.contains("已超时"), "expired shutdown wait returns an explicit failure") }
            try check(peer.startCount == 1 && !bounded.busy, "overall timeout while closing cannot open an unbounded new connection")
        }
        print("HEADSET_HIRES_READ PASS: targeted commands, optional-query isolation, total deadline, missing callbacks and retry after cleanup")
        let simulator = SimulatedHeadset(); simulator.wrongSequenceFirst = true
        let service = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.05, makeConnection: { simulator })
        let first = try await service.refresh()
        try check(first.isX4 && first.connected, "initial product and connected")
        try check(first.notificationIDs == [1,2,3], "subscription")
        let event = try OppoControlPacket(command: 0x0204, payload: [1,1,1,55])
        simulator.packet?(event)
        try check(service.snapshot.battery[1]?.value.percent == 55, "phone notification applied")
        let confirmed = await service.set(.feature(.wearDetection, false), generation: first.generation)
        try check(confirmed.confirmed, "matching ACK plus readback must confirm")
        try check(simulator.sent.filter { $0.command == 0x0403 }.count == 1, "exactly one write")
        let hiResStart = simulator.sent.count
        let hiRes = await service.set(.feature(.hiRes, false), generation: first.generation)
        try check(hiRes.confirmed && Array(simulator.sent.dropFirst(hiResStart).map(\.command)) == [0x010d,0x0114,0x0403,0x010d],
                  "HiRes ACK and readback return before unrelated queries during imminent profile restart")
        let before = simulator.sent.count
        let stale = await service.set(.feature(.wearDetection, true), generation: UUID())
        try check(!stale.confirmed && simulator.sent.count == before, "stale generation never sends")
        try check(Set(simulator.sent.map(\.sequence)).count == simulator.sent.count, "no sequence reuse")
        try await service.suspend()
        try check(simulator.shutdownCount == 1 && !service.snapshot.connected, "suspend barrier")
        // A late packet from the disposed transport cannot make the snapshot live again.
        simulator.packet?(event); try check(service.snapshot.battery[1]?.stale == true, "late notification ignored")
        let slow = SimulatedHeadset(); slow.shutdownDelay = 40_000_000
        let closing = HeadsetControlService(address: "00:11:22:33:44:55", makeConnection: { slow })
        _ = try await closing.refresh()
        async let one: Void = closing.suspend()
        async let two: Void = closing.suspend()
        try await one; try await two
        try check(slow.shutdownCount == 1 && !slow.isOpen, "repeated cancels join the actual close barrier")
        let retiring = SimulatedHeadset(); retiring.shutdownDelay = 60_000_000
        var made = 0
        let canceledOpen = HeadsetControlService(address: "00:11:22:33:44:55", makeConnection: { made += 1; return retiring })
        _ = try await canceledOpen.refresh()
        let barrier = Task { try await canceledOpen.suspend() }
        while retiring.shutdownCount == 0 { await Task.yield() }
        let refresh = Task { try await canceledOpen.refresh() }
        while !canceledOpen.busy { await Task.yield() }
        refresh.cancel()
        try await barrier.value
        do { _ = try await refresh.value; throw ProtocolFailure("canceled refresh unexpectedly succeeded") }
        catch { try check(made == 1, "canceled refresh waiting for shutdown must never open a new transport") }
        let bad = SimulatedHeadset(); bad.failShutdown = true
        let closeFailure = HeadsetControlService(address: "00:11:22:33:44:55", makeConnection: { bad })
        _ = try await closeFailure.refresh()
        do { try await closeFailure.suspend(); throw ProtocolFailure("expected close failure") }
        catch { try check(error.localizedDescription == "simulated close failure", "propagate close failure") }
        let sentBefore = bad.sent.count
        do { _ = try await closeFailure.refresh(); throw ProtocolFailure("expected persistent close failure") }
        catch { try check(bad.sent.count == sentBefore, "unverified close must block a new connection") }
        bad.failShutdown = false
        _ = try await closeFailure.refreshHiRes()
        try check(bad.startCount == 2 && closeFailure.snapshot.connected,
                  "a later confirmed close clears failure without recreating the service")
        try await closeFailure.suspend()
        for failure in 0..<4 {
            let peer = SimulatedHeadset()
            let test = HeadsetControlService(address: "00:11:22:33:44:55", responseTimeout: 0.05, makeConnection: { peer })
            let state = try await test.refresh()
            switch failure { case 0: peer.rejectWrite = true; case 1: peer.mismatchReadback = true; case 2: peer.dropAfterWrite = true; default: peer.loseACK = true }
            let result = await test.set(.feature(.multipoint, true), generation: state.generation)
            try check(!result.confirmed, "failed write must not confirm \(failure)")
            try check(peer.sent.filter { $0.command == 0x0403 }.count == 1, "failed write never retries")
            if failure >= 2 { try check(!test.snapshot.connected, "disconnect/timeout leaves stale") }
            try await test.suspend()
        }
        let peer = SimulatedHeadset()
        let test = HeadsetControlService(address: "00:11:22:33:44:55", makeConnection: { peer })
        _ = try await test.refresh(); let previous = test.snapshot.generation
        try await test.suspend(); _ = try await test.refresh()
        try check(test.snapshot.generation != previous, "new transport generation")
        try check(peer.sent.filter { $0.command == 0x0403 }.isEmpty, "reconnect never replays a setting")
        try await test.suspend()
    }
}
#endif
