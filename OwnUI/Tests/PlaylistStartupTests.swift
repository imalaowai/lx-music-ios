import Foundation
import WebKit
import UIKit

// Exercise the actual saved-source bootstrap, JavaScriptCore provider SDK,
// URLSession bridge and WebKit playlist rendering, rather than mocking musicApi.
final class PlaylistFixtureProtocol: URLProtocol {
    private let stateLock=NSLock()
    private var stopped=false
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
        let delay=request.url?.path=="/source-delayed" ? 4.0 : 0.01
        DispatchQueue.global().asyncAfter(deadline:.now()+delay) { [weak self] in
            guard let self=self,let url=self.request.url else{return}
            self.stateLock.lock();let stopped=self.stopped;self.stateLock.unlock();if stopped{return}
            let data=try! JSONSerialization.data(withJSONObject:Self.payload)
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:data);self.client?.urlProtocolDidFinishLoading(self)
        }
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
        checks["savedLoginAndLargeQueueRestored"]=Player.shared.api.credentials?.username=="fixture" && Player.shared.queue.count==500
        Player.shared.publish()
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
        let data=try! JSONSerialization.data(withJSONObject:PlaylistFixtureProtocol.payload)
        let json=String(data:data,encoding:.utf8)!
        let injected="""
        localStorage.setItem('lx_sync_user','fixture');localStorage.setItem('lx_user_token','fixture-token');localStorage.setItem('songlist-source','wy');
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
        web.evaluateJavaScript("typeof window.SongListManager?.openDetail==='function'") { value,error in
            guard !completed else{return}
            if value as? Bool == true {
                if !opened {
                    opened=true
                    web.evaluateJavaScript("window.SongListManager.openDetail('123','wy');true",completionHandler:nil)
                }
                web.evaluateJavaScript("!!document.getElementById('sl-detail-list')?.textContent.includes('启动歌单测试曲')") { result,error in
                    if result as? Bool == true {checks["playlistSongsRenderThroughRealWebKitNativeBridge"]=true;checks["browsingPlaylistDoesNotStartMediaServices"]=LXOwnMediaIsIdle();finishIfReady()}
                    if !completed {DispatchQueue.main.asyncAfter(deadline:.now()+0.15){poll()}}
                }
            }else{DispatchQueue.main.asyncAfter(deadline:.now()+0.15){poll()}}
        }
    }
    static func finishIfReady(){if checks.count>=7 {finish()}}
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
