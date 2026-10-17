import UIKit
import CarPlay

final class CarScene: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    let player = Player.shared
    weak var controller: CPInterfaceController?
    var queueTemplate: CPListTemplate?
    var libraryTemplate: CPListTemplate?
    var roomTemplate: CPListTemplate?
    var observers: [NSObjectProtocol] = []
    var lastSignature = ""
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        let queue = CPListTemplate(title: "播放队列", sections: []), library = CPListTemplate(title: "我的歌单", sections: []), room = CPListTemplate(title: "一起听", sections: [])
        queue.tabTitle = "播放队列"; queue.tabImage = UIImage(systemName: "music.note.list")
        library.tabTitle = "我的歌单"; library.tabImage = UIImage(systemName: "square.stack")
        room.tabTitle = "一起听"; room.tabImage = UIImage(systemName: "person.2")
        queueTemplate = queue; libraryTemplate = library; roomTemplate = room
        let now = CPNowPlayingTemplate.shared; now.isUpNextButtonEnabled = true; now.upNextTitle = "播放队列"; now.add(self)
        let root = CPTabBarTemplate(templates: [queue, library, room])
        interfaceController.setRootTemplate(root, animated: false) { _, error in if let error = error { NSLog("CarPlay root failed: %@", error.localizedDescription) } }
        for name in [Notification.Name.lxPlayback, .lxRoom, .lxLibrary] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh(force: true)
        player.refreshLibrary(); player.room.refresh()
    }
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnect interfaceController: CPInterfaceController) {
        for item in observers { NotificationCenter.default.removeObserver(item) }; observers = []
        CPNowPlayingTemplate.shared.remove(self); controller = nil; queueTemplate = nil; libraryTemplate = nil; roomTemplate = nil; lastSignature = ""
    }
    func row(_ title: String, _ detail: String? = nil, action: (() -> Void)? = nil) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        if let action = action { item.handler = { _, completion in action(); completion() } }
        return item
    }
    func refresh(force: Bool = false) {
        let signature = "\(player.index)|\(player.wanted)|\(player.failure)|\(player.queue.map(\.key).joined(separator: ","))|\(player.library.map {text($0["id"]) + text($0["name"]) + String(($0["list"] as? [Object])?.count ?? 0)}.joined())|\(player.room.roomID)|\(player.room.connected)|\(player.room.participants.count)|\(player.room.controller)"
        guard force || signature != lastSignature else { return }; lastSignature = signature
        var items: [CPListItem] = []
        if player.current != nil { items.append(row("正在播放", player.current?.name) { [weak self] in self?.showNowPlaying() }) }
        if !player.failure.isEmpty { items.append(row("播放提示", player.failure)) }
        if player.queue.isEmpty { items.append(row("还没有播放队列", "请在手机中登录并选择歌曲")) }
        else { items += songRows(player.queue, start: 0) }
        queueTemplate?.updateSections([CPListSection(items: items)])
        var lists = player.library.map { list in row(text(list["name"]), "\((list["list"] as? [Object])?.count ?? 0) 首") { [weak self] in self?.showList(list) } }
        lists.append(row("刷新歌单") { [weak self] in self?.player.refreshLibrary { self?.refresh(force: true) } })
        if player.api.credentials == nil { lists = [row("请先登录", "在 iPhone 中连接服务器并登录账号")] }
        libraryTemplate?.updateSections([CPListSection(items: lists)])
        let room = player.room
        var roomItems: [CPListItem]
        if room.active {
            roomItems = [row("房间 \(room.roomID)", "\(room.participants.count) 位成员 · \(room.connected ? "已连接" : "连接中")"), row(player.wanted ? "暂停一起听" : "继续一起听") { [weak self] in guard let self = self else { return }; self.player.wanted ? self.player.pause() : self.player.play() }, row("下一首") { [weak self] in self?.player.move() }, row("退出房间") { [weak self] in self?.player.room.membership("leave") { _ in self?.refresh(force: true) } }]
        } else { roomItems = [row("当前未加入房间", "请在 iPhone 中创建或加入房间")] }
        roomTemplate?.updateSections([CPListSection(items: roomItems)])
    }
    func songRows(_ songs: [Song], start: Int) -> [CPListItem] {
        let end = min(songs.count, start + 100)
        guard start < end else { return [] }
        var items = (start..<end).map { index in
            let item = row(songs[index].name, songs[index].artist) { [weak self] in self?.player.select(songs, index: index); self?.showNowPlaying() }
            item.isPlaying = player.current?.key == songs[index].key && player.wanted
            return item
        }
        if end < songs.count { items.append(row("更多歌曲", "\(end + 1)–\(min(end + 100, songs.count))") { [weak self] in guard let self = self else { return }; self.push(CPListTemplate(title: "歌曲", sections: [CPListSection(items: self.songRows(songs, start: end))])) }) }
        return items
    }
    func showList(_ list: Object) {
        let songs = (list["list"] as? [Object] ?? []).map { Song(raw: $0) }
        push(CPListTemplate(title: text(list["name"]), sections: [CPListSection(items: songRows(songs, start: 0))]))
    }
    func push(_ template: CPTemplate) { controller?.pushTemplate(template, animated: true) { _, error in if let error = error { NSLog("CarPlay navigation failed: %@", error.localizedDescription) } } }
    func showNowPlaying() { if controller?.topTemplate !== CPNowPlayingTemplate.shared { push(CPNowPlayingTemplate.shared) } }
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) { push(CPListTemplate(title: "播放队列", sections: [CPListSection(items: songRows(player.queue, start: 0))])) }
}
