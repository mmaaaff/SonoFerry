#!/bin/sh
# Embedded in the signed uninstaller at build time. No user-supplied paths.
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
app='/Applications/SonoFerry.app'
driver='/Library/Audio/Plug-Ins/HAL/SonoFerry.driver'

fail() { echo "$1" >&2; exit 1; }
case "${1:-}" in
    --check-only) check_only=1 ;;
    '') check_only=0 ;;
    *) fail '不支持的卸载参数。' ;;
esac

check_processes() {
    processes=$(/bin/ps -axo comm=) || fail '无法检查运行状态，请稍后重试。'
    if printf '%s\n' "$processes" | /usr/bin/awk '
        /\/SonoFerry\.app\/Contents\// || /(^|\/)(SonoFerry|SonoFerryEngine|SonoFerryAudio)$/ { found=1 }
        END { exit !found }'; then
        fail 'SonoFerry 或会话引擎仍在运行。请停止播放，正常退出应用，等待系统输出恢复后再卸载。'
    fi
}

check_bundle() {
    path="$1"; identifier="$2"
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ ! -L "$path" ] && [ -d "$path" ] && [ ! -L "$path/Contents" ] &&
            [ ! -L "$path/Contents/Info.plist" ] && [ -f "$path/Contents/Info.plist" ] ||
            fail "目标不是正常的应用或驱动目录，已停止卸载：$path"
        actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist") ||
            fail "无法确认目标身份，已停止卸载：$path"
        [ "$actual" = "$identifier" ] || fail "目标不属于 SonoFerry，已停止卸载：$path"
    fi
}

# Validate all targets before removing any one.
for parent in /Applications /Library /Library/Audio /Library/Audio/Plug-Ins /Library/Audio/Plug-Ins/HAL; do
    [ ! -L "$parent" ] || fail "目标父目录是符号链接，已停止卸载：$parent"
done
check_processes
check_bundle "$app" 'local.SonoFerry'
check_bundle "$driver" 'local.SonoFerry.LDACOutput'
[ "$check_only" = 0 ] || { echo 'SONOFERRY_UNINSTALL_READY'; exit 0; }
[ "$(/usr/bin/id -u)" = 0 ] || fail '卸载需要管理员授权。'

# Recheck after authorization. Do not kill the app or restart Core Audio.
check_processes
check_bundle "$app" 'local.SonoFerry'
check_bundle "$driver" 'local.SonoFerry.LDACOutput'
/bin/rm -rf -- "$driver" "$app" || fail '部分文件未能移除，请保留错误信息后重试。'
for path in "$driver" "$app"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "文件仍然存在，卸载未完成：$path"
done
for receipt in local.SonoFerry.package local.SonoFerry.uninstall; do
    if /usr/sbin/pkgutil --pkg-info "$receipt" >/dev/null 2>&1; then
        /usr/sbin/pkgutil --forget "$receipt" >/dev/null ||
            fail '应用和驱动已移除，但安装记录清理失败。请保留错误信息；仍需自行重启 Mac。'
    fi
done
# Keep the root-owned lock inode and all per-user preferences/diagnostics.
echo 'SONOFERRY_UNINSTALL_COMPLETE'
