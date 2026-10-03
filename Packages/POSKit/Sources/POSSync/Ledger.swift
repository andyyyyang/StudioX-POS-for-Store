import Foundation
import POSCore

/// 日誌＋狀態：記一筆事件就同時更新狀態；收到別台的事件時，順序在最後就直接套用，插在中間就整個重播（一天幾千筆，幾毫秒）。
///
/// App 的 @Observable 模型包著它：畫面讀 `state`，動作呼叫 `record`。
public final class Ledger: @unchecked Sendable {
    public let journal: EventJournal
    private let lock = NSLock()
    private var _state: StoreState
    /// 已套用的事件中排序最後的一筆（判斷新事件能不能直接接上）
    private var tail: POSEvent?

    public init(journal: EventJournal) {
        self.journal = journal
        let events = journal.allEvents.sorted(by: POSEvent.replayOrder)
        _state = StoreState.replay(events)
        tail = events.last
    }

    public var state: StoreState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// 記一筆（寫檔＋fsync 之後才更新狀態）
    @discardableResult
    public func record(_ body: EventBody, staffId: String?, at date: Date = Date()) throws -> POSEvent {
        let e = try journal.append(body, staffId: staffId, at: date)
        lock.lock(); defer { lock.unlock() }
        apply([e])
        return e
    }

    /// 一次記好幾筆（例如：收款＋開發票＋結帳），全部寫進去才更新狀態
    @discardableResult
    public func record(_ bodies: [EventBody], staffId: String?, at date: Date = Date()) throws -> [POSEvent] {
        var out: [POSEvent] = []
        for b in bodies { out.append(try journal.append(b, staffId: staffId, at: date)) }
        lock.lock(); defer { lock.unlock() }
        apply(out)
        return out
    }

    /// 收別台的事件。回傳真的新收到的（給 UI 做提示：「A2 加點了 2 項」）
    @discardableResult
    public func merge(_ events: [POSEvent]) throws -> [POSEvent] {
        let fresh = try journal.ingest(events)
        guard !fresh.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        apply(fresh)
        return fresh
    }

    private func apply(_ events: [POSEvent]) {
        let sorted = events.sorted(by: POSEvent.replayOrder)
        if let t = tail, let first = sorted.first, POSEvent.replayOrder(first, t) {
            // 有事件插在已經套用過的事件前面：整個重播
            let all = journal.allEvents.sorted(by: POSEvent.replayOrder)
            _state = StoreState.replay(all)
            tail = all.last
        } else {
            for e in sorted { _state.apply(e) }
            if let last = sorted.last { tail = last }
        }
    }

    /// 整理舊事件後重播（狀態不變，只是記憶體小一點）
    public func compact(keepDays: Int = 7, now: Date = Date()) throws -> Int {
        let n = try journal.compact(keepDays: keepDays, now: now, state: state)
        if n > 0 {
            lock.lock(); defer { lock.unlock() }
            let all = journal.allEvents.sorted(by: POSEvent.replayOrder)
            // 舊的已結帳單從記憶體拿掉；開著的單、班都還在
            _state = StoreState.replay(all)
            tail = all.last
        }
        return n
    }
}
