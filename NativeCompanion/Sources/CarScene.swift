import UIKit
import CarPlay

protocol CarScreenHost: AnyObject {
    var topTemplate: CPTemplate? { get }
    func setRoot(_ template: CPTemplate, completion: @escaping (Bool, Error?) -> Void)
    func push(_ template: CPTemplate)
}
final class CarInterfaceHost: CarScreenHost {
    let controller: CPInterfaceController
    init(_ controller: CPInterfaceController) { self.controller = controller }
    var topTemplate: CPTemplate? { controller.topTemplate }
    func setRoot(_ template: CPTemplate, completion: @escaping (Bool, Error?) -> Void) { controller.setRootTemplate(template, animated: false, completion: completion) }
    func push(_ template: CPTemplate) { controller.pushTemplate(template, animated: true) { _, error in if let error = error { NSLog("CarPlay navigation: %@", error.localizedDescription) } } }
}

final class CarScene: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    static var connectedScene: CarScene?
    static var diagnostic: Object = ["connected": false, "phase": "未连接", "callback": "", "error": ""]
    let player = Player.shared
    var host: CarScreenHost?
    var carWindow: CPWindow?
    var rootTemplate: CPTemplate?
    var queueTemplate: CPListTemplate?
    var libraryTemplate: CPListTemplate?
    var roomTemplate: CPListTemplate?
    var observers: [NSObjectProtocol] = []
    var lastSignature = ""
    var connectionGeneration = 0
    // Both ObjC selectors are intentional: the supplied working v11 IPA uses
    // the window callback. Standard audio scenes use the two-argument callback.
    @objc(templateApplicationScene:didConnectInterfaceController:)
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController) {
        connect(CarInterfaceHost(controller), window: nil, callback: "audio")
    }
    @objc(templateApplicationScene:didConnectInterfaceController:toWindow:)
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController, to window: CPWindow) {
        connect(CarInterfaceHost(controller), window: window, callback: "window")
    }
    func connect(_ target: CarScreenHost, window: CPWindow?, callback: String) {
        releaseConnection()
        connectionGeneration += 1
        let generation = connectionGeneration
        host = target; carWindow = window; Self.connectedScene = self
        Self.diagnostic = ["connected": true, "phase": "正在建立车机页面", "callback": callback, "error": ""]
        if let window = window {
            if window.rootViewController == nil { let controller = UIViewController(); controller.view.backgroundColor = .black; window.rootViewController = controller }
            window.isHidden = false
        }
        let placeholder = CPListSection(items: [row("正在载入本机音乐", "音乐库无需等待服务器")])
        let queue = CPListTemplate(title: "播放队列", sections: [placeholder]), library = CPListTemplate(title: "我的歌单", sections: [placeholder]), room = CPListTemplate(title: "一起听", sections: [placeholder])
        queue.tabTitle = "播放队列"; queue.tabImage = UIImage(systemName: "music.note.list")
        library.tabTitle = "我的歌单"; library.tabImage = UIImage(systemName: "square.stack")
        room.tabTitle = "一起听"; room.tabImage = UIImage(systemName: "person.2")
        queueTemplate = queue; libraryTemplate = library; roomTemplate = room
        // Populate every section before presenting the root, including offline/empty states.
        refresh(force: true)
        let root = CPTabBarTemplate(templates: [queue, library, room]); rootTemplate = root
        target.setRoot(root) { [weak self] success, error in
            guard let self = self, self.connectionGeneration == generation, self.host != nil else { return }
            if success { Self.diagnostic["phase"] = "车机页面已就绪"; return }
            Self.diagnostic["error"] = error?.localizedDescription ?? "系统未接受分页菜单"
            let fallback = CPListTemplate(title: "LX 音乐", sections: [CPListSection(items: [
                self.row("播放队列", "浏览本机队列") { [weak self] in if let page = self?.queueTemplate { self?.push(page) } },
                self.row("我的歌单", "包含已下载音乐") { [weak self] in if let page = self?.libraryTemplate { self?.push(page) } },
                self.row("一起听") { [weak self] in if let page = self?.roomTemplate { self?.push(page) } }
            ])]); self.rootTemplate = fallback
            target.setRoot(fallback) { [weak self] success, error in
                guard let self = self, self.connectionGeneration == generation else { return }
                Self.diagnostic["phase"] = success ? "车机简洁菜单已就绪" : "车机页面建立失败"
                if let error = error { Self.diagnostic["error"] = error.localizedDescription }
            }
        }
        let now = CPNowPlayingTemplate.shared; now.isUpNextButtonEnabled = true; now.upNextTitle = "播放队列"; now.add(self)
        for name in [Notification.Name.lxPlayback, .lxRoom, .lxLibrary, .lxDownloads] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        player.refreshLibrary(); player.room.refresh()
    }
    @objc(templateApplicationScene:didDisconnectInterfaceController:)
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController controller: CPInterfaceController) { releaseConnection() }
    @objc(templateApplicationScene:didDisconnectInterfaceController:fromWindow:)
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnect controller: CPInterfaceController, from window: CPWindow) { releaseConnection() }
    func releaseConnection() {
        connectionGeneration += 1
        for item in observers { NotificationCenter.default.removeObserver(item) }; observers = []
        CPNowPlayingTemplate.shared.remove(self); host = nil; carWindow = nil; rootTemplate = nil; queueTemplate = nil; libraryTemplate = nil; roomTemplate = nil; lastSignature = ""
        if Self.connectedScene === self { Self.connectedScene = nil; Self.diagnostic["connected"] = false; Self.diagnostic["phase"] = "已断开" }
    }
    func row(_ title: String, _ detail: String? = nil, action: (() -> Void)? = nil) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        if let action = action { item.handler = { _, completion in action(); completion() } }
        return item
    }
    func refresh(force: Bool = false) {
        let finished = MusicLibrary.shared.songs().filter { text($0["status"]) == "finished" }
        let signature = "\(player.index)|\(player.wanted)|\(player.failure)|\(player.queueRevision)|\(player.libraryRevision)|\(player.room.roomID)|\(player.room.connected)|\(player.room.participants.count)|\(player.room.controller)|\(finished.count)"
        guard force || signature != lastSignature else { return }; lastSignature = signature
        var items: [CPListItem] = []
        if player.current != nil { items.append(row("正在播放", player.current?.name) { [weak self] in self?.showNowPlaying() }) }
        if !player.failure.isEmpty { items.append(row("播放提示", player.failure)) }
        if player.queue.isEmpty { items.append(row("还没有播放队列", "请在手机选择或导入音乐")) }
        else { items += songRows(player.queue, start: 0) }
        queueTemplate?.updateSections([CPListSection(items: items)])
        var lists = player.library.map { list in row(text(list["name"]), "\((list["list"] as? [Object])?.count ?? 0) 首") { [weak self] in self?.showList(list) } }
        lists.append(row("刷新歌单") { [weak self] in self?.player.refreshLibrary { self?.refresh(force: true) } })
        if !finished.isEmpty { let local: Object = ["name": "已下载", "list": finished.compactMap { $0["song"] as? Object }]; lists.insert(row("已下载", "\(finished.count) 首 · 可离线播放") { [weak self] in self?.showList(local) }, at: 0) }
        if lists.isEmpty { lists = [row("本机暂无歌单", "可以先在 iPhone 导入音乐，无需连接服务器")] }
        libraryTemplate?.updateSections([CPListSection(items: lists)])
        let room = player.room
        var roomItems: [CPListItem]
        if room.active {
            roomItems = [row("房间 \(room.roomID)", "\(room.participants.count) 位成员 · \(room.connected ? "已连接" : "连接中")"), row(player.wanted ? "暂停一起听" : "继续一起听") { [weak self] in guard let self = self else { return }; self.player.wanted ? self.player.pause() : self.player.play() }, row("下一首") { [weak self] in self?.player.move() }, row("退出房间") { [weak self] in self?.player.room.membership("leave") { _ in self?.refresh(force: true) } }]
        } else { roomItems = [row("当前未加入房间", "请在 iPhone 中创建或加入房间")] }
        roomTemplate?.updateSections([CPListSection(items: roomItems)])
    }
    func songRows(_ songs: [Song], start: Int) -> [CPListItem] {
        let limit = max(2, min(100, CPListTemplate.maximumItemCount))
        let end = min(songs.count, start + (songs.count - start > limit ? limit - 1 : limit))
        guard start < end else { return [row("暂无歌曲", "请在手机添加或导入音乐")] }
        var items = (start..<end).map { index in
            let item = row(songs[index].name, songs[index].artist) { [weak self] in self?.player.select(songs, index: index); self?.showNowPlaying() }
            item.isPlaying = player.current?.key == songs[index].key && player.wanted
            return item
        }
        if end < songs.count { items.append(row("更多歌曲", "\(end + 1)–\(min(end + min(100, CPListTemplate.maximumItemCount), songs.count))") { [weak self] in guard let self = self else { return }; self.push(CPListTemplate(title: "歌曲", sections: [CPListSection(items: self.songRows(songs, start: end))])) }) }
        return items
    }
    func showList(_ list: Object) {
        let songs = (list["list"] as? [Object] ?? []).map { Song(raw: $0) }
        push(CPListTemplate(title: text(list["name"]), sections: [CPListSection(items: songRows(songs, start: 0))]))
    }
    func push(_ template: CPTemplate) { host?.push(template) }
    func showNowPlaying() { if host?.topTemplate !== CPNowPlayingTemplate.shared { push(CPNowPlayingTemplate.shared) } }
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) { push(CPListTemplate(title: "播放队列", sections: [CPListSection(items: songRows(player.queue, start: 0))])) }
}
