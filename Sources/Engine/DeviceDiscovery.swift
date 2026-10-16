import Foundation
import IOBluetooth
import CoreBluetooth
import SonoFerryCore

extension IOBluetoothDevice {
    func isClassicConnected() -> Bool {
        let selector = NSSelectorFromString("classicPeer")
        guard responds(to: selector), let peer = perform(selector)?.takeUnretainedValue() as? NSObject,
              peer.responds(to: NSSelectorFromString("state")) else { return isConnected() }
        return (peer.value(forKey: "state") as? NSNumber)?.intValue == 2
    }
}

@MainActor
final class DeviceDiscovery: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    var stateChanged: (() -> Void)?
    func requestAccess() { if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) } }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { stateChanged?() }
    static var bluetoothAuthorization: String { String(CBManager.authorization.rawValue) }
    static func paired() -> [BluetoothDevice] {
        let uuid = IOBluetoothSDPUUID(uuid16: 0x110b)!
        return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
            guard let address = BluetoothIdentity.normalizedAddress(device.addressString ?? "") else { return nil }
            let connected = device.isClassicConnected(), sink = device.getServiceRecord(for: uuid) != nil
            return BluetoothDevice(address: address, name: device.name ?? address,
                connected: connected, a2dpSink: sink,
                nativeAudioOutput: connected && !sink ? SystemAudio.nativeOutput(address: address) != nil : nil,
                controlServices: HeadsetDialect.allCases.filter { dialect in
                    let service = dialect.serviceBytes.withUnsafeBytes { IOBluetoothSDPUUID(bytes: $0.baseAddress!, length: $0.count) }
                    return device.getServiceRecord(for: service) != nil
                }.map(\.rawValue))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func diagnostics() -> [String: String] {
        let device = IOBluetoothDevice(addressString: "00:00:00:00:00:00")
        return ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bluetoothAuthorization": bluetoothAuthorization,
            "controllerAvailable": String(IOBluetoothHostController.default() != nil),
            "classicPeerSelector": String(device?.responds(to: NSSelectorFromString("classicPeer")) == true),
            "driverRevision": (try? LDACNativeOutput.driverRevision()).map(String.init) ?? "not-loaded",
            "hardwareAcceptance": "pending: WH-1000XM5 LDAC and Enco X4 LHDC V5"]
    }
}
