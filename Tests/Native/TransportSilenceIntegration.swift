// Manual hardware test: real NativeSession + Bluetooth helpers + encoder,
// generated zeros from SilenceFixture instead of Core Audio / HAL. Requires
// explicit user permission and paused system audio. Does not prove HAL routing
// or microphone/capture permission. The bundle path must be a test bundle.
import Foundation
import SonoFerryCore
import Darwin
@main struct TransportSilenceIntegration {
    @MainActor static func main() {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 3,
              let bundle = Bundle(path: CommandLine.arguments[1]),
              bundle.bundleIdentifier == "local.SonoFerry.TransportSilenceTest" else { exit(2) }
        var config = PlaybackConfiguration()
        config.codec = .lhdcV5; config.sampleRate = .hz44100
        config.quality = .adaptive; config.bits = 24; config.endpoint = 3
        var session: LDACNativeSession?
        var active = false
        session = LDACNativeSession(id: UUID(), address: CommandLine.arguments[2],
            helpers: .init(bundle: bundle), gain: 0, configuration: config) { event in
            switch event {
            case .capability(let cap): print("CAPABILITY \(cap.codecLabel) \(cap.sampleRates)")
            case .active(let format):
                active = true; print("SILENT_TRANSPORT_ACTIVE \(format)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { session?.stop() }
            case .failed(let error): print("FAILED \(error)")
            case .finished(let result):
                print("FINISHED message=\(String(describing: result.message)) active=\(active)")
                session = nil; exit(active && result.message == nil ? 0 : 1)
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 70) { session?.stop() }
        session!.start(); RunLoop.main.run()
    }
}
