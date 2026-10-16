#!/usr/bin/env python3
"""Offline, deterministic dependency selection; no downloads or system installation."""
import hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, sys, tempfile
from build_settings import (
    ARCHITECTURE, DEPLOYMENT, PRODUCT_NAME, SWIFT_TARGET, APP_VERSION, APP_BUILD, RELEASE_LABEL,
    COMPONENT_VERSION, COMPONENT_BUILD, APP_BUNDLE_ID, ENGINE_BUNDLE_ID,
    ENGINE_BUNDLE_PATH, CAPTURE_BUNDLE_PATH, DRIVER_NAME, ENGINE_HASH_KEY,
)

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build/native'
DIST = ROOT / 'dist'
APP = DIST / (PRODUCT_NAME + '.app')

def run(*args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True)

def plist(path, values):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(values))

def app_info(identifier, name, executable):
    main_app = identifier == APP_BUNDLE_ID
    return {'CFBundleIdentifier': identifier, 'CFBundleName': name, 'CFBundleDisplayName': name,
        'CFBundleExecutable': executable, 'CFBundlePackageType': 'APPL', 'CFBundleVersion': APP_BUILD if main_app else COMPONENT_BUILD,
        'CFBundleShortVersionString': APP_VERSION if main_app else COMPONENT_VERSION, 'LSMinimumSystemVersion': DEPLOYMENT, 'LSUIElement': True,
        'NSBluetoothAlwaysUsageDescription': PRODUCT_NAME + ' 通过内置蓝牙查询耳机音频能力并发送 LDAC 或 LHDC 音频。',
        'NSAudioCaptureUsageDescription': PRODUCT_NAME + ' 捕获虚拟输出的系统音频并在本机编码发送；不保存录音。'}

def sign(path, identifier=None):
    args = ['codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none']
    if identifier: args += ['--identifier', identifier]
    run(*args, path)

