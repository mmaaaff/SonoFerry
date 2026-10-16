#!/usr/bin/env python3
"""Read-only release layout/signature audit. Never installs or launches the product."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile

from build_settings import (
    PRODUCT_NAME, APP_VERSION, APP_BUILD, COMPONENT_VERSION, COMPONENT_BUILD,
    APP_BUNDLE_ID, ENGINE_BUNDLE_ID, ENGINE_BUNDLE_PATH, ENGINE_EXECUTABLE_PATH,
    CAPTURE_BUNDLE_PATH, CAPTURE_EXECUTABLE_PATH, DRIVER_NAME, ENGINE_HASH_KEY,
    ARCHITECTURE, DEPLOYMENT, PACKAGE_ID, RELEASE_LABEL,
)

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True,
                          text=True, timeout=30)


def info(bundle):
    return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())


def files(folder):
    return {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in folder.rglob('*') if p.is_file()}


def audit(app):
    assert info(app)['SonoFerryReleaseLabel'] == RELEASE_LABEL
    engine = app / ENGINE_BUNDLE_PATH
    capture = engine / CAPTURE_BUNDLE_PATH
    driver = app / 'Contents/Resources' / DRIVER_NAME
    components = []
    expected = [
        (app, PRODUCT_NAME, APP_BUNDLE_ID, APP_VERSION, APP_BUILD),
        (engine, PRODUCT_NAME + ' Engine', ENGINE_BUNDLE_ID, COMPONENT_VERSION, COMPONENT_BUILD),
        (capture, PRODUCT_NAME + ' Audio', 'local.SonoFerry.ldac-audio', COMPONENT_VERSION, COMPONENT_BUILD),
        (driver, 'SonoFerry Output', 'local.SonoFerry.LDACOutput', '0.1.0', '1'),
    ]
    for bundle, name, identifier, version, build in expected:
        metadata = info(bundle)
        assert metadata['CFBundleName'] == name, (bundle, metadata)
        assert metadata['CFBundleIdentifier'] == identifier
        assert (metadata['CFBundleShortVersionString'], metadata['CFBundleVersion']) == (version, build)
        assert metadata['LSMinimumSystemVersion'] == DEPLOYMENT
        assert (bundle / 'Contents/MacOS' / metadata['CFBundleExecutable']).is_file()
        run('codesign', '--verify', '--deep', '--strict', bundle)
        components.append({'bundle': str(bundle.relative_to(app.parent)), 'identifier': identifier,
                           'version': version, 'build': build, 'signature': 'passed'})
    assert (app / ENGINE_EXECUTABLE_PATH).is_file()
    assert (engine / CAPTURE_EXECUTABLE_PATH).is_file()
    assert not any('macldac' in p.name.lower() for p in app.rglob('*')), 'Old filename in release'
    signature = run('codesign', '-d', '--verbose=4', engine)
    cdhash = re.search(r'^CDHash=(\w+)$', signature.stderr, re.M).group(1)
    assert info(driver)[ENGINE_HASH_KEY] == cdhash
    assert info(driver)['SonoFerryLDACDriverRevision'] == 7
    symbols = run('nm', driver / 'Contents/MacOS/SonoFerryVirtualOutput').stdout
    assert '_SonoFerryVirtualOutput_Create' in symbols
    assert 'VolumeObserver' not in symbols, 'Diagnostic HAL must not enter ordinary release'
    machos = []
    for p in app.rglob('*'):
        if not p.is_file():
            continue
        with p.open('rb') as f:
            magic = f.read(4)
        if magic != b'\xcf\xfa\xed\xfe':
            continue
        assert run('lipo', '-archs', p).stdout.strip() == ARCHITECTURE
        minimum = re.search(r'\bminos\s+(\S+)', run('vtool', '-show-build', p).stdout).group(1)
        assert minimum == DEPLOYMENT, (p, minimum)
        machos.append({'path': str(p.relative_to(app)), 'arch': ARCHITECTURE, 'minos': minimum})
    assert len(machos) == 8, machos
    licenses = app / 'Contents/Resources/Licenses'
    assert (licenses / 'AOSP-libldac-NOTICE.txt').read_bytes() == (ROOT / 'Vendor/libldac/NOTICE').read_bytes()
    assert (licenses / (PRODUCT_NAME + '.txt')).read_bytes() == (ROOT / 'LICENSE').read_bytes()
    return {'components': components, 'engineCDHash': cdhash, 'matchingHAL': True, 'machO': machos}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=pathlib.Path, help='Also expand and verify a PKG without installing it.')
    args = parser.parse_args()
    app = ROOT / 'dist' / (PRODUCT_NAME + '.app')
    result = audit(app)
    uninstaller = ROOT / 'dist' / ('卸载 ' + PRODUCT_NAME + '.app')
    metadata = info(uninstaller)
    assert (metadata['CFBundleShortVersionString'], metadata['CFBundleVersion']) == ('1.4', '5')
    assert metadata['CFBundleIdentifier'] == 'local.SonoFerry.Uninstaller'
    assert metadata['CFBundleExecutable'] == 'SonoFerryUninstaller'
    run('codesign', '--verify', '--deep', '--strict', uninstaller)
    binary = uninstaller / 'Contents/MacOS/SonoFerryUninstaller'
    assert run('lipo', '-archs', binary).stdout.strip() == ARCHITECTURE
    assert re.search(r'\bminos\s+(\S+)', run('vtool', '-show-build', binary).stdout).group(1) == DEPLOYMENT
    result['uninstaller'] = {'version': '1.4', 'build': '5', 'signature': 'passed'}
    if args.package:
        with tempfile.TemporaryDirectory(prefix='sonoferry-verify-') as temp:
            expanded = pathlib.Path(temp) / 'expanded'
            run('pkgutil', '--expand-full', args.package, expanded)
            apps = list(expanded.glob('**/Applications/SonoFerry.app'))
            assert len(apps) == 1
            assert files(apps[0]) == files(app)
            drivers = list(expanded.rglob(DRIVER_NAME))
            assert len(drivers) == 2
            assert files(drivers[0]) == files(drivers[1])
            assert not any('macldac' in p.name.lower() for p in expanded.rglob('*'))
            for source in (ROOT / 'Packaging/Install').iterdir():
                if source.is_file():
                    copies = list(expanded.glob('**/Scripts/' + source.name))
                    assert len(copies) == 1 and copies[0].read_bytes() == source.read_bytes(), source
            from xml.etree import ElementTree
            package_info = list(expanded.rglob('PackageInfo'))
            assert len(package_info) == 1
            attrs = ElementTree.parse(package_info[0]).getroot().attrib
            assert attrs['identifier'] == PACKAGE_ID and attrs['version'] == APP_VERSION
        result['package'] = {'path': str(args.package), 'size': args.package.stat().st_size,
                             'sha256': hashlib.sha256(args.package.read_bytes()).hexdigest(),
                             'payloadAndScriptsMatch': True}
    result.update(installed=False, restarted=False, playbackTested=False)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
