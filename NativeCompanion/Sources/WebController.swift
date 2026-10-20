import UIKit
import WebKit
import UniformTypeIdentifiers

final class WebController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, UIDocumentPickerDelegate {
    let player = Player.shared
    var web: WKWebView!
    var address: URL?
    var loadingBundledPage = false
    var smokeReloadRequested = false
    var importing: (ticket: String, key: String, url: URL, handle: FileHandle, bytes: Int)?
    var keyboardObserver: NSObjectProtocol?
    var lastSong = ""
    var pickerPurpose = ""
    static let deviceOrigin = URL(string: "https://lx-device.invalid/")!
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationController?.setNavigationBarHidden(true, animated: false)
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.add(self, name: "lxNative")
        config.setURLSchemeHandler(MusicLibrary.shared, forURLScheme: "lx-local")
        let bootstrap: Object = ["server": UserDefaults.standard.string(forKey: "lx.server") ?? "", "username": player.api.credentials?.username ?? "", "hasAccount": player.api.credentials != nil]
        if let value = script(bootstrap) { config.userContentController.addUserScript(WKUserScript(source: "window.__LX_NATIVE_BOOTSTRAP__=" + value + ";", injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        if let path = Bundle.main.url(forResource: "Bridge", withExtension: "js"), let script = try? String(contentsOf: path) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let path = Bundle.main.url(forResource: "AppShell", withExtension: "js"), let shell = try? String(contentsOf: path), let cssPath = Bundle.main.url(forResource: "AppShell", withExtension: "css"), let css = try? String(contentsOf: cssPath), let encoded = script(css) {
            config.userContentController.addUserScript(WKUserScript(source: "window.__LX_SHELL_CSS__=" + encoded + ";\n" + shell, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; web.uiDelegate = self
        web.scrollView.delegate = self
        web.scrollView.bouncesZoom = false
        web.scrollView.bounces = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor), web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), web.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)])
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let local = self.view.convert(frame, from: nil)
            self.emit("keyboard", ["visible": local.minY < self.view.bounds.maxY - 80, "duration": number(note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey], 0.25)])
        }
        player.onState = { [weak self] value in self?.emit("state", value) }
        player.onRoom = { [weak self] value in self?.emit("room", value) }
        player.onRevoked = { [weak self] in self?.web.evaluateJavaScript("window.LXBridge?.revoked()", completionHandler: nil) }
        player.onChat = { [weak self] type, value in self?.emitChat(type, value) }
        MusicLibrary.shared.onChange = { [weak self] value in self?.emit("download", value) }
        MusicLibrary.shared.restoreTasks()
        let rules: [Object] = ["listen_room", "queue_audio", "pwa_update", "ios-background-audio", "ios_audio_output", "room_start"].map { name in
            ["trigger": ["url-filter": ".*/js/" + name + "[.]js.*", "resource-type": ["script"]], "action": ["type": "block"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LXNativeOwner-v2", encodedContentRuleList: String(data: data, encoding: .utf8)!) { [weak self] rules, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let rules = rules else {
                    #if DEBUG
                    if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) { try? Data(String(describing: error).utf8).write(to: support.appendingPathComponent("NativeBridgeError")) }
                    #endif
                    self.alert("无法初始化 App 播放接入：\(error?.localizedDescription ?? "未知错误")"); return }
                self.web.configuration.userContentController.add(rules)
                #if DEBUG
                // CI must verify actual WebKit initialization, not only process launch.
                if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) { try? Data("ready".utf8).write(to: support.appendingPathComponent("NativeBridgeReady")) }
                #endif
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-LXUISmoke") { self.open(URL(string: "https://lx-ui-check.invalid/")!); return }
                #endif
                if let saved = UserDefaults.standard.string(forKey: "lx.server"), let url = URL(string: saved) { self.open(url) }
                else { self.open(Self.deviceOrigin) }
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); emit("state", player.snapshot()); emit("room", player.room.snapshot())
        #if DEBUG
        // Native regressions do not depend on a third WebKit process becoming ready.
        // The separate UI launch above already verifies the real bundled page/reload.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if ProcessInfo.processInfo.arguments.contains("-LXPlaybackSmoke") { PlaybackSmoke.start() }
            if ProcessInfo.processInfo.arguments.contains("-LXCarPlaySmoke") { CarPlaySmoke.start() }
        }
        #endif
    }
    func showWelcome() {
        let label = UILabel(); label.text = "欢迎使用 栖页音乐\n\n连接音乐服务器，即可使用你的歌单与房间\n界面内置于 App，支持后台播放与 CarPlay"; label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .secondaryLabel
        label.frame = view.bounds.insetBy(dx: 24, dy: 100); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; label.tag = 212; view.addSubview(label)
        let connect = UIButton(type: .system); connect.setTitle("连接音乐服务器", for: .normal); connect.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold); connect.addTarget(self, action: #selector(editAddress), for: .touchUpInside); connect.translatesAutoresizingMaskIntoConstraints = false; connect.tag = 213; view.addSubview(connect)
        NSLayoutConstraint.activate([connect.centerXAnchor.constraint(equalTo: view.centerXAnchor), connect.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 115), connect.heightAnchor.constraint(equalToConstant: 48)])
        DispatchQueue.main.async { self.editAddress() }
    }
    @objc func editAddress() {
        guard presentedViewController == nil else { return }
        let dialog = UIAlertController(title: "连接同步服务器", message: "用于账号同步、一起听和网盘。公网地址请使用 HTTPS；局域网可使用 HTTP。本地功能无需连接。", preferredStyle: .alert)
        dialog.addTextField { field in field.placeholder = "https://你的域名:端口/"; field.text = UserDefaults.standard.string(forKey: "lx.server"); field.keyboardType = .URL; field.autocapitalizationType = .none; field.autocorrectionType = .no }
        dialog.addAction(UIAlertAction(title: "取消", style: .cancel))
        if UserDefaults.standard.string(forKey: "lx.server") != nil { dialog.addAction(UIAlertAction(title: "断开服务器", style: .destructive) { [weak self] _ in UserDefaults.standard.removeObject(forKey: "lx.server"); self?.player.configure(nil); self?.open(Self.deviceOrigin) }) }
        dialog.addAction(UIAlertAction(title: "连接", style: .default) { [weak self, weak dialog] _ in
            guard let self = self, let url = URL(string: dialog?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { self?.alert("地址无效，请填写 http:// 或 https:// 开头的网址"); return }
            if self.address?.absoluteString != url.absoluteString { self.player.configure(nil); self.cancelImport() }
            UserDefaults.standard.set(url.absoluteString, forKey: "lx.server"); self.open(url)
        })
        present(dialog, animated: true)
    }
    func open(_ url: URL) {
        address = url; view.viewWithTag(212)?.removeFromSuperview(); view.viewWithTag(213)?.removeFromSuperview()
        guard let file = Bundle.main.url(forResource: "WebUI", withExtension: "html"), let data = try? Data(contentsOf: file) else { alert("内置界面缺失，请重新安装完整安装包。"); return }
        let response = URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        loadingBundledPage = true
        web.loadSimulatedRequest(URLRequest(url: url), response: response, responseData: data)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { if scrollView === web.scrollView, abs(scrollView.contentOffset.y) > 0.5 || abs(scrollView.contentOffset.x) > 0.5 { scrollView.setContentOffset(.zero, animated: false) } }
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
        case "editServer": done(); editAddress()
        case "appInfo":
            done(["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", "server": UserDefaults.standard.string(forKey: "lx.server") ?? "", "username": player.api.credentials?.username ?? "", "hasAccount": player.api.credentials != nil, "bundledUI": true, "localPlayback": true, "carplay": CarScene.diagnostic, "legacySourceFallback": !UserDefaults.standard.bool(forKey: "lx.disableLegacySourceFallback")])
        case "carplayStatus": done(CarScene.diagnostic)
        case "shareCarPlayDiagnostic":
            let data = try? JSONSerialization.data(withJSONObject: ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "iOS": UIDevice.current.systemVersion, "carplay": CarScene.diagnostic], options: [.prettyPrinted, .sortedKeys])
            guard let data = data else { done(false, "无法生成连接诊断"); return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("LX-CarPlay-connection.json")
            do { try data.write(to: file, options: .atomic); let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil); sheet.popoverPresentationController?.sourceView = view; sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 100, width: 1, height: 1); present(sheet, animated: true); done() } catch { done(false, error.localizedDescription) }
        case "uiReady":
            #if LX_OWN_UI
            done(OwnIntegration.uiReady(value))
            #else
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-LXUISmoke"), !smokeReloadRequested {
                smokeReloadRequested = true
                web.evaluateJavaScript("window.location.reload()", completionHandler: nil)
                done(); return
            }
            if bool(value["bundled"]), bool(value["mobile"]), bool(value["themes"]), bool(value["localShell"]), let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) { try? Data("ready".utf8).write(to: support.appendingPathComponent("BundledUIReady")) }
            if ProcessInfo.processInfo.arguments.contains("-LXCarPlaySmoke"), bool(value["localShell"]) { CarPlaySmoke.start() }
            if ProcessInfo.processInfo.arguments.contains("-LXPlaybackSmoke"), bool(value["localShell"]) { PlaybackSmoke.start() }
            #endif
            done()
            #endif
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
        case "musicApi":
            let path = text(value["path"])
            guard path.hasPrefix("/api/music/") || path.hasPrefix("/api/custom-source/") else { done(false, "不是本地音乐接口"); return }
            LocalEngine.shared.call("api", ["path": path, "body": value["body"] as? Object ?? [:]]) { result in switch result { case .success(let response): done(response); case .failure(let error): done(false, error.localizedDescription) } }
        case "sources": LocalEngine.shared.call("sources") { result in switch result { case .success(let response): done(response); case .failure(let error): done(false, error.localizedDescription) } }
        case "sourcePreferences": UserDefaults.standard.set(!bool(value["legacySourceFallback"]), forKey: "lx.disableLegacySourceFallback"); player.api.sourceCache.removeAll(); done()
        case "sourceRemove", "sourceEnable":
            player.api.sourceCache.removeAll()
            LocalEngine.shared.call(op == "sourceRemove" ? "remove" : "enable", ["id": text(value["sourceId"]), "enabled": bool(value["enabled"])]) { result in switch result { case .success(let response): done(response); case .failure(let error): done(false, error.localizedDescription) } }
        case "importSource": showPicker("source"); done()
        case "importSourceURL":
            guard let url = URL(string: text(value["url"])), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { done(false, "请输入完整的音源网址"); return }
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self else { return }
                guard error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let data = data, data.count <= 2_000_000, let code = String(data: data, encoding: .utf8) else { DispatchQueue.main.async { done(false, error?.localizedDescription ?? "无法下载音源，或文件超过 2 MB") }; return }
                LocalEngine.shared.call("import", ["id": UUID().uuidString, "name": url.deletingPathExtension().lastPathComponent, "script": code]) { result in switch result { case .success(let sources): self.player.api.sourceCache.removeAll(); self.emit("sources", ["changed": true]); done(sources); case .failure(let error): done(false, error.localizedDescription) } }
            }.resume()
        case "serverSources":
            guard let credentials = player.api.credentials, let url = player.api.url("/api/custom-source/list?username=" + credentials.username.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!) else { done(false, "请先连接同步服务器并登录"); return }
            var request = URLRequest(url: url); request.setValue(credentials.token, forHTTPHeaderField: "x-user-token"); request.setValue(credentials.username, forHTTPHeaderField: "x-user-name")
            player.api.session.dataTask(with: request) { data, response, error in
                let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                DispatchQueue.main.async { guard error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let value = value else { done(false, error?.localizedDescription ?? "无法读取服务器音源"); return }; done(value) }
            }.resume()
        case "importAudio": showPicker("audio"); done()
        case "downloads": done(MusicLibrary.shared.songs())
        case "playDownload":
            let rows = MusicLibrary.shared.songs().filter { text($0["status"]) == "finished" }
            let songs = rows.compactMap { $0["song"] as? Object }.map { Song(raw: $0) }
            guard let target = songs.firstIndex(where: {text($0.raw["offlineId"]) == text(value["downloadId"])}), MusicLibrary.shared.localURL(songs[target]) != nil else { done(false, "本机音频文件缺失，请重新下载或导入"); return }
            player.select(songs, index: target)
            if player.failure.isEmpty { done() } else { done(false, player.failure) }

        case "download":
            guard let raw = value["song"] as? Object else { done(false, "歌曲信息无效"); return }
            MusicLibrary.shared.download(Song(raw: raw), quality: text(value["quality"]).isEmpty ? player.quality : text(value["quality"]), api: player.api, parts: value["parts"] as? [String] ?? ["song", "lyrics", "cover"]) { result in switch result { case .success(let response): done(response); case .failure(let error): done(false, error.localizedDescription) } }
        case "downloadAssets": do { done(try MusicLibrary.shared.assets(text(value["downloadId"]))) } catch { done(false, error.localizedDescription) }
        case "downloadCancel": MusicLibrary.shared.cancel(text(value["downloadId"])); done()
        case "downloadRemove":
            do { try MusicLibrary.shared.remove(text(value["downloadId"])); done() } catch { done(false, error.localizedDescription) }
        case "shareDownload":
            do {
                let files = try MusicLibrary.shared.shareFiles(text(value["downloadId"]))
                let sheet = UIActivityViewController(activityItems: files, applicationActivities: nil); sheet.popoverPresentationController?.sourceView = view; sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 100, width: 1, height: 1)
                present(sheet, animated: true); done()
            } catch { done(false, error.localizedDescription) }
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
    func showPicker(_ purpose: String) {
        guard presentedViewController == nil else { return }; pickerPurpose = purpose
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: purpose == "source" ? [.javaScript, .plainText, .data] : [.audio, .plainText, .image, .data], asCopy: true)
        picker.allowsMultipleSelection = purpose == "audio"; picker.delegate = self; present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let purpose = pickerPurpose; pickerPurpose = ""
        if purpose == "source", let url = urls.first {
            do {
                guard url.pathExtension.lowercased() == "js", (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else { throw ClientError("请选择不超过 2 MB 的洛雪 .js 音源脚本") }
                let script = try String(contentsOf: url)
                LocalEngine.shared.call("import", ["id": UUID().uuidString, "name": url.deletingPathExtension().lastPathComponent, "script": script]) { [weak self] result in switch result { case .success: self?.player.api.sourceCache.removeAll(); self?.emit("sources", ["changed": true]); case .failure(let error): self?.alert(error.localizedDescription) } }
            } catch { alert(error.localizedDescription) }
        } else if purpose == "audio" { MusicLibrary.shared.importFiles(urls) { [weak self] result in switch result { case .success(let count): self?.emit("sources", ["importedAudio": count]); case .failure(let error): self?.alert(error.localizedDescription) } } }
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
    func alert(_ message: String) { guard presentedViewController == nil else { return }; let dialog = UIAlertController(title: "栖页音乐", message: message, preferredStyle: .alert); dialog.addAction(UIAlertAction(title: "好", style: .default)); present(dialog, animated: true) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" || url.scheme == "blob" { decisionHandler(.allow); return }
        if let address = address, url.scheme == address.scheme, url.host == address.host, url.port == address.port {
            let main = navigationAction.targetFrame?.isMainFrame != false
            let reload = navigationAction.navigationType == .reload
            let playerPage = url.path == address.path && navigationAction.navigationType != .backForward
            if main, reload || playerPage {
                if !reload, loadingBundledPage { loadingBundledPage = false }
                else {
                    // Logout and preference changes reload the page. Keep the installed UI version.
                    decisionHandler(.cancel)
                    DispatchQueue.main.async { self.open(address) }
                    return
                }
            }
            decisionHandler(.allow)
        }
        else { decisionHandler(.cancel); if navigationAction.navigationType == .linkActivated { UIApplication.shared.open(url) } }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { alert("连接失败：\(error.localizedDescription)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if view.window?.windowScene?.activationState == .foregroundActive, let address = address { open(address) } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let dialog = UIAlertController(title: "栖页音乐", message: message, preferredStyle: .alert); dialog.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() }); present(dialog, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let dialog = UIAlertController(title: "栖页音乐", message: message, preferredStyle: .alert); dialog.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) }); dialog.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) }); present(dialog, animated: true)
    }
}
