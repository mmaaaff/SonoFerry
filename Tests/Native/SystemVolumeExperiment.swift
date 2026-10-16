import Foundation
import CoreAudio
import SonoFerryCore

/// Diagnostic for ordinary system-managed A2DP only, not SonoFerry HD playback.
/// The native Core Audio endpoint disappears during SonoFerry handoff.
/// A Core Audio readback confirms the local property, not a radio-level ACK.
@MainActor
final class HardwareVolumeLink {
    enum Event { case changed(Double), failed(String) }
    private var device: AudioObjectID = 0
    private var address = ""
    private var generation = UUID()
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var monitor: Task<Void, Never>?
    private var latest: Double?
    private let changed: (Event) -> Void
    init(changed: @escaping (Event) -> Void) { self.changed = changed }

    func start(address: String, volume: Double) async throws -> Double {
        stop(); self.address = address
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while SystemAudio.nativeOutput(address: address) == nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ProtocolFailure("当前连接没有可用的系统蓝牙音量接口；请关闭音量绑定后重试。") }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard let endpoint = SystemAudio.nativeOutput(address: address),
              SystemAudio.writable(endpoint, SystemAudio.virtualMainVolume) else {
            throw ProtocolFailure("耳机当前未提供可写的系统蓝牙音量；请关闭音量绑定后重试。")
        }
        device = endpoint
        let applied = try setVolume(volume)
        let token = generation
        for selector in [SystemAudio.virtualMainVolume, kAudioDevicePropertyMute] {
            var property = SystemAudio.property(selector, output: true)
            guard AudioObjectHasProperty(device, &property) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh(token: token) }
            }
            guard AudioObjectAddPropertyListenerBlock(device, &property, .main, block) == noErr else {
                throw ProtocolFailure("无法监听耳机音量变化，音量绑定未启用。")
            }
            listeners.append((device, property, block))
        }
        // Also catches a removed/replaced device even when property callbacks stop.
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                self?.refresh(token: token)
            }
        }
        return applied
    }
    func setVolume(_ value: Double) throws -> Double {
        guard value.isFinite, (0...1).contains(value), device != 0,
              SystemAudio.nativeOutput(address: address) == device else { throw ProtocolFailure("耳机音量接口已失效，高清协议已停用。") }
        try write(SystemAudio.virtualMainVolume, Float32(value))
        if SystemAudio.writable(device, kAudioDevicePropertyMute) { try write(kAudioDevicePropertyMute, UInt32(value == 0 ? 1 : 0)) }
        let confirmed = try readVolume()
        // Never release full-scale PCM if a mute/decrease was not reflected locally.
        guard confirmed <= value + 1.0 / 127.0, value != 0 || confirmed == 0 else {
            throw ProtocolFailure("系统未确认所请求的耳机音量，已保持静音并停用高清协议。")
        }
        latest = confirmed
        return confirmed
    }
    private func readVolume() throws -> Double {
        guard device != 0, SystemAudio.nativeOutput(address: address) == device,
              let scalar = SystemAudio.read(device, SystemAudio.virtualMainVolume, Float32(0), output: true),
              scalar.isFinite, (0...1).contains(scalar) else { throw ProtocolFailure("无法读取耳机系统音量，高清协议已停用。") }
        let muted = SystemAudio.read(device, kAudioDevicePropertyMute, UInt32(0), output: true) ?? 0
        return muted != 0 ? 0 : Double(scalar)
    }
    private func write<T>(_ selector: AudioObjectPropertySelector, _ value: T) throws {
        var property = SystemAudio.property(selector, output: true), value = value
        let status = withUnsafeBytes(of: &value) { AudioObjectSetPropertyData(device, &property, 0, nil, UInt32($0.count), $0.baseAddress!) }
        guard status == noErr else { throw ProtocolFailure("设置耳机系统音量失败（\(status)），高清协议已停用。") }
    }
    private func refresh(token: UUID) {
        guard token == generation, device != 0 else { return }
        do {
            let value = try readVolume()
            if latest.map({ abs($0 - value) > 0.0001 }) ?? true { latest = value; changed(.changed(value)) }
        } catch { stop(); changed(.failed(error.localizedDescription)) }
    }
    func stop() {
        generation = UUID(); monitor?.cancel(); monitor = nil
        for (device, property, block) in listeners {
            var property = property
            AudioObjectRemovePropertyListenerBlock(device, &property, .main, block)
        }
        listeners = []; device = 0; latest = nil
    }
}
