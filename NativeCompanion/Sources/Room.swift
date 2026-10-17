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
    var reconnect: DispatchWorkItem?
    var ping: Timer?
    var retry = 0
    var offset = 0.0
    var bestRTT = Double.infinity
    var refreshing = false
    var outgoing: [(Object, Int)] = []
    var sending = false
    var roomID: String { text(binding?["roomId"]) }
    var active: Bool { !roomID.isEmpty && enabled && syncTracks }
    var controller: Bool { !participantID.isEmpty && text(state["controllerId"]) == participantID }
    var api: API { player.api }
    init(player: Player) { self.player = player }
    func publish() {
        player.onRoom?(snapshot())
        NotificationCenter.default.post(name: .lxRoom, object: self)
    }
    func snapshot() -> Object {
        ["binding": binding as Any? ?? NSNull(), "state": state, "participants": participants, "participantId": participantID, "owner": owner, "connected": connected, "enabled": enabled, "syncOnTrack": syncTracks]
    }
    func refresh() {
        guard api.credentials?.token.isEmpty == false, !refreshing else { return }
        refreshing = true
        let originalEpoch = epoch
        api.request("/api/music/config") { [weak self] result in
            guard let self = self else { return }
            if case let .success(config) = result { self.enabled = config["room.syncEnabled"] == nil || bool(config["room.syncEnabled"]); self.syncTracks = config["room.syncOnTrack"] == nil || bool(config["room.syncOnTrack"]) }
        }
        api.request("/api/room/binding") { [weak self] result in
            guard let self = self else { return }; self.refreshing = false
            guard self.epoch == originalEpoch else { return }
            switch result {
            case .success(let value):
                let next = value["binding"] as? Object
                let changed = self.roomID != text(next?["roomId"]) || text(self.binding?["password"]) != text(next?["password"])
                if changed { self.disconnect(clear: true) }
                self.binding = next
                if self.active { if !self.connected { self.connect() } else { self.exchange(["type": "room:sync-request"]) } }
                else { self.disconnect(clear: false) }
                self.publish()
            case .failure(let error): self.player.failure = error.localizedDescription; self.player.publish()
            }
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
        epoch += 1; refreshing = false; socket?.cancel(with: .goingAway, reason: nil); socket = nil; connected = false
        reconnect?.cancel(); reconnect = nil; ping?.invalidate(); ping = nil; outgoing = []; sending = false
        if clear { binding = nil; state = [:]; participants = []; participantID = ""; owner = ""; order = RoomOrder(); offset = 0; bestRTT = .infinity; retry = 0 }
    }
    func connect() {
        guard active, let url = api.url("/api/room/ws"), let credentials = api.credentials else { return }
        socket?.cancel(with: .goingAway, reason: nil); ping?.invalidate(); reconnect?.cancel(); epoch += 1
        let version = epoch
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = url.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "roomId", value: roomID), URLQueryItem(name: "password", value: text(binding?["password"])), URLQueryItem(name: "token", value: credentials.token), URLQueryItem(name: "start", value: "immediate")]
        guard let address = components.url else { return }
        var request = URLRequest(url: address); request.setValue(credentials.token, forHTTPHeaderField: "x-user-token")
        let task = api.session.webSocketTask(with: request); socket = task; task.resume()
        send(["type": "room:ping", "time": Date().timeIntervalSince1970 * 1000]); send(["type": "room:sync-request"])
        receive(task, version: version)
        ping = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.send(["type": "room:ping", "time": Date().timeIntervalSince1970 * 1000]) }
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
            else if player.current != nil { sendState(reason: "join-current") }
        case "room:participants": participants = payload as? [Object] ?? []
        case "room:state", "room:snapshot": apply(value["state"] as? Object ?? value)
        case "room:chat-update", "room:chat-history": player.onChat?(type, value)
        case "room:dissolved": player.pause(user: false); disconnect(clear: true)
        case "room:session-evicted": player.configure(nil); player.failure = "账号登录已失效，请重新登录"; player.publish()
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
        guard active, order.accept(incoming, participant: participantID), let raw = incoming["song"] as? Object else { return }
        let oldKey = player.current?.key ?? "", song = Song(raw: raw), reason = text(incoming["reason"])
        let list = (incoming["playlist"] as? [Object] ?? []).map { Song(raw: $0) }
        let listToUse = list.isEmpty ? [song] : list
        let proposed = Int(number(incoming["index"], -1)), found = listToUse.firstIndex(where: {$0.key == song.key}) ?? 0
        let selected = listToUse.indices.contains(proposed) && listToUse[proposed].key == song.key ? proposed : found
        let shouldPause = bool(incoming["paused"], true), wantedBefore = player.wanted
        state = incoming
        if ["list", "single", "order", "random"].contains(text(incoming["playMode"])) { player.mode = text(incoming["playMode"]) }
        if song.key != oldKey || player.audio.currentItem == nil {
            player.select(listToUse, index: selected, paused: shouldPause, user: false, time: target(incoming))
        } else {
            player.queue = listToUse; player.index = selected
            // Ordinary room snapshots never move an already playing device's clock.
            if reason == "seek" { player.seek(target(incoming), user: false) }
            if shouldPause, wantedBefore { player.pause(user: false) }
            else if !shouldPause, !wantedBefore, ["play", "track", "join-current", "manual", "resume-sync"].contains(reason) { player.play(user: false) }
        }
        publish()
    }
    func sendState(reason: String, position: Double? = nil) {
        guard active, let song = player.current else { return }
        let command = reason == "track" ? UUID().uuidString : ""
        var value: Object = ["reason": reason, "origin": "user", "userInitiated": true, "sentAt": Date().timeIntervalSince1970 * 1000, "song": song.raw, "playlist": player.queue.map(\.raw), "index": player.index, "songKey": song.key, "paused": !player.wanted, "currentTime": reason == "track" ? 0 : (position ?? player.position), "duration": reason == "track" ? 0 : player.duration, "playMode": player.mode]
        if !command.isEmpty { value["commandId"] = command; order.pendingID = command; order.pendingKey = song.key }
        outgoing.append((["type": "room:state", "state": value], epoch)); drain()
    }
    func drain() {
        guard !sending, !outgoing.isEmpty else { return }
        let (command, version) = outgoing.removeFirst()
        guard version == epoch, active else { drain(); return }
        sending = true
        exchange(command) { [weak self] in guard let self = self, self.epoch == version else { return }; self.sending = false; self.drain() }
    }
    func exchange(_ values: Object, completion: (() -> Void)? = nil) {
        guard active else { completion?(); return }
        var body = values; body["roomId"] = roomID; body["immediateStart"] = true
        let version = epoch
        api.request("/api/room/playback", method: "POST", body: body) { [weak self] result in
            guard let self = self, self.epoch == version else { return }
            defer { completion?() }
            switch result {
            case .success(let response):
                if let id = response["participantId"] as? String { self.participantID = id }
                let type = text(values["type"])
                if type == "room:state", !bool(response["accepted"]) {
                    self.order.pendingID = ""; self.order.pendingKey = ""; self.player.failure = "房间未接受这次控制，请重新连接房间"; self.player.publish(); return
                }
                if type != "room:media-ready", let incoming = response["state"] as? Object { self.apply(incoming) }
            case .failure(let error): self.player.failure = error.localizedDescription; self.player.publish()
            }
        }
    }
    func progress() {
        guard active, connected, controller, player.wanted, !player.loading, let song = player.current else { return }
        send(["type": "room:state", "state": ["reason": "progress", "origin": "auto", "userInitiated": false, "songKey": song.key, "currentTime": player.position, "duration": player.duration, "paused": false]])
    }
    func mediaReady() { guard active, let song = player.current else { return }; exchange(["type": "room:media-ready", "songKey": song.key, "duration": player.duration]) }
    func ended() {
        guard active, controller, let song = player.current else { return }
        exchange(["type": "room:ended", "songKey": song.key, "currentTime": player.position, "duration": player.duration, "playbackRevision": number(state["playbackRevision"])])
    }
}
