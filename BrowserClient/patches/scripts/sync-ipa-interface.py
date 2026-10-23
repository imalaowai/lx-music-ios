#!/usr/bin/env python3
"""Refresh the shared Qiye UI from the matching iOS NativeCompanion source."""
import argparse,hashlib,json,pathlib,shutil,re
p=argparse.ArgumentParser();p.add_argument('native_source',type=pathlib.Path);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];web=root/'public/music';source=a.native_source
def adapt_override(name,text):
    text=text.replace('2.8.6','2.9.3')
    text=re.sub(r'data:image/svg\+xml;base64,[A-Za-z0-9+/=]+','/music/assets/logo.svg',text)
    if name=='theme_studio.js':
        text=text.replace("green:{name:'苹果绿',hex:'#27844f'}", "green:{name:'栖页青',hex:'#32756e'}")
        text=text.replace("const defaults={lx:'rose',kugou:'blue',apple:'rose'}", "const defaults={lx:'green',kugou:'green',apple:'green'}")
        text=text.replace("layout==='lx'?(legacy[localStorage.getItem('lx_theme')] || defaults.lx):defaults[layout]", "defaults[layout]")
    if name=='room_social.js':
        text=text.replace("input.setRangeText(item.emoji,start,end,'end');input.focus({preventScroll:true});", "input.setRangeText(item.emoji,start,end,'end');")
        text=text.replace('if(matchMedia("(max-width:767px), (max-width:1024px) and (pointer:coarse)").matches)$(\'room-chat-input\').blur();', "$('room-chat-input').blur();")
        text=text.replace("$('room-emoji-close').onclick=hideEmoji;", "$('room-emoji-close').onclick=()=>{hideEmoji();$('room-chat-input').focus({preventScroll:true});};")
    return text
for name in ['room_social.js','library_hub.js','library_sync.js','account-panel.js','theme_studio.js','songlist_manager.js']:
    (web/'js'/name).write_text(adapt_override(name,(source/'WebOverrides'/name).read_text()))
shutil.copy2(source/'Resources/AppShell.css',web/'css/qiye.css')
s=(source/'Resources/AppShell.js').read_text()
def change(old,new):
    global s
    assert old in s,old[:100]
    s=s.replace(old,new)
start=s.index('async function initLibrary(){');end=s.index('\nfunction calibrateLyrics()',start)
s=s[:start]+"""async function initLibrary(){
 // The browser keeps the existing account, ListStore and synchronization owner.
 // Do not create the app's __device__ identity or replace pushDataChange here.
 renderMine();
}
"""+s[end:]
change("if(!window.LXNative)return;","if(!window.LXNative || window.LXNative.runtime!=='browser')return;")
change("state.info.hasAccount?'已连接账号 · 音乐保存在本机':'本机音乐库 · 无需连接服务器'","state.info.hasAccount?'已登录 · 歌单与房间可同步':'访客模式 · 可导入本机音乐'")
change("页面和音乐库保存在手机，服务器用于可选同步与一起听。","收藏、歌单和一起听使用当前账号，已下载音乐保存在当前浏览器。")
change("搜索、歌单和歌词由手机获取。导入洛雪音源后，播放链接也在本机解析；音频仍从原音源下载。","使用当前音乐服务的音源解析搜索与播放，设置沿用现有账号权限。")
change("个本地音源","个可用音源")
change("从服务器迁移","刷新音源")
change("兼容旧服务器音源","使用当前服务器音源")
change("尚未导入本地音源时，允许使用当前同步服务器解析播放链接。","音源变更由现有服务端校验权限。")
change("导入一次洛雪 .js 音源，之后由手机直接解析。<br>音源文件仅保存在这台设备。<br>尚未导入时，已连接的旧服务器音源可临时继续使用。","尚未配置可用音源。<br>可按当前账号权限导入音源文件或链接。")
change("音源已保存在手机","音源已导入当前音乐服务")
change("function migrateSources(){","function migrateSources(){") # Preserve the shared function's source contract.
start=s.index("async function migrateSources(){");end=s.index("\nasync function saveLibrary",start)
s=s[:start]+"async function migrateSources(){await loadSources();window.showSuccess?.('音源列表已刷新');}"+s[end:]
change(",row('更换同步服务器',()=>request('editServer'),'cloud')","")
change("本机播放</h3><p>音源、设备音乐和下载保存在手机。","播放与离线</h3><p>已下载的音乐、歌词和封面保存在当前浏览器。")
start=s.index("const carStatus=document.createElement('div');");end=s.index("settingsCard.append(carStatus);",start)+len("settingsCard.append(carStatus);")
s=s[:start]+s[end:]
change("window.DeviceLibrary.downloadBatch=songs=>perform(()=>addDownloads(songs));","window.DeviceLibrary.downloadBatch=previousBatch;")
# Browser file downloads use the real queue; only the native app overrides it.
a=s.index(' const manager=window.SystemDownloadManager;');b=s.index('\n const more=',a);s=s[:a]+s[b:]
change("window.openCustomSourceModal=()=>go('sources');","window.openCustomSourceModal=()=>go('sources');")
change("go('home',false);syncNavigation();viewport();window.AccountPanel?.mountHeader?.();","go('home',false);syncNavigation();viewport();window.AccountPanel?.mountHeader?.();window.dispatchEvent(new Event('qiye-shell-ready'));")
change("window.addEventListener('lx-auth-change',()=>{","window.addEventListener('lx-profile-change',()=>{mineSignature='';renderMine();});window.addEventListener('lx-auth-change',()=>{")
change("node.querySelector('[data-action=delete]').onclick=","if(item.canRemove===false){node.querySelector('[data-action=delete]').disabled=true;node.querySelector('[data-action=delete]').title='公共音源由管理员维护';}node.querySelector('[data-action=delete]').onclick=")
s=s.replace('删除本地音源','删除音源')
change("probe:async()=>({qualities:['flac24bit','flac','320k','128k'].map(q=>({quality:q,available:true,format:q.startsWith('flac')?'FLAC':'MP3',extension:q.startsWith('flac')?'flac':'mp3'}))})","probe:()=>songs[0].deviceKey||songs[0].offlineId?Promise.resolve({qualities:[{quality:'original',available:true,format:'原文件',extension:songs[0].filename?.split('.').pop()||'audio'}]}):window.DeviceLibrary.api('/api/media/options',{song:songs[0]})")
change("item.hasCover?'lx-local://cover/'+item.id:artwork(song)","artwork(song)")
s=s.replace('void loadDownloads()','perform(loadDownloads)').replace('void loadSources()','perform(loadSources)')
change('function syncNavigation(){',"function syncNavigation(){document.documentElement.dataset.qiyePage=state.page;")
(web/'js/qiye_shell.js').write_text(s)
manifest={'brand':'栖页音乐','source':'imalaowai/lx-music-ios','iosVersion':'1.9.5','iosBuild':88,'runtime':'browser','nativeAudioBridgeIncluded':False,'sharedFiles':{n:hashlib.sha256((source/'Resources'/n).read_bytes()).hexdigest() for n in ['AppShell.js','AppShell.css']}}
(web/'qiye-ui.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print('Copied shared IPA pages and browser-specific account/download bindings.')
