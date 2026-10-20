#!/usr/bin/env python3
"""Materialize the exact owned UI and local source engine for the integrated IPA."""
import hashlib,json,lzma,pathlib,shutil
root=pathlib.Path(__file__).resolve().parents[2]
old=root/'NativeCompanion'
out=root/'build/own-ui/resources';out.mkdir(parents=True,exist_ok=True)
for name,extension,key in [('WebUI','html','htmlSha256'),('LocalEngine','js','sha256')]:
    data=lzma.decompress((old/f'Resources/{name}.{extension}.xz').read_bytes())
    metadata=json.loads((old/f'Resources/{name}.manifest.json').read_text())
    assert hashlib.sha256(data).hexdigest()==metadata[key],name+' integrity mismatch'
    (out/f'{name}.{extension}').write_bytes(data)
for name in ['Bridge.js','AppShell.js','AppShell.css','ThirdPartyNotices.txt']:
    shutil.copy2(old/'Resources'/name,out/name)
manifest={'phoneUI':'own-local-ui','entry':'OwnUI/index.js','pages':['home','playlists','room-chat','mine','downloads','sources','settings','local-and-cloud'],'resources':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir()) if p.is_file() and p.name!='OwnUI.manifest.json'}}
(out/'OwnUI.manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
# Browser checks use the same bytes as the device runtime.
(old/'generated').mkdir(exist_ok=True)
shutil.copy2(out/'WebUI.html',old/'generated/WebUI.html')
shutil.copy2(out/'LocalEngine.js',old/'generated/LocalEngine.js')
print(json.dumps({'resources':len(manifest['resources']),'phoneUI':manifest['phoneUI'],'webBytes':(out/'WebUI.html').stat().st_size}))
