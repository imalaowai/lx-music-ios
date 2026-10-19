#!/usr/bin/env python3
"""Embed the existing web interface and its local dependencies, without its audio owner.

Usage: python3 scripts/bundle_web.py /path/to/lx-music-sync-server
The compressed, readable HTML is the versioned source artifact, not a remote loader.
"""
import base64, hashlib, html, json, lzma, mimetypes, pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parents[1]
source = pathlib.Path(sys.argv[1]).resolve()
music = source/'public/music'
entries = {}
omitted = {'queue_audio.js','room_start.js','ios_audio_output.js','ios-background-audio.js','listen_room.js','pwa.js','pwa_update.js'}
compiled_css = root/'build/native-css/tailwind.css'
subprocess.run(['node', str(root/'Engine/build-css.cjs'), str(source), str(compiled_css)], check=True)

def local(url, base):
    value = url.split('?',1)[0].split('#',1)[0]
    if value.startswith('/music/'): return music/value[7:]
    if value.startswith('/'): return source/'public'/value[1:]
    return (base/value).resolve()

def read(path):
    data = path.read_bytes()
    rel = path.relative_to(source).as_posix()
    entries[rel] = {'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
    return data

def data_url(path):
    mime = mimetypes.guess_type(path)[0] or 'application/octet-stream'
    return 'data:'+mime+';base64,'+base64.b64encode(read(path)).decode()

def image_urls(text):
    # Bundle fixed UI illustrations; album artwork remains fetched from its original service.
    def replace(match):
        quote,url=match.group(1,2)
        path=local(url,music)
        return quote+data_url(path)+quote if path.is_file() else match.group(0)
    return re.sub(r'''(["'])((?:/music/)?assets/[^"'\s<>]+\.(?:svg|png|jpg|webp))\1''',replace,text)

def script(match):
    url=html.unescape(match.group(1))
    name=url.split('?',1)[0].split('/')[-1]
    if name in omitted: return '<!-- Native layer owns '+name+' -->'
    if name == 'tailwindcss.js': return '<style data-source="native/precompiled-tailwind.css">'+compiled_css.read_text()+'</style>'
    if name == 'tailwind_setup.js':
        read(local(url,music))
        return '<!-- Tailwind theme configuration compiled before packaging -->'
    path=local(url,music)
    code=read(path).decode('utf-8')
    if name=='config.js': code += '\nwindow.CONFIG.disableTelemetry=true;\n'
    code=image_urls(code).replace('</script','<\\/script')
    return '<script data-source="'+html.escape(url,quote=True)+'">\n'+code+'\n</script>'

def stylesheet(match):
    url=html.unescape(match.group(1)); path=local(url,music)
    css=read(path).decode('utf-8')
    css=re.sub(r'@font-face\{[^}]*fa-v4compatibility[^}]*\}', '', css)
    # iOS 15 supports WOFF2. Keep one local format per icon font.
    css=re.sub(r',url\([^)]*\.ttf[^)]*\)\s*format\([^)]*\)','',css)
    def asset(m):
        value=m.group(1).strip('"\'')
        if value.startswith(('data:','http:','https:','#')): return m.group(0)
        target=local(value,path.parent)
        if not target.is_file(): raise ValueError('Missing CSS asset '+str(target))
        return 'url("'+data_url(target)+'")'
    css=re.sub(r'url\(([^)]+)\)',asset,css)
    return '<style data-source="'+html.escape(url,quote=True)+'">'+css+'</style>'

content=read(music/'index.html').decode('utf-8')
content=content.replace('<meta charset="UTF-8">','<meta charset="UTF-8"><script>window.__LX_BUNDLED_UI__=true;</script>')
content=re.sub(r'<link\s+rel="manifest"[^>]*>','',content)
content=re.sub(r'<script\s+src="([^"]+)"[^>]*>\s*</script>',script,content)
content=re.sub(r'<link\s+rel="stylesheet"\s+href="([^"]+)"[^>]*>',stylesheet,content)
content=image_urls(content)
assert not re.search(r'<script\s+src=',content)
assert 'navigator.serviceWorker.register(' not in content
payload=content.encode('utf-8')
(root/'Resources/WebUI.html.xz').write_bytes(lzma.compress(payload,preset=9))
manifest={'version':'2.8.6-native-1.2.1','htmlSha256':hashlib.sha256(payload).hexdigest(),'htmlBytes':len(payload),'assets':entries,'excludedNativeOwners':sorted(omitted),'precompiledStyles':True,'runtimeStyleCompiler':False}
(root/'Resources/WebUI.manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
print(json.dumps({'assets':len(entries),'htmlBytes':len(payload),'compressedBytes':(root/'Resources/WebUI.html.xz').stat().st_size,'sha256':manifest['htmlSha256']}))
