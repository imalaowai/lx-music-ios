import Foundation
import WebKit
import UIKit

// Exercise the actual saved-source bootstrap, JavaScriptCore provider SDK,
// URLSession bridge and WebKit playlist rendering, rather than mocking musicApi.
final class PlaylistFixtureProtocol: URLProtocol {
    private let stateLock=NSLock()
    private var stopped=false
    static let renewedToken = "renewed-fixture-token"
    static var loginReply: (() -> Void)?
    static var obsoleteReply: (() -> Void)?
    override class func canInit(with request:URLRequest)->Bool { ["http","https"].contains(request.url?.scheme ?? "") }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    static var payload:Object {
        let image="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a/l0AAAAASUVORK5CYII="
        let track:Object=["id":1231,"name":"启动歌单测试曲","ar":[["id":1,"name":"测试歌手"]],"al":["id":1,"name":"测试专辑","picUrl":image],"dt":180000,"mv":0,"h":["size":6000000],"l":["size":3000000]]
        let list:Object=["id":123,"name":"启动测试歌单","creator":["nickname":"Fixture"],"coverImgUrl":image,"description":"Fixture","playCount":100,"trackCount":1,"trackIds":[["id":1231]],"tracks":[track]]
        let lists:Object=["loveList":[],"defaultList":[["id":"fixture-song","name":"已同步歌曲","source":"wy","songmid":"1231"]],"userList":[]]
        return ["success":true,"code":200,"enabled":false,"room":NSNull(),"binding":NSNull(),"total":1,"playlist":list,"playlists":[list],"songs":[track],"privileges":[["id":1231,"maxbr":320000,"maxBrLevel":"exhigh"]],"sub":[["category":0,"name":"全部"]],"categories":["0":"全部"],"tags":[],"user":["name":"fixture","username":"fixture"],"username":"fixture","data":lists,"loveList":[],"defaultList":lists["defaultList"]!,"userList":[]]
    }
    override func startLoading() {
        if let url = request.url, url.host == "qiye-fixture.invalid" {
            switch url.path {
            case "/api/user/login":
                DispatchQueue.main.async { Self.loginReply = { [weak self] in self?.reply(200, ["success":true, "token":Self.renewedToken]) } }
                return
            case "/api/user/list" where url.query == "session-test=obsolete":
                DispatchQueue.main.async { Self.obsoleteReply = { [weak self] in self?.reply(401, ["success":false]) } }
                return
            case "/api/music/url":
                if request.value(forHTTPHeaderField: "x-user-token") == Self.renewedToken,
                   let audio = Bundle.main.url(forResource: "local-audio", withExtension: "flac") {
                    reply(200, ["url":audio.absoluteString, "quality":"flac"])
                } else { reply(401, ["message":"Unauthorized"]) }
                return
            default: break
            }
        }
        let delay=request.url?.path=="/source-delayed" ? 4.0 : 0.01
        DispatchQueue.global().asyncAfter(deadline:.now()+delay) { [weak self] in
            self?.reply(200, Self.payload)
        }
    }
    private func reply(_ status: Int, _ payload: Object) {
        guard let url = request.url else { return }
        stateLock.lock();let stopped = self.stopped;stateLock.unlock();if stopped { return }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {stateLock.lock();stopped=true;stateLock.unlock()}
}
enum PlaylistStartupTests {
    static var checks:Object=[:]
    static var metrics:Object=[:]
    static var began=ProcessInfo.processInfo.systemUptime
    static var completed=false
    static var opened=false
    static var web:WKWebView?
    static func prepare() {
        _ = URLProtocol.registerClass(PlaylistFixtureProtocol.self)
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[PlaylistFixtureProtocol.self]
        LocalEngine.shared=LocalEngine(configuration:configuration)
        let credentials=Credentials(server:"https://qiye-fixture.invalid/",username:"fixture",token:"fixture-token")
        Vault.save(credentials);UserDefaults.standard.set(credentials.server,forKey:"lx.server")
        let queue=(0..<500).map{["id":"saved-\($0)","name":"历史歌曲\($0)","source":"wy","songmid":"\($0)","singer":"Fixture"]}
        let saved:Object=["server":credentials.server,"username":credentials.username,"queue":queue,"index":0,"mode":"list","position":10,"quality":"flac"]
        UserDefaults.standard.set(try! JSONSerialization.data(withJSONObject:saved),forKey:"lx.queue")
        UserDefaults.standard.set(false,forKey:"lx.routeHold")
        let engine=LocalEngine.shared,folder=try! engine.directory(),id="16DE785F-48B3-47D0-BD9E-6951CE1135AB"
        let script="""
        lx.on('request',()=>Promise.resolve('https://audio.invalid/restored.mp3'));
        lx.request('https://qiye-fixture.invalid/source-delayed',{},(error)=>{
          if(!error)lx.send('inited',{sources:{kw:{actions:['musicUrl'],qualitys:['128k']}}});
        });
        """
        try! script.write(to:folder.appendingPathComponent(id+".js"),atomically:true,encoding:.utf8)
        try! JSONSerialization.data(withJSONObject:[["id":id,"name":"Slow saved source","enabled":true]]).write(to:folder.appendingPathComponent("index.json"))
        began=ProcessInfo.processInfo.systemUptime
        // This host is ad-hoc signed in Simulator; Keychain availability varies
        // with its entitlements. Seed the restored-account boundary explicitly,
        // then execute the production queue-restoration routine. This does not
        // claim a real Keychain round trip or modify the production Vault.
        metrics["simulatorKeychainFixtureReadable"]=Vault.load()==credentials
        let player=Player.shared;player.api.credentials=credentials;player.restoreQueue()
        checks["restoredAccountFixtureAndLargeQueuePresent"]=player.api.credentials?.username=="fixture" && player.queue.count==500
        checks["upgradeSeedsRecentWithOnlyTheRestoredCurrentSong"]=player.recent.map(\.key)==["saved-0"]
        player.publish()
        DispatchQueue.main.async {
            checks["restoredIdleHistoryDoesNotInitializeLockScreenServices"]=LXOwnMediaIsIdle()
        }
        engine.call("api",["path":"/api/music/config"],completionQueue:engine.queue) { result in
            let elapsed=ProcessInfo.processInfo.systemUptime-began
            DispatchQueue.main.async {
                metrics["configMilliseconds"]=Int(elapsed*1000)
                if case .success = result {checks["catalogueDoesNotWaitForSavedAudioSource"]=elapsed<2.5} else {checks["catalogueDoesNotWaitForSavedAudioSource"]=false}
                finishIfReady()
            }
        }
        engine.call("api",["path":"/api/music/songList/detail?source=wy&id=123&page=1"]) { result in
            if case .success(let response)=result,let value=response as? Object,let songs=value["list"] as? [Object] {
                checks["realProviderSDKAndURLSessionReturnPlaylistSongs"]=songs.contains{text($0["name"])=="启动歌单测试曲"}
            }else{checks["realProviderSDKAndURLSessionReturnPlaylistSongs"]=false}
            finishIfReady()
        }
        player.api.cover(Song(raw:["source":"wy","id":"wy_1231"])) { result in
            if case .success(let address)=result {
                checks["nativeCoverLookupUsesProviderSDKWithoutPhoneWebView"]=address.hasPrefix("data:image/png;base64,")
            } else {checks["nativeCoverLookupUsesProviderSDKWithoutPhoneWebView"]=false}
            finishIfReady()
        }
        engine.call("resolve",["song":["source":"kw","songmid":"123"],"quality":"128k"]) { result in
            if case .success(let response)=result,let value=response as? Object {
                checks["playbackResolutionWaitsForSavedSourceInitialization"]=text(value["url"])=="https://audio.invalid/restored.mp3" && ProcessInfo.processInfo.systemUptime-began>=3.5
            }else{checks["playbackResolutionWaitsForSavedSourceInitialization"]=false}
            finishIfReady()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+45){if !completed{finish(error:"Playlist startup verification timed out")}}
    }
    static func attach(_ parent:UIViewController) {
        guard let controller=parent.children.compactMap({$0 as? WebController}).first else{finish(error:"Production WebController missing");return}
        web=controller.web
        checks["nativeCoverHidesBundledPageDuringStartup"] = controller.view.viewWithTag(214) != nil && !controller.pageRecovery.ready
        checks["defaultServerPreservesExplicitPorts"] = WebController.defaultServer.absoluteString == "https://lx.minyue.de5.net:99" &&
            WebController.serverURL("HTTPS://Example.com:9443/")?.absoluteString == "https://example.com:9443"
        let data=try! JSONSerialization.data(withJSONObject:PlaylistFixtureProtocol.payload)
        let json=String(data:data,encoding:.utf8)!
        let injected="""
        localStorage.setItem('lx_sync_user','fixture');localStorage.setItem('lx_user_token','stale-web-fixture-token');localStorage.setItem('songlist-source','wy');
        const catalogueFetch=window.fetch.bind(window);
        window.fetch=function(input,options={}){
          const url=new URL(typeof input==='string'?input:input.url,location.href);
          if(url.pathname.startsWith('/api/music/')||url.pathname==='/api/custom-source/list')return catalogueFetch(input,options);
          return Promise.resolve(new Response(JSON.stringify(\(json)),{status:200,headers:{'Content-Type':'application/json'}}));
        };
        """
        controller.web.configuration.userContentController.addUserScript(WKUserScript(source:injected,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        poll()
    }
    static func poll() {
        guard !completed,let web=web else{return}
        // The script defines SongListManager before HTML parsing and bridge
        // installation finish. Do not simulate a tap against an unfinished DOM.
        web.evaluateJavaScript("document.readyState!=='loading' && window.LXBridge?.isReady?.()===true && window.NativeShell?.ready===true && typeof window.SongListManager?.openDetail==='function' && typeof window.ListSearch?.init==='function' && !!document.getElementById('sl-detail-list')") { value,error in
            guard !completed else{return}
            if value as? Bool == true {
                if !opened {
                    opened=true
                    web.evaluateJavaScript("window.SongListManager.openDetail('123','wy');true") { _,error in
                        if let error=error {metrics["detailOpenError"]=error.localizedDescription;opened=false}
                    }
                }
                web.evaluateJavaScript("!!document.getElementById('sl-detail-list')?.textContent.includes('启动歌单测试曲')") { result,error in
                    if result as? Bool == true {
                        checks["playlistSongsRenderThroughRealWebKitNativeBridge"]=true
                        checks["browsingPlaylistDoesNotStartMediaServices"]=LXOwnMediaIsIdle()
                        let proof = """
                        const detail=document.getElementById('view-player-detail');
                        const settings=document.getElementById('btn-mode-local')?.parentElement?.parentElement;
                        const shell=window.NativeShell, info=shell.state.info;
                        shell.state.info={...info,hasAccount:false};
                        document.getElementById('native-person-avatar').click();
                        const login=document.querySelector('.native-sign-in');
                        const loginReady=!!login?.querySelector('[autocomplete="username"]') &&
                            !!login?.querySelector('[autocomplete="current-password"]') &&
                            login.querySelector('small').textContent===info.server;
                        document.querySelector('.native-sheet-close')?.click();
                        shell.state.info=info;
                        return detail?.classList.contains('hidden') && !document.body.classList.contains('mobile-player-open') &&
                            loginReady && settings && getComputedStyle(settings).display==='none' && !document.getElementById('qiye-account') &&
                            localStorage.getItem('lx_user_token')==='fixture-token' &&
                            window.LXBridge.getPlayback().queue.length===500 &&
                            document.querySelectorAll('#queue-list [data-queue-index]').length===0;
                        """
                        web.evaluateJavaScript("(function(){\(proof)})()") { value, _ in
                            if value as? Bool == true {
                                checks["compactStartupRestoresNativeSessionAndKeepsTheQueueUnrendered"]=true
                                finishIfReady()
                            }
                        }
                    }
                    if !completed {DispatchQueue.main.asyncAfter(deadline:.now()+0.15){poll()}}
                }
            }else{DispatchQueue.main.asyncAfter(deadline:.now()+0.15){poll()}}
        }
    }
    static func finishIfReady(){if checks.count>=12 {finish()}}
    static func finish(error:String?=nil) {
        guard !completed else{return};completed=true
        var report:Object=["checks":checks,"metrics":metrics]
        if let error=error{report["error"]=error;checks["completed"]=false;report["checks"]=checks}
        let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:root.appendingPathComponent("LX-Playlist-Startup-Checks.json"),options:.atomic)
        web=nil
        OfflinePlayback.start()
    }
}
