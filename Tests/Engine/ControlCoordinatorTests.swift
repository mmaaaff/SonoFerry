import Foundation
import SonoFerryCore

@main struct ControlCoordinatorTests {
    static func main() {
        Task { @MainActor in
            do { try await run(); print("CONTROL_COORDINATOR PASS: real controller serialization, busy-read race, cancellation, queue deadline, explicit one-shot writes behind reads and no write replay"); exit(0) }
            catch { fputs("Control coordinator failure: \(error)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }
    static func check(_ value: @autoclosure () -> Bool, _ reason: String) throws {
        if !value() { throw ProtocolFailure(reason) }
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() {
            if Date() > deadline { throw ProtocolFailure("controller test timed out") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    @MainActor static func identityChecks() async throws {
        let device = BluetoothDevice(address: "00:11:22:33:44:55", name: "Renamed", connected: true, a2dpSink: true, controlServices: [HeadsetDialect.elnk079A.rawValue])
        for mode in ["known", "unknown", "close-failure", "cancel", "no-service"] {
            let peer = SimulatedHeadset(); peer.shutdownDelay = 20_000_000
            peer.failShutdown = mode == "close-failure"; if mode == "unknown" { peer.productID = 0xffffff }
            let service = HeadsetControlService(address: device.address, makeConnection: { peer })
            var events: [WireMessage] = []
            var observed = device; if mode == "no-service" { observed.controlServices = [] }
            let controller = SessionController(observeSystem: false, emitHandler: { events.append($0) }, pairedDevices: { [observed] }, makeControlService: { _ in service })
            var request = WireMessage("deviceIdentity", requestID: UUID()); request.device = device
            controller.handle(request)
            if mode == "cancel" {
                try await wait { peer.shutdownCount > 0 }
                controller.handle(WireMessage("headsetCancel", requestID: request.requestID))
            }
            try await wait { events.contains { $0.kind == "deviceIdentity" && $0.requestID == request.requestID } }
            let reply = events.last { $0.kind == "deviceIdentity" && $0.requestID == request.requestID }!
            try check(!peer.sent.contains { $0.command == 0x0200 || $0.command >= 0x0400 }, "identity never subscribes or writes")
            if mode == "known" || mode == "unknown" {
                try check(reply.restartSafe == true && peer.shutdownCompleted == 1 && !service.snapshot.connected, "identity result only follows confirmed shutdown")
                try check(reply.headsetIdentity?.productID == peer.productID, "name cannot override product reply")
            } else if mode == "close-failure" { try check(reply.restartSafe == false, "failed close blocks addition") }
            else if mode == "cancel" { try check(reply.headsetIdentity == nil, "canceled identity cannot register") }
            else { try check(peer.startCount == 0, "engine checks observed services rather than trusting App") }
            peer.failShutdown = false; try await service.suspend()
        }
        print("CONTROL_IDENTITY PASS: single owner, actual service, ID, no subscribe/write, confirmed close and cancellation")
    }
    @MainActor static func run() async throws {
        try await identityChecks()
        try await outputTransitionChecks()
        try await outputSelectionChecks()
        let device = BluetoothDevice(address: "00:11:22:33:44:55", name: "Simulated", connected: true, a2dpSink: true)
        do {
            let peer = SimulatedHeadset()
            let service = HeadsetControlService(address: device.address, responseTimeout: 0.03, makeConnection: { peer })
            var events: [WireMessage] = []
            let controller = SessionController(observeSystem: false, emitHandler: { events.append($0) }, makeControlService: { _ in service })
            var read = WireMessage("oppoQuery", requestID: UUID()); read.device = device
            controller.handle(read)
            try await wait { events.contains { $0.kind == "oppoResult" && $0.requestID == read.requestID } }
            let count = peer.sent.count
            var listen = WireMessage("headsetListen", requestID: UUID()); listen.device = device
            controller.handle(listen)
            try await wait { events.contains { $0.kind == "headsetResult" && $0.requestID == listen.requestID } }
            try check(Array(peer.sent.dropFirst(count).map(\.command)) == [0x0200,0x0205,0x010c,0x0109,0x0106], "post-HiRes listen reads quick baseline without optional full state")
            let ready = events.last { $0.kind == "headsetResult" && $0.requestID == listen.requestID }
            try check(ready?.headset?.canChooseNoise == true && ready?.headset?.ears[1]?.stale == false,
                      "controller delivers usable noise and wear baseline to App after compact HiRes")
            var write = WireMessage("headsetSet", requestID: UUID()); write.device = device
            write.headsetSetting = .feature(.multipoint, true); write.controlGeneration = UUID()
            controller.handle(write)
            try await wait { events.contains { $0.kind == "headsetResult" && $0.requestID == write.requestID } }
            try check(!peer.sent.contains { $0.command == 0x0403 }, "stale generation cannot submit write")
            controller.handle(WireMessage("headsetUnwatch"))
            try await wait { !service.snapshot.connected }
            try check(events.contains { $0.kind == "headsetConnection" && $0.headset?.connected == false },
                      "connection invalidation is published even after UI unwatch")
        }
        for mode in ["complete", "close-failure", "cancel"] {
            let peer = SimulatedHeadset()
            let service = HeadsetControlService(address: device.address, makeConnection: { peer })
            var events: [WireMessage] = []
            let controller = SessionController(observeSystem: false, emitHandler: { events.append($0) }, makeControlService: { _ in service })
            var watch = WireMessage("headsetWatch", requestID: UUID()); watch.device = device
            controller.handle(watch)
            try await wait { events.contains { $0.kind == "headsetResult" && $0.requestID == watch.requestID } }
            peer.responseDelay = 0.02; peer.shutdownDelay = 20_000_000
            var read = WireMessage("headsetRefresh", requestID: UUID()); read.device = device; read.details = ["refreshScope": "quick"]
            controller.handle(read); try await wait { service.busy }
            var write = WireMessage("headsetSet", requestID: UUID()); write.device = device
            write.headsetSetting = .noise(8); write.controlGeneration = service.snapshot.generation; write.details = ["waitForRead": "true"]
            controller.handle(write)
            peer.failShutdown = mode == "close-failure"
            var recovery = WireMessage("headsetRecover", requestID: UUID()); recovery.device = device
            controller.handle(recovery)
            if mode == "cancel" { controller.handle(WireMessage("headsetCancel", requestID: recovery.requestID)) }
            try await wait { events.contains { $0.kind == "headsetResult" && $0.requestID == recovery.requestID } }
            let reply = events.last { $0.kind == "headsetResult" && $0.requestID == recovery.requestID }!
            try check(!peer.sent.contains { $0.command == 0x0404 }, "manual refresh never replays queued write")
            try check(events.contains { $0.requestID == write.requestID && $0.kind == "headsetResult" }, "queued setting gets cancellation terminal")
            if mode == "complete" {
                try check(peer.startCount == 2 && peer.shutdownCount == 1, "control channel closes before reopening once")
                try check(reply.headset?.canChooseNoise == true && reply.headset?.versions?.stale == false && reply.headset?.features[24]?.stale == false,
                          "full recovery includes ANC firmware and HiRes")
            } else {
                try check(peer.startCount == 1 && reply.headset == nil, "failed/canceled cleanup never opens another channel")
            }
            peer.failShutdown = false; try await service.suspend()
        }
        do {
            let peer = SimulatedHeadset()
            let service = HeadsetControlService(address: device.address, makeConnection: { peer })
            var events: [WireMessage] = []
            let controller = SessionController(observeSystem: false, emitHandler: { events.append($0) }, makeControlService: { _ in service })
            var watch = WireMessage("headsetWatch", requestID: UUID()); watch.device = device
            controller.handle(watch)
            try await wait { events.contains { $0.kind == "headsetResult" && $0.requestID == watch.requestID } }
            peer.loseACK = true
            var write = WireMessage("headsetSet", requestID: UUID()); write.device = device
            write.headsetSetting = .noise(8); write.controlGeneration = service.snapshot.generation
            controller.handle(write)
            try await wait { peer.sent.contains { $0.command == 0x0404 } }
            var recovery = WireMessage("headsetRecover", requestID: UUID()); recovery.device = device
            controller.handle(recovery)
            try await wait { events.contains { $0.kind == "headsetResult" && $0.requestID == recovery.requestID } }
            let result = events.last { $0.kind == "headsetResult" && $0.requestID == recovery.requestID }
            try check(peer.sent.filter { $0.command == 0x0404 }.count == 1, "in-flight unacknowledged setting never replays")
            try check(result?.headset?.noise?.value == 8 && result?.headset?.noise?.stale == false,
                      "recovery queries actual earbud state after ambiguous write")
            try await service.suspend()
        }
        for mode in ["complete", "cancel", "deadline", "unwatch", "stale"] {
            let peer = SimulatedHeadset()
            let service = HeadsetControlService(address: device.address, makeConnection: { peer })
            _ = try await service.listen()
            var events: [WireMessage] = []
            let controller = SessionController(observeSystem: false, controlQueueTimeout: mode == "deadline" ? 0.005 : 1,
                emitHandler: { events.append($0) }, makeControlService: { _ in service })
            peer.responseDelay = 0.012
            var read = WireMessage("headsetRefresh", requestID: UUID()); read.device = device
            read.details = ["refreshScope": "quick"]
            controller.handle(read); try await wait { service.busy }
            var write = WireMessage("headsetSet", requestID: UUID()); write.device = device
            write.headsetSetting = .noise(8); write.controlGeneration = mode == "stale" ? UUID() : service.snapshot.generation
            write.details = ["waitForRead": "true"]
            controller.handle(write)
            try check(!events.contains { $0.requestID == write.requestID }, "explicit write waits behind read without premature failure")
            if mode == "cancel" { controller.handle(WireMessage("headsetCancel", requestID: write.requestID)) }
            if mode == "unwatch" { controller.handle(WireMessage("headsetUnwatch")) }
            try await wait { events.contains { $0.kind == "headsetResult" && $0.requestID == write.requestID } }
            try await wait { !service.busy }
            let replies = events.filter { $0.kind == "headsetResult" && $0.requestID == write.requestID }
            try check(replies.count == 1, "queued user write gets exactly one terminal response")
            try check(peer.sent.filter { $0.command == 0x0404 }.count == (mode == "complete" ? 1 : 0),
                      "waiting write executes once or cancels without any write: " + mode)
            if mode == "complete" { try check(replies[0].headsetResult?.confirmed == true, "queued user setting actually confirmed") }
            try await service.suspend()
        }
        for mode in ["complete", "cancel", "deadline", "unwatch"] {
            let peer = SimulatedHeadset(); peer.responseDelay = 0.006
            let service = HeadsetControlService(address: device.address, makeConnection: { peer })
            var events: [WireMessage] = []
            let controller = SessionController(observeSystem: false, controlQueueTimeout: mode == "deadline" ? 0.02 : 1,
                emitHandler: { events.append($0) }, makeControlService: { _ in service })
            var watch = WireMessage("headsetWatch", requestID: UUID()); watch.device = device
            controller.handle(watch)
            try await wait { service.busy }
            var read = WireMessage("oppoQuery", requestID: UUID()); read.device = device
            controller.handle(read)
            try check(events.contains { $0.requestID == read.requestID && $0.kind == "oppoProgress" }, "read queues behind the engine-owned refresh")
            var write = WireMessage("headsetSet", requestID: UUID()); write.device = device
            write.headsetSetting = .feature(.multipoint, true); write.controlGeneration = service.snapshot.generation
            controller.handle(write)
            try check(events.contains { $0.requestID == write.requestID && $0.kind == "headsetResult" }, "write gets a terminal busy response, never queued")
            if mode == "cancel" { controller.handle(WireMessage("oppoCancel", requestID: read.requestID)) }
            if mode == "unwatch" { controller.handle(WireMessage("headsetUnwatch")) }
            try await wait { events.contains { $0.requestID == read.requestID && ["oppoResult", "oppoFailed"].contains($0.kind) } }
            try await wait { !service.busy }
            let results = events.filter { $0.requestID == read.requestID && ["oppoResult", "oppoFailed"].contains($0.kind) }
            try check(results.count == 1, "exactly one terminal response for every queued read")
            if mode == "complete" {
                try check(results[0].kind == "oppoResult" && results[0].oppoReport?.hiRes == true, "queued read completes without manual refresh")
                try check(peer.sent.filter { $0.command == 0x0114 }.count == 2, "one compact read after full refresh")
            } else {
                try check(results[0].kind == "oppoFailed", "canceled/expired queued read is terminal")
                try check(peer.sent.filter { $0.command == 0x0114 }.count <= 1, "canceled queued read is never sent later")
            }
            try check(!peer.sent.contains { $0.command == 0x0403 }, "busy setter never writes/replays")
            try await service.suspend()
        }
    }
    @MainActor static func outputTransitionChecks() async throws {
        // Actual 0.1.29 failure: hidden=1, running=0, both eligibility flags=0,
        // but Core Audio keeps alive=1. This must retire without a false timeout.
        for alive in [false, true] {
            let retired = OutputTransition.State(alive: alive, hidden: true, running: false, canDefault: false, canSystemDefault: false)
            try check(retired.retired, "hidden stopped output can retire independently of host alive cache")
            var running = retired; running.running = true
            var visible = retired; visible.hidden = false
            var defaultEligible = retired; defaultEligible.canDefault = true
            var systemEligible = retired; systemEligible.canSystemDefault = true
            try check(!running.retired && !visible.retired && !defaultEligible.retired && !systemEligible.retired,
                      "each actual use/visibility indicator still blocks retirement")
        }
        var states: [OutputTransition.State] = [
            .init(alive: true, hidden: false, running: true, canDefault: true, canSystemDefault: true),
            .init(alive: true, hidden: true, running: true, canDefault: false, canSystemDefault: false),
            .init(alive: true, hidden: true, running: false, canDefault: true, canSystemDefault: false),
            .init(alive: true, hidden: true, running: false, canDefault: false, canSystemDefault: false)]
        var reads = 0
        try await OutputTransition.wait(stage: "retire", timeout: .milliseconds(100), interval: .milliseconds(1)) {
            reads += 1; return states.removeFirst().retired
        }
        try check(reads == 4, "wait for hidden, stopped and ineligible output, without waiting for alive=0")
        do {
            try await OutputTransition.wait(stage: "retire", timeout: .milliseconds(5), interval: .milliseconds(1)) { false }
            throw ProtocolFailure("unretired output was accepted")
        } catch is OutputTransition.Timeout { }
        var attempts = 0
        do {
            try await OutputTransition.wait(stage: "read", interval: .milliseconds(1)) {
                attempts += 1; throw ProtocolFailure("read failed")
            }
        } catch is ProtocolFailure { }
        try check(attempts == 1, "property/permission errors propagate without retry")
        let task = Task { @MainActor in
            try await OutputTransition.wait(stage: "cancel") { false }
        }
        task.cancel()
        do { try await task.value; throw ProtocolFailure("canceled transition continued") }
        catch is CancellationError { }
        var cleanupFinished = false
        let canceledStartup = Task { @MainActor in
            try await OutputTransition.retire(timeout: .milliseconds(200)) {
                cleanupFinished = true; return true
            }
        }
        canceledStartup.cancel()
        try await canceledStartup.value
        try check(cleanupFinished, "canceling startup cannot skip mandatory retirement")
        print("OUTPUT_TRANSITION PASS: real alive=1 hidden=1 idle trace, eligibility/IO gates, delayed retirement, bounded timeout, no error retry, cancellation")
    }
    @MainActor static func outputSelectionChecks() async throws {
        let device = BluetoothDevice(address: "00:11:22:33:44:55", name: "Simulated X4", connected: true, a2dpSink: true)
        for scenario in ["success", "stale", "disconnected", "generation", "unknown", "readback-mismatch"] {
            var route = OutputRoute(uid: "speaker")
            var devices = [device], events: [WireMessage] = [], writes = 0
            let controller = SessionController(observeSystem: false, emitHandler: { events.append($0) },
                pairedDevices: { devices }, readRoute: { route }, selectNativeOutput: { address, expected in
                    writes += 1
                    try check(expected == route.uid, "compare-and-set uses actual route")
                    route = scenario == "readback-mismatch" ? .init(uid: "external-winner") : .init(uid: address, bluetoothAddress: address)
                })
            controller.handle(WireMessage("environment", requestID: UUID()))
            var observed = events.last!.environment!
            if scenario == "stale" { route = .init(uid: "changed-by-user") }
            if scenario == "generation" { observed.generation = UUID() }
            if scenario == "disconnected" { devices = [] }
            if scenario == "unknown" { observed.route.uid = nil }
            let id = UUID(); var request = WireMessage("selectOutput", requestID: id)
            request.device = device; request.environment = observed; controller.handle(request)
            try await wait { events.contains { $0.kind == "outputSelected" && $0.requestID == id } }
            let reply = events.first { $0.kind == "outputSelected" && $0.requestID == id }!
            try check(writes == (["success", "readback-mismatch"].contains(scenario) ? 1 : 0), "one or zero route writes, never retry: " + scenario)
            try check((reply.message == nil) == (scenario == "success"), "route result confirms actual output only: " + scenario)
            try check(events.last?.environment?.route == route, "failure and success both publish authoritative current output")
        }
        print("OUTPUT_SELECTION PASS: generation, stale route, disconnected device, unknown output, single write and readback mismatch")
    }

}
