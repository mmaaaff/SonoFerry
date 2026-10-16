#!/usr/bin/env python3
"""Build the standalone uninstaller without rebuilding or installing SonoFerry."""
import base64
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
from build_settings import DEPLOYMENT, PRODUCT_NAME, SWIFT_TARGET

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'dist' / ('卸载 ' + PRODUCT_NAME + '.app')


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, timeout=120)


def main():
    with tempfile.TemporaryDirectory(prefix='sonoferry-uninstaller-') as temp:
        work = pathlib.Path(temp)
        app = work / OUTPUT.name
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        info = dict(CFBundleIdentifier='local.SonoFerry.Uninstaller',
                    CFBundleName='卸载 ' + PRODUCT_NAME, CFBundleDisplayName='卸载 ' + PRODUCT_NAME,
                    CFBundleExecutable='SonoFerryUninstaller', CFBundlePackageType='APPL',
                    CFBundleShortVersionString='1.5', CFBundleVersion='6',
                    LSMinimumSystemVersion=DEPLOYMENT, NSHighResolutionCapable=True)
        icon = ROOT / 'dist' / (PRODUCT_NAME + '.app') / 'Contents/Resources/AppIcon.icns'
        if icon.exists():
            shutil.copyfile(icon, contents / 'Resources/AppIcon.icns')
            info['CFBundleIconFile'] = 'AppIcon'
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        payload = base64.b64encode((ROOT / 'Packaging/Uninstall/remove.sh').read_bytes()).decode('ascii')
        generated = work / 'RemovalPayload.swift'
        generated.write_text('import Foundation\nenum RemovalPayload {\n'
                             '    static let script = String(data: Data(base64Encoded: "' + payload + '")!, encoding: .utf8)!\n}\n')
        # Swift top-level entry point must be named main.swift in a multi-file build.
        shutil.copyfile(ROOT / 'Packaging/Uninstall/Uninstaller.swift', work / 'main.swift')
        sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True, timeout=15).strip()
        run('xcrun', 'swiftc', '-target', SWIFT_TARGET, '-sdk', sdk,
            '-swift-version', '5', '-O', '-module-cache-path', work / 'ModuleCache',
            work / 'main.swift', ROOT / 'Packaging/Uninstall/UserDataRemoval.swift', generated,
            '-o', contents / 'MacOS/SonoFerryUninstaller')
        run('codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        run('/usr/bin/ditto', '--norsrc', '--noextattr', app, OUTPUT)
        run('codesign', '--verify', '--deep', '--strict', OUTPUT)
    print('Built uninstaller 1.5/build 6:', OUTPUT)
    print('No installation, removal, administrator authentication or audio restart was performed.')


if __name__ == '__main__':
    main()