def build_app(APP):
    ENGINE = APP / ENGINE_BUNDLE_PATH
    HELPERS = ENGINE / 'Contents/Helpers'
    run(sys.executable, ROOT/'scripts/generate-headphone-catalog.py', '--check')
    manifest = json.loads((ROOT/'Configuration/vendor-sha256.json').read_text())
    for relative, expected in manifest.items():
        if hashlib.sha256((ROOT/relative).read_bytes()).hexdigest() != expected:
            raise SystemExit('Vendored source checksum mismatch: ' + relative)
    for p in [BUILD, HELPERS, ENGINE/'Contents/MacOS', APP/'Contents/MacOS', APP/'Contents/Resources']:
        p.mkdir(parents=True, exist_ok=True)
    plist(ENGINE/'Contents/Info.plist', app_info(ENGINE_BUNDLE_ID, PRODUCT_NAME + ' Engine', 'SonoFerryEngine'))
    main_info = app_info(APP_BUNDLE_ID, PRODUCT_NAME, PRODUCT_NAME)
    # UI-only releases may advance the main App while retaining matched engine/HAL components.
    main_info.update(CFBundleIconFile='AppIcon', SonoFerryReleaseLabel=RELEASE_LABEL)
    plist(APP/'Contents/Info.plist', main_info)
    sdk = subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
    cc = ['xcrun','clang','-arch',ARCHITECTURE,'-isysroot',sdk, '-mmacosx-version-min='+DEPLOYMENT, '-O2', '-ffp-contract=off']
    frameworks = ['-framework','Foundation','-framework','CoreFoundation','-framework','CoreBluetooth','-framework','IOBluetooth']
    include = ['-I',ROOT/'Vendor/libldac/inc','-I',ROOT/'Vendor/libldac/src','-I',ROOT/'Vendor/lhdcv5/include','-I',ROOT/'Vendor/lhdcv5/src']
    codec_objects = []
    for src in [ROOT/'Vendor/libldac/src/ldacBT.c', ROOT/'Vendor/libldac/src/ldaclib.c', *sorted((ROOT/'Vendor/lhdcv5/src').glob('*.c')), ROOT/'Native/Codec/LHDCBackend.c']:
        obj = BUILD/(src.stem+'.o'); run(*cc,'-std=c99',*include,'-c',src,'-o',obj); codec_objects.append(obj)
    for name, source in [('AVDTPSignaling','AVDTPSignaling.m'),('MediaTransport','MediaTransport.m'),('ClassicConnection','ClassicConnection.m')]:
        info = BUILD/(name+'.plist'); plist(info,app_info('local.SonoFerry.'+name,name,name))
        extra = [*include,*codec_objects] if name == 'MediaTransport' else ['-framework','CoreAudio'] if name == 'ClassicConnection' else []
        run(*cc,'-fobjc-arc','-fblocks','-D_DARWIN_C_SOURCE','-DSONOFERRY_LDAC_PROBE_ONLY=1',*frameworks,
            '-Wl,-sectcreate,__TEXT,__info_plist,'+str(info),ROOT/'Native/Transport'/source,*extra,'-o',HELPERS/name)
        sign(HELPERS/name,'local.SonoFerry.'+name)
    run(*cc,ROOT/'Native/Transport/LogObserver.c','-o',HELPERS/'LogObserver'); sign(HELPERS/'LogObserver','local.SonoFerry.LogObserver')
    capture = ENGINE/CAPTURE_BUNDLE_PATH; (capture/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
    plist(capture/'Contents/Info.plist',app_info('local.SonoFerry.ldac-audio',PRODUCT_NAME + ' Audio','SonoFerryAudio'))
    run(*cc,'-fobjc-arc','-fblocks','-DSONOFERRY_AUDIO_HELPER_BUNDLE_ID="local.SonoFerry.ldac-audio"','-DSONOFERRY_AUDIO_HELPER_STREAM_ONLY=1',
        '-framework','Foundation','-framework','CoreAudio','-framework','AudioToolbox',ROOT/'Native/Capture/CaptureMain.m','-o',capture/'Contents/MacOS/SonoFerryAudio')
    sign(capture)
    swift = ['xcrun','swiftc','-target',SWIFT_TARGET,'-sdk',sdk,'-swift-version','5','-O']
    run(*swift,ROOT/'scripts/make-icon.swift','-o',BUILD/'make-icon')
    run(BUILD/'make-icon',BUILD/'AppIcon.iconset')
    run('iconutil','-c','icns',BUILD/'AppIcon.iconset','-o',APP/'Contents/Resources/AppIcon.icns')
    run(*swift,'-emit-library','-static','-emit-module','-module-name','SonoFerryCore','-emit-module-path',BUILD/'SonoFerryCore.swiftmodule',
        *sorted((ROOT/'Sources/Core').glob('*.swift')),'-o',BUILD/'libSonoFerryCore.a')
    run(*swift,'-I',BUILD,'-L',BUILD,'-lSonoFerryCore','-parse-as-library',*sorted((ROOT/'Sources/Engine').glob('*.swift')),'-o',ENGINE/'Contents/MacOS/SonoFerryEngine')
    sign(ENGINE)
    signature = subprocess.check_output(['codesign','-d','--verbose=4',str(ENGINE)],stderr=subprocess.STDOUT,text=True)
    cdhash = re.search(r'^CDHash=([a-f0-9]+)$',signature,re.M).group(1)
    (BUILD/'EngineIdentity.h').write_text('#define SONOFERRY_ENGINE_REQUIREMENT "identifier \\"local.SonoFerry.Engine\\" and cdhash H\\"'+cdhash+'\\""\n')
    with (BUILD/'EngineIdentity.h').open('a') as f: f.write('#define SONOFERRY_ENGINE_CDHASH \"'+cdhash+'\"\n')
    driver = APP/'Contents/Resources'/DRIVER_NAME
    (driver/'Contents/MacOS').mkdir(parents=True,exist_ok=True); (driver/'Contents/Resources').mkdir(exist_ok=True)
    driver_info = plistlib.loads((ROOT/'Configuration/Driver-Info.plist').read_bytes()); driver_info['LSMinimumSystemVersion'] = DEPLOYMENT
    driver_info[ENGINE_HASH_KEY] = cdhash; plist(driver/'Contents/Info.plist',driver_info)
    run(*cc,'-std=gnu11','-fblocks','-Werror','-bundle','-I',BUILD,'-framework','CoreAudio','-framework','CoreFoundation','-framework','Security',
        ROOT/'Native/Driver/SonoFerryOutput.c','-o',driver/'Contents/MacOS/SonoFerryVirtualOutput')
    for file in ['LICENSE.txt','NullAudio.c']: shutil.copy2(ROOT/'Native/Driver'/file,driver/'Contents/Resources'/file)
    shutil.copy2(ROOT/"Native/Driver/Resources/Headphones.png", driver/"Contents/Resources/Headphones.png")
    sign(driver)
    if list((ROOT/'Sources/App').glob('*.swift')):
        run(*swift,'-I',BUILD,'-L',BUILD,'-lSonoFerryCore','-parse-as-library',*sorted((ROOT/'Sources/App').glob('*.swift')),'-o',APP/'Contents/MacOS'/PRODUCT_NAME)
        if (ROOT/'THIRD-PARTY-NOTICES.md').exists(): shutil.copy2(ROOT/'THIRD-PARTY-NOTICES.md',APP/'Contents/Resources')
        licenses = APP/'Contents/Resources/Licenses'; licenses.mkdir(exist_ok=True)
        for source, name in [('LICENSE',PRODUCT_NAME + '.txt'), ('Vendor/Acouplet-LICENSE','Acouplet.txt'),
                             ('Vendor/libldac/LICENSE','AOSP-libldac.txt'), ('Vendor/lhdcv5/LICENSE','LHDC-V5-Encoder.txt'),
                             ('Vendor/libldac/NOTICE','AOSP-libldac-NOTICE.txt'),
                             ('Vendor/KISS-FFT-LICENSE','KISS-FFT.txt'), ('Native/Driver/LICENSE.txt','Apple-NullAudio.txt')]:
            shutil.copy2(ROOT/source, licenses/name)
        sign(APP); run('codesign','--verify','--deep','--strict',APP)
    (BUILD/'build.json').write_text(json.dumps({'engineCDHash':cdhash,'deployment':DEPLOYMENT,'ldac':'eeee1a3f5f8df1282e3a6d297085885fd886737b','lhdc':'3f9d1980fa9c57cdfb78792f9455a7dbac50edda'},indent=2))
def main():
    # Build from an empty bundle: renamed/removed files must not survive into a release.
    # Publish only after signing and verification, keeping the previous bundle recoverable.
    BUILD.mkdir(parents=True, exist_ok=True)
    DIST.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sonoferry-build-', dir=ROOT/'.build') as temp:
        staged = pathlib.Path(temp) / APP.name
        build_app(staged)
        previous = None
        if APP.exists():
            archive = pathlib.Path(tempfile.mkdtemp(prefix='previous-sonoferry-', dir=ROOT/'.build'))
            previous = archive / APP.name
            APP.rename(previous)
        try:
            staged.rename(APP)
        except OSError:
            if previous is not None:
                previous.rename(APP)
            raise
    print('Built:', APP)
if __name__ == '__main__': main()
