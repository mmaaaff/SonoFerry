import AppKit
import Foundation

enum HighBitrateWarning {
    static let suppressionKey = "suppressLHDCHighBitrateWarning"
    static let message = "选择码率为 900/1000 kbps时，传输稳定性将降低，在信号干扰较强时声音可能出现断续，这并非软件问题，建议在信号干扰较少处使用，或降低码率/使用自适应码率"

    @MainActor static func confirm() -> (apply: Bool, suppress: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "高码率传输提示"
        alert.informativeText = message
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再提示"
        let response = alert.runModal()
        return (response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
    }
}

enum ApplicationVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let release = Bundle.main.object(forInfoDictionaryKey: "SonoFerryReleaseLabel") as? String
        return release.map { version + " " + $0 } ?? version
    }
}

// Persist only this application's domain; never touch the global macOS preferences.
enum ApplicationAppearance: String, CaseIterable {
    case dark, light, system
    var title: String { switch self { case .dark: "深色"; case .light: "浅色"; case .system: "跟随系统" } }
    var symbol: String { switch self { case .dark: "moon.fill"; case .light: "sun.max.fill"; case .system: "circle.lefthalf.filled" } }
    var native: NSAppearance? { switch self { case .dark: NSAppearance(named: .darkAqua); case .light: NSAppearance(named: .aqua); case .system: nil } }
}

enum ApplicationData {
    static func clearFiles() throws {
        try clearFiles(in: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0])
    }
    static func clearFiles(in library: URL) throws {
        let fm = FileManager.default
        // The engine must be completely stopped before deleting its logs/caches.
        // Exported diagnostics and headset-side settings are not application storage.
        for relative in ["Caches/SonoFerry", "Caches/local.SonoFerry", "Saved Application State/local.SonoFerry.savedState", "Application Support/SonoFerry"] {
            let url = library.appendingPathComponent(relative)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }
}
