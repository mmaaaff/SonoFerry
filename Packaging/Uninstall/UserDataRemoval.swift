import Foundation

struct RemovalSelection {
    var preferences = true
    var diagnostics = true

    var summary: String {
        "设备偏好、个人设置：" + (preferences ? "删除" : "保留")
            + "\n诊断记录：" + (diagnostics ? "删除" : "保留")
    }
}

/// Runs in the launching user's process, never inside the administrator shell.
/// System deletion and authentication must succeed before remove is called.
struct UserDataRemoval {
    private let library: URL
    private let clearPreferences: () throws -> Void
    private let fm = FileManager.default

    static func currentUser() -> UserDataRemoval {
        UserDataRemoval(library: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) {
            let defaults = UserDefaults.standard
            defaults.removePersistentDomain(forName: "local.SonoFerry")
            guard defaults.synchronize(), (defaults.persistentDomain(forName: "local.SonoFerry") ?? [:]).isEmpty else {
                throw Failure("未能清除 SonoFerry 偏好，请保留错误信息后重试。")
            }
        }
    }

    // Explicit library and preferences operation enable isolated temporary-directory tests.
    init(library: URL, clearPreferences: @escaping () throws -> Void) {
        self.library = library
        self.clearPreferences = clearPreferences
    }

    private func paths(_ selection: RemovalSelection) -> [String] {
        var paths: [String] = []
        if selection.preferences {
            paths += ["Preferences/local.SonoFerry.plist", "Caches/local.SonoFerry",
                      "Saved Application State/local.SonoFerry.savedState", "Application Support/SonoFerry"]
        }
        // Sessions, Routes, Control and StartupHealth are all diagnostics in this tree.
        if selection.diagnostics { paths.append("Caches/SonoFerry") }
        return paths
    }

    func validate(_ selection: RemovalSelection) throws {
        for relative in paths(selection) {
            var current = library
            let components = relative.split(separator: "/").map(String.init)
            for component in [""] + components {
                if !component.isEmpty { current.appendPathComponent(component) }
                let attributes: [FileAttributeKey: Any]
                do { attributes = try fm.attributesOfItem(atPath: current.path) }
                catch CocoaError.fileReadNoSuchFile { continue }
                let type = attributes[.type] as? FileAttributeType
                guard type != .typeSymbolicLink else {
                    throw Failure("数据路径是符号链接，已停止清理：\(current.path)")
                }
                if current.lastPathComponent == "local.SonoFerry.plist" {
                    guard type == .typeRegular, (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                        throw Failure("偏好文件类型或链接数异常，已停止清理：\(current.path)")
                    }
                } else if type != .typeDirectory {
                    throw Failure("数据路径不是目录，已停止清理：\(current.path)")
                }
            }
        }
    }

    func remove(_ selection: RemovalSelection) throws {
        // Validate every selected path before changing any user data.
        try validate(selection)
        if selection.preferences { try clearPreferences() }
        for relative in paths(selection) where relative != "Preferences/local.SonoFerry.plist" {
            let url = library.appendingPathComponent(relative)
            do { try fm.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile { continue }
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
