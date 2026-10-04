import Foundation
import POSCore
import POSInvoice

/// 本機的事件日誌：iPad 上唯一的真相。
///
///   own.jsonl     這台產生的事件（流水號、雜湊鏈），一行一筆，寫入就 fsync —— 先寫日誌、再印單、再開錢櫃，
///                 所以就算當機、沒電，收過的錢一定查得到
///   remote.jsonl  別台的事件（從後台或同一個 Wi-Fi 的 iPad 來的），用事件 id 去重、驗過雜湊才收
///   cursor.json   送到後台送到哪（pushedSeq）、從後台拉到哪（pullCursor）、這台最後一筆的雜湊與時鐘
///
/// 執行緒：所有方法都可以從任何執行緒呼叫（內部一把鎖）；App 在主執行緒上用就好。
public final class EventJournal: @unchecked Sendable {
    public struct Cursor: Codable, Sendable, Hashable {
        /// 這台最後一筆的流水號、雜湊
        public var lastSeq: Int = 0
        public var lastHash: String = POSEvent.genesis
        /// 看過的最大 Lamport 時鐘（自己的與別台的）
        public var lamport: Int = 0
        /// 後台確認收到的流水號（含）
        public var pushedSeq: Int = 0
        /// 從後台拉到的 serverSeq
        public var pullCursor: Int = 0
        /// 被後台拒收、要人處理的事件（雜湊錯：通常是檔案壞了）
        public var quarantined: [String] = []
    }

    public let directory: URL
    public let deviceId: String
    private let lock = NSLock()
    private var own: [POSEvent] = []
    private var remote: [POSEvent] = []
    private var ids: Set<String> = []
    private(set) public var cursor = Cursor()

    private var ownURL: URL { directory.appendingPathComponent("own.jsonl") }
    private var remoteURL: URL { directory.appendingPathComponent("remote.jsonl") }
    private var cursorURL: URL { directory.appendingPathComponent("cursor.json") }

    /// 打開（沒有就建立）。檔案最後一行寫到一半（當機）會被忽略並修掉
    public init(directory: URL, deviceId: String) throws {
        self.directory = directory
        self.deviceId = deviceId
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        own = try Self.load(ownURL)
        remote = try Self.load(remoteURL)
        ids = Set(own.map(\.id) + remote.map(\.id))
        if let data = try? Data(contentsOf: cursorURL), let c = try? JSONDecoder().decode(Cursor.self, from: data) {
            cursor = c
        }
        // 檔案比 cursor 新（寫了事件、還沒寫 cursor 就當機）：以檔案為準
        if let last = own.max(by: { $0.seq < $1.seq }), last.seq > cursor.lastSeq {
            cursor.lastSeq = last.seq
            cursor.lastHash = last.hash
        }
        cursor.lamport = max(cursor.lamport, (own + remote).map(\.lamport).max() ?? 0)
    }

    // MARK: 寫

    /// 記一筆這台的事件：給流水號、時鐘、雜湊，寫進檔案並 fsync，然後才回傳
    @discardableResult
    public func append(_ body: EventBody, staffId: String?, at date: Date = Date(), id: String = UUID().uuidString.lowercased()) throws -> POSEvent {
        lock.lock(); defer { lock.unlock() }
        let e = try POSEvent(id: id, deviceId: deviceId, seq: cursor.lastSeq + 1, lamport: cursor.lamport + 1, at: date,
                             staffId: staffId, body: body, prevHash: cursor.lastHash)
        try Self.write([e], to: ownURL)
        own.append(e)
        ids.insert(e.id)
        cursor.lastSeq = e.seq
        cursor.lastHash = e.hash
        cursor.lamport = e.lamport
        try saveCursor()
        return e
    }

    /// 收別台的事件（後台、區網）：去重、驗雜湊、寫檔。回傳真的新收到的
    @discardableResult
    public func ingest(_ events: [POSEvent]) throws -> [POSEvent] {
        lock.lock(); defer { lock.unlock() }
        var fresh: [POSEvent] = []
        for e in events where !ids.contains(e.id) && e.deviceId != deviceId {
            guard e.isHashValid else { continue }
            fresh.append(e)
            ids.insert(e.id)
        }
        if let max = events.map(\.lamport).max() { cursor.lamport = Swift.max(cursor.lamport, max) }
        guard !fresh.isEmpty else { try saveCursor(); return [] }
        try Self.write(fresh, to: remoteURL)
        remote += fresh
        try saveCursor()
        return fresh
    }

    // MARK: 讀

    public var allEvents: [POSEvent] {
        lock.lock(); defer { lock.unlock() }
        return own + remote
    }

    public var ownEvents: [POSEvent] {
        lock.lock(); defer { lock.unlock() }
        return own
    }

    public func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    /// 還沒送到後台的（照流水號）
    public func unpushed(limit: Int = 200) -> [POSEvent] {
        lock.lock(); defer { lock.unlock() }
        return Array(own.filter { $0.seq > cursor.pushedSeq && !cursor.quarantined.contains($0.id) }.sorted { $0.seq < $1.seq }.prefix(limit))
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return own.filter { $0.seq > cursor.pushedSeq }.count
    }

    // MARK: 同步的進度

    public func markPushed(through seq: Int) throws {
        lock.lock(); defer { lock.unlock() }
        cursor.pushedSeq = max(cursor.pushedSeq, seq)
        try saveCursor()
    }

    /// 後台說「從 seq 開始重送」（chain_gap）
    public func rewindPushed(to seq: Int) throws {
        lock.lock(); defer { lock.unlock() }
        cursor.pushedSeq = max(min(cursor.pushedSeq, seq - 1), 0)
        try saveCursor()
    }

