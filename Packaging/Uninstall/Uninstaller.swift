import AppKit

// RemovalPayload is generated from remove.sh and compiled into this executable.
// Opening this app only presents a confirmation. Preview cannot authorize removal.
final class Uninstaller: NSObject, NSApplicationDelegate {
    private let preview = CommandLine.arguments.contains("--ui-preview")
    private var selection = RemovalSelection()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出卸载工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.presentConfirmation() }
    }

    private func alert(_ title: String, _ message: String, symbol: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return alert
    }

    private func presentConfirmation() {
        while true {
            let prompt = alert("卸载 SonoFerry", "选择要移除的内容，取消勾选即可保留对应数据。", symbol: "trash.circle")
            let detail = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: 236))
            let heading = NSTextField(labelWithString: "将移除")
            heading.font = .boldSystemFont(ofSize: 13)
            heading.frame = NSRect(x: 0, y: 212, width: 370, height: 20)
            detail.addSubview(heading)
            func checkbox(_ title: String, y: CGFloat, selected: Bool, enabled: Bool) -> NSButton {
                let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
                button.state = selected ? .on : .off
                button.isEnabled = enabled
                button.frame = NSRect(x: 0, y: y, width: 370, height: 22)
                detail.addSubview(button)
                return button
            }
            _ = checkbox("SonoFerry 应用", y: 184, selected: true, enabled: false)
            _ = checkbox("SonoFerry 音频驱动", y: 156, selected: true, enabled: false)
            let preferences = checkbox("设备偏好、个人设置", y: 128, selected: selection.preferences, enabled: true)
            let diagnostics = checkbox("诊断记录", y: 100, selected: selection.diagnostics, enabled: true)
            let note = NSTextField(wrappingLabelWithString: "仅处理当前用户的设置和应用内诊断，保留手动导出的文件。\n\n请先停止播放并正常退出 SonoFerry，确认系统输出已恢复。卸载后请自行重启 Mac。")
            note.font = .systemFont(ofSize: 12)
            note.textColor = .secondaryLabelColor
            note.frame = NSRect(x: 0, y: 0, width: 370, height: 86)
            detail.addSubview(note)
            prompt.accessoryView = detail
            let remove = prompt.addButton(withTitle: "卸载…")
            remove.hasDestructiveAction = true
            remove.keyEquivalent = ""
            let cancel = prompt.addButton(withTitle: "取消")
            cancel.keyEquivalent = "\r"
            if preview {
                prompt.informativeText += "\n界面预览：卸载操作已禁用。"
                remove.isEnabled = false
            }
            let response = prompt.runModal()
            guard !preview, response == .alertFirstButtonReturn else {
                NSApp.terminate(nil)
                return
            }
            selection = RemovalSelection(preferences: preferences.state == .on, diagnostics: diagnostics.state == .on)
            if removeWithAuthorization() { return }
        }
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private func removeWithAuthorization() -> Bool {
        let userData = UserDataRemoval.currentUser()
        do {
            guard getuid() != 0 else { throw UserDataRemoval.Failure("请以当前用户身份打开卸载工具，不要使用 sudo。") }
            try userData.validate(selection)
        } catch {
            showFailure(error.localizedDescription)
            return false
        }
        // Check locally first, then run the same checks again with administrator privileges.
        // The shell text is embedded, never loaded from a writable script at elevation time.
        let check = "set -- --check-only\n" + RemovalPayload.script
        let checkSource = "do shell script " + appleScriptString(check)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: checkSource),
              script.executeAndReturnError(&error).stringValue == "SONOFERRY_UNINSTALL_READY",
              error == nil else {
            showFailure(error?[NSAppleScript.errorMessage] as? String ?? "无法完成卸载前检查。")
            return false
        }

        let source = "do shell script " + appleScriptString(RemovalPayload.script)
            + " with administrator privileges with prompt "
            + appleScriptString("卸载 SonoFerry 将移除应用和音频驱动。\n" + selection.summary)
        error = nil
        guard let privileged = NSAppleScript(source: source),
              privileged.executeAndReturnError(&error).stringValue == "SONOFERRY_UNINSTALL_COMPLETE",
              error == nil else {
            if (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128 {
                return false
            } else {
                showFailure(error?[NSAppleScript.errorMessage] as? String ?? "卸载未完成，请检查应用和驱动是否仍然存在。")
            }
            return false
        }
        do { try userData.remove(selection) }
        catch {
            showFailure("应用和驱动已移除，但选中的用户数据未能全部清理。\n\n" + error.localizedDescription + "\n\n可以保留当前选项重试。仍需自行重启 Mac。")
            return false
        }
        let done = alert("SonoFerry 已移除", "应用和音频驱动文件已删除。\n" + selection.summary.replacingOccurrences(of: "：删除", with: "：已删除").replacingOccurrences(of: "：保留", with: "：已保留") + "\n\n请自行重启 Mac，使已加载的音频驱动完全卸载。", symbol: "checkmark.circle")
        done.addButton(withTitle: "完成")
        done.runModal()
        NSApp.terminate(nil)
        return true
    }

    private func showFailure(_ message: String) {
        let failure = alert("未完成卸载", message, symbol: "exclamationmark.triangle")
        failure.addButton(withTitle: "返回")
        failure.runModal()
    }
}

let app = NSApplication.shared
let delegate = Uninstaller()
app.delegate = delegate
app.run()
