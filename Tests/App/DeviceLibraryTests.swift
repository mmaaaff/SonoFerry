import Foundation
import SonoFerryCore

@MainActor private final class LibraryHarness {
    let suite = "local.SonoFerry.LibraryTests." + UUID().uuidString
    let prefs: UserDefaults
    var client: EngineClient!
    var commands: [WireMessage] = []
    let generation = UUID()
    var revision: UInt64 = 0
    let x4 = BluetoothDevice(address: "00:11:22:33:44:55", name: "OPPO Enco X4", connected: true, a2dpSink: true, controlServices: [HeadsetDialect.elnk079A.rawValue])
    let xm5 = BluetoothDevice(address: "00:11:22:33:44:66", name: "WH-1000XM5", connected: true, a2dpSink: true)
    let computer = BluetoothDevice(address: "00:11:22:33:44:77", name: "MacBook Pro", connected: true, a2dpSink: true)
    let lhdc = try! CapabilityParser.codec(endpoint: 3, bytes: [0,255,0x3a,5,0,0,0x35,0x4c,0x30,0x06,0x11,0,0])
    let ldac = try! CapabilityParser.codec(endpoint: 1, bytes: [0,255,0x2d,1,0,0,0xaa,0,0x3c,7])
    var fileClears = 0
    var timeouts: [@MainActor () -> Void] = []
    var recoveries: [@MainActor () -> Void] = []
    init(library: Bool = false, cache: Bool = false) {
        prefs = UserDefaults(suiteName: suite)!
        if library {
            prefs.set(try! JSONEncoder().encode([RegisteredHeadphone(address: x4.address, model: .encoX4), .init(address: xm5.address, model: .wh1000xm5)]), forKey: "headphoneLibrary.v1")
        }
        if cache { seed(x4, cap: lhdc); seed(xm5, cap: ldac) }
        reload()
    }
    func reload() {
        client = EngineClient(previewMode: false, preferences: prefs, messageSink: { [weak self] in self?.commands.append($0) }, recoveryScheduler: { [weak self] _, action in self?.recoveries.append(action) }, controlScheduler: { [weak self] _, action in self?.timeouts.append(action) }, preferencesDomain: suite, clearStoredFiles: { [weak self] in self?.fileClears += 1 })
    }
    func seed(_ device: BluetoothDevice, cap: CodecCapabilities) {
        struct Cache: Encodable {
            var capabilities: [CodecCapabilities]; var selectedCapability: String
            let rate = 0; let quality = Quality.adaptive; let fixedBitrate = 0
        }
        prefs.set(try! JSONEncoder().encode(Cache(capabilities: [cap], selectedCapability: cap.id)), forKey: "device." + device.address)
    }
    func observe(_ route: OutputRoute, devices: [BluetoothDevice]? = nil, request: UUID? = nil,
                 session: UUID? = nil, transition: Bool = false, details: [String:String]? = nil) {
        revision += 1
        var event = WireMessage("environment", requestID: request)
        event.details = details
        event.environment = .init(generation: generation, revision: revision, devices: devices ?? [x4,xm5,computer], route: route, audioSessionID: session, transitioning: transition)
        client.receive(event)
    }
    func answerIdentity(product: UInt32? = 0x06ec10, safe: Bool? = true, request supplied: WireMessage? = nil) {
        guard let request = supplied ?? commands.last(where: { $0.kind == "deviceIdentity" }) else { return }
        var response = WireMessage("deviceIdentity", requestID: request.requestID)
        response.device = request.device; response.restartSafe = safe
        if let product { response.headsetIdentity = .init(address: request.device!.address, productID: product, serviceUUID: request.device!.controlServices?.first ?? HeadsetDialect.elnk079A.rawValue, generation: UUID()) }
        else { response.message = "身份读取失败" }
        client.receive(response)
    }
    var native: OutputRoute { .init(uid: x4.address, bluetoothAddress: x4.address, sampleRate: 48000) }
    var speaker: OutputRoute { .init(uid: "BuiltInSpeakerDevice", sampleRate: 48000) }
    var lastProbe: WireMessage { commands.last(where: { $0.kind == "probe" })! }
    func endProbe(caps: [CodecCapabilities]? = nil, success: Bool = true, safe: Bool = true, id: UUID? = nil) {
        var event = WireMessage(success ? "stopped" : "failed", sessionID: id ?? lastProbe.sessionID)
        event.capabilities = caps ?? [lhdc]; event.restartSafe = safe
        event.details = ["probeComplete": success ? "true" : "false"]
        if !success { event.message = "offline failure" }
        client.receive(event)
    }
    func answerCodec(_ codec: UInt8 = 2) {
        guard let request = commands.last(where: { $0.kind == "oppoQuery" }) else { return }
        var event = WireMessage("oppoResult", requestID: request.requestID, sessionID: request.sessionID)
        event.device = request.device; var report = OppoProbeReport(); report.currentCodecID = codec; event.oppoReport = report
        var state = client.headset ?? HeadsetSnapshot(address: request.device!.address)
        state.connected = true; state.currentCodec = codec
        event.headset = state; event.controlGeneration = state.generation
        client.receive(event)
    }
    func cleanup() { client.quit(); prefs.removePersistentDomain(forName: suite) }
}
private func expect(_ ok: @autoclosure () -> Bool, _ name: String) {
    if !ok() { fatalError(name) }
    print("PASS " + name)
}
@main private struct DeviceLibraryTests {
    @MainActor static func main() {
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.observe(h.native)
            expect(h.client.registeredHeadphones.isEmpty && h.client.selectedAddress.isEmpty, "first launch does not adopt all paired devices or old selectedDevice")
            expect(!h.commands.contains(where: { $0.kind == "probe" || $0.kind == "start" }), "initial empty library sends no capability probe or playback")
            h.client.addHeadphone(h.x4)
            h.observe(h.native, request: h.commands.last!.requestID)
            expect(!h.commands.contains { $0.kind == "probe" }, "identity must close before codec probe")
            h.answerIdentity()
            expect(h.client.registeredHeadphones.isEmpty && h.lastProbe.gain == 0, "addition remains provisional until the silent capability probe finishes")
            h.endProbe(id: UUID())
            expect(h.client.registeredHeadphones.isEmpty && h.client.busy, "late unrelated probe cannot register a device")
            h.endProbe()
            expect(h.client.registeredHeadphones.count == 1 && h.client.registeredHeadphones[0].model == .encoX4, "matching complete capability probe registers and persists device")
            h.observe(h.native, request: h.commands.last!.requestID)
            let select = h.commands.last!
            expect(select.kind == "selectOutput" && select.environment?.route == h.native, "addition requests compare-and-set of real system output")
            var selected = WireMessage("outputSelected", requestID: select.requestID); selected.device = h.x4
            h.client.receive(selected); h.observe(h.native); h.answerCodec()
            expect(h.client.selectedAddress == h.x4.address && h.client.transportChoice == "system" && h.client.systemCodecLabel == "AAC · 系统", "native Enco route shows queried AAC, never cached LHDC")
            let count = h.commands.filter { $0.kind == "probe" }.count
            h.observe(h.native)
            expect(h.commands.filter { $0.kind == "probe" }.count == count, "cached capabilities do not reprobe on subsequent observations")
            expect(!h.commands.contains(where: { $0.kind == "start" }), "addition never starts HD playback")
            h.reload(); h.observe(h.native)
            expect(h.client.registeredHeadphones.count == 1 && h.client.probeComplete, "library and capabilities survive app restart")
        }
        // List enumeration followed by bounded identity only; codecs still require a selection.
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.client.scanConnectedDevices()
            let keyboard = BluetoothDevice(address: "00:11:22:33:44:88", name: "Keyboard", connected: true, a2dpSink: false)
            let audio = BluetoothDevice(address: h.computer.address, name: "Renamed Audio", connected: true, a2dpSink: false, nativeAudioOutput: true)
            h.observe(h.speaker, devices: [keyboard, audio, h.x4, h.xm5], request: h.commands.last!.requestID)
            expect(h.client.connectedAudioDevices.count == 3, "passive discovery filters keyboard and accepts native Bluetooth output")
            expect(h.commands.map(\.kind) == ["environment", "headsetUnwatch", "deviceIdentity"] && h.client.selectedAddress.isEmpty, "scan reads identity only, without codec, output or audio commands")
            h.answerIdentity()
            expect(h.client.discoveryModelName(h.x4) == "OPPO Enco X4" && h.client.discoveryLabel(h.x4) == "已适配", "list confirms model from product ID before selection")
            h.client.scanConnectedDevices(); h.observe(h.speaker, devices: [], request: h.commands.last!.requestID, details: ["bluetoothAuthorization":"2"])
            expect(!h.client.scanMessage.isEmpty && !h.client.scanningDevices, "permission denial is distinct from an empty device list")
        }
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            let renamed = BluetoothDevice(address: h.x4.address, name: "My Headphones", connected: true, a2dpSink: true, controlServices: h.x4.controlServices)
            let second = BluetoothDevice(address: "00:11:22:33:44:99", name: renamed.name, connected: true, a2dpSink: true, controlServices: h.x4.controlServices)
            h.client.scanConnectedDevices()
            h.observe(h.speaker, devices: [renamed, second, h.computer], request: h.commands.last!.requestID)
            let firstRequest = h.commands.last!
            expect(firstRequest.kind == "deviceIdentity" && firstRequest.device?.address == renamed.address, "renamed device is queried from service, not name")
            expect(!h.client.canAddDevice && !h.client.canEditSettings && !h.client.canPrepareAudioRestart, "identity holds all conflicting entry points until close")
            h.client.addHeadphone(second); h.client.start(); h.client.refreshAllHeadset()
            expect(h.commands.last?.requestID == firstRequest.requestID, "addition, playback and manual control cannot race identity")
            h.answerIdentity(request: firstRequest)
            let secondRequest = h.commands.last!
            expect(secondRequest.kind == "deviceIdentity" && secondRequest.device?.address == second.address && secondRequest.requestID != firstRequest.requestID, "second identical name starts only after first confirmed close")
            h.answerIdentity(product: 0x061410, request: firstRequest)
            expect(h.commands.last?.requestID == secondRequest.requestID && h.client.identifyingDevices, "late first response cannot complete next device")
            var wrongAddress = WireMessage("deviceIdentity", requestID: secondRequest.requestID); wrongAddress.device = renamed; wrongAddress.restartSafe = true
            h.client.receive(wrongAddress)
            expect(h.client.identifyingDevices, "wrong address cannot release identity owner")
            h.answerIdentity(product: 0x061410)
            expect(h.client.discoveryModelName(renamed) == "OPPO Enco X4" && h.client.discoveryModelName(second) == "OPPO Enco X", "same names resolve to independent product IDs")
            expect(h.client.canAddDevice && h.client.registeredHeadphones.isEmpty && h.client.selectedAddress.isEmpty, "list confirmation neither registers nor selects")
            expect(!h.commands.contains { ["probe", "start", "selectOutput", "headsetSet", "oppoSetHiRes"].contains($0.kind) }, "automatic identity never probes codecs, writes settings or changes output")
            h.client.addHeadphone(renamed); h.observe(h.speaker, devices: [renamed, second], request: h.commands.last!.requestID)
            expect(h.commands.last?.kind == "deviceIdentity" && h.commands.last?.requestID != firstRequest.requestID, "selection freshly verifies identity instead of authorizing from list cache")
            h.answerIdentity(); expect(h.lastProbe.device?.address == renamed.address, "selected device enters existing silent probe after fresh identity close")
        }
        for safe: Bool? in [true, false, nil] {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.client.scanConnectedDevices(); h.observe(h.speaker, request: h.commands.last!.requestID)
            h.answerIdentity(product: nil, safe: safe)
            expect(h.client.discoveryLabel(h.x4) == "型号确认失败" && h.client.discoveryModelName(h.x4) == nil, "failed ID remains failure, not unsupported \(String(describing: safe))")
            expect(h.client.canAddDevice == (safe == true), "unconfirmed close never releases addition \(String(describing: safe))")
            let count = h.commands.count; h.observe(h.speaker)
            expect(h.commands.count == count, "identity failure never automatically loops \(String(describing: safe))")
            if safe != true { h.client.start(); h.client.selectHeadphone(.init(address: h.xm5.address, model: .wh1000xm5)); expect(h.commands.count == count, "unsafe close also blocks playback and output selection") }
        }
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.client.scanConnectedDevices(); h.observe(h.speaker, request: h.commands.last!.requestID)
            h.answerIdentity(product: 0xabcdef)
            expect(h.client.discoveryLabel(h.x4) == "未适配" && h.client.discoveryModelName(h.x4)?.contains("ABCDEF") == true, "unknown actual product overrides recognized Bluetooth name")
            expect(!h.client.supportsHeadsetControl, "list identity grants no persistent controls")
            h.client.scanConnectedDevices(); h.observe(h.speaker, request: h.commands.last!.requestID); h.answerIdentity()
            expect(h.commands.filter { $0.kind == "deviceIdentity" }.count == 2, "explicit refresh rechecks product ID")
            h.observe(h.speaker, devices: [h.computer])
            expect(h.client.discoveryModelName(h.x4) == nil, "disconnect invalidates confirmed list identity")
        }
        for reason in ["close", "sleep", "timeout", "disconnect"] {
            let h = LibraryHarness(); defer { h.cleanup() }
            let second = BluetoothDevice(address: h.xm5.address, name: "Other", connected: true, a2dpSink: true, controlServices: h.x4.controlServices)
            h.client.scanConnectedDevices(); h.observe(h.speaker, devices: [h.x4, second], request: h.commands.last!.requestID)
            let request = h.commands.last!
            switch reason {
            case "close": h.client.endDeviceDiscovery()
            case "sleep": h.client.receive(WireMessage("systemSleep"))
            case "timeout": h.timeouts.last!()
            default: h.observe(h.speaker, devices: [second])
            }
            expect(h.commands.contains { $0.kind == "headsetCancel" && $0.requestID == request.requestID } && !h.client.canAddDevice, "\(reason) cancels and waits for safe close")
            expect(h.commands.filter { $0.kind == "deviceIdentity" }.count == 1, "\(reason) does not advance while cleanup is pending")
            h.answerIdentity(request: request)
            expect(h.client.discoveryModelName(h.x4) == nil, "\(reason) discards canceled identity")
            if ["close", "sleep"].contains(reason) {
                expect(h.commands.filter { $0.kind == "deviceIdentity" }.count == 1 && !h.client.identifyingDevices, "\(reason) stops the remaining queue")
            } else {
                expect(h.commands.last?.kind == "deviceIdentity" && h.commands.last?.device?.address == second.address, "\(reason) advances only after confirmed cleanup")
                h.answerIdentity()
            }
        }
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.client.busy = true
            h.client.scanConnectedDevices(); h.observe(h.speaker, request: h.commands.last!.requestID, transition: true)
            expect(h.commands.map(\.kind) == ["environment"] && !h.client.discoveryMessage.isEmpty, "busy list stays passive and shows waiting state")
            h.client.busy = false; h.observe(h.speaker, transition: true)
            expect(h.commands.count == 1, "audio cleanup transition blocks identity even after App becomes idle")
            h.client.headsetBusy = true; h.observe(h.speaker)
            expect(h.commands.count == 1, "existing control read or write finishes before list identity")
            h.client.headsetBusy = false; h.client.receive(WireMessage("offlineTick"))
            expect(h.commands.last?.kind == "deviceIdentity", "idle terminal resumes pending list confirmation without polling")
            h.answerIdentity(); h.client.endDeviceDiscovery()
        }
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.client.scanConnectedDevices(); let request = h.commands.last!
            h.client.endDeviceDiscovery(); h.observe(h.native, request: request.requestID)
            expect(h.commands.count == 1, "closing before enumeration prevents late identity and output synchronization")
            h.client.scanConnectedDevices(); let late = h.commands.last!; h.timeouts.last!()
            h.observe(h.native, request: late.requestID)
            expect(h.commands.count == 2 && !h.client.scanningDevices, "late timed-out enumeration cannot trigger identity or auto probe")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec(); h.client.watchHeadset()
            let watch = h.commands.last!
            var reply = WireMessage("headsetResult", requestID: watch.requestID)
            reply.device = h.x4
            var snapshot = HeadsetSnapshot(address: h.x4.address)
            snapshot.connected = true; snapshot.productID = 0x06ec10; snapshot.serviceUUID = HeadsetDialect.elnk079A.rawValue; snapshot.currentCodec = 2
            reply.headset = snapshot; reply.controlGeneration = snapshot.generation
            h.client.receive(reply)
            expect(!h.client.headsetBusy, "existing watch settled before list identity")
            let before = h.client.headset
            let commandCount = h.commands.count
            h.client.scanConnectedDevices(); h.observe(h.native, request: h.commands.last!.requestID)
            expect(h.commands.dropFirst(commandCount).map(\.kind) == ["environment"], "opening add with registered headphones only never interrupts or rebuilds the existing watch")
            expect(h.client.headset == before && h.client.headsetDisplaySnapshot == before && h.client.canControlHeadset, "registered native-codec headphone preserves live state and controls while opening add")
            expect(h.client.systemCodecLabel == "AAC · 系统" && h.client.discoveryLabel(h.x4) == "已添加" && h.client.discoveryModelName(h.x4) == "OPPO Enco X4", "registered row retains its known model and current native codec")
            h.client.scanConnectedDevices(); h.observe(h.native, request: h.commands.last!.requestID)
            h.client.endDeviceDiscovery()
            expect(h.commands.dropFirst(commandCount).map(\.kind) == ["environment", "environment"] && h.client.headset == before, "refresh and close of registered-only list also preserve the watch")
            let candidate = BluetoothDevice(address: "00:11:22:33:44:99", name: "New headphones", connected: true, a2dpSink: true, controlServices: h.x4.controlServices)
            h.client.scanConnectedDevices(); h.observe(h.native, devices: [h.x4, candidate], request: h.commands.last!.requestID)
            expect(h.client.identifyingDevices && !h.client.canControlHeadset, "identity suspends existing control watch without changing route")
            expect(h.commands.last?.kind == "deviceIdentity" && h.commands.last?.device?.address == candidate.address, "only unregistered candidate requires a fresh product identity")
            let watchCount = h.commands.filter { $0.kind == "headsetWatch" }.count
            h.answerIdentity()
            expect(h.commands.filter { $0.kind == "headsetWatch" }.count == watchCount + 1 && h.commands.last?.device?.address == h.x4.address, "last identity close restores previously requested watch for selected address")
            expect(!h.commands.contains { ["probe", "start", "selectOutput"].contains($0.kind) }, "watch restoration never restarts or redirects audio")
        }
        for duringIdentity in [false, true] {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.client.scanConnectedDevices(); let scan = h.commands.last!
            if duringIdentity { h.observe(h.speaker, request: scan.requestID) }
            let pending = h.commands.last!
            h.client.endDeviceDiscovery(); h.client.scanConnectedDevices()
            if duringIdentity {
                expect(h.commands.last?.kind == "headsetCancel", "reopened list waits for canceled identity cleanup")
                h.answerIdentity(request: pending)
                expect(h.commands.last?.kind == "environment", "reopened list starts a fresh scan after safe close")
                h.observe(h.speaker, request: h.commands.last!.requestID)
            } else {
                expect(h.commands.count == 1, "reopened list reuses pending passive enumeration")
                h.observe(h.speaker, request: scan.requestID)
            }
            expect(h.commands.last?.kind == "deviceIdentity" && h.client.identifyingDevices, "quick reopening resumes identification \(duringIdentity)")
            h.answerIdentity()
            expect(h.client.discoveryModelName(h.x4) == "OPPO Enco X4" && h.client.canAddDevice, "reopened result is fresh and usable \(duringIdentity)")
        }
        for variant in 0..<6 {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.observe(h.speaker)
            h.client.addHeadphone(h.computer); h.observe(h.speaker, request: h.commands.last!.requestID)
            let oldLHDC = try! CapabilityParser.codec(endpoint: 2, bytes: [0,255,0x3a,5,0,0,0x32,0x4c,0x30,6,0x11,0,0])
            let caps = [[h.ldac], [h.lhdc], [h.ldac,h.lhdc], [], [oldLHDC], []][variant]
            h.endProbe(caps: caps, success: variant != 5)
            expect(h.client.registeredHeadphones.count == 1 && h.client.registeredHeadphones[0].model == nil, "unknown device saved independently of codec variant \(variant)")
            expect(!h.client.supportsHeadsetControl && !h.client.canQueryOppo && !h.client.canControlHeadset, "unknown device has no persistent or writable OPPO controls \(variant)")
            expect(!h.commands.contains { $0.kind == "deviceIdentity" || $0.kind == "oppoQuery" || $0.kind == "headsetWatch" || $0.kind == "start" }, "unknown addition never probes private control or starts audio \(variant)")
            h.reload(); h.observe(.init(uid: h.computer.address, bluetoothAddress: h.computer.address))
            expect(h.client.codecProbeState.status == (variant == 5 ? .failed : .complete), "complete-empty and failed survive reload distinctly \(variant)")
            expect(h.commands.filter { $0.kind == "probe" }.count == 1, "empty or failed codec cache does not reprobe \(variant)")
            expect(h.client.availableHDCodecs.count == (variant == 2 ? 2 : variant < 2 ? 1 : 0), "only implemented codecs offered \(variant)")
            if variant < 3 {
                h.client.start(); let start = h.commands.last { $0.kind == "start" }!
                var active = WireMessage("active", sessionID: start.sessionID); active.configuration = start.configuration; h.client.receive(active)
                expect(!h.commands.contains { $0.kind == "oppoQuery" || $0.kind == "headsetListen" }, "unknown HD active skips all control recovery")
                h.client.scanConnectedDevices()
                expect(h.commands.last?.kind == "environment" && !h.client.canAddDevice, "HD allows passive list refresh but blocks addition")
            }
        }
        for safe in [false, true] {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.observe(h.speaker); h.client.addHeadphone(h.x4); h.observe(h.speaker, request: h.commands.last!.requestID)
            h.answerIdentity(product: 0xabcdef, safe: safe)
            expect(h.commands.contains(where: { $0.kind == "probe" }) == safe, "identity cleanup gates probe \(safe)")
            if safe {
                h.endProbe(caps: []); expect(h.client.registeredHeadphones.first?.profile == nil, "unrecognized product does not adopt name hint")
            } else { expect(h.client.registeredHeadphones.isEmpty, "unsafe identity cleanup cannot save") }
        }
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.observe(h.speaker); h.client.addHeadphone(h.computer); h.observe(h.speaker, request: h.commands.last!.requestID)
            var partial = WireMessage("stopped", sessionID: h.lastProbe.sessionID)
            partial.restartSafe = true; partial.capabilities = [h.ldac]; partial.details = ["probeComplete":"true", "endpointsFailed":"1"]
            h.client.receive(partial); h.reload(); h.observe(.init(uid: h.computer.address, bluetoothAddress: h.computer.address))
            expect(h.client.codecProbeState.status == .failed && h.client.codecProbeState.error != nil && h.client.availableHDCodecs == [.ldac] && h.client.probeComplete, "partial endpoint failure persists separately and retains confirmed usable codecs")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native)
            var state = HeadsetSnapshot(address: h.x4.address); state.productID = 0xffffff; state.connected = true
            h.client.headset = state
            expect(!h.client.supportsHeadsetControl && !h.client.canControlHeadset, "fresh unknown product overrides migrated X4 hint")
        }
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.observe(h.speaker); h.client.addHeadphone(h.x4); h.observe(h.speaker, request: h.commands.last!.requestID)
            h.observe(h.speaker, devices: []); h.answerIdentity()
            expect(h.client.registeredHeadphones.isEmpty && !h.commands.contains { $0.kind == "probe" || $0.kind == "selectOutput" }, "disconnect while identity closes cannot begin codec discovery or select output")
        }
        for failure in 0..<3 {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.observe(h.speaker); h.client.addHeadphone(h.x4); h.observe(h.speaker, request: h.commands.last!.requestID); h.answerIdentity()
            h.endProbe(caps: failure == 0 ? [h.ldac] : [h.lhdc], success: failure != 1, safe: failure != 2)
            expect(h.client.registeredHeadphones.count == (failure == 2 ? 0 : 1), "either codec and safe failed detection save system device; unsafe cleanup rejects \(failure)")
            h.observe(h.speaker)
            expect(h.commands.filter { $0.kind == "probe" }.count == 1, "failed addition does not auto retry \(failure)")
        }
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.observe(h.speaker); h.client.addHeadphone(h.x4)
            let disconnected = BluetoothDevice(address: h.x4.address, name: h.x4.name, connected: false, a2dpSink: true)
            h.observe(h.speaker, devices: [disconnected,h.xm5,h.computer], request: h.commands.last!.requestID)
            expect(!h.client.libraryActionBusy && !h.commands.contains(where: { $0.kind == "probe" }), "addition never reconnects disconnected or unrelated devices")
            h.client.addHeadphone(h.x4)
            let duplicate = BluetoothDevice(address: "00:11:22:33:44:99", name: h.x4.name, connected: true, a2dpSink: true)
            h.observe(h.speaker, devices: [h.x4,duplicate], request: h.commands.last!.requestID)
            h.answerIdentity(); expect(h.lastProbe.device?.address == h.x4.address, "duplicate names do not change the explicitly selected address")
            h.client.cancelAddingDevice(); h.endProbe(); expect(h.client.registeredHeadphones.isEmpty, "cancelled add does not save or select output")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec()
            expect(h.client.probeComplete && h.commands.filter { $0.kind == "probe" }.isEmpty, "existing library loads cached capabilities")
            h.observe(.init(uid: h.xm5.address, bluetoothAddress: h.xm5.address))
            expect(h.client.selectedAddress == h.xm5.address && h.client.capability?.codec == .ldac && h.client.transportChoice == "system", "external output changes switch selection and per-device capabilities")
            h.observe(h.speaker)
            expect(h.client.selectedAddress.isEmpty && h.client.selectedOutputAddress == nil, "system speakers deselect all headphone icons without adding a speaker")
            let disconnected = BluetoothDevice(address: h.xm5.address, name: h.xm5.name, connected: false, a2dpSink: true)
            h.observe(h.speaker, devices: [h.x4,disconnected]); let count = h.commands.count
            h.client.selectHeadphone(h.client.registeredHeadphones[1])
            expect(h.commands.count == count && !h.client.isConnected(h.client.registeredHeadphones[1]), "disconnected icon cannot trigger output change")
            h.client.selectHeadphone(h.client.registeredHeadphones[0])
            h.observe(h.speaker, request: h.commands.last!.requestID)
            let select = h.commands.last!; expect(select.kind == "selectOutput", "click connected icon requests actual output switch")
            var refused = WireMessage("outputSelected", requestID: select.requestID); refused.message = "system route changed"
            h.client.receive(refused); h.observe(h.speaker)
            expect(h.client.selectedAddress.isEmpty && !h.client.libraryActionBusy, "failed system route confirmation cannot leave a falsely selected icon")
        }
        do {
            let h = LibraryHarness(library: true); defer { h.cleanup() }
            // Only X4 connected: missing cache should trigger once, then not spin after failure.
            h.observe(h.native, devices: [h.x4])
            expect(h.commands.filter { $0.kind == "probe" }.count == 1, "connected registered headset without cache detects automatically")
            h.endProbe(success: false); h.observe(h.native, devices: [h.x4]); h.observe(h.native, devices: [h.x4])
            expect(h.commands.filter { $0.kind == "probe" }.count == 1, "automatic detection failure does not loop")
            h.observe(h.speaker, devices: []); h.observe(h.native, devices: [h.x4])
            expect(h.commands.filter { $0.kind == "probe" }.count == 1, "failed detection is explicit and does not loop after reconnect; user can retry")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec(); h.client.chooseCodec(CodecID.lhdcV5.rawValue)
            let start = h.commands.last(where: { $0.kind == "start" })!
            h.observe(h.speaker, session: start.sessionID, transition: true)
            expect(h.client.busy && h.client.transportChoice == CodecID.lhdcV5.rawValue, "temporary takeover route cannot cancel HD startup")
            var active = WireMessage("active", sessionID: start.sessionID); active.configuration = start.configuration
            active.format = start.configuration?.format; h.client.receive(active); h.answerCodec(8)
            h.observe(.init(uid: AudioIdentifiers.virtualOutputUID, isVirtual: true), session: start.sessionID)
            expect(h.client.active && h.client.selectedOutputAddress == h.x4.address, "virtual system output keeps the correct playing headphone selected")
            let beforeSameSelection = h.commands.count
            h.client.selectHeadphone(h.client.registeredHeadphones[0])
            expect(h.client.active && h.commands.count == beforeSameSelection, "clicking the already selected headphone preserves HD playback")
            h.client.selectHeadphone(h.client.registeredHeadphones[1])
            expect(h.commands.last!.kind == "stop" && !h.commands.contains(where: { $0.kind == "selectOutput" }), "switching headphones during HD waits for ordered teardown")
            var stopped = WireMessage("stopped", sessionID: start.sessionID); stopped.restartSafe = true
            h.client.receive(stopped); h.observe(h.native, request: h.commands.last!.requestID)
            expect(h.commands.last!.kind == "selectOutput" && h.commands.last!.device == h.xm5, "after teardown the requested headphone becomes the real output target")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec(); h.client.chooseCodec(CodecID.lhdcV5.rawValue)
            let start = h.commands.last(where: { $0.kind == "start" })!
            var active = WireMessage("active", sessionID: start.sessionID); active.configuration = start.configuration; h.client.receive(active)
            h.observe(h.speaker, session: start.sessionID)
            expect(!h.client.active && h.commands.last!.kind == "stop", "external system output takeover stops HD without auto-reconnect")
            var stopped = WireMessage("stopped", sessionID: start.sessionID); stopped.restartSafe = true; h.client.receive(stopped)
            h.observe(h.speaker)
            expect(h.client.transportChoice == "system" && h.client.selectedAddress.isEmpty, "external route wins after cleanup")
            let before = h.client.environment!
            var stale = WireMessage("environment"); stale.environment = before; stale.environment?.route = h.native
            h.client.receive(stale)
            stale.environment?.generation = UUID(); stale.environment?.revision += 1; h.client.receive(stale)
            expect(h.client.environment == before, "old revision and retired engine generation cannot overwrite system state")
        }
        do {
            let h = LibraryHarness(); defer { h.cleanup() }
            h.observe(h.speaker); h.client.addHeadphone(h.x4)
            let request = h.commands.last!.requestID
            h.timeouts.last!()
            expect(!h.client.libraryActionBusy && h.client.registeredHeadphones.isEmpty, "device lookup timeout releases the UI")
            h.observe(h.native, request: request)
            expect(!h.commands.contains(where: { $0.kind == "probe" }), "late reply after timeout cannot start adding")
            h.client.addHeadphone(h.x4); h.observe(h.native, request: h.commands.last!.requestID); h.answerIdentity()
            h.client.receive(WireMessage("systemSleep")); h.endProbe()
            expect(h.client.registeredHeadphones.isEmpty, "sleep cancels provisional addition even if a late successful probe arrives")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec(); h.client.chooseCodec(CodecID.lhdcV5.rawValue)
            let start = h.commands.last(where: { $0.kind == "start" })!
            var failed = WireMessage("failed", sessionID: start.sessionID)
            failed.playbackFailure = .deviceNotReady; failed.restartSafe = true; h.client.receive(failed)
            expect(!h.recoveries.isEmpty && h.client.busy, "transient failure keeps existing delayed reconnect policy")
            h.observe(h.native)
            expect(h.client.busy, "safe native restoration does not cancel delayed reconnect")
            h.observe(h.speaker)
            let count = h.commands.filter { $0.kind == "start" }.count
            h.recoveries.last!()
            expect(!h.client.busy && h.client.selectedAddress.isEmpty && h.commands.filter { $0.kind == "start" }.count == count, "system takeover during retry delay cancels continuation without stealing output")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec()
            h.client.removeHeadphone(h.client.registeredHeadphones[0])
            expect(h.client.registeredHeadphones.count == 1 && h.prefs.data(forKey: "device." + h.x4.address) == nil, "native deletion clears only that device")
            expect(h.client.selectedAddress.isEmpty && !h.commands.contains { $0.kind == "selectOutput" }, "native deletion leaves Bluetooth output connected")
            h.reload(); expect(h.client.registeredHeadphones.count == 1, "deletion persists")
        }
        for safe in [false, true] {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec(); h.client.chooseCodec(CodecID.lhdcV5.rawValue)
            let start = h.commands.last(where: { $0.kind == "start" })!
            var active = WireMessage("active", sessionID: start.sessionID); active.configuration = start.configuration
            active.format = start.configuration?.format; h.client.receive(active); h.answerCodec(8)
            h.client.removeHeadphone(h.client.registeredHeadphones[0])
            expect(h.client.localDataBusy && h.client.registeredHeadphones.count == 2 && h.commands.last?.kind == "stop", "HD deletion first waits for cleanup")
            var final = WireMessage(safe ? "stopped" : "failed", sessionID: start.sessionID); final.restartSafe = safe
            if !safe { final.message = "cleanup failed" }
            h.client.receive(final)
            expect(h.client.registeredHeadphones.count == (safe ? 1 : 2) && !h.client.localDataBusy, "deletion commits only after safe route cleanup")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec(); h.client.appearance = .dark
            h.prefs.set("old record", forKey: "arbitrary.old.record")
            h.prefs.set(true, forKey: HighBitrateWarning.suppressionKey)
            expect(!h.client.highBitrateWarningEnabled, "warning suppression present before reset")
            h.client.clearApplicationData()
            expect(h.client.localDataBusy && h.fileClears == 0 && h.commands.last?.kind == "quit", "reset awaits complete engine termination")
            h.observe(h.native); expect(h.fileClears == 0, "late observation cannot finish reset")
            h.client.finishApplicationReset(exitStatus: 0)
            expect(h.client.highBitrateWarningEnabled, "successful reset restores high bitrate warning immediately")
            expect(h.fileClears == 1 && h.client.registeredHeadphones.isEmpty && !h.client.localDataBusy, "reset clears after quiescing")
            expect(h.prefs.persistentDomain(forName: h.suite)?.isEmpty != false && h.client.appearance == .system && h.client.gain == 1 && h.client.catchupLimitTenths == 50, "all app records removed and defaults restored")
            h.reload(); expect(h.client.registeredHeadphones.isEmpty && h.client.capabilities.isEmpty, "reset survives restart")
            expect(h.client.highBitrateWarningEnabled, "restored warning survives restart")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.prefs.set(true, forKey: HighBitrateWarning.suppressionKey)
            h.observe(h.native); h.answerCodec(); h.client.clearApplicationData(); h.client.finishApplicationReset(exitStatus: 1)
            expect(!h.client.highBitrateWarningEnabled, "failed reset preserves warning preference")
            expect(h.fileClears == 0 && h.client.registeredHeadphones.count == 2 && !h.client.localDataBusy, "failed teardown preserves data")
        }
        do {
            let h = LibraryHarness(library: true, cache: true); defer { h.cleanup() }
            h.observe(h.native); h.answerCodec(); h.client.chooseCodec(CodecID.lhdcV5.rawValue)
            let start = h.commands.last(where: { $0.kind == "start" })!
            h.client.clearApplicationData()
            expect(h.commands.last?.kind == "stop" && h.fileClears == 0, "reset during connection waits for audio cleanup")
            var final = WireMessage("stopped", sessionID: start.sessionID); final.restartSafe = false
            h.client.receive(final)
            expect(!h.client.localDataBusy && h.fileClears == 0 && h.client.registeredHeadphones.count == 2, "explicit unsafe stopped event cannot clear application data")
        }
        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("SonoFerry-ResetTests-" + UUID().uuidString)
            defer { try? fm.removeItem(at: root) }
            do {
                for relative in ["Caches/SonoFerry/Sessions", "Caches/local.SonoFerry", "Application Support/SonoFerry", "Saved Application State/local.SonoFerry.savedState", "Caches/UnrelatedApp"] {
                    let folder = root.appendingPathComponent(relative); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data([1]).write(to: folder.appendingPathComponent("record"))
                }
                try ApplicationData.clearFiles(in: root)
                expect(!fm.fileExists(atPath: root.appendingPathComponent("Caches/SonoFerry").path) && !fm.fileExists(atPath: root.appendingPathComponent("Saved Application State/local.SonoFerry.savedState").path), "app caches and restoration files cleared")
                expect(fm.fileExists(atPath: root.appendingPathComponent("Caches/UnrelatedApp/record").path), "reset never deletes unrelated application data")
            } catch { fatalError("scoped reset failed: \(error)") }
        }
        print("Device library, passive discovery, output synchronization and cache tests passed")
    }
}
