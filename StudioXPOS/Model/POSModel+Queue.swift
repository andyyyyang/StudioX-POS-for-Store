import AVFoundation
import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 叫號（號碼牌）：取號 → 出單 → 叫號 → 過號。號碼存在後台（或後台代轉的原本叫號伺服器），iPad 只顯示、送動作。
///
/// - 叫號頁開著：每 2 秒抓一次；動作的回應直接拿來更新畫面
/// - 沒開著：每 15 秒抓一次（側欄的等候人數）；「也印別台取的號碼」開著時每 2 秒（取代樹莓派出單）
/// - 叫號要網路（和原本的 App 一樣）：連不上時這一頁只能看、不能按，動作也不重送
/// - 號碼牌：這台有「號碼牌」出單機就在取號時直接印（docs/API.md「叫號」的「誰印」）
@Observable
final class QueueBoard {
    /// 後台最後一次給的號碼
    var state: QueueState?
    /// 連不上的原因（nil＝正常）
    var problem: QueueProblem?
    /// 最後一次拿到號碼的時間
    var syncedAt: Date?
    /// 冷卻中的鍵：同一個鍵 1.2 秒內（或上一次還沒回來）不能再按（舊的 App 也有）
    var cooling: Set<QueueKey> = []
    /// 開著的叫號頁（頁面自己每 2 秒抓，背景的就不抓）
    var pageLoops = 0
    /// 右欄最上面的叫號卡（DockPinned、手機點餐頁上面那張）開著：卡片自己每 3 秒抓
    var pinnedLoops = 0
    /// 蓋住右欄的「叫號」面板（叫號卡點開的）：外帶＝叫指定號碼；排隊等內用＝叫號入座。nil＝關著
    var panel: QueueUsage?
    /// 叫到號、等著選桌入座（排隊等內用）：右欄的選桌面板
    var seating: QueueSeat?
    /// 這台取號時帶的人數（原本的叫號伺服器不存附帶資料：入座時照這裡的人數，不用再問）
    var localEntries: [Int: QueueEntry] = [:]
    /// 剛結帳取到的號碼（右欄的叫號卡大大地顯示幾秒：「24 號」）
    var justTaken: QueueJustTaken?
    /// 背景圖（號碼牌）
    let art = QueueTicketArt()

    let speaker = AVSpeechSynthesizer()
    /// 這台印過的號碼牌（同一個營業日不重複；存在這台）
    @ObservationIgnored var printed = QueuePrintLog.load()
    /// 上一次看到的等候中（「也印別台取的號碼」：只印這次新出現的；nil＝下一次抓到時只記下來、不補印）
    @ObservationIgnored var lastWaiting: Set<Int>?

    var pageVisible: Bool { pageLoops > 0 }
    var pinnedVisible: Bool { pinnedLoops > 0 }

    /// 換店、結束示範
    func reset() {
        state = nil
        problem = nil
        syncedAt = nil
        cooling = []
        lastWaiting = nil
        panel = nil
        seating = nil
        localEntries = [:]
        justTaken = nil
        // 示範店的號碼不會存進這台（重新讀一次存著的）
        printed = QueuePrintLog.load()
    }
}

/// 有冷卻時間的鍵（防連按）
enum QueueKey: Hashable {
    case take, next, miss, call
}

/// 剛結帳取到的號碼（「A023 已結帳・24 號」）
struct QueueJustTaken: Equatable {
    var number: Int
    var ticketNumber: String
    var at = Date()
}

/// 叫到號、等著選桌入座（排隊等內用）
struct QueueSeat: Identifiable, Equatable {
    var number: Int
    var guests: Int
    var id: Int { number }
}

/// 外帶結帳後取號的結果：取到了、連不上、等太久（號碼晚點到也照樣掛上、印出來）
nonisolated enum TakeoutNumber: Sendable, Equatable {
    case taken(Int)
    case failed
    case late
}

/// 結帳後取號：號碼回來、等太久，誰先到就用誰（只接一次）
final class TakeoutGate {
    var continuation: CheckedContinuation<TakeoutNumber, Never>?

    func finish(_ result: TakeoutNumber) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// 叫號頁不能按的原因
enum QueueProblem: Equatable {
    /// 沒網路
    case offline
    /// 原本的叫號伺服器連不上（legacy 模式，後台回 502 upstream）
    case upstream
    /// 後台沒開叫號（409 queue_off）
    case off
    /// 其他（後台給的一句話）
    case failed(String)

    var message: String {
        switch self {
        case .offline: "沒有網路：叫號要連上後台，現在只能看、不能按"
        case .upstream: "叫號伺服器連不上：現在只能看、不能按，連上後自動恢復"
        case .off: "後台沒有開叫號：請到後台「門市 POS」打開叫號"
        case .failed(let m): m
        }
    }

    /// 這種錯誤要把整頁停住（不是單一動作被拒絕）
    var blocksPage: Bool {
        switch self {
        case .offline, .upstream, .off: true
        case .failed: false
        }
    }

