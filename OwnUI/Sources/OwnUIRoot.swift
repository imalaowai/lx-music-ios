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
                // The SDK imports rootTemplate as nonoptional, although a scene
                // without an installed root can return nil. KVC preserves nil.
                item["root"] = (car.interfaceController.value(forKey:"rootTemplate") as? CPTemplate).map { NSStringFromClass(type(of:$0)) } ?? ""
                item["top"] = (car.interfaceController.value(forKey:"topTemplate") as? CPTemplate).map { NSStringFromClass(type(of:$0)) } ?? ""
            }
            return item
        }
        value["phoneUI"]="own-local-ui"; value["audioCore"]="reference-track-player-and-flac"
        let player=Player.shared
        let nowPlaying=NSMutableDictionary()
        NotificationCenter.default.post(name:Notification.Name("LXOwnNowPlayingDiagnostic"),object:nowPlaying)
        value["nowPlaying"]=nowPlaying as? Object ?? [:]
        value["runtime"]=["room":player.room.diagnostic(),"wanted":player.wanted,"loading":player.loading,
            "audioFailed":player.audio.hasFailed,"generation":player.generation,"position":player.position,"routeHold":player.routeGate.held,
            "duration":player.duration,"audioRate":player.audio.rate,"audioState":player.audio.timeControlStatus.rawValue,
            "artworkLookupAttempted":player.artworkLookupAttempted,"artworkResolved":!player.resolvedArtwork.isEmpty,
            "events":RuntimeTrace.snapshot()] as Object
        return value
    }
}

@objc(LXOwnIntegration) final class OwnIntegration:NSObject {
    private static var tokens:[NSObjectProtocol]=[]
    private static var active=false
    private static var publishing:DispatchWorkItem?
    private static var lastLibraryRevision:[Int] = []
    @objc static func handleBackgroundDownload(_ completion:@escaping ()->Void) {
        activate();MusicLibrary.shared.backgroundCompletion=completion;MusicLibrary.shared.restoreTasks()
    }
    @objc static func activate() {
        guard !active else { return }; active=true
        let player=Player.shared
        RuntimeTrace.record("runtime.start")
        for name in [Notification.Name.lxLibrary,.lxPlayback,.lxDownloads] {
            tokens.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { _ in publish() })
        }
        tokens.append(NotificationCenter.default.addObserver(forName:Notification.Name("LXFullActionQueued"),object:nil,queue:.main) { _ in
            // Drain through the ObjC facade so no RN/Swift header coupling is needed.
            NotificationCenter.default.post(name:Notification.Name("LXOwnDrainCarPlay"),object:nil)
        })
        for name in [UIScene.didActivateNotification,UIScene.willEnterForegroundNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main){note in
                if note.object is CPTemplateApplicationScene {
                    player.room.recoverConnection("carplay-scene")
                    player.refreshNowPlaying()
                }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName:Notification.Name("LXOwnCarPlayAction"),object:nil,queue:.main) { note in
            handleCarPlayAction(note.userInfo as? Object ?? [:])
        })
        tokens.append(NotificationCenter.default.addObserver(forName:Notification.Name("LXOwnCarPlayConnected"),object:nil,queue:.main) { _ in
            player.room.recoverConnection("carplay-connected")
            NotificationCenter.default.post(name:Notification.Name("LXOwnDrainCarPlay"),object:nil)
            player.refreshNowPlaying()
            publish()
        })
        tokens.append(NotificationCenter.default.addObserver(forName:Notification.Name("LXOwnCarPlayDisconnected"),object:nil,queue:.main) { _ in
            player.room.cancelCarPlayAction()
        })
        NotificationCenter.default.post(name:Notification.Name("LXOwnDrainCarPlay"),object:nil)
        // CarPlay may launch while the phone WebKit view is suspended. Account
        // restoration and room networking must start without a web auth message.
        player.room.refresh()
        publish()
    }
    private static let recentListID = "__own_recent"
    private static func handleCarPlayAction(_ action: Object) {
        let player = Player.shared
        let operation = text(action["type"])
        if operation == "refresh-library" { player.refreshLibrary(); publish(); return }
        guard operation == "play" else { return }
        let listID = text(action["listId"]), musicID = text(action["musicId"])
        let isRecent = listID == recentListID
        let list = isRecent ? nil : rawLists().first { text($0["id"]) == listID }
        let songs = isRecent ? player.recent : (list?["list"] as? [Object] ?? []).map { Song(raw: $0) }
        let matches: (Song) -> Bool = { (isRecent ? $0.playbackIdentity : $0.key) == musicID }
        let proposed = Int(number(action["index"], -1))
        guard let index = songs.indices.contains(proposed) && matches(songs[proposed]) ? proposed : songs.firstIndex(where:matches) else { return }
        player.performCarPlayAction { player.select(songs, index: index) }
    }
    private static func rawLists()->[Object] {
        let player=Player.shared
        let downloads=MusicLibrary.shared.songs().filter { text($0["status"])=="finished" }.compactMap { $0["song"] as? Object }
        return [["id":"__own_queue","name":"当前播放队列","list":player.queue.map(\.raw)],["id":"__own_downloaded","name":"已下载","list":downloads]]+player.library
    }
    static func publish() {
        let player = Player.shared
        let revision = [player.libraryRevision, player.queueRevision, player.recentRevision, MusicLibrary.shared.playableRevision]
        guard revision != lastLibraryRevision, publishing == nil else { return }
        let work=DispatchWorkItem { publishNow() };publishing=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work)
    }
    private static func publishNow() {
        publishing=nil
        let player = Player.shared
        lastLibraryRevision = [player.libraryRevision, player.queueRevision, player.recentRevision, MusicLibrary.shared.playableRevision]
        let lists=rawLists().map { list -> Object in
            let songs=(list["list"] as? [Object] ?? []).map { raw -> Object in let song=Song(raw:raw); return ["id":song.key,"name":song.name,"singer":song.artist] }
            return ["id":text(list["id"]),"name":text(list["name"]),"musics":songs]
        }
        let recent = Player.shared.recent.map { song -> Object in
            ["id": song.playbackIdentity, "name": song.name, "singer": song.artist, "listId": recentListID]
        }
        NotificationCenter.default.post(name:Notification.Name("LXOwnLibrary"),object:nil,userInfo:["version":3,"lists":lists,"recent":recent])
    }
    private static let readinessWriter = DispatchQueue(label: "net.minyue.lxcompanion.ui-readiness", qos: .utility)
    static func uiReady(_ value:Object)->Bool {
        guard bool(value["bundled"]), bool(value["localShell"]), bool(value["nativeSnapshot"]),
              bool(value["compactLayout"]), value["navigation"] as? [String] == ["首页","我的歌单","一起听","我的"],
              bool(value["roomChat"]), bool(value["mine"]), bool(value["downloads"]) else { return false }
        let report:Object = ["phoneUI":"own-local-ui", "navigation":value["navigation"] ?? [], "roomChat":true,
                             "mine":true, "downloads":true, "build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") ?? "", "ready":true]
        readinessWriter.async {
            guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            if let data = try? JSONSerialization.data(withJSONObject:value, options:.prettyPrinted) {
                try? data.write(to:folder.appendingPathComponent("LX-OwnUI-Handshake.json"), options:.atomic)
            }
            if let data = try? JSONSerialization.data(withJSONObject:report, options:.prettyPrinted) {
                try? data.write(to:folder.appendingPathComponent("LX-OwnUI-Ready.json"), options:.atomic)
            }
        }
        return true
    }
}
