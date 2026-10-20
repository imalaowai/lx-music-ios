#!/usr/bin/env python3
"""Add components to the user-owned full reference IPA without distributing that input.

package.py REFERENCE_IPA COMPONENTS_ZIP LDID OUTPUT_IPA
All original immutable resources and executable sections are verified, byte for byte.
"""
import copy, hashlib, io, json, os, pathlib, plistlib, struct, subprocess, sys, tempfile, zipfile

REFERENCE_SHA = 'ca6e8331816d69f42e41a22bdb10a3efc18df66b58b0a4e1cda4a900e2e1eb9e'
DYLIB = '@executable_path/Frameworks/LXFullCarPlay.dylib'
def sha(value): return hashlib.sha256(value).hexdigest()

def commands(binary):
    assert struct.unpack_from('<II',binary)==(0xfeedfacf,0x0100000c),'Expected unencrypted thin arm64'
    cursor=32
    for _ in range(struct.unpack_from('<I',binary,16)[0]):
        cmd,size=struct.unpack_from('<II',binary,cursor)
        assert size>=8 and cursor+size<=len(binary)
        yield cursor,cmd,size
        cursor+=size

def sections(binary):
    result={}
    for pos,cmd,size in commands(binary):
        if cmd==0x19:
            segment=binary[pos+8:pos+24].split(b'\0')[0].decode()
            for i in range(struct.unpack_from('<I',binary,pos+64)[0]):
                at=pos+72+80*i; name=binary[at:at+16].split(b'\0')[0].decode()
                length=struct.unpack_from('<Q',binary,at+40)[0];off=struct.unpack_from('<I',binary,at+48)[0]
                if off and length:result[segment+','+name]=(off,length)
        elif cmd==0x2c:assert struct.unpack_from('<I',binary,pos+16)[0]==0,'Encrypted executables are unsupported'
    return result

def entitlements(binary):
    for pos,cmd,size in commands(binary):
        if cmd==0x1d:
            off,length=struct.unpack_from('<II',binary,pos+8);sig=binary[off:off+length]
            assert struct.unpack_from('>I',sig)[0]==0xfade0cc0
            for i in range(struct.unpack_from('>I',sig,8)[0]):
                slot,start=struct.unpack_from('>II',sig,12+8*i)
                if slot==5:
                    length=struct.unpack_from('>I',sig,start+4)[0]
                    return plistlib.loads(sig[start+8:start+length])
    raise AssertionError('Missing signing entitlements')

def inject(binary):
    out=bytearray(binary);n,size=struct.unpack_from('<II',binary,16);start=32+size
    name=DYLIB.encode()+b'\0';length=(24+len(name)+7)//8*8
    first=min(off for off,length in sections(binary).values())
    assert start+length<=first and not any(binary[start:start+length]),'No safe load-command padding'
    out[start:start+length]=struct.pack('<IIIIII',0xc,length,24,0,0x10000,0x10000)+name+b'\0'*(length-24-len(name))
    struct.pack_into('<II',out,16,n+1,size+length)
    return bytes(out)

