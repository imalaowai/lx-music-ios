import UIKit
import WebKit

final class WebController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let player = Player.shared
    var web: WKWebView!
    var address: URL?
    var importing: (ticket: String, key: String, url: URL, handle: FileHandle, bytes: Int)?
    var lastSong = ""
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "LX 音乐"; view.backgroundColor = .systemBackground
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.add(self, name: "lxNative")
        if let path = Bundle.main.url(forResource: "Bridge", withExtension: "js"), let script = try? String(contentsOf: path) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; web.uiDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor), web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "服务器", style: .plain, target: self, action: #selector(editAddress))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reload))
        player.onState = { [weak self] value in self?.emit("state", value) }
        player.onRoom = { [weak self] value in self?.emit("room", value) }
        player.onRevoked = { [weak self] in self?.web.evaluateJavaScript("window.LXBridge?.revoked()", completionHandler: nil) }
        player.onChat = { [weak self] type, value in self?.emitChat(type, value) }
        let rules: [Object] = [["trigger": ["url-filter": ".*/js/(listen_room|queue_audio|pwa_update|ios-background-audio|ios_audio_output|room_start)\\.js([?].*)?$", "resource-type": ["script"]], "action": ["type": "block"]]]
        let data = try! JSONSerialization.data(withJSONObject: rules)
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LXNativeOwner-v1", encodedContentRuleList: String(data: data, encoding: .utf8)!) { [weak self] rules, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let rules = rules else { self.alert("无法初始化 App 播放接入：\(error?.localizedDescription ?? "未知错误")"); return }
                self.web.configuration.userContentController.add(rules)
                if let saved = UserDefaults.standard.string(forKey: "lx.server"), let url = URL(string: saved) { self.open(url) }
                else { self.showWelcome() }
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); emit("state", player.snapshot()); emit("room", player.room.snapshot()) }
    func showWelcome() {
        let label = UILabel(); label.text = "连接你的 LX 音乐服务器\n\n点击左上角“服务器”填写网页地址\n登录后，App 将接管播放和房间同步。"; label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .secondaryLabel
        label.frame = view.bounds.insetBy(dx: 24, dy: 100); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; label.tag = 212; view.addSubview(label)
        editAddress()
    }
    @objc func editAddress() {
        guard presentedViewController == nil else { return }
        let dialog = UIAlertController(title: "音乐服务器", message: "填写完整播放器网页地址，支持自定义端口和路径。", preferredStyle: .alert)
        dialog.addTextField { field in field.placeholder = "https://你的域名:端口/"; field.text = self.address?.absoluteString ?? UserDefaults.standard.string(forKey: "lx.server"); field.keyboardType = .URL; field.autocapitalizationType = .none; field.autocorrectionType = .no }
        dialog.addAction(UIAlertAction(title: "取消", style: .cancel))
        dialog.addAction(UIAlertAction(title: "连接", style: .default) { [weak self, weak dialog] _ in
            guard let self = self, let url = URL(string: dialog?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { self?.alert("地址无效，请填写 http:// 或 https:// 开头的网址"); return }
            if self.address?.absoluteString != url.absoluteString { self.player.configure(nil); self.cancelImport() }
            UserDefaults.standard.set(url.absoluteString, forKey: "lx.server"); self.open(url)
        })
        present(dialog, animated: true)
    }
    func open(_ url: URL) { address = url; view.viewWithTag(212)?.removeFromSuperview(); web.load(URLRequest(url: url)) }
    @objc func reload() { if let address = address { web.load(URLRequest(url: address)) } }
    func allowed(_ origin: WKSecurityOrigin) -> Bool {
        guard let url = address, origin.protocol == url.scheme, origin.host.lowercased() == url.host?.lowercased() else { return false }
        let expected = url.port ?? (url.scheme == "https" ? 443 : 80)
        return (origin.port == 0 ? (origin.protocol == "https" ? 443 : 80) : origin.port) == expected
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, allowed(message.frameInfo.securityOrigin), let value = message.body as? Object, let id = value["id"] as? NSNumber else { return }
        let op = text(value["op"])
        func done(_ result: Any = true, _ error: String? = nil) { self.reply(id.intValue, result, error) }
        switch op {
        case "auth":
            guard let address = address else { done(false, "服务器地址无效"); return }
            let username = text(value["username"]), token = text(value["token"])
            let credentials = username.isEmpty || token.isEmpty ? nil : Credentials(server: address.absoluteString, username: username, token: token)
            let changedIdentity = credentials?.server != player.api.credentials?.server || credentials?.username != player.api.credentials?.username
            if changedIdentity { cancelImport() }
            player.configure(credentials)
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies { HTTPCookieStorage.shared.setCookies([cookie], for: address, mainDocumentURL: address) }
            }
            done()
        case "ready": player.onState?(player.snapshot()); player.onRoom?(player.room.snapshot()); player.room.refresh(); done()
        case "preferences":
            player.quality = text(value["quality"]).isEmpty ? "flac" : text(value["quality"]); player.allowFallback = bool(value["allowFallback"], true)
            let previousMode = player.mode
            if ["list", "single", "random", "order"].contains(text(value["mode"])) { player.mode = text(value["mode"]) }
            if previousMode != player.mode { player.room.sendState(reason: "mode") }
            player.persistQueue(); done()
        case "select":
            guard let queue = value["queue"] as? [Object], queue.count <= 20000 else { done(false, "播放队列无效"); return }
            player.quality = text(value["quality"]).isEmpty ? player.quality : text(value["quality"]); player.allowFallback = bool(value["allowFallback"], true)
            player.mode = ["list", "single", "random", "order"].contains(text(value["mode"])) ? text(value["mode"]) : "list"
            let target = Int(number(value["index"], -1)); guard queue.indices.contains(target) else { done(false, "歌曲索引无效"); return }
            player.select(queue.map { Song(raw: $0) }, index: target); done()
        case "queue":
            guard let list = value["queue"] as? [Object], list.count <= 20000 else { done(false, "播放队列无效"); return }
            let selected = player.current?.key
            let songs = list.map { Song(raw: $0) }, found = songs.firstIndex(where: {$0.key == selected})
            if !songs.isEmpty, selected != nil, found == nil {
                player.select(songs, index: max(0, min(Int(number(value["index"])), songs.count - 1)), paused: !player.wanted)
            } else {
                player.queue = songs; player.queueRevision += 1; player.index = found ?? -1
                if songs.isEmpty { player.finishTransition(); player.pause(); player.generation += 1; player.resolution?.cancel(); player.audio.replaceCurrentItem(with: nil) }
                player.room.sendState(reason: "queue"); player.persistQueue(); player.publish()
            }
            done()
        case "play": player.play(); done()
        case "pause": player.pause(); done()
        case "next": player.move(); done()
        case "previous": player.move(previous: true); done()
        case "volume": player.audio.volume = Float(max(0, min(1, number(value["volume"], 1)))); player.audio.isMuted = bool(value["muted"]); player.publish(includeQueue: false); done()
        case "seek": player.seek(number(value["time"])); done()
        case "roomRefresh": player.room.refresh(); done()
        case "roomMembership":
            player.room.membership(text(value["operation"]), values: ["roomId": text(value["roomId"]), "password": text(value["password"])]) { result in switch result { case .success(let response): done(response); case .failure(let error): done(false, error.localizedDescription) } }
        case "library":
            if let lists = value["lists"] as? [Object] { player.library = lists; player.libraryRevision += 1; player.persistLibrary(); NotificationCenter.default.post(name: .lxLibrary, object: player) }; done()
        case "importLookup":
            let key = "lx.import." + (player.api.credentials?.server ?? "") + "." + (player.api.credentials?.username ?? "") + "." + text(value["key"])
            if let stored = UserDefaults.standard.string(forKey: key), let url = URL(string: stored), url.path.hasPrefix((try? Self.importDirectory().path) ?? "INVALID"), FileManager.default.fileExists(atPath: url.path) { done(["url": stored]) } else { done([:]) }
        case "importBegin":
            do {
                cancelImport()
                let ticket = UUID().uuidString, directory = try Self.importDirectory(), ext = (text(value["name"]) as NSString).pathExtension.lowercased()
                guard ["mp3", "flac", "m4a", "aac", "wav", "aiff", "alac", "ogg", "opus"].contains(ext) else { throw ClientError("请选择音频文件") }
                let url = directory.appendingPathComponent(ticket).appendingPathExtension(ext)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                importing = (ticket, "lx.import." + (player.api.credentials?.server ?? "") + "." + (player.api.credentials?.username ?? "") + "." + text(value["key"]), url, try FileHandle(forWritingTo: url), 0); done(["ticket": ticket])
            } catch { done(false, error.localizedDescription) }
        case "importChunk":
            guard var item = importing, item.ticket == text(value["ticket"]), let data = Data(base64Encoded: text(value["data"])), data.count <= 65536, item.bytes + data.count <= 500 * 1024 * 1024 else { done(false, "设备文件接收状态无效"); return }
            do { try item.handle.write(contentsOf: data); item.bytes += data.count; importing = item; done() } catch { cancelImport(); done(false, error.localizedDescription) }
        case "importEnd":
            guard let item = importing, item.ticket == text(value["ticket"]), item.bytes > 0 else { done(false, "设备文件为空"); return }
            do { try item.handle.close(); UserDefaults.standard.set(item.url.absoluteString, forKey: item.key); importing = nil; done(["url": item.url.absoluteString]) } catch { cancelImport(); done(false, error.localizedDescription) }
        case "importCancel": cancelImport(); done()
        default: done(false, "App 不支持此操作")
        }
    }
    static func importDirectory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ImportedAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func cancelImport() { if let item = importing { try? item.handle.close(); try? FileManager.default.removeItem(at: item.url) }; importing = nil }
    func script(_ value: Any) -> String? { guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }; return String(data: data, encoding: .utf8) }
    func reply(_ id: Int, _ value: Any, _ error: String?) {
        guard let encoded = script(value), let failure = script(error as Any? ?? NSNull()) else { return }
        web.evaluateJavaScript("window.LXBridge?.reply(\(id),\(encoded),\(failure))", completionHandler: nil)
    }
    func emit(_ method: String, _ value: Object) {
        guard isViewLoaded, view.window?.windowScene?.activationState == .foregroundActive, let data = script(value) else { return }
        web.evaluateJavaScript("window.LXBridge?.\(method)(\(data))", completionHandler: nil)
    }
    func emitChat(_ type: String, _ value: Object) { guard let a = script(type), let b = script(value) else { return }; web.evaluateJavaScript("window.LXBridge?.chat(\(a),\(b))", completionHandler: nil) }
    func alert(_ message: String) { guard presentedViewController == nil else { return }; let dialog = UIAlertController(title: "LX 音乐", message: message, preferredStyle: .alert); dialog.addAction(UIAlertAction(title: "好", style: .default)); present(dialog, animated: true) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" || url.scheme == "blob" { decisionHandler(.allow); return }
        if let address = address, url.scheme == address.scheme, url.host == address.host, url.port == address.port { decisionHandler(.allow) }
        else { decisionHandler(.cancel); if navigationAction.navigationType == .linkActivated { UIApplication.shared.open(url) } }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { alert("连接失败：\(error.localizedDescription)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if view.window?.windowScene?.activationState == .foregroundActive { webView.reload() } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let dialog = UIAlertController(title: "LX 音乐", message: message, preferredStyle: .alert); dialog.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() }); present(dialog, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let dialog = UIAlertController(title: "LX 音乐", message: message, preferredStyle: .alert); dialog.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) }); dialog.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) }); present(dialog, animated: true)
    }
}
