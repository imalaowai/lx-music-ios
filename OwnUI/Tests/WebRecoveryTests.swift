import UIKit
import WebKit

// Exercise the production WKWebView delegate and foreground path while keeping
// the native Player alive. Test-only scene visibility simulates an OS reclaim.
enum WebRecoveryTests {
    static var checks: Object = [:]
    static weak var controller: WebController?
    static var finished = false
    static func check(_ condition: Bool, _ name: String) throws { checks[name] = condition; if !condition { throw ClientError(name) } }
    static func start() {
        controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).compactMap { $0.rootViewController }.flatMap(\.children).compactMap { $0 as? WebController }.first
        guard let c = controller else { finish(ClientError("Production WebController missing")); return }
        do {
            let generation = c.pageRecovery.generation, audioGeneration = Player.shared.generation
            c.testPhoneInactive = true
            c.webViewWebContentProcessDidTerminate(c.web)
            try check(c.pageRecovery.needsReload && c.pageRecovery.generation == generation, "backgroundReclaimIsRememberedWithoutLoadingTheHiddenPhoneUI")
            c.testPhoneInactive = false; c.recoverForegroundPage()
            try check(c.pageRecovery.generation > generation, "phoneActivationReloadsTheBundledPageAfterBackgroundReclaim")
            try check(c.view.viewWithTag(214) != nil, "loadingCoverRemainsUntilTheRecoveredAppLayoutIsReady")
            try check(Player.shared.generation == audioGeneration, "pageRecoveryDoesNotReplaceTheNativePlayerOrQueue")
            waitReady(deadline:Date().addingTimeInterval(30)) {
                guard let c = controller else { finish(ClientError("Controller disappeared")); return }
                do {
                    try check(c.pageRecovery.ready && c.view.viewWithTag(214) == nil, "recoveredPageCompletesTheRealNativeUIHandshake")
                    let generation = c.pageRecovery.generation
                    c.web.evaluateJavaScript("window.LXBridge = undefined; true") { _, error in
                        if let error = error { finish(error); return }
                        c.recoverForegroundPage()
                        waitReady(after:generation,deadline:Date().addingTimeInterval(30)) {
                            Task { @MainActor in
                                do {
                                    try check(c.pageRecovery.ready && c.pageRecovery.generation > generation, "foregroundLivenessProbeRecoversABlankBridgeWithoutATerminationCallback")
                                    try await checkSessionRecovery(c)
                                    weak var released: WebController?
                                    autoreleasepool { var orphan: WebController? = WebController(); released = orphan; orphan?.loadViewIfNeeded(); orphan = nil }
                                    try check(released == nil, "scriptMessageHandlerDoesNotRetainAnAbandonedPhoneController")
                                    finish()
                                } catch { finish(error) }
                            }
                        }
                    }
                } catch { finish(error) }
            }
        } catch { finish(error) }
    }
    @MainActor static func checkSessionRecovery(_ c: WebController) async throws {
        let player = Player.shared
        let server = URL(string: "https://qiye-session.invalid/")!
        // Earlier playback and CarPlay checks have their own source fixture.
        UserDefaults.standard.set(server.absoluteString, forKey: WebController.serverKey)
        player.configure(Credentials(server: server.absoluteString, username: "fixture", token: "fixture-token"))
        c.open(server)
        try await waitFor("Old account page is ready") { c.pageRecovery.ready }
        try check(player.api.credentials?.token == "fixture-token", "sessionRecoveryStartsWithTheOldToken")
        var obsoleteError: URLError?
        player.api.request("/api/user/list?session-test=obsolete", timeout: 30) { result in
            if case .failure(let error) = result { obsoleteError = error as? URLError }
        }
        try await waitFor("Old session request reached the server") { PlaylistFixtureProtocol.obsoleteReply != nil }

        let selectSong = "window.playSong({id:'session-track',songmid:1231,meta:{songId:'1231'},name:'重登播放测试曲',singer:'Fixture',source:'wy'},0); true"
        let signedInPage = c.pageRecovery.generation
        _ = try await c.web.evaluateJavaScript(selectSong)
        try await waitFor("An unauthorized playback request opens the signed-out page") {
            player.api.credentials == nil && c.pageRecovery.generation > signedInPage && c.pageRecovery.ready
        }
        let cleared = try await c.web.evaluateJavaScript("localStorage.getItem('lx_user_token') === null")
        try check(cleared as? Bool == true && player.current == nil && !player.loading, "evictedPlaybackClearsStaleSessionAndQueue")

        _ = try await c.web.evaluateJavaScript("void window.LXNative.request('signIn',{username:'fixture',password:'fixture-password',deviceId:'simulator-fixture'}); true")
        try await waitFor("Login reached the server") { PlaylistFixtureProtocol.loginReply != nil }
        c.retryPage()
        let reloadedPage = c.pageRecovery.generation
        PlaylistFixtureProtocol.loginReply?(); PlaylistFixtureProtocol.loginReply = nil
        try await waitFor("A login in flight survives the page reload") {
            player.api.credentials?.token == PlaylistFixtureProtocol.renewedToken && c.pageRecovery.generation > reloadedPage && c.pageRecovery.ready
        }
        let restored = try await c.web.evaluateJavaScript("localStorage.getItem('lx_user_token') === 'renewed-fixture-token'")
        try check(restored as? Bool == true, "reloadedPageUsesFreshNativeCredentials")

        PlaylistFixtureProtocol.obsoleteReply?(); PlaylistFixtureProtocol.obsoleteReply = nil
        try await waitFor("Obsolete HTTP 401 was discarded") { obsoleteError?.code == .cancelled }
        try check(player.api.credentials?.token == PlaylistFixtureProtocol.renewedToken, "obsoleteAuthorizationFailureCannotRevokeNewLogin")
        _ = try await c.web.evaluateJavaScript(selectSong)
        try await waitFor("A track plays after login using the fresh token") {
            player.current?.key == "session-track" && player.playbackAdvancing && player.position > 0
        }
        let pauseIcon = try await c.web.evaluateJavaScript("!!document.querySelector('#mobile-mini-play .fa-pause') && !!document.querySelector('#btn-play .fa-pause')")
        try check(pauseIcon as? Bool == true && player.failure.isEmpty, "firstTrackAfterLoginPlaysAndUpdatesBothButtons")

        player.audio.localAudio?.numberOfLoops = -1
        let musicRequests = PlaylistFixtureProtocol.musicRequests
        player.queue.append(Song(raw:["id":"prefetch-no-source","name":"没有本机音源的下一首","source":"wy"]))
        player.mode = "list"
        player.prefetchNext()
        let verifications = PlaylistFixtureProtocol.verificationRequests
        var rejected = false
        player.api.request("/api/room/binding?session-test=denied") { result in
            if case .failure = result { rejected = true }
        }
        try await waitFor("Secondary endpoint's 401 triggers verification") {
            rejected && PlaylistFixtureProtocol.verificationRequests > verifications
        }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try check(PlaylistFixtureProtocol.musicRequests == musicRequests, "speculativePrefetchDoesNotCallAuthenticatedFallback")
        try check(player.api.credentials?.token == PlaylistFixtureProtocol.renewedToken &&
                  player.current?.key == "session-track" && player.playbackAdvancing && player.failure.isEmpty,
                  "background401DoesNotStopPlaybackWithAValidLogin")
        player.pause(user: false)
    }
    @MainActor static func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw ClientError(description) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    static func waitReady(after generation: Int = -1, deadline: Date, completion: @escaping () -> Void) {
        guard !finished else { return }
        if let c = controller, c.pageRecovery.ready && c.pageRecovery.generation > generation { completion(); return }
        if Date() >= deadline { finish(ClientError("UI recovery handshake timed out")); return }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitReady(after:generation,deadline:deadline,completion:completion) }
    }
    static func finish(_ error: Error? = nil) {
        guard !finished else { return }; finished = true; controller?.testPhoneInactive = false
        checks["passed"] = error == nil
        if let error = error { checks["error"] = error.localizedDescription }
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        try? JSONSerialization.data(withJSONObject:checks,options:.prettyPrinted).write(to:root.appendingPathComponent("LX-Web-Recovery-Checks.json"),options:.atomic)
    }
}