    init(_ error: Error) {
        guard let e = error as? APIError else {
            self = .failed(error.localizedDescription)
            return
        }
        switch e {
        case .offline: self = .offline
        case .http(_, "upstream", _): self = .upstream
        case .http(_, "queue_off", _): self = .off
        case .http(let status, _, _) where status == 502 || status == 503 || status == 504: self = .upstream
        default: self = .failed(e.userMessage)
        }
    }
}

/// 這台印過的號碼牌（樹莓派的 printed.log）：同一個營業日不重複印；號碼從 1 重新開始時清掉
nonisolated struct QueuePrintLog: Codable, Equatable {
    var businessDate = ""
    var numbers: Set<Int> = []
    /// 上次看到的下一張號碼（變小＝歸零了）
    var nextNo: Int?
    /// 上次看到的最大號碼（後台沒給 nextNo 時用來看歸零）
    var highest = 0

    private static let key = "queuePrinted"

    static func load() -> QueuePrintLog {
        guard let data = UserDefaults.standard.data(forKey: key), let log = try? JSONDecoder().decode(QueuePrintLog.self, from: data) else {
            return QueuePrintLog()
        }
        return log
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension POSModel {
    // MARK: - 查詢

    /// 號碼存在哪裡：後台這次回的，否則開機資料的設定
    var queueMode: QueueMode { queue.state?.mode ?? queueConfig?.mode ?? .native }

    /// 現在可以按（有號碼、連得上）
    var queueCanAct: Bool { features.queue && queue.state != nil && !(queue.problem?.blocksPage ?? false) }

    func queueCooling(_ key: QueueKey) -> Bool { queue.cooling.contains(key) }

    /// 這台接了「號碼牌」出單機
    var hasQueuePrinter: Bool { !printers.targets(.queue).isEmpty }

    /// 也印別台取的號碼（取代樹莓派）：要有號碼牌出單機才算開著
    var queuePrintsOthers: Bool { features.queue && settings.queuePrintsOthers && hasQueuePrinter }

    // MARK: 用在哪裡（後台的 queue.usage）

    /// 後台開的用法（沒開叫號是空的）
    var queueUsage: Set<QueueUsage> { features.queue ? (queueConfig?.usage ?? []) : [] }

    /// 外帶取餐：外帶單結帳完成時自動取號、做好了叫號。要是有外帶的營業模式（餐飲、攤位）
    var queueForTakeout: Bool { queueUsage.contains(.takeout) && (mode.showsOrderType || mode == .retail) }

    /// 排隊等內用：取號時打人數、叫到號選桌入座。要是有內用的營業模式（餐飲）
    var queueForDineIn: Bool { queueUsage.contains(.dineIn) && mode.showsOrderType }

    /// 右欄最上面的叫號卡放哪一種：外帶（點餐、訂單、廚房）、排隊等內用（桌位）；不放是 nil。
    /// 結帳時收起來（右欄要給收款的鍵盤）
    var queuePinned: QueueUsage? {
        guard features.queue, phase == .ready, checkoutTicketId == nil else { return nil }
        switch section {
        case .order, .orders, .kitchen: return queueForTakeout ? .takeout : nil
        case .floor: return queueForDineIn ? .dineIn : nil
        default: return nil
        }
    }

    /// 這個號碼的附帶資料：後台存的（native），沒有就是這台取號時記的
    func queueEntry(_ n: Int) -> QueueEntry? {
        queue.state?.entry(n) ?? queue.localEntries[n]
    }

    /// 這個號碼的單（外帶結帳時取的）：後台記的 ticketId，沒有就照今天的單子上掛的號碼找
    func queueTicket(_ n: Int) -> Ticket? {
        if let id = queueEntry(n)?.ticketId, let t = state.tickets[id] { return t }
        let today = businessDate
        return state.tickets.values.first { $0.queueNumber == n && $0.businessDate == today && $0.status != .voided }
    }

    /// 外帶單做好了沒（廚房的進度）：全部好了＝true、還在做＝false、沒有送廚房的品項＝nil
    func queueTicketReady(_ t: Ticket) -> Bool? {
        let sent = t.activeLines.filter(\.isSent)
        guard !sent.isEmpty else { return nil }
        return sent.allSatisfy { $0.kitchen == .ready || $0.kitchen == .served }
    }

    /// 號碼方塊上的小字：「4 位」（排隊等內用）、「好了」（外帶單做好了）
    func queueTag(_ n: Int) -> String? {
        if let g = queueEntry(n)?.guests { return "\(g) 位" }
        if let t = queueTicket(n), queueTicketReady(t) == true { return "好了" }
        return nil
    }

    /// 號碼的說明（右欄、面板）：「4 位」「A012・3 項・好了」
    func queueDetail(_ n: Int) -> String? {
        var parts: [String] = []
        let entry = queueEntry(n)
        if let g = entry?.guests { parts.append("\(g) 位") }
        if let t = queueTicket(n) {
            parts.append(entry?.label ?? queueLabel(t))
            switch queueTicketReady(t) {
            case .some(true): parts.append("好了")
            case .some(false): parts.append("製作中")
            case .none: break
            }
        } else if let label = entry?.label {
            parts.append(label)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// 桌位頁的右欄：「排隊 5 組・下一號 31（4 位）」
    var queueDineInSummary: String? {
        guard let s = queue.state else { return nil }
        guard let n = s.waiting.first else { return "沒有人在排隊" }
        let guests = queueEntry(n)?.guests.map { "（\($0) 位）" } ?? ""
        return "排隊 \(s.waiting.count) 組・下一號 \(n)\(guests)"
    }

    /// 「叫號入座 31（4 位）」
    var queueSeatNextTitle: String {
        guard let n = queue.state?.waiting.first else { return "叫號入座" }
        return "叫號入座 \(n)" + (queueEntry(n)?.guests.map { "（\($0) 位）" } ?? "")
    }

    // MARK: - 抓號碼

    /// 抓一次現在的號碼
    func refreshQueue() async {
        guard features.queue, let api else { return }
        do {
            let s = try await api.queue()
            applyQueue(s)
        } catch {
            queue.problem = QueueProblem(error)
        }
    }

    /// 叫號頁開著：每 2 秒抓一次（頁面關掉時 task 取消，迴圈就停）
    func queuePageLoop() async {
        queue.pageLoops += 1
        defer { queue.pageLoops -= 1 }
        // 號碼牌的背景圖先下載起來（不等它）
        if let url = queueConfig?.ticket.backgroundUrl {
            let art = queue.art
            Task { await art.prefetch(url) }
        }
        while !Task.isCancelled {
            await refreshQueue()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// 右欄的叫號卡開著：每 3 秒抓一次（叫號頁開著時頁面已經在抓；卡片收起來時 task 取消，迴圈就停）
    func queuePinnedLoop() async {
        queue.pinnedLoops += 1
        defer { queue.pinnedLoops -= 1 }
        while !Task.isCancelled {
            if !queue.pageVisible { await refreshQueue() }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// 背景（每次回傳下一次要等幾秒）：叫號頁、右欄的叫號卡開著時它們自己抓；「也印別台取的號碼」開著時每 2 秒（鎖定畫面也印）；
    /// 其他時候每 15 秒（側欄的等候人數）
    func queueBackgroundTick() async -> Double {
        guard features.queue, api != nil, phase == .ready || phase == .locked else { return 15 }
        if queue.pageVisible || queue.pinnedVisible { return 2 }
        if queuePrintsOthers {
            await refreshQueue()
            return 2
        }
        guard phase == .ready, visibleSections.contains(.queue) else { return 15 }
        await refreshQueue()
        return 15
    }

    /// 後台給的號碼更新到畫面；taken＝這台剛取的號碼（記成印過，不會再印第二次）
    func applyQueue(_ s: QueueState, taken: [Int] = []) {
        queue.state = s
        queue.problem = nil
        queue.syncedAt = Date()
        trackPrinted(s, taken: taken)
    }

    /// 號碼牌的紀錄（樹莓派的 monitor_waiting）：新的營業日、號碼從 1 重新開始時清掉；
    /// 「也印別台取的號碼」開著時，印出這次新出現、還沒印過的號碼
    private func trackPrinted(_ s: QueueState, taken: [Int]) {
        var log = queue.printed
        let today = businessDate
        if log.businessDate != today {
            log = QueuePrintLog(businessDate: today)
        } else if let now = s.nextNo, let before = log.nextNo {
            if now < before { log.numbers = [] }
        } else if s.highestNumber < log.highest {
            log.numbers = []
        }
        log.nextNo = s.nextNo
        log.highest = s.highestNumber
        log.numbers.formUnion(taken)

        var fresh: [Int] = []
        if queuePrintsOthers {
            // 剛打開（或剛開 App）的第一次只記下來：不補印以前的
            if let last = queue.lastWaiting {
                fresh = s.waiting.filter { !last.contains($0) && !log.numbers.contains($0) }
                log.numbers.formUnion(fresh)
            }
            queue.lastWaiting = Set(s.waiting)
        } else {
            queue.lastWaiting = nil
        }
        if log != queue.printed {
            queue.printed = log
            if !isDemo { log.save() }
        }
        if !fresh.isEmpty { printQueueTickets(fresh, waiting: s.waiting.count) }
    }

    /// 打開／關掉「也印別台取的號碼」：打開後第一次抓到的號碼只記下來，不補印
    func setQueuePrintsOthers(_ on: Bool) {
        settings.queuePrintsOthers = on
        queue.lastWaiting = nil
        if on { show(hasQueuePrinter ? "這台會印別台取的號碼牌（一家店只開一台）" : "要先在出單機勾「號碼牌」才會印", tone: hasQueuePrinter ? .info : .warning) }
    }

    // MARK: - 動作

    /// 送一個動作。連不上：橫幅＋這一頁只能看（動作類的請求不重送）；被拒絕（例如沒有在叫號）：跳一句話
    private func sendQueue(_ action: QueueAction) async -> QueueState? {
        guard features.queue, let api else { return nil }
        touch()
        do {
            return try await api.queue(action)
        } catch {
            let p = QueueProblem(error)
            if p.blocksPage { queue.problem = p }
            show(p.message, tone: p.blocksPage ? .danger : .warning)
            return nil
        }
    }

    /// 防連按：同一個鍵 1.2 秒內（或上一次還沒回來）不能再按
    private func coolingDown(_ key: QueueKey, _ work: () async -> Void) async {
        guard !queue.cooling.contains(key) else { return }
        queue.cooling.insert(key)
        let started = Date()
        await work()
        let left = 1.2 - Date().timeIntervalSince(started)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
        queue.cooling.remove(key)
    }

    /// 取號（1–20 張，號碼連續）。這台有號碼牌出單機就馬上印，一個號碼一張
    func takeQueue(_ count: Int = 1) async {
        await coolingDown(.take) {
            let n = min(max(count, 1), 20)
            guard let s = await sendQueue(.take(count: n, requestId: newID())) else { return }
            let numbers = s.numbers ?? Array(s.waiting.suffix(n))
            applyQueue(s, taken: numbers)
            if hasQueuePrinter { printQueueTickets(numbers, waiting: s.waiting.count) }
            if let first = numbers.first, let last = numbers.last {
                show(numbers.count == 1 ? "取號 \(first) 號・目前 \(s.waiting.count) 人等候" : "取號 \(first)–\(last) 號（\(numbers.count) 張）")
            }
        }
    }

    /// 取幾張：右欄的鍵盤問（1–20，快速鍵 2／3／4／5 張）
    func askTakeQueue() async {
        guard let n = await keypad.askNumber(.queueTickets()) else { return }
        await takeQueue(n)
    }

    /// 下一號：等候的第一個變成現在叫的（原本的算服務完了）
    func nextQueue() async {
        await coolingDown(.next) {
            guard let s = await sendQueue(.next(requestId: newID())) else { return }
            applyQueue(s)
            if let n = s.current {
                announceQueue(n)
            } else {
                show("沒有人在等了", tone: .info)
            }
        }
    }

    /// 過號：現在叫的移到過號，自動叫下一號
    func missQueue() async {
        await coolingDown(.miss) {
            let missed = queue.state?.current
            guard let s = await sendQueue(.miss(requestId: newID())) else { return }
            applyQueue(s)
            if let n = s.current {
                announceQueue(n, prefix: missed.map { "\($0) 號過號・" } ?? "")
            } else if let m = missed {
                show("\(m) 號過號・沒有人在等了", tone: .info)
            }
        }
    }

    /// 返回前一號：現在叫的放回等候的最前面（按錯「下一號」時用）
    func previousQueue() async {
        let back = queue.state?.current
        guard let s = await sendQueue(.previous) else { return }
        applyQueue(s)
        show(back.map { "\($0) 號放回等候的最前面" } ?? "已返回前一號", tone: .info)
    }

    /// 再叫一次過號的（只有後台自己存號碼時可以）
    func recallQueue(_ n: Int) async {
        guard let s = await sendQueue(.recall(n)) else { return }
        applyQueue(s)
        announceQueue(s.current ?? n, prefix: "再叫一次・")
    }

    /// 從過號清單刪掉
    func unmissQueue(_ n: Int) async {
        guard let s = await sendQueue(.unmiss(n)) else { return }
        applyQueue(s)
        show("\(n) 號已從過號刪掉", tone: .info)
    }

    /// 標記／取消標記（店員自己看的星號：例如還沒結帳）。先改畫面，後台說不行再抓回來
    func toggleQueueMark(_ n: Int) async {
        guard var s = queue.state else { return }
        let marked = s.isMarked(n)
        if marked { s.marked.removeAll { $0 == n } } else { s.marked.append(n) }
        queue.state = s
        if let fresh = await sendQueue(marked ? .unmark(n) : .mark(n)) {
            applyQueue(fresh)
        } else {
            await refreshQueue()
        }
    }

    /// 全部歸零：店長以上（不是的話右欄問主管 PIN）
    func resetQueue() async {
        guard let auth = await authorize(.resetQueue, detail: "叫號全部歸零") else { return }
        let staffId = auth.authorizerId ?? currentStaff?.id ?? ""
        guard let s = await sendQueue(.reset(staffId: staffId)) else { return }
        applyQueue(s)
        show("叫號已歸零：下一張從 \(s.nextNo ?? 1) 號開始", tone: .info)
    }

    /// 開單：號碼掛在單子上（「外帶 23 號」；結帳時不會再取一張），跳到點餐
    func openQueueTicket(_ n: Int) {
        guard let t = openTicket(type: mode.defaultOrderType) else { return }
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, queueNumber: n)))
        selectedTicketId = t.id
        if visibleSections.contains(.order) {
            go(.order)
        } else {
            show("已開單 \(t.number)（\(n) 號）", tone: .info)
        }
    }

    /// 這台可以幫叫到的號碼開單（有點餐頁的崗位）
    var queueCanOpenTicket: Bool { role.takesOrders && visibleSections.contains(.order) }

    // MARK: - 叫指定的號碼

    /// 打開右欄的叫號面板（右欄最上面那張卡點開的）
    func openQueuePanel(_ usage: QueueUsage) {
        touch()
        keypad.cancel()
        queue.seating = nil
        queue.panel = usage
    }

    /// 叫這一號（外帶：先做好的先叫）。是等候的第一位就用「下一號」（哪一種伺服器都一樣）；
    /// 不是第一位：後台存號碼的直接叫那一號，原本的叫號伺服器只能照順序叫，就說明要改成後台叫號。
    /// 已經是現在叫的＝再唸一次；過號的＝再叫一次。回傳現在叫的是不是這一號
    @discardableResult
    func callQueue(_ n: Int) async -> Bool {
        guard features.queue, let s = queue.state else { return false }
        if s.current == n {
            announceQueue(n, prefix: "再唸一次・", force: true)
            return true
        }
        if s.missed.contains(n) {
            guard queueMode.canRecall else {
                show("\(n) 號過號了：原本的叫號伺服器不能再叫一次，請直接服務或請客人重新取號", tone: .warning)
                return false
            }
            await recallQueue(n)
            return queue.state?.current == n
        }
        guard let position = s.waiting.firstIndex(of: n) else {
            show("\(n) 號不在等候中（可能已經叫過了）", tone: .warning)
            return false
        }
        if position == 0 {
            await nextQueue()
            return queue.state?.current == n
        }
        guard queueMode == .native else {
            show("原本的叫號伺服器只能照順序叫「下一號」：\(n) 號前面還有 \(position) 位。要叫指定的號碼，請在後台「叫號」把號碼改存在後台", tone: .warning)
            return false
        }
        var called = false
        await coolingDown(.call) {
            guard let fresh = await sendQueue(.call(n, requestId: newID())) else { return }
            applyQueue(fresh)
            announceQueue(fresh.current ?? n)
            called = fresh.current == n
        }
        return called
    }

    /// 這個號碼能不能直接叫（原本的叫號伺服器只能叫等候的第一位）
    func queueCanCall(_ n: Int) -> Bool {
        guard queueCanAct, let s = queue.state else { return false }
        if s.current == n { return true }
        if s.missed.contains(n) { return queueMode.canRecall }
        guard let i = s.waiting.firstIndex(of: n) else { return false }
        return i == 0 || queueMode == .native
    }

    // MARK: - 外帶：結帳完成時自動取號

    /// 這張單用叫號的號碼當單號（叫號用在外帶取餐、不是內用有桌子的單）：一進結帳就取號，
    /// 結帳畫面、收據、廚房、叫號、QR 都是這一個號碼。結帳時沒取到（斷網）就結完再取一次
    func takesTakeoutNumber(_ t: Ticket) -> Bool {
        queueForTakeout && t.orderType != .dineIn && t.tableIds.isEmpty
    }

    /// 一進結帳就取號（取號＝印號碼牌，客人付完就拿得到）。取不到也不擋結帳，結完再取
    func takeNumberForCheckout(_ t: Ticket) {
        guard takesTakeoutNumber(t), t.queueNumber == nil, features.queue, api != nil else { return }
        Task { await requestTakeoutNumber(t) }
    }

    /// 作廢的外帶單：號碼放回去（叫號螢幕、等候清單不再列它）。連不上就算了（店員可以在叫號頁按過號）
    func releaseNumber(of t: Ticket) {
        guard let n = t.queueNumber, features.queue, queueMode == .native, let api else { return }
        Task {
            if let s = try? await api.queue(.cancel(n, requestId: "cancel-\(t.id)")) { applyQueue(s) }
        }
    }

    /// 外帶單的取餐號碼是叫號的號碼（付完才取）：點餐、結帳畫面不寫單號（A036），免得和取餐號碼搞混。
    /// 訂單、廚房照樣有單號（找單、補取號用）
    func hidesTicketNumber(_ t: Ticket) -> Bool {
        queueForTakeout && t.orderType != .dineIn && t.tableIds.isEmpty
    }

    /// 點餐、結帳畫面上的單子名字：外帶叫號的店＝「外帶」（取到號＝「外帶 33 號」、有稱呼＝「外帶 王小姐」）；其他照 Ticket.title
    func orderTitle(_ t: Ticket) -> String {
        guard hidesTicketNumber(t), t.queueNumber == nil, (t.customerName ?? "").isEmpty else { return t.title(floor: floor) }
        if t.serviceMode?.showsOrderType == false {
            if let m = t.member { return m.name ?? m.maskedPhone }
            return "這一單"
        }
        return t.orderType.label
    }

    /// 剛結帳的那一筆（點餐頁下面那一條）：外帶叫號的店也不寫單號
    func hidesSaleNumber(_ s: SaleRecord) -> Bool {
        queueForTakeout && s.orderType != .dineIn && s.tableIds.isEmpty
    }

    /// 點餐、結帳畫面上寫的單號（外帶叫號的店不寫：nil）
    func orderNumber(_ t: Ticket) -> String? { hidesTicketNumber(t) ? nil : t.number }

    /// 「A036・外帶 A036」；外帶叫號的店「外帶 33 號」（還沒取到：結帳中「取號中…」、還沒結帳「結帳時給號碼」）
    func orderCaption(_ t: Ticket) -> String {
        guard hidesTicketNumber(t) else { return "\(t.number)・\(t.title(floor: floor))" }
        guard t.queueNumber == nil else { return orderTitle(t) }
        return "\(orderTitle(t))・\(pendingNumberText(t))"
    }

    /// 外帶單還沒有號碼時寫什麼：結帳中＝正在向叫號取號；還沒結帳＝結帳時才給
    func pendingNumberText(_ t: Ticket) -> String {
        checkoutTicketId == t.id ? "取號中…" : "結帳時給號碼"
    }

    /// 外帶單的號碼網頁（號碼牌、收據上的 QR）：叫到幾號、前面幾位、大約還要等多久。
    /// day：哪一個營業日的號碼（補印舊收據時用那一天；號碼每天從 1 開始）
    func queueLink(_ n: Int, waiting: Int, day: String? = nil) -> String? {
        queueConfig?.customerLink(number: n, waiting: waiting, date: (day ?? businessDate).replacingOccurrences(of: "-", with: ""))
    }

    /// 號碼帶的一句話（後台叫號頁、右欄的叫號面板看得到）：「A012・3 項」
    func queueLabel(_ t: Ticket) -> String { "\(t.number)・\(t.itemCount) 項" }

    /// 同一張單用同一個 requestId：結帳時沒回應、之後「補取號」，後台十分鐘內認得，給回同一個號碼（不會多取一張）
    static func takeoutRequestId(_ ticketId: String) -> String { "take-\(ticketId)" }

    /// 結帳後取號：最多等 seconds 秒（收據要印號碼）。等太久回 .late：號碼晚點到也照樣掛上單子、印出來（lateTakeout）
    func takeTakeoutNumber(for t: Ticket, sale: SaleRecord, waitUpTo seconds: Double = 5) async -> TakeoutNumber {
        let work = Task { await requestTakeoutNumber(t) }
        let gate = TakeoutGate()
        let result = await withCheckedContinuation { (c: CheckedContinuation<TakeoutNumber, Never>) in
            gate.continuation = c
            Task {
                let n = await work.value
                gate.finish(n.map { TakeoutNumber.taken($0) } ?? .failed)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.finish(.late)
            }
        }
        if result == .late {
            Task {
                let n = await work.value
                printTakeoutSlips(t, sale: sale, number: n, kitchenLines: [], kitchenMode: .new)
                if let n {
                    flashTakeout(n, ticket: t)
                    show("取號了・取餐號碼 \(n) 號")
                } else {
                    show("\(t.number) 沒有取到號碼（叫號連不上）：收據已經印了，連上後到「訂單」這一筆按「補取號」", tone: .warning)
                }
            }
        }
        return result
    }

    /// 送出取號（帶這張單）：取到就掛在單子上（ticket.updated 的 queueNumber）、這台有號碼牌出單機就印。連不上回 nil。
    /// 已經有號碼（一進結帳就取了）直接用；同一張單用同一個 requestId，重送後台給回同一個號碼
    @discardableResult
    func requestTakeoutNumber(_ t: Ticket) async -> Int? {
        if let n = state.tickets[t.id]?.queueNumber { return n }
        guard features.queue, let api else { return nil }
        let entry = QueueEntry(ticketId: t.id, label: queueLabel(t))
        do {
            let s = try await api.queue(.takeOne(entry: entry, requestId: Self.takeoutRequestId(t.id)))
            guard let n = s.numbers?.first ?? s.waiting.last else {
                applyQueue(s)
                return nil
            }
            applyQueue(s, taken: [n])
            record(.ticketUpdated(TicketUpdated(ticketId: t.id, queueNumber: n)))
            if hasQueuePrinter { printQueueTickets([n], waiting: s.waiting.count) }
            return n
        } catch {
            let p = QueueProblem(error)
            if p.blocksPage { queue.problem = p }
            return nil
        }
    }

    /// 取號之後才印的：收據（取餐號碼＝叫號的號碼）、廚房單（上面是號碼）。
    /// 號碼牌印出來了（這台有號碼牌出單機）：收據照設定；沒有號碼牌、或沒取到號碼：收據就是客人手上那張，一定印
    func printTakeoutSlips(_ t: Ticket, sale given: SaleRecord, number: Int?, kitchenLines: [TicketLine], kitchenMode: Templates.KitchenMode) {
        let sale = state.sales[t.id] ?? given
        let touchesAccount = sale.lines.contains { $0.redeem != nil || $0.kind == .pass || $0.kind == .storedValue }
            || sale.payments.contains { $0.tender == .prepaid }
        if number == nil || !hasQueuePrinter || touchesAccount {
            printers.print(receipt(for: sale), role: .receipt)
        } else {
            switch settings.receiptMode {
            case "always": printers.print(receipt(for: sale), role: .receipt)
            case "ask": receiptOffer = sale
            default: break
            }
        }
        if !kitchenLines.isEmpty {
            printKitchen(state.tickets[t.id] ?? t, lines: kitchenLines, mode: kitchenMode)
        }
    }

    /// 剛取到的號碼：右欄的叫號卡（手機是點餐頁上面那張）大大地顯示幾秒
    func flashTakeout(_ n: Int, ticket t: Ticket) {
        queue.justTaken = QueueJustTaken(number: n, ticketNumber: t.number)
    }

    /// 「補取號」：結帳時叫號連不上的外帶單（訂單的這一筆）
    func canRetakeQueueNumber(_ sale: SaleRecord) -> Bool {
        guard queueUsage.contains(.takeout), sale.orderType != .dineIn, sale.tableIds.isEmpty, sale.businessDate == businessDate,
              let t = state.tickets[sale.ticketId], t.status == .closed, t.queueNumber == nil else { return false }
        return role.takesPayment || role.takesOrders
    }

    /// 補取號：同一張單十分鐘內重送拿回同一個號碼（結帳時其實取到了、只是沒回應）；取到就印號碼牌（沒有號碼牌出單機就補印收據）
    func retakeQueueNumber(for sale: SaleRecord) async {
        guard let t = state.tickets[sale.ticketId] else { return }
        if let n = t.queueNumber {
            show("\(t.number) 已經是 \(n) 號", tone: .info)
            return
        }
        // 連不上的提示可能是舊的：照樣送一次（取到了提示就消失）
        guard let n = await requestTakeoutNumber(t) else {
            show(queue.problem?.message ?? "叫號連不上，等一下再試", tone: .warning)
            return
        }
        if !hasQueuePrinter, let fresh = state.sales[t.id] {
            printers.print(receipt(for: fresh, reprint: true), role: .receipt)
        }
        flashTakeout(n, ticket: t)
        show("\(t.number) 補取號・取餐號碼 \(n) 號")
    }

    // MARK: - 廚房、出餐口叫號

    /// 叫這張外帶單的號碼（廚房、出餐口的「叫號」）；沒有號碼的單回 false（照原本的唸取餐號碼）
    func callTicketNumber(_ t: Ticket) async -> Bool {
        guard features.queue, t.orderType != .dineIn, let n = t.queueNumber else { return false }
        return await callQueue(n)
    }

    // MARK: - 排隊等內用

    /// 排隊取號：右欄的鍵盤問幾位 → 取一張（帶人數）→ 印號碼牌
    func askTakeDineIn() async {
        let spec = KeypadSpec(kind: .count, title: "排隊取號", subtitle: "幾位？取號後印號碼牌",
                              quickKeys: [1, 2, 3, 4, 6].map { .init("\($0) 位", digits: String($0)) }, confirmLabel: "取號", maxValue: 30, minValue: 1)
        guard let guests = await keypad.askNumber(spec) else { return }
        await takeQueue(entry: QueueEntry(guests: guests))
    }

    /// 取一張、帶附帶資料（人數）：這台有號碼牌出單機就印
    @discardableResult
    func takeQueue(entry: QueueEntry) async -> Int? {
        var taken: Int?
        await coolingDown(.take) {
            guard let s = await sendQueue(.takeOne(entry: entry, requestId: newID())) else { return }
            guard let n = s.numbers?.first ?? s.waiting.last else {
                applyQueue(s)
                return
            }
            queue.localEntries[n] = entry
            applyQueue(s, taken: [n])
            if hasQueuePrinter { printQueueTickets([n], waiting: s.waiting.count) }
            let ahead = s.waiting.firstIndex(of: n) ?? max(s.waiting.count - 1, 0)
            show("取號 \(n) 號" + (entry.guests.map { "・\($0) 位" } ?? "") + (ahead > 0 ? "・前面 \(ahead) 組" : "・下一組就是"))
            taken = n
        }
        return taken
    }

    /// 叫號入座：叫這一號（沒給就叫下一號）→ 不知道幾位的先問 → 有桌子就直接入座，沒有就打開右欄的選桌
    func callToSeat(_ number: Int? = nil, table: DiningTable? = nil) async {
        guard let s = queue.state else { return }
        guard let n = number ?? s.waiting.first else {
            show("沒有人在排隊", tone: .info)
            return
        }
        queue.panel = nil
        guard await callQueue(n) else { return }
        await seatCalled(n, table: table)
    }

    /// 叫到的號碼入座（現在叫的那一號）：不知道幾位的先在右欄的鍵盤問
    func seatCalled(_ n: Int, table: DiningTable? = nil) async {
        var guests = queueEntry(n)?.guests
        if guests == nil {
            guests = await keypad.askNumber(KeypadSpec(kind: .count, title: "人數", subtitle: "\(n) 號幾位？",
                                                       quickKeys: [1, 2, 3, 4, 6].map { .init("\($0) 位", digits: String($0)) },
                                                       confirmLabel: "下一步", maxValue: 99, minValue: 1))
        }
        guard let g = guests else { return }
        let seat = QueueSeat(number: n, guests: g)
        if let table {
            seatQueue(seat, at: [table.id])
        } else if !(features.seating && mode.usesTables) || floor.allTables.isEmpty {
            // 沒有桌位圖：直接開內用單
            seatQueue(seat, at: [])
        } else {
            queue.seating = seat
        }
    }

    /// 入座：開內用單（人數、號碼掛上去），跳到點餐
    func seatQueue(_ seat: QueueSeat, at tableIds: [String]) {
        queue.seating = nil
        guard let t = openTicket(type: .dineIn, tableIds: tableIds, guests: seat.guests) else { return }
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, queueNumber: seat.number)))
        selectedTicketId = t.id
        let place = tableIds.isEmpty ? "內用" : floor.tableNames(tableIds)
        if visibleSections.contains(.order) {
            go(.order)
            show("\(seat.number) 號入座 \(place)・\(seat.guests) 位")
        } else {
            show("\(seat.number) 號入座 \(place)・\(seat.guests) 位・\(t.number) 已同步到結帳櫃台", tone: .info)
        }
    }

    // MARK: - 唸號碼

    /// 叫到了：跳一句話；這台設定要唸（或 force：「再唸一次」）就用 iPad 的喇叭唸
    func announceQueue(_ n: Int, prefix: String = "", force: Bool = false) {
        // 和叫號螢幕、廣播一樣的說法：「請 33 號客人」（全外帶的店唸「請 33 號客人取餐」）
        show("\(prefix)請 \(n) 號客人")
        guard force || settings.queueSpeaks else { return }
        let u = AVSpeechUtterance(string: "請 \(n) 號客人" + (queueForTakeout && !queueForDineIn ? "取餐" : ""))
        u.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        if queue.speaker.isSpeaking { _ = queue.speaker.stopSpeaking(at: .word) }
        queue.speaker.speak(u)
    }

    // MARK: - 號碼牌

    /// 印號碼牌：一個號碼一張，版面照後台（背景圖還沒下載好就用預設版面，不等）。
    /// waiting＝取號後的等候人數（樹莓派的 len(waiting)）
    func printQueueTickets(_ numbers: [Int], waiting: Int) {
        let layout = queueConfig?.ticket ?? .standard
        let background = queue.art.image(for: layout.backgroundUrl)
        if let url = layout.backgroundUrl, background == nil {
            let art = queue.art
            Task { await art.prefetch(url) }
        }
        let now = Date()
        for n in numbers {
            let ticket = QueueTicket(layout: layout, number: n, waiting: waiting, link: queueLink(n, waiting: waiting),
                                     storeName: store.name, at: now, background: background)
            printers.printQueueTicket(ticket)
        }
    }

    /// 設定頁：印一張測試號碼牌（下一張的號碼；不會真的取號）
    func printTestQueueTicket() {
        let s = queue.state
        printQueueTickets([s?.nextNo ?? 1], waiting: (s?.waiting.count ?? 0) + 1)
        show(hasQueuePrinter ? "已送出測試號碼牌" : "沒有號碼牌出單機：測試的在出單機設定的「最近列印」看得到", tone: hasQueuePrinter ? .active : .warning)
    }

    /// 設定頁的預覽（下一張的號碼；和真的印出來一樣：後台沒設網址就沒有 QR）
    func sampleQueueTicket() -> QueueTicket {
        let layout = queueConfig?.ticket ?? .standard
        let s = queue.state
        let n = s?.nextNo ?? 24
        let waiting = (s?.waiting.count ?? 4) + 1
        return QueueTicket(layout: layout, number: n, waiting: waiting, link: queueConfig?.customerLink(number: n, waiting: waiting),
                           storeName: store.name, at: Date(), background: queue.art.image(for: layout.backgroundUrl))
    }
}
