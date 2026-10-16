#!/usr/bin/env python3
import hashlib, json, pathlib, subprocess, sys
from build_settings import ARCHITECTURE, DEPLOYMENT, SWIFT_TARGET, PRODUCT_NAME, ENGINE_BUNDLE_PATH, CAPTURE_EXECUTABLE_PATH
ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD=ROOT/'.build/native'
HELPERS=ROOT/'dist'/(PRODUCT_NAME+'.app')/ENGINE_BUNDLE_PATH/'Contents/Helpers'
def run(*args): subprocess.run([str(x) for x in args],cwd=ROOT,check=True)
run(sys.executable, ROOT/'scripts/generate-headphone-catalog.py', '--check')
run(sys.executable, ROOT/'Tests/Uninstaller/test_remove.py')
run(sys.executable, ROOT/'Tests/Installer/test_brand_migration.py')
run(sys.executable, ROOT/'Tests/Installer/test_clean_build.py')
run(sys.executable, ROOT/'Tests/Native/route-owner-contract.py')
run('xcrun','swiftc','-target',SWIFT_TARGET,'-swift-version','5','-parse-as-library','-module-cache-path',ROOT/'.build/uninstaller-module-cache',
    ROOT/'Packaging/Uninstall/UserDataRemoval.swift',ROOT/'Tests/Uninstaller/UserDataRemovalTests.swift','-o',ROOT/'.build/UserDataRemovalTests')
run(ROOT/'.build/UserDataRemovalTests')
run('swift','test','--scratch-path','.build/tests','--cache-path','.build/swift-cache','--disable-sandbox')
for helper in ['AVDTPSignaling','MediaTransport']:
    run(HELPERS/helper,'--self-test')
run(HELPERS/'MediaTransport','--sender-self-test')
run('xcrun','clang','-arch',ARCHITECTURE,'-mmacosx-version-min='+DEPLOYMENT,'-Wall','-Wextra','-Werror','-O2',ROOT/'Tests/Native/SenderWaitTests.c','-o',BUILD/'SenderWaitTests')
run(BUILD/'SenderWaitTests')
run('xcrun','clang','-arch',ARCHITECTURE,'-mmacosx-version-min='+DEPLOYMENT,'-Wall','-Wextra','-Werror','-O2',ROOT/'Tests/Native/NativeRestoreTests.c','-o',BUILD/'NativeRestoreTests')
run(BUILD/'NativeRestoreTests')
run('xcrun','swiftc','-target',SWIFT_TARGET,'-swift-version','5','-O','-parse-as-library',
    '-I',BUILD,'-L',BUILD,'-lSonoFerryCore',ROOT/'Sources/App/BoundedCommand.swift',ROOT/'Sources/App/StartupHealthController.swift',ROOT/'Sources/App/ApplicationPreferences.swift',ROOT/'Sources/App/EngineClient.swift',ROOT/'Tests/App/EngineClientTests.swift',
    '-o',BUILD/'EngineClientTests')
run(BUILD/'EngineClientTests')
run('xcrun','swiftc','-target',SWIFT_TARGET,'-swift-version','5','-O','-parse-as-library',
    '-I',BUILD,'-L',BUILD,'-lSonoFerryCore',ROOT/'Sources/App/BoundedCommand.swift',ROOT/'Sources/App/StartupHealthController.swift',ROOT/'Sources/App/ApplicationPreferences.swift',ROOT/'Sources/App/EngineClient.swift',ROOT/'Tests/App/DeviceLibraryTests.swift',
    '-o',BUILD/'DeviceLibraryTests')
run(BUILD/'DeviceLibraryTests')
run('xcrun','swiftc','-target',SWIFT_TARGET,'-swift-version','5','-O','-parse-as-library',
    '-I',BUILD,'-L',BUILD,'-lSonoFerryCore',ROOT/'Sources/App/BoundedCommand.swift',ROOT/'Sources/App/StartupHealthController.swift',
    ROOT/'Tests/App/StartupHealthTests.swift','-o',BUILD/'StartupHealthTests')
run(BUILD/'StartupHealthTests')
run('xcrun','swiftc','-target',SWIFT_TARGET,'-swift-version','5','-O','-parse-as-library',
    '-I',BUILD,'-L',BUILD,'-lSonoFerryCore',ROOT/'Sources/App/BoundedCommand.swift',ROOT/'Sources/App/StartupHealthController.swift',ROOT/'Sources/App/ApplicationPreferences.swift',ROOT/'Sources/App/EngineClient.swift',ROOT/'Sources/App/HeadsetSoundView.swift',
    ROOT/'Sources/App/DynaudioBadge.swift',ROOT/'Tests/App/HeadsetSoundViewTests.swift','-o',BUILD/'HeadsetSoundViewTests')
