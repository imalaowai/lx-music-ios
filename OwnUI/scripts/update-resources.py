#!/usr/bin/env python3
"""Update an already integrated own-UI IPA, retaining all native binaries.

update-resources.py OWN_V15_IPA LDID OUTPUT_IPA
No reference UI or executable is substituted. Rebuild native components with the
normal workflow when Swift/Objective-C behavior changes.
"""
import copy,hashlib,importlib.util,json,os,pathlib,plistlib,stat,subprocess,sys,tempfile,zipfile
root=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('full_package',root/'FullReference/scripts/package.py')
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
sha=lambda b:hashlib.sha256(b).hexdigest()
def package(source,signer,output):
    source,signer,output=map(pathlib.Path,[source,signer,output])
    assert sha(source.read_bytes())=='24c67c8043ea52ab5ac41b30d4977d95e035a9ee707f4932ad820b055b264d87','Expected the complete own-UI v15 release'
    subprocess.run([sys.executable,str(root/'OwnUI/scripts/prepare.py')],check=True)
    resources=root/'build/own-ui/resources'
    with zipfile.ZipFile(source) as z,tempfile.TemporaryDirectory(prefix='qiye-own-update-') as work:
        assert z.testzip() is None
        prefix='Payload/LxMusicMobile.app/';app=pathlib.Path(work)/prefix
        for info in z.infolist():
            relative=pathlib.PurePosixPath(info.filename)
            assert not relative.is_absolute() and '..' not in relative.parts
            p=pathlib.Path(work)/info.filename;p.parent.mkdir(parents=True,exist_ok=True)
            if info.is_dir():p.mkdir(exist_ok=True);continue
            mode=info.external_attr>>16
            if stat.S_ISLNK(mode):p.symlink_to(z.read(info).decode());continue
            p.write_bytes(z.read(info));p.chmod(mode&0o777 or 0o644)
        old_manifest=json.loads((app/'OwnUI.manifest.json').read_text())
        assert old_manifest['phoneUI']=='own-local-ui'
        old_main=z.read(prefix+'LxMusicMobile');ent=base.entitlements(old_main)
        assert ent['com.apple.developer.carplay-audio'] is True
        for p in resources.iterdir():
            if p.is_file():(app/p.name).write_bytes(p.read_bytes())
        info=plistlib.loads((app/'Info.plist').read_bytes())
        info.update(CFBundleShortVersionString='1.9.3',CFBundleVersion='86')
        (app/'Info.plist').write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_BINARY))
        ent_file=pathlib.Path(work)/'entitlements.plist';ent_file.write_bytes(plistlib.dumps(ent))
        env=dict(os.environ);env['LD_LIBRARY_PATH']=str(signer.resolve().parent)+':'+env.get('LD_LIBRARY_PATH','')
        subprocess.run([str(signer.resolve()),'-w','-S'+str(ent_file),str(app)],env=env,check=True)
        new_main=(app/'LxMusicMobile').read_bytes();assert base.entitlements(new_main)==ent
        for name,(offset,length) in base.sections(old_main).items():
            next_offset,next_length=base.sections(new_main)[name]
            assert length==next_length and old_main[offset:offset+length]==new_main[next_offset:next_offset+length],name
        allowed={prefix+n for n in ['Info.plist','LxMusicMobile',*(p.name for p in resources.iterdir() if p.is_file())]}
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
        report={'version':'1.9.3','build':86,'base':'own UI v15','baseBytes':source.stat().st_size,'bytes':output.stat().st_size,'sha256':sha(output.read_bytes()),'originalFilesRemoved':[],'originalFilesRetainedByteForByte':len(retained),'changedFiles':changed,'nativeExecutableSectionsPreserved':True,'integrationBinaryPreserved':True}
        output.with_suffix('.verification.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
        print(json.dumps(report,ensure_ascii=False))
if __name__=='__main__':package(*sys.argv[1:])