def package(reference,components,signer,output):
    raw=pathlib.Path(reference).read_bytes();assert sha(raw)==REFERENCE_SHA,'Wrong reference IPA; refusing a different base'
    with zipfile.ZipFile(io.BytesIO(raw)) as original,zipfile.ZipFile(components) as additions:
        assert original.testzip() is None and additions.testzip() is None
        info_name=next(n for n in original.namelist() if n.startswith('Payload/') and n.count('/')==2 and n.endswith('Info.plist'))
        prefix=info_name[:-10];info=plistlib.loads(original.read(info_name));exe_name=prefix+info['CFBundleExecutable'];old_exe=original.read(exe_name)
        assert info['CFBundleIdentifier']=='cn.toside.music.cplay3'
        assert sha(original.read(prefix+'Frameworks/CarPlaySupport.dylib')) != ''
        js=additions.read('main.jsbundle');module=additions.read('LXFullCarPlay.dylib')
        metadata=json.loads(additions.read('components.json'));assert sha(js)==metadata['jsSha256']
        own_ui=metadata.get('ownUI') is True
        assert struct.unpack_from('<I',js,8)[0]==96 and len(js)>(500000 if own_ui else 3000000)
        e=entitlements(old_exe);assert e['com.apple.developer.carplay-audio'] is True
        # Keep the working reference's team/container identity; release build needs no debugger entitlement.
        e.pop('get-task-allow',None)
        with tempfile.TemporaryDirectory(prefix='lx-full-sign-') as temp:
            directory=pathlib.Path(temp);executable=directory/'LxMusicMobile';executable.write_bytes(inject(old_exe));executable.chmod(0o755)
            ent=directory/'entitlements.plist';ent.write_bytes(plistlib.dumps(e))
            env=dict(os.environ);env['LD_LIBRARY_PATH']=str(pathlib.Path(signer).resolve().parent)+':'+env.get('LD_LIBRARY_PATH','')
            subprocess.run([str(pathlib.Path(signer).resolve()),'-S'+str(ent),str(executable)],env=env,check=True)
            signed=executable.read_bytes();assert entitlements(signed)==e
        new_sections=sections(signed)
        for name,(off,size) in sections(old_exe).items():
            next_off,next_size=new_sections[name];assert size==next_size and old_exe[off:off+size]==signed[next_off:next_off+next_size], 'Original native section changed: '+name
        info['CFBundleVersion']='83' if own_ui else '82'
        if own_ui:
            info['CFBundleShortVersionString']='1.9.0'
            info['MinimumOSVersion']='15.0'
        replacements={exe_name:signed,info_name:plistlib.dumps(info,fmt=plistlib.FMT_BINARY),prefix+'main.jsbundle':js}
        new_files={prefix+'Frameworks/LXFullCarPlay.dylib':module}
        old_names=set(original.namelist())
        if own_ui:
            own_manifest=json.loads(additions.read('OwnUIResources/OwnUI.manifest.json'))
            assert own_manifest['phoneUI']=='own-local-ui' and own_manifest['entry']=='OwnUI/index.js'
            assert {'WebUI.html','LocalEngine.js','Bridge.js','AppShell.js','AppShell.css'}<=set(own_manifest['resources'])
            assert {'home','room-chat','mine','downloads'}<=set(own_manifest['pages'])
            for name,digest in own_manifest['resources'].items():
                assert pathlib.PurePosixPath(name).name==name
                data=additions.read('OwnUIResources/'+name);assert sha(data)==digest
                assert prefix+name not in old_names,'Unexpected reference resource collision: '+name
                new_files[prefix+name]=data
            new_files[prefix+'OwnUI.manifest.json']=additions.read('OwnUIResources/OwnUI.manifest.json')
        for name in additions.namelist():
            path=pathlib.PurePosixPath(name)
            assert not path.is_absolute() and '..' not in path.parts
            if name.startswith('assets/') and not name.endswith('/') and prefix+name not in old_names:new_files[prefix+name]=additions.read(name)
        output=pathlib.Path(output);output.parent.mkdir(parents=True,exist_ok=True)
        with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as result:
            # writestr updates ZipInfo.header_offset. Keep the input archive's
            # entries intact so later byte-for-byte verification reads its real offsets.
            for entry in original.infolist():result.writestr(copy.copy(entry),replacements.get(entry.filename,original.read(entry.filename)))
            for name,data in new_files.items():result.writestr(name,data)
        preserved=[]
        with zipfile.ZipFile(output) as result:
            assert result.testzip() is None
            for name in original.namelist():
                assert name in result.namelist(),'Removed original file: '+name
                if name not in replacements:
                    assert result.read(name)==original.read(name),'Original resource changed: '+name
                    if not name.endswith('/'):preserved.append({'path':name,'sha256':sha(result.read(name))})
        report={'referenceSHA256':REFERENCE_SHA,'outputSHA256':sha(output.read_bytes()),'outputBytes':output.stat().st_size,'referenceFiles':len(original.namelist()),'removedOriginalFiles':0,'modifiedOriginalFiles':sorted(replacements),'addedFiles':sorted(new_files),'preservedFiles':preserved,'nativeCodeSectionsUnchanged':True,'bundleIdentifier':info['CFBundleIdentifier'],'build':info['CFBundleVersion'],'carplayConnectionOwner':'original CarPlaySupport.dylib','phoneUI':'own-local-ui' if own_ui else 'complete original React Native client','sourceCommit':metadata.get('sourceCommit',''),'physicalCarPlayVerified':False}
        output.with_suffix('.verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:v for k,v in report.items() if k not in ('preservedFiles','addedFiles')},ensure_ascii=False))
        return report

if __name__=='__main__':
    if len(sys.argv)!=5:raise SystemExit(__doc__)
    package(*sys.argv[1:])
