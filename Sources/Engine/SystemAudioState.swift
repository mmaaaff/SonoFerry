import Foundation
import CoreAudio
import AudioToolbox
import SonoFerryCore

/// Native Bluetooth output and our HAL output are separate Core Audio devices.
enum SystemAudio {
    static let virtualMainVolume: AudioObjectPropertySelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    static func property(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static func read<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, output: Bool = false) -> T? {
        var property = property(selector, output: output), value = initial, size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!) }
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }
    static func array<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, output: Bool = false) -> [T] {
        var property = property(selector, output: output), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0,
              size <= 65536, Int(size) % MemoryLayout<T>.stride == 0 else { return [] }
        var values = Array(repeating: initial, count: Int(size) / MemoryLayout<T>.stride)
        let capacity = size
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size <= capacity else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }
    static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard let value = read(device, selector, Optional<Unmanaged<CFString>>.none) ?? nil else { return nil }
        return value.takeRetainedValue() as String
    }
    static func writable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var property = property(selector, output: true), settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
    }
    static func devices() -> [AudioObjectID] { array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioObjectID(0)) }
    static func nativeOutput(address: String) -> AudioObjectID? {
        guard let target = BluetoothIdentity.normalizedAddress(address) else { return nil }
        return devices().first { device in
            guard read(device, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBluetooth,
                  let uid = string(device, kAudioDevicePropertyDeviceUID), uid.count >= 17,
                  uid.count == 17 || uid.dropFirst(17).first == ":",
                  BluetoothIdentity.normalizedAddress(String(uid.prefix(17))) == target,
                  !array(device, kAudioDevicePropertyStreams, AudioObjectID(0), output: true).isEmpty else { return false }
            return read(device, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) == 1
        }
    }
    static func currentRoute() -> OutputRoute {
        guard let id = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
              id != 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return .init(uid: nil) }
        var address: String?
        if read(id, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBluetooth,
           uid.count >= 17, uid.count == 17 || uid.dropFirst(17).first == ":" {
            address = BluetoothIdentity.normalizedAddress(String(uid.prefix(17)))
        }
        let rate = read(id, kAudioDevicePropertyNominalSampleRate, Float64(0))
        return .init(uid: uid, bluetoothAddress: address, isVirtual: uid == AudioIdentifiers.virtualOutputUID,
                     sampleRate: rate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }
    /// One compare-and-set; no retries that could override a later system selection.
    static func selectNative(address: String, expectedUID: String?) throws {
        guard let expectedUID, currentRoute().uid == expectedUID else { throw ProtocolFailure("系统输出已变化，请重新选择耳机。") }
        guard let id = nativeOutput(address: address) else { throw ProtocolFailure("尚未找到耳机的系统音频输出，请连接耳机蓝牙后重试。") }
        if currentRoute().bluetoothAddress == BluetoothIdentity.normalizedAddress(address) { return }
        var property = property(kAudioHardwarePropertyDefaultOutputDevice), value = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value)
        guard status == noErr else { throw ProtocolFailure("系统音频输出切换失败（\(status)）。") }
    }
    static func snapshot(address: String) -> SystemAudioState {
        let own = devices().first { string($0, kAudioDevicePropertyDeviceUID) == AudioIdentifiers.virtualOutputUID }
        func endpoint(_ id: AudioObjectID) -> AudioEndpointState {
            let ranges = array(id, kAudioDevicePropertyAvailableNominalSampleRates, AudioValueRange())
            let rates = ranges.filter { $0.mMinimum == $0.mMaximum && $0.mMinimum.isFinite && $0.mMinimum > 0 }.map(\.mMinimum)
            let rate = read(id, kAudioDevicePropertyNominalSampleRate, Float64(0))
            return .init(sampleRate: rate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, availableRates: rates,
                         volumeWritable: writable(id, virtualMainVolume))
        }
        let current = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        return .init(nativeOutput: nativeOutput(address: address).map(endpoint), virtualOutput: own.map(endpoint), defaultIsVirtual: own != nil && own == current)
    }
}
