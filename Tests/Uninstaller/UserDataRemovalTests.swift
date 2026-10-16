import Foundation

@main
struct UserDataRemovalTests {
    static let fm = FileManager.default
    static let settings = ["Preferences/local.SonoFerry.plist", "Caches/local.SonoFerry/cache",
                           "Saved Application State/local.SonoFerry.savedState/window", "Application Support/SonoFerry/settings"]
    static let diagnostics = ["Sessions/session.log", "Routes/route.json", "Control/control.jsonl", "StartupHealth/health.json"]
        .map { "Caches/SonoFerry/" + $0 }
    static var passed = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw UserDataRemoval.Failure(message) }
    }

    static func fixture(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sonoferry-user-data-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for path in settings + diagnostics + ["Preferences/com.example.other.plist", "Caches/Other/log", "Exports/SonoFerry-diagnostics.json"] {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        try body(root)
        passed += 1
    }

    static func expectFailure(_ action: () throws -> Void) throws {
        do { try action() }
        catch { return }
        throw UserDataRemoval.Failure("Expected failure")
    }

    static func main() throws {
        let initial = RemovalSelection()
        try check(initial.preferences && initial.diagnostics, "Both optional removals must default to selected")
        for preferences in [false, true] {
            for logs in [false, true] {
                try fixture { root in
                    var calls = 0
                    let selection = RemovalSelection(preferences: preferences, diagnostics: logs)
                    let removal = UserDataRemoval(library: root) {
                        calls += 1
                        let path = root.appendingPathComponent(settings[0])
                        if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
                    }
                    try removal.validate(selection)
                    try check(calls == 0, "Validation must not touch the preference domain")
                    try check((settings + diagnostics).allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }, "Validation deleted data")
                    try removal.remove(selection)
                    try check(calls == (preferences ? 1 : 0), "Preference selection ignored")
                    for path in settings { try check(fm.fileExists(atPath: root.appendingPathComponent(path).path) == !preferences, "Wrong setting selection: " + path) }
                    for path in diagnostics { try check(fm.fileExists(atPath: root.appendingPathComponent(path).path) == !logs, "Wrong diagnostic selection: " + path) }
                    for path in ["Preferences/com.example.other.plist", "Caches/Other/log", "Exports/SonoFerry-diagnostics.json"] {
                        try check(fm.fileExists(atPath: root.appendingPathComponent(path).path), "Unrelated/exported data removed")
                    }
                    try removal.remove(selection) // idempotent, including already absent directories
                }
            }
        }
        for relative in ["Caches", "Caches/SonoFerry", "Preferences/local.SonoFerry.plist"] {
            try fixture { root in
                let original = root.appendingPathComponent(relative)
                let preserved = root.appendingPathComponent("outside-" + UUID().uuidString)
                try fm.moveItem(at: original, to: preserved)
                try fm.createSymbolicLink(at: original, withDestinationURL: preserved)
                var calls = 0
                let removal = UserDataRemoval(library: root) { calls += 1 }
                try expectFailure { try removal.remove(RemovalSelection()) }
                try check(calls == 0, "Any invalid selected path must block all user-data changes")
                try check(fm.fileExists(atPath: preserved.path), "Symlink target was removed")
            }
        }
        try fixture { root in
            let original = root.appendingPathComponent("Caches/SonoFerry")
            let target = root.appendingPathComponent("preserved-logs")
            try fm.moveItem(at: original, to: target)
            try fm.createSymbolicLink(at: original, withDestinationURL: target)
            var calls = 0
            try UserDataRemoval(library: root) { calls += 1 }.remove(.init(preferences: true, diagnostics: false))
            try check(calls == 1 && fm.fileExists(atPath: target.path), "Unchecked diagnostics must be untouched")
        }
        try fixture { root in
            let file = root.appendingPathComponent(settings[0])
            try fm.linkItem(at: file, to: root.appendingPathComponent("hardlink"))
            let removal = UserDataRemoval(library: root) { throw UserDataRemoval.Failure("Must not reach preference clearing") }
            try expectFailure { try removal.validate(RemovalSelection()) }
        }
        try fixture { root in
            let file = root.appendingPathComponent("Caches/SonoFerry")
            try fm.removeItem(at: file)
            try Data("not a directory".utf8).write(to: file)
            try expectFailure { try UserDataRemoval(library: root, clearPreferences: {}).remove(RemovalSelection()) }
            try check(fm.fileExists(atPath: root.appendingPathComponent(settings[0]).path), "Invalid logs must block settings deletion")
        }
        try fixture { root in
            let removal = UserDataRemoval(library: root) { throw CocoaError(.fileWriteNoPermission) }
            try expectFailure { try removal.remove(RemovalSelection()) }
            try check((settings + diagnostics).allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }, "Preference failure must not be reported as success or delete logs")
        }
        print("Passed \(passed) isolated user-data cases plus default-selection check; no actual preferences or installed files touched.")
    }
}
