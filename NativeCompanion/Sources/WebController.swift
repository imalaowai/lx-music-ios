import UIKit
import WebKit
import UniformTypeIdentifiers

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WKScriptMessageHandler?
    init(_ owner: WKScriptMessageHandler) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { owner?.userContentController(controller, didReceive: message) }
}

final class WebController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, UIDocumentPickerDelegate {
    let player = Player.shared
    var web: WKWebView!
    var address: URL?
    var loginTask: URLSessionDataTask?
    var serverGeneration = 0
    static let defaultServer = URL(string: "https://lx.minyue.de5.net:99")!
    static let serverKey = "lx.server"
    static let migratedSessionKey = Vault.webSessionMigratedKey
    private var guestOrigin: URL {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey:"lx.guestOrigin"), let origin = URL(string:saved) { return origin }
        let legacy = !defaults.bool(forKey:Self.migratedSessionKey) ? defaults.string(forKey:Self.serverKey) : nil
        let origin = legacy.flatMap(URL.init(string:)) ?? Self.deviceOrigin
        defaults.set(origin.absoluteString, forKey:"lx.guestOrigin")
        return origin
    }
    var server: URL {
        Self.serverURL(UserDefaults.standard.string(forKey: Self.serverKey)) ?? player.api.base ?? Self.defaultServer
    }
    static func serverURL(_ value: String?) -> URL? {
        guard let value = value, var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.scheme = scheme; parts.host = host; parts.path = ""; parts.query = nil; parts.fragment = nil
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        return parts.url
    }
    var accountInfo: Object {
        ["server":server.absoluteString, "username":player.api.credentials?.username ?? "", "hasAccount":player.api.credentials != nil]
    }
    var loadingBundledPage = false
    var smokeReloadRequested = false
    private var devicePreparations: [String:(key:String, request:LocalRequest, completion:(Result<URL,Error>) -> Void)] = [:]
    var importing: (ticket: String, key: String, url: URL, handle: FileHandle, bytes: Int)?
    var keyboardObserver: NSObjectProtocol?
    var lifecycleObservers: [NSObjectProtocol] = []
    var recoveryTimer: Timer?
    var pageRecovery = PageRecovery()
    var pageProbeInFlight = false
    private var sessionReloadPending = false
    private var sessionRevokedNotice = false
    #if LX_OWN_UI_TESTING
    var testPhoneInactive = false
    #endif
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
        config.userContentController.add(WeakScriptHandler(self), name: "lxNative")
        config.setURLSchemeHandler(MusicLibrary.shared, forURLScheme: "lx-local")
        let bootstrap = accountInfo
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
        showRecovery("正在打开栖页音乐…", retry: false)
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let local = self.view.convert(frame, from: nil)
            self.emit("keyboard", ["visible": local.minY < self.view.bounds.maxY - 80, "duration": number(note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey], 0.25)])
        }
        player.api.prepareDevice = { [weak self] song, completion in
            guard let self = self else { completion(.failure(ClientError("请在手机上准备设备音乐"))); return nil }
            return self.prepareDevice(song, completion:completion)
        }
        player.onState = { [weak self] value in self?.emit("state", value) }
        player.onRoom = { [weak self] value in self?.emit("room", value) }
        player.onRevoked = { [weak self] in
            self?.sessionRevokedNotice = true
            self?.sessionReloadPending = true
            self?.recoverForegroundPage()
        }
        player.onChat = { [weak self] type, value in self?.emitChat(type, value) }
        MusicLibrary.shared.onChange = { [weak self] value in self?.emit("download", value) }
        MusicLibrary.shared.restoreTasks()
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName:name, object:nil, queue:.main) { [weak self] _ in self?.recoverForegroundPage() })
        }
        let timer = Timer(timeInterval:5, repeats:true) { [weak self] _ in self?.recoverForegroundPage() }
        recoveryTimer = timer; RunLoop.main.add(timer, forMode:.common)
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
                let guest = self.guestOrigin
                self.open(self.player.api.base ?? guest)
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); emit("state", player.snapshot()); emit("room", player.room.snapshot())
        recoverForegroundPage()
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
        let dialog = UIAlertController(title: "同步服务器", message: "用于账号同步、一起听和网盘。填写服务器域名及端口。", preferredStyle: .alert)
        dialog.addTextField { field in
            field.placeholder = Self.defaultServer.absoluteString
            field.text = self.server.absoluteString
            field.keyboardType = .URL; field.autocapitalizationType = .none; field.autocorrectionType = .no
        }
        dialog.addAction(UIAlertAction(title: "取消", style: .cancel))
        if server != Self.defaultServer {
            dialog.addAction(UIAlertAction(title: "恢复默认", style: .default) { [weak self] _ in self?.changeServer(Self.defaultServer) })
        }
        dialog.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak dialog] _ in
            guard let self = self else { return }
            guard let url = Self.serverURL(dialog?.textFields?.first?.text) else {
                DispatchQueue.main.async { self.alert("请输入有效的 HTTP 或 HTTPS 服务器地址") }; return
            }
            self.changeServer(url)
        })
        present(dialog, animated: true)
    }
    func changeServer(_ url: URL) {
        guard server != url else { return }
        serverGeneration += 1; loginTask?.cancel(); loginTask = nil
        let wasSignedIn = player.api.credentials != nil
        UserDefaults.standard.set(url.absoluteString, forKey: Self.serverKey)
        UserDefaults.standard.set(true, forKey: Self.migratedSessionKey)
        if wasSignedIn {
            player.configure(nil)
            open(guestOrigin)
        } else {
            emit("server", accountInfo)
        }
    }
    func open(_ requestedURL: URL) {
        let url = sessionReloadPending ? (player.api.base ?? guestOrigin) : requestedURL
        sessionReloadPending = false
        address = url; cancelImport()
        for ticket in Array(devicePreparations.keys) { finishDevicePreparation(ticket, error:"页面已重新加载，请重试") }
        view.viewWithTag(212)?.removeFromSuperview(); view.viewWithTag(213)?.removeFromSuperview()
        showRecovery("正在打开栖页音乐…", retry: false)
        guard let file = Bundle.main.url(forResource: "WebUI", withExtension: "html"), let data = try? Data(contentsOf: file) else {
            showRecovery("内置界面缺失，请重新安装完整安装包。"); return
        }
        let response = URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        pageRecovery.loading(at:ProcessInfo.processInfo.systemUptime); pageProbeInFlight = false
        RuntimeTrace.record("ui.loading", ["generation":pageRecovery.generation])
        loadingBundledPage = true
        web.loadSimulatedRequest(URLRequest(url: url), response: response, responseData: data)
    }
    var phoneForeground: Bool {
        #if LX_OWN_UI_TESTING
        if testPhoneInactive { return false }
        #endif
        return isViewLoaded && view.window?.windowScene?.activationState == .foregroundActive
    }
    func recoverForegroundPage() {
        guard phoneForeground, let address = address else { return }
        if sessionReloadPending {
            // Keep an in-flight login from being abandoned by a late logout.
            guard loginTask == nil else { return }
            open(player.api.base ?? guestOrigin); return
        }
        if pageRecovery.canReload(active:true, at:ProcessInfo.processInfo.systemUptime) {
            open(address); return
        }
        guard pageRecovery.ready, !pageProbeInFlight else { return }
        pageProbeInFlight = true
        let generation = pageRecovery.generation
        web.evaluateJavaScript("window.LXBridge?.isReady?.() === true") { [weak self] value, error in
            guard let self = self, self.pageRecovery.generation == generation, self.pageProbeInFlight else { return }
            self.pageProbeInFlight = false
            if error != nil || value as? Bool != true {
                self.pageRecovery.terminated(); self.recoverForegroundPage()
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self = self, self.pageRecovery.generation == generation, self.pageProbeInFlight else { return }
            self.pageProbeInFlight = false; self.pageRecovery.terminated(); self.recoverForegroundPage()
        }
    }
    func showRecovery(_ message: String, retry: Bool = true) {
        view.viewWithTag(214)?.removeFromSuperview()
        let panel = UIView(); panel.tag = 214; panel.backgroundColor = .systemBackground; panel.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel(); label.text = message; label.numberOfLines = 0; label.textAlignment = .center
        let button = UIButton(type:.system); button.setTitle("重新加载", for:.normal); button.addTarget(self, action:#selector(retryPage), for:.touchUpInside)
        let stack = UIStackView(arrangedSubviews:retry ? [label, button] : [label]); stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack); view.addSubview(panel)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo:view.leadingAnchor),panel.trailingAnchor.constraint(equalTo:view.trailingAnchor),panel.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),panel.bottomAnchor.constraint(equalTo:view.bottomAnchor),stack.centerYAnchor.constraint(equalTo:panel.centerYAnchor),stack.leadingAnchor.constraint(equalTo:panel.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:panel.trailingAnchor,constant:-28)])
    }
    @objc func retryPage() { if let address = address { open(address) } }
    deinit {
        if let observer = keyboardObserver { NotificationCenter.default.removeObserver(observer) }
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        recoveryTimer?.invalidate(); cancelImport()
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
        let pageGeneration = pageRecovery.generation
        func done(_ result: Any = true, _ error: String? = nil) {
            guard self.pageRecovery.generation == pageGeneration else { return }
            self.reply(id.intValue, result, error)
        }
        switch op {
        case "editServer": done(); editAddress()
        case "appInfo":
            var info = accountInfo
            info["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            info["bundledUI"] = true; info["localPlayback"] = true
            info["legacySourceFallback"] = !UserDefaults.standard.bool(forKey: "lx.disableLegacySourceFallback")
            done(info)
        case "session":
            if let account = player.api.credentials, Self.serverURL(address?.absoluteString) == Self.serverURL(account.server) {
                done(["username":account.username, "token":account.token, "info":accountInfo])
            } else {
                let revoked = player.api.credentials == nil && sessionRevokedNotice && !sessionReloadPending
                if revoked { sessionRevokedNotice = false }
                done(["info":accountInfo, "revoked":revoked, "migrate":player.api.credentials == nil && !UserDefaults.standard.bool(forKey: Self.migratedSessionKey)])
            }
        case "signIn":
            let username = text(value["username"]).trimmingCharacters(in: .whitespacesAndNewlines), password = text(value["password"])
            guard !username.isEmpty, !password.isEmpty else { done(false, "请输入账号和密码"); return }
            guard loginTask == nil else { done(false, "正在登录"); return }
            let endpoint = server, attempt = serverGeneration
            var deviceID = UserDefaults.standard.string(forKey: "lx.loginDeviceId") ?? ""
            if deviceID.isEmpty { deviceID = text(value["deviceId"]) }
            if deviceID.isEmpty { deviceID = UUID().uuidString }
            UserDefaults.standard.set(deviceID, forKey: "lx.loginDeviceId")
            let payload = ["username":username, "password":password, "deviceId":deviceID, "deviceName":"栖页音乐 · " + UIDevice.current.model]
            loginTask = player.api.requestServer(endpoint, path: "/api/user/login", body: payload, timeout: 10) { [weak self] result in
                guard let self = self, self.serverGeneration == attempt else { return }
                self.loginTask = nil
                do {
                    let session = try result.get()
                    let token = text(session["token"])
                    guard !token.isEmpty else { throw ClientError("登录服务没有返回会话") }
                    UserDefaults.standard.set(true, forKey: Self.migratedSessionKey)
                    let credentials = Credentials(server: endpoint.absoluteString, username: username, token: token)
                    self.sessionRevokedNotice = false
                    self.player.configure(credentials)
                    done(true)
                    DispatchQueue.main.async {
                        // The server may have issued a new token while WebKit reloaded.
                        guard self.serverGeneration == attempt, self.player.api.credentials == credentials else { return }
                        self.open(endpoint)
                    }
                } catch {
                    let message = error.localizedDescription
                    done(false, message == "Invalid credentials" ? "账号或密码不正确" : message)
                    self.recoverForegroundPage()
                }
            }
        case "signOut":
            serverGeneration += 1; loginTask?.cancel(); loginTask = nil
            UserDefaults.standard.set(true, forKey: Self.migratedSessionKey)
            if player.api.credentials != nil { player.api.request("/api/user/logout", method: "POST", body: [:], timeout: 4) { _ in } }
            player.configure(nil); done()
            DispatchQueue.main.async { self.open(self.guestOrigin) }
        case "carplayStatus": done(CarScene.diagnostic)
        case "shareCarPlayDiagnostic":
            let data = try? JSONSerialization.data(withJSONObject: ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "iOS": UIDevice.current.systemVersion, "carplay": CarScene.diagnostic], options: [.prettyPrinted, .sortedKeys])
            guard let data = data else { done(false, "无法生成连接诊断"); return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("LX-CarPlay-connection.json")
            do { try data.write(to: file, options: .atomic); let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil); sheet.popoverPresentationController?.sourceView = view; sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 100, width: 1, height: 1); present(sheet, animated: true); done() } catch { done(false, error.localizedDescription) }
        case "uiReady":
            #if LX_OWN_UI
            let ready = OwnIntegration.uiReady(value)
            if ready { pageRecovery.acknowledged(); view.viewWithTag(214)?.removeFromSuperview() }
            done(ready)
            #else
            pageRecovery.acknowledged(); view.viewWithTag(214)?.removeFromSuperview()
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
            let username = text(value["username"]), token = text(value["token"])
            guard let address = address, !username.isEmpty, username != "__device__", !token.isEmpty,
                  Self.serverURL(address.absoluteString) == server else { done(false); return }
            if let identity = player.api.credentials {
                done(identity.username == username && identity.token == token); return
            }
            guard !UserDefaults.standard.bool(forKey: Self.migratedSessionKey) else { done(false); return }
            UserDefaults.standard.set(true, forKey: Self.migratedSessionKey)
            cancelImport(); player.configure(Credentials(server: address.absoluteString, username: username, token: token))
            done()
        case "ready":
            done(["state":player.snapshot(), "room":player.room.snapshot()]); player.room.refresh()
        case "musicApi":
            let path = text(value["path"])
            guard path.hasPrefix("/api/music/") || path.hasPrefix("/api/custom-source/") else { done(false, "不是本地音乐接口"); return }
            let body = value["body"] as? Object ?? [:]
            if path == "/api/music/comment" { loadComments(body, page:pageGeneration) { done($0) }; return }
            LocalEngine.shared.call("api", ["path": path, "body": body]) { result in switch result { case .success(let response): done(response); case .failure(let error): done(false, error.localizedDescription) } }
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
            let songs = list.map { Song(raw: $0) }, found = QueuePolicy.matchingIndex(in:songs,key:selected,proposed:Int(number(value["index"],-1)))
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
        case "devicePrepared":
            let error = text(value["error"])
            finishDevicePreparation(text(value["ticket"]), error:error.isEmpty ? nil : error)
            done()
        case "importLookup":
            done(player.api.importedURL(text(value["key"])).map { ["url":$0.absoluteString] } ?? [:])
        case "importBegin":
            do {
                cancelImport()
                let ticket = UUID().uuidString, directory = try Self.importDirectory(), ext = (text(value["name"]) as NSString).pathExtension.lowercased()
                guard ["mp3", "flac", "m4a", "aac", "wav", "aiff", "alac", "ogg", "opus"].contains(ext) else { throw ClientError("请选择音频文件") }
                let url = directory.appendingPathComponent(ticket).appendingPathExtension(ext)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                importing = (ticket, player.api.importKey(text(value["key"])), url, try FileHandle(forWritingTo: url), 0); done(["ticket": ticket])
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
    private func loadComments(_ body: Object, page: Int, completion: @escaping (Object) -> Void) {
        let endpoint = server, serverVersion = serverGeneration
        let failure: Object = ["error":"评论暂时不可用，请稍后重试"]
        let fallback: (Object, Object) -> Void = { [weak self] response, request in
            guard let self = self, self.pageRecovery.generation == page, self.serverGeneration == serverVersion else { return }
            self.player.api.requestServer(endpoint, path:"/api/music/comment", body:request, timeout:5) { result in
                guard self.serverGeneration == serverVersion else { completion(failure); return }
                if case .success(let result) = result, result["comments"] is [Object] { completion(result) }
                else { completion(response) }
            }
        }
        var answered = false
        var task: Cancellable?
        let deadline = DispatchWorkItem {
            guard !answered else { return }
            answered = true; task?.cancel(); completion(failure)
        }
        task = LocalEngine.shared.call("api", ["path":"/api/music/comment", "body":body]) { result in
            guard !answered else { return }
            answered = true; deadline.cancel()
            guard case .success(let data) = result, var response = data as? Object else { completion(failure); return }
            if let request = response.removeValue(forKey:"request") as? Object { fallback(response, request) }
            else { completion(response) }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+8, execute:deadline)
    }
    private func prepareDevice(_ song: Song, completion: @escaping (Result<URL, Error>) -> Void) -> Cancellable? {
        guard phoneForeground, pageRecovery.ready, let raw = script(song.raw) else {
            completion(.failure(ClientError("请打开手机 App 准备这首设备音乐"))); return nil
        }
        let request = LocalRequest(), ticket = UUID().uuidString
        devicePreparations[ticket] = (text(song.raw["deviceKey"]), request, completion)
        // Use the existing script-message channel. The Swift WebKit async
        // overlay adds a hard dependency unavailable on older runtimes.
        web.evaluateJavaScript("window.LXBridge?.prepareDevice(\(raw), '\(ticket)')") { [weak self] result, error in
            if error != nil || result as? Bool != true {
                self?.finishDevicePreparation(ticket, error:"设备音乐读取失败，请重新选择文件")
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+60) { [weak self] in
            self?.finishDevicePreparation(ticket, error:"设备音乐准备超时，请重试")
        }
        return request
    }
    private func finishDevicePreparation(_ ticket: String, error: String? = nil) {
        guard let pending = devicePreparations.removeValue(forKey:ticket), !pending.request.isCancelled else { return }
        if let error = error { pending.completion(.failure(ClientError(error))) }
        else if let url = player.api.importedURL(pending.key) { pending.completion(.success(url)) }
        else { pending.completion(.failure(ClientError("设备音乐读取失败，请重新选择文件"))) }
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
    func emitChat(_ type: String, _ value: Object) { guard phoneForeground, pageRecovery.ready, let a = script(type), let b = script(value) else { return }; web.evaluateJavaScript("window.LXBridge?.chat(\(a),\(b))", completionHandler: nil) }
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
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        pageRecovery.terminated(); showRecovery("页面暂时无法加载，请重试。")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.webView(webView, didFailProvisionalNavigation:navigation, withError:error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageRecovery.terminated(); RuntimeTrace.record("ui.process-terminated")
        recoverForegroundPage()
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let dialog = UIAlertController(title: "栖页音乐", message: message, preferredStyle: .alert); dialog.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() }); present(dialog, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let dialog = UIAlertController(title: "栖页音乐", message: message, preferredStyle: .alert); dialog.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) }); dialog.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) }); present(dialog, animated: true)
    }
}
