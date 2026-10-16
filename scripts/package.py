#!/usr/bin/env python3
import argparse,pathlib,shutil,subprocess,tempfile,plistlib,sys
from build_settings import PRODUCT_NAME, DRIVER_NAME, PACKAGE_ID
ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description='Build the install package and standalone uninstaller; never installs or uninstalls.')
parser.add_argument('--uninstaller-only',action='store_true',help='Only build the uninstaller; leave the App, HAL and install package unchanged.')
args=parser.parse_args()
if args.uninstaller_only:
    subprocess.run([sys.executable,str(ROOT/'scripts/build-uninstaller.py')],check=True)
    sys.exit(0)
app=ROOT/'dist'/(PRODUCT_NAME+'.app')
metadata=plistlib.loads((app/'Contents/Info.plist').read_bytes())
version=metadata['CFBundleShortVersionString']
release=metadata.get('SonoFerryReleaseLabel', '').replace(' ', '')
package_name=PRODUCT_NAME+'-'+version+('-'+release if release else '')+'.pkg'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
with tempfile.TemporaryDirectory(prefix='sonoferry-package-',dir=ROOT/'.build') as temp:
    root=pathlib.Path(temp)/'root';(root/'Applications').mkdir(parents=True)
    shutil.copytree(app,root/'Applications'/app.name,symlinks=True)
    driver=root/'Library/Audio/Plug-Ins/HAL'/DRIVER_NAME;driver.parent.mkdir(parents=True)
    shutil.copytree(app/'Contents/Resources'/DRIVER_NAME,driver,symlinks=True)
    for script in (ROOT/'Packaging/Install').iterdir():script.chmod(0o755)
    components=pathlib.Path(temp)/'components.plist'
    subprocess.run(['pkgbuild','--analyze','--root',str(root),str(components)],check=True)
    values=plistlib.loads(components.read_bytes())
    for value in values:
        value['BundleIsRelocatable']=False
        value['BundleIsVersionChecked']=False
    components.write_bytes(plistlib.dumps(values))
    subprocess.run(['pkgbuild','--root',str(root),'--component-plist',str(components),'--identifier',PACKAGE_ID,'--version',version,
        '--ownership','recommended','--scripts',str(ROOT/'Packaging/Install'),'--install-location','/',str(ROOT/'dist'/package_name)],check=True)
subprocess.run([sys.executable,str(ROOT/'scripts/build-uninstaller.py')],check=True)
print('Installer and standalone uninstaller built. Administrator authorization and a subsequent manual restart are required to install/remove the HAL.')
