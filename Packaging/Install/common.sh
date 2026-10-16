#!/bin/sh
# Loaded only from the install package's own script directory.
app='/Applications/SonoFerry.app'
legacy_app='/Applications/MacLDAC.app'
driver='/Library/Audio/Plug-Ins/HAL/SonoFerry.driver'
# Old names appear only in fixed-path removal checks, never in the new runtime.
legacy_driver='/Library/Audio/Plug-Ins/HAL/MacLDAC.driver'

fail() { echo "$1" >&2; exit 1; }

check_bundle() {
    path="$1"; identifier="$2"; previous_identifier="${3:-}"
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ ! -L "$path" ] && [ -d "$path" ] && [ ! -L "$path/Contents" ] &&
            [ ! -L "$path/Contents/Info.plist" ] && [ -f "$path/Contents/Info.plist" ] ||
            fail "Refusing an invalid or linked bundle: $path"
        actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist") ||
            fail "Unable to confirm bundle identity: $path"
        { [ "$actual" = "$identifier" ] || { [ -n "$previous_identifier" ] && [ "$actual" = "$previous_identifier" ]; }; } || fail "An unrelated item occupies $path; migration stopped."
    fi
}

check_processes() {
    processes=$(/bin/ps -axo comm=) || fail 'Unable to check running apps; installation stopped.'
    if printf '%s\n' "$processes" | /usr/bin/awk '
        /\/(MacLDAC|SonoFerry)\.app\/Contents\// || /(^|\/)(MacLDAC|SonoFerry|MacLDACEngine|MacLDACAudio|SonoFerryEngine|SonoFerryAudio)$/ { found=1 }
        END { exit !found }'; then
        fail 'Quit SonoFerry / MacLDAC and wait for its audio engine to exit before installing.'
    fi
}

check_targets() {
    for parent in /Applications /Library /Library/Audio /Library/Audio/Plug-Ins /Library/Audio/Plug-Ins/HAL; do
        [ ! -L "$parent" ] || fail "Refusing a linked installation parent: $parent"
    done
    check_processes
    check_bundle "$app" 'local.SonoFerry' "${1:-}"
    check_bundle "$legacy_app" 'local.MacLDAC'
    check_bundle "$driver" 'local.SonoFerry.LDACOutput'
    check_bundle "$legacy_driver" 'local.MacLDAC.LDACOutput'
}
