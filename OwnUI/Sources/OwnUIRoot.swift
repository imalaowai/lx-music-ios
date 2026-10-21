import UIKit
import CarPlay

@objc(LXOwnUIRootView) final class OwnUIRootView:UIView {
    private let controller=WebController()
    override init(frame:CGRect) { super.init(frame:frame); backgroundColor = .systemBackground }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, controller.parent == nil {
            var responder:UIResponder?=self.next
            while let item=responder {
                if let parent=item as? UIViewController {
                    parent.addChild(controller); addSubview(controller.view); controller.view.frame=bounds
                    controller.view.autoresizingMask=[.flexibleWidth,.flexibleHeight]; controller.didMove(toParent:parent)
                    break
                }
                responder=item.next
            }
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); if controller.isViewLoaded { controller.view.frame=bounds } }
}

// WebController's public diagnostic interface is shared by both build routes.
// The scene lifecycle remains owned by the reference's CPSceneDelegate.
enum CarScene {
    static var diagnostic:Object {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first!
        let file=documents.appendingPathComponent("LX-CarPlay-Connection.json")
        var value=(try? Data(contentsOf:file)).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? Object ?? [:]
        value["liveScenes"] = UIApplication.shared.connectedScenes.map { scene -> Object in
            var item:Object = ["class":NSStringFromClass(type(of:scene)),"role":scene.session.role.rawValue,"state":scene.activationState.rawValue,"delegate":scene.delegate.map { String(describing:type(of:$0)) } ?? ""]
            if let car = scene as? CPTemplateApplicationScene {
                item["root"] = car.interfaceController.rootTemplate.map { NSStringFromClass(type(of:$0)) } ?? ""
                item["top"] = car.interfaceController.topTemplate.map { NSStringFromClass(type(of:$0)) } ?? ""
            }
            return item
        }
        value["phoneUI"]="own-local-ui"; value["audioCore"]="reference-track-player-and-flac"; return value
    }
}

@objc(LXOwnIntegration) final class OwnIntegration:NSObject {
    private static var tokens:[NSObjectProtocol]=[]
    private static var active=false
    private static var publishing:DispatchWorkItem?
    private static var lastLibrary:Data?
    @objc static func handleBackgroundDownload(_ completion:@escaping ()->Void) {
        activate();MusicLibrary.shared.backgroundCompletion=completion;MusicLibrary.shared.restoreTasks()
    }
    @objc static func activate() {
        guard !active else { return }; active=true
        let player=Player.shared
        for name in [Notification.Name.lxLibrary,.lxPlayback,.lxDownloads] {
            tokens.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { _ in publish() })
        }
        tokens.append(NotificationCenter.default.addObserver(forName:Notification.Name("LXFullActionQueued"),object:nil,queue:.main) { _ in
            // Drain through the ObjC facade so no RN/Swift header coupling is needed.
            NotificationCenter.default.post(name:Notification.Name("LXOwnDrainCarPlay"),object:nil)
        })
        tokens.append(NotificationCenter.default.addObserver(forName:Notification.Name("LXOwnCarPlayAction"),object:nil,queue:.main) { note in
            let action=note.userInfo as? Object ?? [:]
            if text(action["type"])=="refresh-library" { player.refreshLibrary(); publish(); return }
            let lists=rawLists(),list=lists.first { text($0["id"])==text(action["listId"]) }
            let songs=(list?["list"] as? [Object] ?? []).map { Song(raw:$0) }
            if let index=songs.firstIndex(where:{$0.key==text(action["musicId"])}) { player.select(songs,index:index) }
        })
        NotificationCenter.default.post(name:Notification.Name("LXOwnDrainCarPlay"),object:nil)
        publish()
    }
    private static func rawLists()->[Object] {
        let player=Player.shared
        let downloads=MusicLibrary.shared.songs().filter { text($0["status"])=="finished" }.compactMap { $0["song"] as? Object }
        return [["id":"__own_queue","name":"当前播放队列","list":player.queue.map(\.raw)],["id":"__own_downloaded","name":"已下载","list":downloads]]+player.library
    }
    static func publish() {
        publishing?.cancel()
        let work=DispatchWorkItem { publishNow() };publishing=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work)
    }
    private static func publishNow() {
        publishing=nil
        let lists=rawLists().map { list -> Object in
            let songs=(list["list"] as? [Object] ?? []).map { raw -> Object in let song=Song(raw:raw); return ["id":song.key,"name":song.name,"singer":song.artist] }
            return ["id":text(list["id"]),"name":text(list["name"]),"musics":songs]
        }
        let snapshot:Object=["version":3,"lists":lists,"recent":[]]
        guard let data=try? JSONSerialization.data(withJSONObject:snapshot,options:.sortedKeys),data != lastLibrary else { return };lastLibrary=data
        NotificationCenter.default.post(name:Notification.Name("LXOwnLibrary"),object:nil,userInfo:snapshot)
    }
    static func uiReady(_ value:Object)->Bool {
        let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first!
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        if let diagnostic=try? JSONSerialization.data(withJSONObject:value,options:.prettyPrinted) { try? diagnostic.write(to:folder.appendingPathComponent("LX-OwnUI-Handshake.json"),options:.atomic) }
        guard bool(value["bundled"]),bool(value["localShell"]) else { return false }
        guard value["navigation"] as? [String]==["首页","我的歌单","一起听","我的"],bool(value["roomChat"]),bool(value["mine"]),bool(value["downloads"]) else { return false }
        let report:Object=["phoneUI":"own-local-ui","navigation":value["navigation"] ?? [],"roomChat":true,"mine":true,"downloads":true,"build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") ?? "","ready":true]
        do { let data=try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted);try data.write(to:folder.appendingPathComponent("LX-OwnUI-Ready.json"),options:.atomic);return true } catch { return false }
    }
}