run(BUILD/'HeadsetSoundViewTests')
run('xcrun','swiftc','-target',SWIFT_TARGET,'-swift-version','5','-O','-parse-as-library',
    '-I',BUILD,'-L',BUILD,'-lSonoFerryCore',ROOT/'Sources/Engine/OppoControlConnection.swift',
    ROOT/'Sources/Engine/HeadsetControlService.swift',ROOT/'Tests/Engine/HeadsetServiceTests.swift',
    '-o',BUILD/'HeadsetServiceTests')
run(BUILD/'HeadsetServiceTests')
run('xcrun','swiftc','-target',SWIFT_TARGET,'-swift-version','5','-O','-parse-as-library',
    '-D','CONTROL_COORDINATOR_TESTS','-I',BUILD,'-L',BUILD,'-lSonoFerryCore',
    *sorted((ROOT/'Sources/Engine').glob('*.swift')), ROOT/'Tests/Engine/HeadsetServiceTests.swift',
    ROOT/'Tests/Engine/ControlCoordinatorTests.swift','-o',BUILD/'ControlCoordinatorTests')
run(BUILD/'ControlCoordinatorTests')
run('xcrun','swiftc','-target',SWIFT_TARGET,'-swift-version','5','-O','-parse-as-library',
    '-I',BUILD,'-L',BUILD,'-lSonoFerryCore',ROOT/'Sources/Engine/NativeSession.swift',ROOT/'Tests/Native/SessionRecoveryTests.swift',
    '-o',BUILD/'SessionRecoveryTests')
run(BUILD/'SessionRecoveryTests')
for check in ['--check-stream-ring', '--check-stream-rates', '--permission-self-test']:
    run(HELPERS.parent.parent/CAPTURE_EXECUTABLE_PATH,check)
objects = [BUILD/'LHDCBackend.o', *[BUILD/(p.stem+'.o') for p in (ROOT/'Vendor/lhdcv5/src').glob('*.c')]]
flags=['xcrun','clang','-arch',ARCHITECTURE,'-mmacosx-version-min='+DEPLOYMENT,'-O2','-ffp-contract=off','-I',ROOT/'Vendor/lhdcv5/include']
run(*flags,ROOT/'Tests/Native/LHDCBackendTests.c',*objects,'-o',BUILD/'LHDCBackendTests')
run(BUILD/'LHDCBackendTests')
if '--reference' in sys.argv:
    for filename, folder in [('reference-decoder.json','reference-decoder'),('reference-ldac-decoder.json','reference-ldac-decoder')]:
        for name, checksum in json.loads((ROOT/'Configuration'/filename).read_text())['files'].items():
            file=ROOT/'work'/folder/name
            if not file.exists() or hashlib.sha256(file.read_bytes()).hexdigest()!=checksum:
                raise SystemExit('Reference decoder mismatch: '+str(file)+'; run scripts/fetch-reference-decoder.py')
    reference=ROOT/'work/reference-decoder'
    run(*flags,'-DLHDC_HOST_BUILD=1','-DSONOFERRY_REFERENCE_DECODE=1','-I',reference,
        ROOT/'Tests/Native/LHDCBackendTests.c',*objects,*sorted(reference.glob('*.c')),'-o',BUILD/'LHDCRoundtripTests')
    run(BUILD/'LHDCRoundtripTests')
    ldac=ROOT/'work/reference-ldac-decoder'
    run(*flags,'-I',ldac,'-I',ROOT/'Vendor/libldac/inc','-I',ROOT/'Vendor/libldac/src',
        ROOT/'Tests/Native/LDACRoundtripTests.c',BUILD/'ldacBT.o',BUILD/'ldaclib.o',
        *[ldac/name for name in ['libldacdec.c','bit_allocation.c','huffCodes.c','bit_reader.c','utility.c','imdct.c','spectrum.c']],
        '-o',BUILD/'LDACRoundtripTests')
    run(BUILD/'LDACRoundtripTests')
run('xcrun','clang','-arch',ARCHITECTURE,'-mmacosx-version-min='+DEPLOYMENT,'-std=gnu11','-fblocks','-I',BUILD,'-framework','CoreAudio','-framework','CoreFoundation','-framework','Security',ROOT/'Tests/Native/DriverTests.c','-o',BUILD/'DriverTests')
run(BUILD/'DriverTests')
run(sys.executable, ROOT/'Tests/Native/reject-unsupported-volume.py')
run(sys.executable, ROOT/'Tests/Native/reject-invalid-force.py')
run(sys.executable, ROOT/'Tests/Native/deferred-helper-startup.py')
print('All selected checks passed.')
