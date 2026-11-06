import Foundation

final class RoomClient {
    unowned let player: Player
    var binding: Object?
    var state: Object = [:]
    var participants: [Object] = []
    var participantID = ""
    var owner = ""
    var enabled = true
    var syncTracks = true
    var connected = false
    var order = RoomOrder()
    var socket: URLSessionWebSocketTask?
    var epoch = 0
    var commandEpoch = 0
    var reconnect: DispatchWorkItem?
    var ping: Timer?
    var retry = 0
    var offset = 0.0
    var bestRTT = Double.infinity
    var refreshing = false
    private var bindingCheck = 0
    private var bindingChecked = false
    private var pendingCarPlayAction: (() -> Void)?
    var refreshRetry: DispatchWorkItem?
    var refreshFailures = 0
    var needsSnapshotSync = false
    var lastProgressAt = -Double.infinity
    var outgoing: [(Object, Int)] = []
    var sending = false
    var lastError = ""
    var publishedSignature = ""
    var health = RoomConnectionHealth()
    var lastRecovery = -Double.infinity
    var receivedFrames = 0
    var roomID: String { text(binding?["roomId"]) }
    var active: Bool { !roomID.isEmpty && enabled && syncTracks }
    var controller: Bool { !participantID.isEmpty && text(state["controllerId"]) == participantID }
    var api: API { player.api }
    var localRouteHeld: Bool {
        #if LX_OWN_UI
        return player.routeGate.held
        #else
        return false
        #endif
    }
    init(player: Player) { self.player = player }
    func diagnostic()->Object {
        ["active":active,"connected":connected,"receivedFrames":receivedFrames,
         "lastFrameAge":max(0,ProcessInfo.processInfo.systemUptime-health.lastReceived),
         "reconnectScheduled":reconnect != nil,"error":lastError,"epoch":epoch,
         "bindingChecked":bindingChecked,"checkingBinding":refreshing,"carPlayActionPending":pendingCarPlayAction != nil]
    }
    func recoverConnection(_ reason:String) {
        guard active, bindingChecked else {refresh();return}
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastRecovery>=1 else{return};lastRecovery=now
        RuntimeTrace.record("room.recover",["reason":reason,"epoch":epoch])
        needsSnapshotSync = true
        if socket == nil || health.expired(at:now) { connect() }
        else { send(["type":"room:sync-request"]) }
        refresh()
    }
    func heartbeat() {
        guard active else{return}
        if health.expired(at:ProcessInfo.processInfo.systemUptime) {
            lastError="房间连接无响应，正在自动恢复"
            recoverConnection("heartbeat-timeout");return
        }
        send(["type":"room:ping","time":Date().timeIntervalSince1970*1000])
        // Audio state callbacks/phone JavaScript are not a background clock.
        progress()
    }
    func publish() {
        let visible: Object = ["room": roomID, "connected": connected, "enabled": enabled, "sync": syncTracks, "members": participants, "participantId": participantID, "controller": text(state["controllerId"]), "paused": bool(state["paused"], true), "song": (state["song"] as? Object).map { Song(raw: $0).key } ?? "", "error": lastError]
        let signature = (try? JSONSerialization.data(withJSONObject: visible, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard signature != publishedSignature else { return }; publishedSignature = signature
        player.onRoom?(snapshot())
        NotificationCenter.default.post(name: .lxRoom, object: self)
    }
    func snapshot() -> Object {
        ["binding": binding as Any? ?? NSNull(), "state": state, "participants": participants, "participantId": participantID, "owner": owner, "connected": connected, "enabled": enabled, "syncOnTrack": syncTracks, "error": lastError]
    }
    // A cold CarPlay tap can arrive before the account's room binding is known.
    // Retain only the latest action and run it after the first room snapshot.
    func afterInitialBinding(_ action: @escaping () -> Void) {
        guard !bindingChecked, api.credentials?.token.isEmpty == false else { action(); return }
        pendingCarPlayAction = action
        refresh()
    }
    func cancelCarPlayAction() { pendingCarPlayAction = nil }
    private func completeBindingCheck(_ attempt: Int) {
        guard bindingCheck == attempt, refreshing else { return }
        refreshing = false
        bindingChecked = true
        let action = pendingCarPlayAction
        pendingCarPlayAction = nil
        action?()
        publish()
    }
    func refresh() {
        guard api.credentials?.token.isEmpty == false, !refreshing else { return }
        refreshing = true
        bindingCheck += 1
        let attempt = bindingCheck
        var configuration: Result<Object, Error>?
        var bindingResult: Result<Object, Error>?
        let finish = { [weak self] in
            guard let self = self, self.bindingCheck == attempt,
                  let configuration = configuration, let bindingResult = bindingResult else { return }
            self.applyBindingCheck(bindingResult, configuration: configuration, attempt: attempt)
        }
        api.request("/api/music/config", timeout: 6) { result in configuration = result; finish() }
        api.request("/api/room/binding", timeout: 6) { result in bindingResult = result; finish() }
    }
    private func applyBindingCheck(_ result: Result<Object, Error>, configuration: Result<Object, Error>, attempt: Int) {
        if case let .success(config) = configuration {
            enabled = config["room.syncEnabled"] == nil || bool(config["room.syncEnabled"])
            syncTracks = config["room.syncOnTrack"] == nil || bool(config["room.syncOnTrack"])
        }
        refreshRetry?.cancel(); refreshRetry = nil
        switch result {
        case .success(let value):
            refreshFailures = 0; lastError = ""
            let next = value["binding"] as? Object
            let changed = roomID != text(next?["roomId"]) || text(binding?["password"]) != text(next?["password"])
            if changed { resetConnection(clear: true) }
            binding = next
            guard active else { resetConnection(clear: false); completeBindingCheck(attempt); return }
            if socket == nil { connect() }
            needsSnapshotSync = true
            // A proxy may delay the WebSocket handshake. The authenticated
            // playback endpoint can restore the same state directly.
            exchange(["type": "room:sync-request"], timeout: 6) { [weak self] in self?.completeBindingCheck(attempt) }
        case .failure(let error):
            lastError = error.localizedDescription
            completeBindingCheck(attempt)
            guard bindingCheck == attempt else { return }
            let delay = min(30, pow(2, Double(min(refreshFailures, 5)))); refreshFailures += 1
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.bindingCheck == attempt else { return }
                self.refreshRetry = nil; self.refresh()
            }
            refreshRetry = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
    func membership(_ operation: String, values: Object = [:], completion: @escaping (Result<Object, Error>) -> Void) {
        guard ["create", "join", "leave"].contains(operation) else { return }
        api.request("/api/room/" + operation, method: "POST", body: values) { [weak self] result in
            if case .success = result { self?.disconnect(clear: true); self?.refresh() }
            completion(result)
        }
    }
    func disconnect(clear: Bool) {
        bindingCheck += 1; refreshing = false; refreshRetry?.cancel(); refreshRetry = nil
        if clear { bindingChecked = false; refreshFailures = 0; cancelCarPlayAction() }
        resetConnection(clear: clear)
    }
    private func resetConnection(clear: Bool) {
        epoch += 1; commandEpoch += 1; socket?.cancel(with: .goingAway, reason: nil); socket = nil; connected = false
        reconnect?.cancel(); reconnect = nil; ping?.invalidate(); ping = nil; outgoing = []; sending = false
        needsSnapshotSync = false; lastProgressAt = -.infinity
        if clear { binding = nil; state = [:]; participants = []; participantID = ""; owner = ""; order = RoomOrder(); offset = 0; bestRTT = .infinity; retry = 0 }
    }
    func connect() {
        guard active, let url = api.url("/api/room/ws"), let credentials = api.credentials else { return }
        socket?.cancel(with: .goingAway, reason: nil); ping?.invalidate(); reconnect?.cancel(); reconnect=nil;connected=false;epoch += 1
        health.opened(at:ProcessInfo.processInfo.systemUptime)
        needsSnapshotSync = true
        RuntimeTrace.record("room.connect",["epoch":epoch])
        let version = epoch
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = url.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "roomId", value: roomID), URLQueryItem(name: "password", value: text(binding?["password"])), URLQueryItem(name: "token", value: credentials.token), URLQueryItem(name: "start", value: "immediate")]
        guard let address = components.url else { return }
        var request = URLRequest(url: address); request.setValue(credentials.token, forHTTPHeaderField: "x-user-token")
        let task = api.session.webSocketTask(with: request); socket = task; task.resume()
        send(["type": "room:ping", "time": Date().timeIntervalSince1970 * 1000]); send(["type": "room:sync-request"])
        receive(task, version: version)
        let timer=Timer(timeInterval:4,repeats:true){[weak self] _ in self?.heartbeat()}
        ping=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func send(_ body: Object) {
        guard let socket = socket, let data = try? JSONSerialization.data(withJSONObject: body), let message = String(data: data, encoding: .utf8) else { return }
        let version = epoch
        socket.send(.string(message)) { [weak self] error in if error != nil { DispatchQueue.main.async { self?.lost(version) } } }
    }
    func receive(_ task: URLSessionWebSocketTask, version: Int) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.epoch == version, self.socket === task else { return }
                switch result {
                case .success(let message):
                    self.connected = true; self.retry = 0
                    self.lastError="";self.receivedFrames += 1;self.health.received(at:ProcessInfo.processInfo.systemUptime)
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: data = Data() }
                    if let value = (try? JSONSerialization.jsonObject(with: data)) as? Object { self.handle(text(value["type"]), value["data"]) }
                    self.receive(task, version: version)
                case .failure: self.lost(version)
                }
            }
        }
    }
    func lost(_ version: Int) {
        guard epoch == version, active else { return }
        RuntimeTrace.record("room.socket-lost",["epoch":version])
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; connected = false; ping?.invalidate(); ping = nil; publish()
        guard reconnect == nil else { return }
        let delay = min(15, pow(2, Double(retry))); retry += 1
        let work = DispatchWorkItem { [weak self] in guard let self = self, self.epoch == version else { return }; self.reconnect = nil; self.connect(); self.exchange(["type": "room:sync-request"]) }
        reconnect = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func handle(_ type: String, _ payload: Any?) {
        let value = payload as? Object ?? [:]
        switch type {
        case "room:pong":
            let now = Date().timeIntervalSince1970 * 1000, rtt = now - number(value["clientTime"], now)
            if rtt >= 0, rtt < bestRTT { bestRTT = rtt; offset = number(value["serverTime"], now) + rtt / 2 - now }
        case "room:config": enabled = value["syncEnabled"] == nil || bool(value["syncEnabled"]); syncTracks = value["syncOnTrack"] == nil || bool(value["syncOnTrack"])
        case "room:joined":
            participantID = text((value["participant"] as? Object)?["id"]); owner = text(value["owner"]); participants = value["participants"] as? [Object] ?? []
            if let config = value["config"] as? Object { enabled = config["syncEnabled"] == nil || bool(config["syncEnabled"]); syncTracks = config["syncOnTrack"] == nil || bool(config["syncOnTrack"]) }
            if let initial = value["state"] as? Object, initial["song"] is Object { apply(initial) }
            else if player.wanted, player.audio.currentItem != nil, !localRouteHeld, order.pendingID.isEmpty { sendState(reason: "join-current") }
        case "room:participants": participants = payload as? [Object] ?? []
        case "room:state", "room:snapshot": apply(value["state"] as? Object ?? value)
        case "room:chat-update", "room:chat-history": player.onChat?(type, value)
        case "room:dissolved": player.pause(user: false); disconnect(clear: true)
        case "room:session-evicted": player.onRevoked?(); player.configure(nil); player.failure = "账号登录已失效，请重新登录"; player.publish()
        case "room:switched": disconnect(clear: true); refresh()
        case "room:error": player.failure = text(value["message"]); player.publish()
        default: break
        }
        publish()
    }
    func target(_ incoming: Object) -> Double {
        let now = Date().timeIntervalSince1970 * 1000 + offset
        let start = max(number(incoming["updatedAt"], now), number(incoming["playAt"]))
        return max(0, number(incoming["currentTime"]) + (bool(incoming["paused"], true) ? 0 : max(0, now - start) / 1000))
    }
    func apply(_ incoming: Object) {
        let wasPending = !order.pendingID.isEmpty
        guard active, let raw = incoming["song"] as? Object, order.accept(incoming, participant: participantID) else { return }
        let resynchronizing = needsSnapshotSync; needsSnapshotSync = false
        let oldPlaybackRevision = number(state["playbackRevision"], -1)
        let oldKey = player.current?.key ?? "", song = Song(raw: raw), reason = text(incoming["reason"])
        let list = (incoming["playlist"] as? [Object] ?? []).map { Song(raw: $0) }
        let listToUse = list.isEmpty ? [song] : list
        let proposed = Int(number(incoming["index"], -1)), found = listToUse.firstIndex(where: {$0.key == song.key}) ?? 0
        let selected = listToUse.indices.contains(proposed) && listToUse[proposed].key == song.key ? proposed : found
        let shouldPause = bool(incoming["paused"], true) || localRouteHeld, wantedBefore = player.wanted
        state = incoming
        if ["list", "single", "order", "random"].contains(text(incoming["playMode"])) { player.mode = text(incoming["playMode"]) }
        let restarted = !wasPending && number(incoming["playbackRevision"], -1) > oldPlaybackRevision && ["track", "ended"].contains(reason)
        let recoverEnded = resynchronizing && !shouldPause && player.endGuard.handled && target(incoming) < max(0, player.duration - 1)
        let needsDecoder = player.audio.currentItem == nil && !player.loading && !localRouteHeld
        if song.key != oldKey || needsDecoder || restarted || recoverEnded {
            RuntimeTrace.record("room.track",["revision":number(incoming["revision"]),"paused":shouldPause,"reason":reason])
            player.select(listToUse, index: selected, paused: shouldPause, user: false, time: target(incoming))
        } else {
            if listToUse.map(\.key) != player.queue.map(\.key) { player.queue = listToUse; player.queueRevision += 1 }; player.index = selected
            // Correct once after reconnect, including a missed seek whose newest
            // snapshot is now a progress event. Routine snapshots stay smooth.
            if reason == "seek" || ((resynchronizing || wasPending) && !localRouteHeld && !player.loading && abs(player.position - target(incoming)) > 1) { player.seek(target(incoming), user: false) }
            if shouldPause, wantedBefore { player.pause(user: false) }
            else if !shouldPause, !wantedBefore, !player.endGuard.handled, resynchronizing || ["play", "track", "join-current", "manual", "resume-sync"].contains(reason) { player.play(user: false) }
        }
        player.publish(); publish()
        if wasPending && !player.loading { mediaReady() }
    }
    func sendState(reason: String, position: Double? = nil) {
        guard active, let song = player.current else { return }
        let command = reason == "track" ? UUID().uuidString : ""
        var value: Object = ["reason": reason, "origin": "user", "userInitiated": true, "sentAt": Date().timeIntervalSince1970 * 1000, "song": song.raw, "index": player.index, "songKey": song.key, "paused": !player.wanted, "currentTime": reason == "track" ? 0 : (position ?? player.position), "duration": reason == "track" ? 0 : player.duration, "playMode": player.mode]
        if ["track", "queue", "join-current", "manual"].contains(reason) { value["playlist"] = player.queue.map(\.raw) }
        if state["playbackRevision"] != nil { value["playbackRevision"] = state["playbackRevision"] }
        if !command.isEmpty { value["commandId"] = command; order.pendingID = command; order.pendingKey = song.key }
        // Keep the in-flight request ordered, but never replay a backlog of old
        // song selections after the network wakes. A track contains the full queue.
        if reason == "track" { outgoing.removeAll() }
        else { outgoing.removeAll { item in
            guard let old = item.0["state"] as? Object, text(old["songKey"]) == song.key else { return false }
            let oldReason = text(old["reason"])
            return oldReason == reason || (["play", "pause"].contains(reason) && ["play", "pause"].contains(oldReason))
        } }
        outgoing.append((["type": "room:state", "state": value], commandEpoch)); drain()
    }
    func drain() {
        guard !sending, !outgoing.isEmpty else { return }
        let (command, version) = outgoing.removeFirst()
        guard version == commandEpoch, active else { drain(); return }
        sending = true
        exchange(command) { [weak self] in guard let self = self, self.commandEpoch == version else { return }; self.sending = false; self.drain() }
    }
    func exchange(_ values: Object, timeout: TimeInterval? = nil, completion: (() -> Void)? = nil) {
        guard active else { completion?(); return }
        var body = values; body["roomId"] = roomID; body["immediateStart"] = true
        let version = commandEpoch
        api.request("/api/room/playback", method: "POST", body: body, timeout: timeout) { [weak self] result in
            guard let self = self, self.commandEpoch == version else { return }
            defer { completion?() }
            switch result {
            case .success(let response):
                self.lastError = ""
                if let id = response["participantId"] as? String { self.participantID = id }
                let type = text(values["type"])
                if type == "room:state", !bool(response["accepted"]) {
                    let command = text((values["state"] as? Object)?["commandId"])
                    if command == self.order.pendingID {
                        self.order.pendingID = ""; self.order.pendingKey = ""; self.needsSnapshotSync = true
                        if let incoming = response["state"] as? Object { self.apply(incoming) }
                    }
                    self.lastError = "房间未接受这次控制，请重新连接房间"; self.publish(); return
                }
                if type != "room:media-ready", let incoming = response["state"] as? Object { self.apply(incoming) }
            case .failure(let error):
                let command = text((values["state"] as? Object)?["commandId"])
                if !command.isEmpty && command == self.order.pendingID { self.order.pendingID = ""; self.order.pendingKey = ""; self.needsSnapshotSync = true }
                self.lastError = error.localizedDescription; self.publish()
            }
        }
    }
    func progress() {
        guard active, connected, controller, player.wanted, !player.loading, !player.seeking, let song = player.current else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgressAt >= 4 else { return }; lastProgressAt = now
        var progress: Object = ["reason": "progress", "origin": "auto", "userInitiated": false, "songKey": wireSongKey(song), "currentTime": player.position, "duration": player.duration, "paused": false]
        if state["playbackRevision"] != nil { progress["playbackRevision"] = state["playbackRevision"] }
        send(["type": "room:state", "state": progress])
    }
    // Use the server's negotiated key for telemetry, including older servers.
    func wireSongKey(_ song: Song) -> String {
        if let raw = state["song"] as? Object, Song(raw:raw).key == song.key, !text(state["songKey"]).isEmpty { return text(state["songKey"]) }
        return song.key
    }
    func mediaReady() {
        guard active, let song = player.current else { return }
        // Resolving/buffering can take seconds after the track's room snapshot.
        // Join the current timeline once ready, before the first progress report.
        if !localRouteHeld && player.wanted && !player.loading && !player.seeking && !bool(state["paused"],true),
           let raw = state["song"] as? Object, Song(raw:raw).key == song.key,
           abs(player.position - target(state)) > 1 { player.seek(target(state), user:false) }
        var value: Object = ["type": "room:media-ready", "songKey": wireSongKey(song), "duration": player.duration]
        if state["playbackRevision"] != nil { value["playbackRevision"] = state["playbackRevision"] }
        exchange(value)
    }
    func ended(attempt: Int = 0) {
        guard active, let song = player.current else { player.finishTransition(); return }
        let generation = player.generation, version = commandEpoch
        let body: Object = ["type": "room:ended", "roomId": roomID, "songKey": wireSongKey(song), "currentTime": max(player.position, player.duration), "duration": player.duration, "playbackRevision": number(state["playbackRevision"]), "immediateStart": true]
        api.request("/api/room/playback", method: "POST", body: body) { [weak self] result in
            guard let self = self, self.commandEpoch == version, self.player.generation == generation, self.active else { return }
            if case .success(let response) = result {
                if let id = response["participantId"] as? String { self.participantID = id }
                if let incoming = response["state"] as? Object { self.apply(incoming) }
                if self.player.generation != generation { return }
                if !self.player.wanted { self.player.finishTransition(); return }
            }
            if attempt < 4 {
                self.send(["type": "room:sync-request"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in guard let self = self, self.player.generation == generation else { return }; self.ended(attempt: attempt + 1) }
            } else { self.player.fail(ClientError("本首已播完，房间未返回下一首。请检查房间连接或点下一首。")) }
        }
    }
}
