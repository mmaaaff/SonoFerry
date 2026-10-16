import Foundation
import CoreAudio
import SonoFerryCore

/// Opt-in local-device test. No encoder, route switch, or audio playback.
/// Briefly mutes the selected device, simulates a system volume change, then restores it.
@main struct HardwareVolumeIntegration {
    @MainActor static func main() async throws {
        let address = CommandLine.arguments[1]
        guard let device = SystemAudio.nativeOutput(address: address),
              let original = SystemAudio.read(device, SystemAudio.virtualMainVolume, Float32(0), output: true) else { fatalError("No volume endpoint") }
        let originalMute = SystemAudio.read(device, kAudioDevicePropertyMute, UInt32(0), output: true)
        func write<T>(_ selector: AudioObjectPropertySelector, _ value: T) throws {
            var property = SystemAudio.property(selector, output: true), value = value
            let status = withUnsafeBytes(of: &value) { AudioObjectSetPropertyData(device, &property, 0, nil, UInt32($0.count), $0.baseAddress!) }
            guard status == 0 else { throw ProtocolFailure("Core Audio write failed: \(status)") }
        }
        var observed: Double?, failure: String?
        let link = HardwareVolumeLink { event in
            switch event { case .changed(let value): observed = value; case .failed(let message): failure = message }
        }
        defer {
            link.stop()
            do {
                try write(SystemAudio.virtualMainVolume, original)
                if let originalMute { try write(kAudioDevicePropertyMute, originalMute) }
                print("Original native volume/mute restored.")
            } catch { print("RESTORE FAILED: \(error)") }
        }
        let zero = try await link.start(address: address, volume: 0)
        guard zero == 0 else { throw ProtocolFailure("Mute confirmation failed") }
        try write(SystemAudio.virtualMainVolume, Float32(0.05))
        if originalMute != nil { try write(kAudioDevicePropertyMute, UInt32(0)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while observed == nil && failure == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard failure == nil, let observed, abs(observed - 0.05) < 0.01 else { throw ProtocolFailure("Two-way notification failed: \(failure ?? String(describing: observed))") }
        let muted = try link.setVolume(0)
        guard muted == 0 else { throw ProtocolFailure("Second mute failed") }
        link.stop()
        do { _ = try link.setVolume(0.05); throw ProtocolFailure("Stopped link accepted a write") }
        catch let error as ProtocolFailure { guard error.message != "Stopped link accepted a write" else { throw error } }
        print("PASS: selected device write/readback, external-change callback, mute, stopped-link rejection.")
        print("Physical headset-button feedback and AVRCP radio acknowledgement are not asserted.")
    }
}
