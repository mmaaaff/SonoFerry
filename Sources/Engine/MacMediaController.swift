import Foundation
import AppKit
import Darwin
import SonoFerryCore

/// Private API stays behind a fail-closed adapter. No synthetic play/pause toggle keys.
@MainActor
final class MacMediaController {
    typealias Info = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias PID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    typealias Playing = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias Origin = @convention(c) () -> UnsafeRawPointer?
    typealias Command = @convention(c) (UInt32, CFDictionary?, UnsafeRawPointer?, CFString, UInt32, DispatchQueue, @escaping @convention(block) (Int32, CFArray?) -> Void) -> Bool
    private let library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)
    private var getInfo: Info?
    private var getPID: PID?
    private var getPlaying: Playing?
    private var getOrigin: Origin?
    private var sendCommand: Command?
    private(set) var status = "Mac 摘戴联动已关闭"
    private(set) var session: MediaSession?
    private var machine = WearPlaybackMachine()
    private var gestures = GestureRouter()
    private var timer: Timer?
    private var querying = false
    private var epoch = UUID()
    var enabled = false { didSet { cancel(); status = enabled ? unavailableReason : "Mac 摘戴联动已关闭" } }
    var wearing: UInt8?
    var outputIdentity: (() -> String?) = { nil }
    var changed: (String) -> Void = { _ in }
    // MediaRemote's public-to-the-process notifications don't identify the origin of an already-paused
    // command. Until an OS adapter proves that observation, automatic resume would override user intent.
    let unavailableReason = "当前 macOS 尚无可靠的用户接管／应用输出观测，摘戴联动已停用；不会自动恢复播放"
    init() {
        if let library {
            func symbol<T>(_ name: String, _ type: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: T.self) } }
            getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", Info.self)
            getPID = symbol("MRMediaRemoteGetNowPlayingApplicationPID", PID.self)
            getPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", Playing.self)
            getOrigin = symbol("MRMediaRemoteGetLocalOrigin", Origin.self)
            sendCommand = symbol("MRMediaRemoteSendCommandToApp", Command.self)
        }
    }
    func cancel() { epoch = UUID(); machine.cancel(); gestures.reset(); session = nil; timer?.invalidate(); timer = nil; querying = false }
    /// Bounded, coherent identity snapshot used by diagnostics and future verified adapters.
    func inspect(completion: @escaping (MediaSession?) -> Void) {
        guard !querying, let getInfo, let getPID, let getPlaying, let output = outputIdentity() else { completion(nil); return }
        querying = true; let token = epoch
        var pid: Int32?, playing: Bool?, metadata: [String: Any]?, remaining = 3, finished = false
        func finish(_ timedOut: Bool = false) {
            guard !finished, timedOut || remaining == 0 else { return }; finished = true
            self.querying = false
            guard !timedOut, self.epoch == token, self.outputIdentity() == output,
                  let pid, let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, let playing,
                  let unique = metadata?["kMRMediaRemoteNowPlayingInfoUniqueIdentifier"], !String(describing: unique).isEmpty else { completion(nil); return }
            let value = MediaSession(application: app, media: String(describing: unique), output: output, playing: playing)
            self.session = value; completion(value)
        }
        getPID(.main) { value in pid = value; remaining -= 1; finish() }
        getPlaying(.main) { value in playing = value; remaining -= 1; finish() }
        getInfo(.main) { value in metadata = value as? [String: Any]; remaining -= 1; finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(true) }
    }
    func command(_ action: MediaAction, for expected: MediaSession, completion: @escaping (Bool) -> Void) {
        let token = epoch
        inspect { [weak self] current in
            guard let self, self.epoch == token, let current, current == expected, let command = self.sendCommand, let origin = self.getOrigin?() else { completion(false); return }
            let code: UInt32 = [.play: 0, .pause: 1, .next: 4, .previous: 5][action]!
            var finished = false
            func finish(_ success: Bool) { guard !finished else { return }; finished = true; completion(success) }
            let accepted = command(code, nil, origin, expected.application as CFString, 0, .main) { error, _ in finish(error == 0 && self.epoch == token) }
            if !accepted { finish(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(false) }
        }
    }
    func observe(_ event: HeadsetGesture) {
        // Native is the sole execution source until an AAC/LHDC action test demonstrates a missing
        // native response and confirms F1's scene semantics. Configuration success is not that test.
        _ = gestures.action(for: event, from: .earphone, media: session, at: Date())
    }
}
