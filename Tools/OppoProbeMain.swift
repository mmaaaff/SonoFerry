import Foundation
import AppKit
import IOBluetooth
import SonoFerryCore
import Darwin

@main struct OppoProbeMain {
    static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    static func main() {
        let args = CommandLine.arguments
        let options = ["--compare-batch", "--enable-hires-once", "--disable-hires-once", "--initialize-control", "--enable-hires-codec-once", "--enable-hires-lhdc-once", "--integrated-client"]
        guard args.count >= 2, args.dropFirst(2).allSatisfy(options.contains),
              Set(args.dropFirst(2)).count == args.count - 2,
              args.filter({ ["--compare-batch", "--enable-hires-once", "--disable-hires-once", "--enable-hires-codec-once", "--enable-hires-lhdc-once"].contains($0) }).count <= 1,
              BluetoothIdentity.normalizedAddress(args[1]) != nil else {
            fputs("Usage: \(URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent) PAIRED-BLUETOOTH-ADDRESS [--initialize-control] [--integrated-client] [--compare-batch | --enable-hires-once | --disable-hires-once | --enable-hires-codec-once | --enable-hires-lhdc-once]\nDefault is read-only. Enable options send one experimental feature write after baseline query; pause audio first. Never claims the audio driver.\n", stderr)
            exit(64)
        }
        var done = false; var status: Int32 = 1
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let probe = OppoControlSession(compareBatch: args.contains("--compare-batch"), initializeControl: args.contains("--initialize-control") || args.contains("--enable-hires-codec-once") || args.contains("--enable-hires-lhdc-once") || args.contains("--integrated-client"), integratedClient: args.contains("--integrated-client"), progress: { emit(["kind":"progress", "message":$0]) },
            trace: { direction, value in
                if ["tx", "rx", "rxChunk"].contains(direction) { emit(["kind":"frame", "direction":direction, "hex":value]) }
                else { emit(["kind":"diagnostic", "stage":direction, "message":value]) }
            }) { result in
                switch result {
                case .success(let report):
                    let data = try! JSONEncoder().encode(report)
                    emit(["kind":"result", "report":try! JSONSerialization.jsonObject(with:data)]); status = 0
                case .failure(let error): emit(["kind":"error", "message":error.localizedDescription])
                }
                done = true
            }
        if args.contains("--enable-hires-once") || args.contains("--disable-hires-once") {
#if OPPO_EXPERIMENTAL_WRITE
            emit(["kind":"experiment", "message":"将记录基线，发送一次明确指定的 HiRes 设置请求，然后只读查询；不自动重试、不推断设置成功。"])
            probe.prepareHiResEnableExperiment(enabled: !args.contains("--disable-hires-once"))
#else
            fputs("Experimental writes are not compiled into this binary.\n", stderr); exit(64)
#endif
        }
        if args.contains("--enable-hires-codec-once") || args.contains("--enable-hires-lhdc-once") {
#if OPPO_EXPERIMENTAL_WRITE
            let selectLHDC = args.contains("--enable-hires-lhdc-once")
            emit(["kind":"experiment", "message": selectLHDC ? "先查询命令能力；只选择耳机报告的 LHDC 编码，发送一次 041A HiRes 开启请求，不自动重试。" : "先查询命令能力和当前编码；满足条件才发送一次 041A HiRes 开启请求，保留当前编码，不自动重试。"])
            probe.prepareCodecHiResEnableExperiment(selectLHDC: selectLHDC)
#else
            fputs("Experimental writes are not compiled into this binary.\n", stderr); exit(64)
#endif
        }
        probe.start(address: args[1])
        while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
        withExtendedLifetime(probe) {}; exit(status)
    }
}
