#!/usr/bin/env python3
"""Materialize the exact owned UI and local source engine for the integrated IPA."""
import hashlib,json,lzma,pathlib,re,shutil
from patch_web_ui import patch_web_ui
root=pathlib.Path(__file__).resolve().parents[2]
old=root/'NativeCompanion'
out=root/'build/own-ui/resources';out.mkdir(parents=True,exist_ok=True)
for name,extension,key in [('WebUI','html','htmlSha256'),('LocalEngine','js','sha256')]:
    data=lzma.decompress((old/f'Resources/{name}.{extension}.xz').read_bytes())
    metadata=json.loads((old/f'Resources/{name}.manifest.json').read_text())
    assert hashlib.sha256(data).hexdigest()==metadata[key],name+' integrity mismatch'
    if name=='LocalEngine':
        patches = [
            (b'new Function("lx","require","Buffer",e.script+`\n//# sourceURL=imported-music-source.js`)(w,A,T.Buffer)',
             b'runImportedMusicSource(e.script,w,A,T.Buffer)'),
            (b'let b=p.sources[a.source]?.qualitys||p.sources[a.source]?.qualities||["128k","320k","flac"],_=[t,...r?["flac","320k","128k"]:[]].filter((w,E,A)=>A.indexOf(w)===E&&b.includes(w))',
             b'let b=p.sources[a.source],_=localSourceQualities(b?.qualitys||b?.qualities,t,r)'),
            (b'let E=await p.handler({source:a.source,action:"musicUrl",info:{musicInfo:a,type:w}}),A=typeof E=="string"?E:E?.url;if(!/^https?:\\/\\//i.test(A||""))throw new Error("\\u97F3\\u6E90\\u6CA1\\u6709\\u8FD4\\u56DE\\u6709\\u6548\\u7684\\u64AD\\u653E\\u5730\\u5740");return{url:A,type:w,sourceId:p.id}',
             b'return localSourceAudio(await p.handler({source:a.source,action:"musicUrl",info:{musicInfo:a,type:w,quality:w}}),w,p.id)'),
        ]
        for anchor, replacement in patches:
            assert data.count(anchor) == 1, 'Local source compatibility anchor changed'
            data = data.replace(anchor, replacement)
        source_compat = (old/'Engine/src/source-compat.cjs').read_bytes().split(b'if (typeof module', 1)[0]
        data = source_compat + b'\n' + data
        marker=b'var Bx=e=>e?.promise||e;'
        replacement=b'var Bx=async e=>{for(let i=0;i<8;i++){e=await e;if(e&&typeof e.promise?.then==="function"){e=e.promise;continue}return e}throw new Error("Provider response nesting is too deep")};'
        assert data.count(marker)==1,'Provider response unwrap anchor changed; review cover/lyric resolver'
        data=data.replace(marker,replacement)
        marker=b'return r.promise.then(({body:a})=>{if(a.returnCode!=="000000")'
        replacement=b'return r.promise=r.promise.then(({body:a})=>{if(a.returnCode!=="000000")'
        assert data.count(marker)==1,'Migu cover response mapping anchor changed'
        data=data.replace(marker,replacement)
        marker=rb'if(t>5)return Promise.reject(new Error("\u56FE\u7247\u83B7\u53D6\u5931\u8D25"));let u=this.getPic(e,++t);return r.cancelHttp=u.cancelHttp.bind(u),u.promise'
        replacement=b'if(t>=2)throw new Error("Provider artwork request failed");return this.getPicUrl(e,t+1).then(u=>u.promise||u)'
        assert data.count(marker)==1,'Migu cover retry anchor changed'
        data=data.replace(marker,replacement)
        marker=b'case"/api/music/comment":return kx(i.songInfo).comment[i.type==="hot"?"getHotComment":"getComment"](i.songInfo,i.page||1,i.limit||20);'
        assert data.count(marker)==1,'Provider comment route anchor changed'
        helper=(old/'Engine/src/comment.cjs').read_bytes().split(b'if (typeof module',1)[0]
        data=helper+b'\n'+data.replace(marker,b'case"/api/music/comment":return routeComment(i,kx);')
    if name=='WebUI':
        html=data.decode()
        for override in sorted((old/'WebOverrides').glob('*.js')):
            pattern=r'(<script\b[^>]*data-source="js/'+re.escape(override.name)+r'\?[^"\n]*"[^>]*>).*?(</script>)'
            html,count=re.subn(pattern,lambda m:m[1]+override.read_text()+m[2],html,flags=re.S)
            if count==0 and override.name=='library_sync.js':
                anchor=re.search(r'<script\b[^>]*data-source="js/library_hub\.js\?[^"\n]*"[^>]*>',html)
                assert anchor,'Missing library script anchor'
                html=html[:anchor.start()]+'<script data-source="js/library_sync.js?v=2.9.1">'+override.read_text()+'</script>\n'+html[anchor.start():]
                count=1
            assert count==1,'Missing bundled script: '+override.name
        html=html.replace('<title>LX Music', '<title>栖页音乐')
        data=patch_web_ui(html).encode()
    (out/f'{name}.{extension}').write_bytes(data)
for name in ['Bridge.js','AppShell.js','AppShell.css','ThirdPartyNotices.txt']:
    shutil.copy2(old/'Resources'/name,out/name)
manifest={'brand':'栖页音乐','phoneUI':'own-local-ui','entry':'OwnUI/index.js','pages':['home','playlists','room-chat','mine','downloads','sources','settings','local-and-cloud'],'resources':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir()) if p.is_file() and p.name!='OwnUI.manifest.json'}}
(out/'OwnUI.manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
# Browser checks use the same bytes as the device runtime.
(old/'generated').mkdir(exist_ok=True)
shutil.copy2(out/'WebUI.html',old/'generated/WebUI.html')
shutil.copy2(out/'LocalEngine.js',old/'generated/LocalEngine.js')
print(json.dumps({'resources':len(manifest['resources']),'phoneUI':manifest['phoneUI'],'webBytes':(out/'WebUI.html').stat().st_size}))
