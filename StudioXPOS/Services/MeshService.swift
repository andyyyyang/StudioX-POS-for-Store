import CryptoKit
import Foundation
import Network
import Observation
import POSCore
import POSSync

/// 同一家店的 iPad 在同一個 Wi-Fi 上直接互傳事件（不經過網際網路）。
///
/// - 用 Bonjour（`_studiox-pos._tcp`）找彼此；服務名稱是裝置 id，id 比較小的那台主動連（不會連兩條）
/// - 每則訊息：MeshEnvelope（HMAC 簽章、5 分鐘內）的 JSON，再用店家的 mesh 金鑰 AES-GCM 加密；前面 4 bytes 是長度
/// - 剛連上先交換「每台看到第幾筆」，各自補給對方缺的；之後記了新事件就馬上送
/// - 收到的事件一樣走 Ledger.merge（驗雜湊、去重）：從雲端、從區網來的同一筆只會記一次
@Observable
final class MeshService {
    /// 現在連著的其他 iPad（裝置 id）
    private(set) var peers: [String] = []
    private(set) var running = false

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [ObjectIdentifier: MeshLink] = [:]
    private var linkPeer: [ObjectIdentifier: String] = [:]
    private var deviceId = ""
    private var key: [UInt8] = []
    private var onEvents: (([POSEvent]) -> Void)?
    private var allEvents: (() -> [POSEvent])?

    static let serviceType = "_studiox-pos._tcp"

    func start(deviceId: String, key: [UInt8], onEvents: @escaping ([POSEvent]) -> Void, summary: @escaping () -> [POSEvent]) {
        stop()
        self.deviceId = deviceId
        self.key = key
        self.onEvents = onEvents
        self.allEvents = summary
        running = true

        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: deviceId, type: Self.serviceType)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.attach(conn) }
            }
            l.start(queue: .global(qos: .utility))
            listener = l
        } catch {
            running = false
            return
        }

        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in self?.found(endpoints) }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        for l in links.values { l.close() }
        links = [:]
        linkPeer = [:]
        peers = []
        running = false
    }

    /// 這台記了新事件：送給所有連著的 iPad
    func broadcast(_ events: [POSEvent]) {
        guard running, !events.isEmpty, !links.isEmpty else { return }
        guard let frame = seal(MeshEnvelope.Kind.events, events: events) else { return }
        for l in links.values { l.send(frame) }
    }

    // MARK: 連線

    private func found(_ endpoints: [NWEndpoint]) {
        for ep in endpoints {
            guard case .service(let name, _, _, _) = ep, name != deviceId else { continue }
            // id 小的主動連（兩台不會互連兩條）；已經連著的不重連
            guard deviceId < name, !linkPeer.values.contains(name) else { continue }
            attach(NWConnection(to: ep, using: .tcp), peer: name)
        }
    }

    private func attach(_ conn: NWConnection, peer: String? = nil) {
        let link = MeshLink(connection: conn)
        let id = ObjectIdentifier(link)
        links[id] = link
        if let peer { linkPeer[id] = peer }
        link.onReady = { [weak self] in
            Task { @MainActor in self?.hello(id) }
        }
        link.onFrame = { [weak self] data in
            Task { @MainActor in self?.received(data, from: id) }
        }
        link.onClose = { [weak self] in
            Task { @MainActor in self?.closed(id) }
        }
        link.start()
    }

    private func hello(_ id: ObjectIdentifier) {
        guard let link = links[id], let events = allEvents?() else { return }
        if let frame = seal(.summary, seen: MeshEnvelope.seen(in: events)) { link.send(frame) }
    }

    private func closed(_ id: ObjectIdentifier) {
        links[id] = nil
        linkPeer[id] = nil
        refreshPeers()
    }

    private func received(_ data: Data, from id: ObjectIdentifier) {
        guard let env = open(data), env.from != deviceId else { return }
        if linkPeer[id] == nil {
            linkPeer[id] = env.from
            refreshPeers()
        }
        switch env.kind {
        case .events:
            onEvents?(env.events)
        case .summary:
            // 對方缺的補給他（一次最多 500 筆，分批送）
            guard let all = allEvents?(), let link = links[id] else { return }
            let missing = MeshEnvelope.missing(theirs: env.seen, from: all)
            var i = 0
            while i < missing.count {
                let chunk = Array(missing[i..<min(i + 500, missing.count)])
                if let frame = seal(.events, events: chunk) { link.send(frame) }
                i += 500
            }
        case .request:
            break
        }
    }

    private func refreshPeers() {
        peers = Array(Set(linkPeer.values)).sorted()
    }

    // MARK: 加密

    private func seal(_ kind: MeshEnvelope.Kind, events: [POSEvent] = [], seen: [String: Int] = [:]) -> Data? {
        guard let env = try? MeshEnvelope(kind: kind, from: deviceId, events: events, seen: seen, key: key),
              let json = try? JSONEncoder().encode(env),
              let box = try? AES.GCM.seal(json, using: SymmetricKey(data: key)),
              let combined = box.combined else { return nil }
        return combined
    }

    private func open(_ data: Data) -> MeshEnvelope? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let json = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
              let env = try? JSONDecoder().decode(MeshEnvelope.self, from: json),
              env.isAuthentic(key: key) else { return nil }
        return env
    }
}

/// 一條區網連線：4 bytes 長度＋內容的訊框
nonisolated final class MeshLink: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "tw.studiox.pos.mesh")
    private var buffer = Data()
    var onReady: (@Sendable () -> Void)?
    var onFrame: (@Sendable (Data) -> Void)?
    var onClose: (@Sendable () -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?()
                self?.receive()
            case .failed, .cancelled:
                self?.onClose?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() { connection.cancel() }

    func send(_ payload: Data) {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.drain()
            if complete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            // 太大的訊框（不是我們的程式送的）：斷線
            guard length < 16 << 20 else {
                connection.cancel()
                return
            }
            guard buffer.count >= 4 + length else { return }
            let payload = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + length)
            onFrame?(payload)
        }
    }
}
