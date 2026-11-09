#!/usr/bin/env python3
"""Rebuild an already integrated full own-UI IPA with verified native components.

update-components.py OWN_1_9_16_IPA COMPONENTS_ZIP LDID OUTPUT_IPA
Preserves the reference executable sections, frameworks, resources and identity.
The own integration module and Hermes entry come from the native CI build.
"""
import copy,hashlib,importlib.util,json,os,pathlib,plistlib,stat,subprocess,sys,tempfile,zipfile
root=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('full_package',root/'FullReference/scripts/package.py')
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
sha=lambda b:hashlib.sha256(b).hexdigest()
def package(source,components,signer,output):
    source,components,signer,output=map(pathlib.Path,[source,components,signer,output])
    source_sha=sha(source.read_bytes())
    assert source_sha=='b494f3d718082118ffacc028b887d7e939f624ebc797100a144ee2d12f0317e0','Expected the previously delivered complete 1.9.16 / build 104 IPA'
    with zipfile.ZipFile(source) as z,zipfile.ZipFile(components) as additions,tempfile.TemporaryDirectory(prefix='qiye-own-rebuild-') as work:
        assert z.testzip() is None and additions.testzip() is None
        prefix='Payload/LxMusicMobile.app/';app=pathlib.Path(work)/prefix
        for info in z.infolist():
            relative=pathlib.PurePosixPath(info.filename)
            assert not relative.is_absolute() and '..' not in relative.parts
            p=pathlib.Path(work)/info.filename;p.parent.mkdir(parents=True,exist_ok=True)
            if info.is_dir():p.mkdir(exist_ok=True);continue
            mode=info.external_attr>>16
            if stat.S_ISLNK(mode):
                target=z.read(info).decode();resolved=(p.parent/target).resolve()
                assert resolved.is_relative_to(pathlib.Path(work).resolve()),'Archive symlink escapes app'
                p.symlink_to(target);continue
            p.write_bytes(z.read(info));p.chmod(mode&0o777 or 0o644)
        old_manifest=json.loads((app/'OwnUI.manifest.json').read_text())
        assert old_manifest['phoneUI']=='own-local-ui'
        old_main=z.read(prefix+'LxMusicMobile');ent=base.entitlements(old_main)
        assert ent['com.apple.developer.carplay-audio'] is True
        metadata=json.loads(additions.read('components.json'))
        assert metadata['ownUI'] is True and metadata['version']=='1.9.17' and metadata['build']=='105'
        assert metadata['iconMasterSha256']==sha((root/'OwnUI/Brand/CartoonIcon.png').read_bytes())
        js=additions.read('main.jsbundle');module=additions.read('LXFullCarPlay.dylib')
        assert module!=z.read(prefix+'Frameworks/LXFullCarPlay.dylib'),'Expected newly rebuilt native integration'
        assert sha(js)==metadata['jsSha256'] and b'LXOwnUIRootView' in module and b'LXOwnUIBridge' in module
        assert b'LXNativeRemoteTarget' in module,'Native play/pause/toggle transport integration missing'
        assert b'lx.queueProgress' in module, 'Native playback checkpoint missing'
        assert b'positionSampledAt' in module, 'Native decoder sample timestamp missing'
        assert b'ServerAuthorizationRejected' in module and b'/api/user/auth/verify' in module, 'Verified native session recovery missing'
        assert b'/usr/lib/swift/libswiftWebKit.dylib' not in module, 'WebKit Swift overlay breaks older iOS runtimes'
        assert b'LXOwnCarPlayDisconnected' in module and b'carPlayActionPending' in module,'Native CarPlay startup integration missing'
        assert __import__('struct').unpack_from('<I',js,8)[0]==96,'Hermes bytecode must match the retained runtime'
        assert b'LXOwnUI.Screen' in js and b'LXOwnUIRoot' in js
        assert metadata['clockABI']=='ios-native-seconds' and b'iOS native playback clock is unavailable' in js,'Native clock adapter missing'
        bridge=additions.read('OwnUIResources/Bridge.js')
        assert b'compactLayout:' in bridge and b'nativeSnapshot:' in bridge, 'Phone readiness proof missing'
        assert b'positionSampledAt' in bridge and b'projectionLimit' in bridge, 'Playback clock fix missing'
        assert all(marker in bridge for marker in (b'renderedPaused',b'!account.revoked',b'state.error !== previous.error')), 'Playback button, error notice or account recovery fix missing'
        assert b'window.LXBridge?.getPlayback().paused ?? audio.paused' in additions.read('OwnUIResources/WebUI.html'), 'Mini-player transport fix missing'
        manifest=json.loads(additions.read('OwnUIResources/OwnUI.manifest.json'))
        assert manifest['phoneUI']=='own-local-ui' and manifest['entry']=='OwnUI/index.js'
        assert {'AppShell.js','AppShell.css','Bridge.js','WebUI.html','LocalEngine.js'}<=set(manifest['resources'])
        resource_names=[*manifest['resources'],'OwnUI.manifest.json']
        for name in resource_names:
            assert pathlib.PurePosixPath(name).name==name
            data=additions.read('OwnUIResources/'+name)
            if name in manifest['resources']:assert sha(data)==manifest['resources'][name]
            (app/name).write_bytes(data)
        (app/'main.jsbundle').write_bytes(js)
        (app/'Frameworks/LXFullCarPlay.dylib').write_bytes(module)
        info=plistlib.loads((app/'Info.plist').read_bytes())
        assert info['CFBundleIdentifier']=='cn.toside.music.cplay3' and info['CFBundleVersion']=='104'
        info.update(CFBundleShortVersionString=metadata['version'],CFBundleVersion=metadata['build'])
        brand=plistlib.loads(additions.read('OwnUIBrand/BrandInfo.plist'))
        for key in ['CFBundleIcons','CFBundleIcons~ipad']:
            assert key in brand,'Missing compiled icon metadata: '+key
            info[key]=brand[key]
        brand_names=set(metadata['brandResources'])
        assert {'Assets.car','AppIcon60x60@2x.png','AppIcon60x60@3x.png','AppIcon60x60@2x~car.png','AppIcon60x60@3x~car.png'}<=brand_names
        for name in brand_names:
            assert pathlib.PurePosixPath(name).name==name and pathlib.Path(name).suffix in ['.png','.car']
            data=additions.read('OwnUIBrand/'+name)
            assert sha(data)==metadata['brandResources'][name],name
            (app/name).write_bytes(data)
        (app/'Info.plist').write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_BINARY))
        ent_file=pathlib.Path(work)/'entitlements.plist';ent_file.write_bytes(plistlib.dumps(ent))
        env=dict(os.environ);env['LD_LIBRARY_PATH']=str(signer.resolve().parent)+':'+env.get('LD_LIBRARY_PATH','')
        subprocess.run([str(signer.resolve()),'-w','-S'+str(ent_file),str(app)],env=env,check=True)
        new_main=(app/'LxMusicMobile').read_bytes();assert base.entitlements(new_main)==ent
        for name,(offset,length) in base.sections(old_main).items():
            next_offset,next_length=base.sections(new_main)[name]
            assert length==next_length and old_main[offset:offset+length]==new_main[next_offset:next_offset+length],name
        allowed={prefix+n for n in ['Info.plist','LxMusicMobile','_CodeSignature/CodeResources','main.jsbundle','Frameworks/LXFullCarPlay.dylib',*resource_names,*brand_names]}
        changed=[];retained=[]
        for item in z.infolist():
            if item.is_dir():continue
            p=pathlib.Path(work)/item.filename
            data=os.readlink(p).encode() if p.is_symlink() else p.read_bytes()
            if data!=z.read(item):assert item.filename in allowed,item.filename;changed.append(item.filename)
            else:retained.append(item.filename)
        output.parent.mkdir(parents=True,exist_ok=True)
        old_names=set(z.namelist())
        with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as out:
            for item in z.infolist():
                p=pathlib.Path(work)/item.filename
                data=b'' if item.is_dir() else os.readlink(p).encode() if p.is_symlink() else p.read_bytes()
                out.writestr(copy.copy(item),data)
            for p in sorted(app.rglob('*')):
                name=p.relative_to(work).as_posix()
                if p.is_file() and name not in old_names:
                    item=zipfile.ZipInfo(name);item.compress_type=zipfile.ZIP_DEFLATED;item.external_attr=(stat.S_IFREG|0o644)<<16;out.writestr(item,p.read_bytes())
        with zipfile.ZipFile(output) as rebuilt:assert rebuilt.testzip() is None
        report={'version':metadata['version'],'build':int(metadata['build']),'base':'previously delivered 1.9.16 / build 104','baseSha256':source_sha,'baseBytes':source.stat().st_size,'bytes':output.stat().st_size,'sha256':sha(output.read_bytes()),'originalFilesRemoved':[],'originalFilesRetainedByteForByte':len(retained),'changedFiles':changed,'nativeExecutableSectionsPreserved':True,'integrationBinaryRebuilt':True,'sourceCommit':metadata['sourceCommit'],'componentsSha256':sha(components.read_bytes()),'iconMasterSha256':metadata['iconMasterSha256'],'brandResourcesVerified':len(brand_names),'physicalCarPlayVerified':False,'packagerSha256':sha(pathlib.Path(__file__).read_bytes())}
        output.with_suffix('.verification.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
        print(json.dumps(report,ensure_ascii=False))
if __name__=='__main__':package(*sys.argv[1:])
