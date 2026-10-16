#!/usr/bin/env python3
"""Optional verification dependency; never included in app/pkg. Pinned SHA-256 files."""
import hashlib,json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
for filename, directory, repository, prefix in [
    ('reference-decoder.json','reference-decoder','WillyBilly06/LHDC-V5-Decoder','decoder/'),
    ('reference-ldac-decoder.json','reference-ldac-decoder','hegdi/libldacdec','')]:
    manifest=json.loads((ROOT/'Configuration'/filename).read_text())
    folder=ROOT/'work'/directory;folder.mkdir(parents=True,exist_ok=True)
    for name,checksum in manifest['files'].items():
        path=folder/name
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest()!=checksum:
            url='https://raw.githubusercontent.com/'+repository+'/'+manifest['commit']+'/'+prefix+name
            subprocess.run(['curl','-L','--fail','--silent','--show-error','--max-time','30',url,'-o',str(path)],check=True)
        if hashlib.sha256(path.read_bytes()).hexdigest()!=checksum:raise SystemExit('SHA-256 mismatch: '+name)
print('Reference decoder files verified; run python3 scripts/test.py --reference')
