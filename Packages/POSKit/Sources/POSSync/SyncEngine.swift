import Foundation
import POSCore

/// 同步的狀態（畫面右上角的小點：綠＝同步中、橘＝離線但照常營業、紅＝要處理）
public struct SyncStatus: Sendable, Hashable {
    public enum Health: String, Sendable, Hashable {
        case synced, syncing, offline, paused, attention
    }

    public var health: Health = .offline
    public var pending: Int = 0
    public var lastSyncAt: Date?
    public var lastError: String?
    /// 這次拉到別台的事件數
    public var lastPulled: Int = 0

    public init() {}

    public var label: String {
        switch health {
        case .synced: pending == 0 ? "已同步" : "已同步・\(pending) 筆待送"
        case .syncing: "同步中"
        case .offline: pending > 0 ? "離線・\(pending) 筆待送" : "離線"
        case .paused: "後台暫停同步"
        case .attention: lastError ?? "需要處理"
        }
    }
}

/// 和後台同步：送出這台的事件、拉回別台的事件。
///
/// - 送：照流水號一批 200 筆；後台說 chain_gap 就從它要的那筆重送；bad_hash（檔案壞了）隔離起來交給人處理
/// - 拉：從 pullCursor 接著拿，直到沒有更多
/// - 失敗：2、4、8…最多 60 秒後再試；有新事件、App 回到前景、心跳說後台有新的，立刻再跑一次
public actor SyncEngine {
    public let api: any POSAPI
    public let ledger: Ledger
    public private(set) var status = SyncStatus()
    private var backoff: Double = 0
    private var running = false
    private var again = false
    private var loop: Task<Void, Never>?
    private var listeners: [UUID: @Sendable (SyncStatus, [POSEvent]) -> Void] = [:]

    public init(api: any POSAPI, ledger: Ledger) {
        self.api = api
        self.ledger = ledger
        status.pending = ledger.journal.pendingCount
    }

    /// 狀態變了、收到別台的事件時通知（App 用來刷新畫面）
    public func observe(_ f: @escaping @Sendable (SyncStatus, [POSEvent]) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = f
        f(status, [])
        return id
    }

    public func removeObserver(_ id: UUID) { listeners[id] = nil }

    /// 開始背景同步（每 interval 秒一次，或被 kick 叫醒）
    public func start(interval: Double = 15) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncNow()
                let wait = await self.nextWait(interval)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func nextWait(_ interval: Double) -> Double { backoff > 0 ? backoff : interval }

    /// 馬上同步一次（記了新事件、回到前景時呼叫）。正在跑就排到它跑完再跑一次
    public func kick() {
        if running { again = true; return }
        Task { await syncNow() }
    }

    @discardableResult
    public func syncNow() async -> SyncStatus {
        if running { again = true; return status }
        running = true
        defer { running = false }
        repeat {
            again = false
            await runOnce()
        } while again
        return status
    }

    private func runOnce() async {
        update { $0.health = .syncing }
        var pulled: [POSEvent] = []
        do {
            try await pushAll()
            pulled = try await pullAll()
            backoff = 0
            update {
                $0.health = .synced
                $0.lastSyncAt = Date()
                $0.lastError = nil
                $0.lastPulled = pulled.count
            }
        } catch let e as APIError {
            switch e {
            case .serviceOff: update { $0.health = .paused; $0.lastError = e.userMessage }
            case .unauthorized, .revoked: update { $0.health = .attention; $0.lastError = e.userMessage }
            default:
                backoff = min(max(backoff * 2, 2), 60)
                update { $0.health = e.isRetryable ? .offline : .attention; $0.lastError = e.userMessage }
            }
        } catch {
            backoff = min(max(backoff * 2, 2), 60)
            update { $0.health = .attention; $0.lastError = "本機資料寫入失敗：\(error.localizedDescription)" }
        }
        status.pending = ledger.journal.pendingCount
        notify(pulled)
    }

    private func pushAll() async throws {
        var rounds = 0
        while rounds < 50 {
            rounds += 1
            let batch = ledger.journal.unpushed(limit: 200)
            guard !batch.isEmpty else { return }
            let result = try await api.push(batch)
            let done = Set(result.accepted + result.duplicates)
            // 照順序算：從頭連續被收下的最後一筆
            var through = ledger.journal.cursor.pushedSeq
            for e in batch where done.contains(e.id) && e.seq == through + 1 { through = e.seq }
            try ledger.journal.markPushed(through: through)
            if let gap = result.rejected.first(where: { $0.reason == "chain_gap" }), let expect = gap.expectSeq {
                try ledger.journal.rewindPushed(to: expect)
                continue
            }
            for r in result.rejected where r.reason != "chain_gap" {
                try ledger.journal.quarantine(r.id)
            }
            if !result.rejected.isEmpty && done.isEmpty { return }
            status.pending = ledger.journal.pendingCount
        }
    }

    private func pullAll() async throws -> [POSEvent] {
        var fresh: [POSEvent] = []
        var rounds = 0
        while rounds < 100 {
            rounds += 1
            let page = try await api.pull(after: ledger.journal.cursor.pullCursor, limit: 500)
            fresh += try ledger.merge(page.events)
            try ledger.journal.setPullCursor(page.next)
            if !page.hasMore { break }
        }
        return fresh
    }

    private func update(_ f: (inout SyncStatus) -> Void) {
        f(&status)
        status.pending = ledger.journal.pendingCount
        notify([])
    }

    private func notify(_ events: [POSEvent]) {
        for l in listeners.values { l(status, events) }
    }
}
