#!/usr/bin/env python3
"""Build the opt-in diagnostic probe without replacing dist or the installed app/HAL."""
import pathlib, plistlib, subprocess
from build_settings import SWIFT_TARGET
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/oppo-probe'
OUT.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
swift = ['xcrun', 'swiftc', '-target', SWIFT_TARGET, '-sdk', sdk, '-swift-version', '5', '-O']
def run(*args): subprocess.run([str(x) for x in args], cwd=ROOT, check=True)
run(*swift, '-emit-library', '-static', '-emit-module', '-module-name', 'SonoFerryCore',
    '-emit-module-path', OUT/'SonoFerryCore.swiftmodule', *sorted((ROOT/'Sources/Core').glob('*.swift')),
    '-o', OUT/'libSonoFerryCore.a')
info = OUT/'Info.plist'
info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.SonoFerry.OppoProbe',
    'CFBundleName':'SonoFerry OPPO Probe', 'NSBluetoothAlwaysUsageDescription':'读取用户选择的耳机控制状态；只有显式启用实验写入选项时才发送 HiRes 开启请求。'}))
run(*swift, '-D', 'OPPO_EXPERIMENTAL_WRITE', '-I', OUT, '-L', OUT, '-lSonoFerryCore', '-parse-as-library',
    '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', info,
    ROOT/'Sources/Engine/OppoControlSession.swift', ROOT/'Tools/OppoProbeMain.swift', '-o', OUT/'SonoFerryOppoProbe')
run('codesign', '--force', '--sign', '-', '--identifier', 'local.SonoFerry.OppoProbe', OUT/'SonoFerryOppoProbe')
print(OUT/'SonoFerryOppoProbe')
