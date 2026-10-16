import Foundation

/// The setup catalogue is a UI filter only. Playback still requires queried AVDTP endpoints.
public enum HeadphoneModel: String, Codable, CaseIterable, Sendable {
    case encoX4, wh1000xm5
    public var title: String { self == .encoX4 ? "Enco X4" : "WH-1000XM5" }
    public var displayTitle: String { title + (self == .wh1000xm5 ? "（实验性）" : "") }
    public var symbol: String { self == .encoX4 ? "earbuds" : "headphones" }
    public var codec: CodecID { self == .encoX4 ? .lhdcV5 : .ldac }
    public func matches(_ device: BluetoothDevice) -> Bool {
        let name = device.name.lowercased().filter { $0.isLetter || $0.isNumber }
        return name.contains(self == .encoX4 ? "encox4" : "wh1000xm5")
    }
}
public struct RegisteredHeadphone: Codable, Equatable, Identifiable, Sendable {
    public let address: String
    public var model: HeadphoneModel?
    public var name: String?
    public var identity: HeadsetIdentity?
    public var id: String { address }
    public var profile: HeadphoneProfile? { if let identity { return identity.profile }; return model == .encoX4 ? HeadphoneProfile.find(0x06ec10) : nil }
    public var displayTitle: String { name ?? model?.displayTitle ?? profile?.name ?? address }
    public var symbol: String { model?.symbol ?? "earbuds" }
    public init(address: String, model: HeadphoneModel? = nil, name: String? = nil, identity: HeadsetIdentity? = nil) {
        self.address = address; self.model = model; self.name = name; self.identity = identity
    }
}
/// A read-only observation of the actual default output. PCM rate never identifies a Bluetooth codec.
public struct OutputRoute: Codable, Equatable, Sendable {
    public var uid: String?
    public var bluetoothAddress: String?
    public var isVirtual: Bool
    public var sampleRate: Double?
    public init(uid: String?, bluetoothAddress: String? = nil, isVirtual: Bool = false, sampleRate: Double? = nil) {
        self.uid = uid; self.bluetoothAddress = bluetoothAddress; self.isVirtual = isVirtual; self.sampleRate = sampleRate
    }
}
public struct DeviceEnvironment: Codable, Equatable, Sendable {
    public var generation: UUID
    public var revision: UInt64
    public var devices: [BluetoothDevice]
    public var route: OutputRoute
    public var audioSessionID: UUID?
    public var transitioning: Bool
    public init(generation: UUID, revision: UInt64, devices: [BluetoothDevice], route: OutputRoute,
                audioSessionID: UUID? = nil, transitioning: Bool = false) {
        self.generation = generation; self.revision = revision; self.devices = devices; self.route = route
        self.audioSessionID = audioSessionID; self.transitioning = transitioning
    }
}