    public func setPullCursor(_ serverSeq: Int) throws {
        lock.lock(); defer { lock.unlock() }
        cursor.pullCursor = max(cursor.pullCursor, serverSeq)
        try saveCursor()
    }

    public func quarantine(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        if !cursor.quarantined.contains(id) { cursor.quarantined.append(id) }
        try saveCursor()
    }

    /// 檢查這台的雜湊鏈（設定頁的「檢查資料」、交班時）
    /// 檢查這台的雜湊鏈。整理過（compact）的日誌中間會少一段：少的那段一定都已經送到後台（後台有完整的鏈），
    /// 所以只要求「接得上的要接對、斷掉的地方在已送出的範圍內、最後一筆就是 cursor 記的那一筆」
    public func verifyChain() -> EventError? {
        lock.lock(); defer { lock.unlock() }
        var prev: POSEvent?
        for e in own.sorted(by: { $0.seq < $1.seq }) {
            if !e.isHashValid { return .badHash(id: e.id) }
            if let p = prev {
                if e.seq == p.seq + 1 {
                    if e.prevHash != p.hash { return .brokenChain(deviceId: deviceId, seq: e.seq) }
                } else if e.seq <= p.seq || e.seq - 1 > cursor.pushedSeq {
                    return .brokenChain(deviceId: deviceId, seq: e.seq)
                }
            } else if e.seq == 1 && e.prevHash != POSEvent.genesis {
                return .brokenChain(deviceId: deviceId, seq: 1)
            } else if e.seq > 1 && e.seq - 1 > cursor.pushedSeq {
                return .brokenChain(deviceId: deviceId, seq: e.seq)
            }
            prev = e
        }
        if let last = prev, last.hash != cursor.lastHash { return .brokenChain(deviceId: deviceId, seq: last.seq) }
        return nil
    }

    // MARK: 整理（每天一次）

    /// 整理：大部分的資料在後台，iPad 只留「快速開機、斷網照常營業」需要的：
    ///   - 還沒送到後台的（一定留）
    ///   - 最近 keepDays 天（今天、昨天：報表、補印、退款最常用）
    ///   - 還開著的單、還沒交班的班
    ///   - 這一期與上一期的發票事件（算下一張號碼不能重號；也是後台 usedThrough 之外的第二道保險）
    /// 其他的刪掉（archive = true 時搬到 archive/ 而不是刪除，除錯用）。雜湊鏈不會斷：cursor 記著最後一筆的雜湊
    public func compact(keepDays: Int = 2, now: Date = Date(), state: StoreState, archive: Bool = false) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(max(keepDays, 1)) * 86_400)
        let openTickets = Set(state.openTickets.map(\.id))
        let openShifts = Set(state.shifts.values.filter(\.isOpen).map(\.id))
        let period = InvoicePeriod(date: now)
        let invoicePeriods: Set<String> = [period.code, period.previous.code]
        func keep(_ e: POSEvent, pushed: Bool) -> Bool {
            if !pushed || e.date >= cutoff { return true }
            if let t = e.body.ticketId, openTickets.contains(t) { return true }
            switch e.body {
            case .shiftOpened(let s): return openShifts.contains(s.shiftId)
            case .cashMoved(let m): return openShifts.contains(m.shiftId)
            case .invoiceIssued(let i): return invoicePeriods.contains(i.invoice.period)
            case .invoiceVoided: return e.date >= now.addingTimeInterval(-62 * 86_400)
            default: return false
            }
        }
        let keptOwn = own.filter { keep($0, pushed: $0.seq <= cursor.pushedSeq) }
        let keptRemote = remote.filter { keep($0, pushed: true) }
        let removed = (own.count - keptOwn.count) + (remote.count - keptRemote.count)
        guard removed > 0 else { return 0 }

        if archive {
            let dir = directory.appendingPathComponent("archive", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = EventCoding.timestamp(now).replacingOccurrences(of: ":", with: "-")
            let keptOwnIds = Set(keptOwn.map(\.id)), keptRemoteIds = Set(keptRemote.map(\.id))
            try Self.write(own.filter { !keptOwnIds.contains($0.id) }, to: dir.appendingPathComponent("own-\(stamp).jsonl"))
            try Self.write(remote.filter { !keptRemoteIds.contains($0.id) }, to: dir.appendingPathComponent("remote-\(stamp).jsonl"))
        }
        try Self.rewrite(keptOwn, to: ownURL)
        try Self.rewrite(keptRemote, to: remoteURL)
        own = keptOwn
        remote = keptRemote
        return removed
    }

    /// 刪掉這台的所有資料（後台移除這台、重新配對）
    public func wipe() throws {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        own = []; remote = []; ids = []; cursor = Cursor()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: 檔案

    private func saveCursor() throws {
        let data = try JSONEncoder().encode(cursor)
        try data.write(to: cursorURL, options: .atomic)
    }

    private static func load(_ url: URL) throws -> [POSEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var out: [POSEvent] = []
        var badTail = false
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let e = try? decoder.decode(POSEvent.self, from: Data(line)) {
                out.append(e)
            } else {
                badTail = true
            }
        }
        // 最後一行寫到一半：重寫成只有好的那些
        if badTail { try rewrite(out, to: url) }
        return out
    }

    private static func write(_ events: [POSEvent], to url: URL) throws {
        guard !events.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var blob = Data()
        for e in events {
            blob += try encoder.encode(e)
            blob.append(UInt8(ascii: "\n"))
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: blob)
        try h.synchronize()
    }

    private static func rewrite(_ events: [POSEvent], to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        _ = FileManager.default.createFile(atPath: tmp.path, contents: nil)
        try write(events, to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
