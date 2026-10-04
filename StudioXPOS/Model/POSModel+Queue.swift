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
    /// 背景圖（號碼牌）
    let art = QueueTicketArt()

    let speaker = AVSpeechSynthesizer()
    /// 這台印過的號碼牌（同一個營業日不重複；存在這台）
    @ObservationIgnored var printed = QueuePrintLog.load()
    /// 上一次看到的等候中（「也印別台取的號碼」：只印這次新出現的；nil＝下一次抓到時只記下來、不補印）
    @ObservationIgnored var lastWaiting: Set<Int>?

    var pageVisible: Bool { pageLoops > 0 }

    /// 換店、結束示範
    func reset() {
        state = nil
        problem = nil
        syncedAt = nil
        cooling = []
        lastWaiting = nil
        // 示範店的號碼不會存進這台（重新讀一次存著的）
        printed = QueuePrintLog.load()
    }
}

/// 有冷卻時間的鍵（防連按）
enum QueueKey: Hashable {
    case take, next, miss
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

    /// 背景（每次回傳下一次要等幾秒）：叫號頁開著時頁面自己抓；「也印別台取的號碼」開著時每 2 秒（鎖定畫面也印）；
    /// 其他時候每 15 秒（側欄的等候人數）
    func queueBackgroundTick() async -> Double {
        guard features.queue, api != nil, phase == .ready || phase == .locked else { return 15 }
        if queue.pageVisible { return 2 }
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

    /// 開單：客人的稱呼是號碼（「23 號」），跳到點餐
    func openQueueTicket(_ n: Int) {
        guard let t = openTicket(type: mode.defaultOrderType, customerName: "\(n) 號") else { return }
        selectedTicketId = t.id
        if visibleSections.contains(.order) {
            go(.order)
        } else {
            show("已開單 \(t.number)（\(n) 號）", tone: .info)
        }
    }

    /// 這台可以幫叫到的號碼開單（有點餐頁的崗位）
    var queueCanOpenTicket: Bool { role.takesOrders && visibleSections.contains(.order) }

    // MARK: - 唸號碼

    /// 叫到了：跳一句話；這台設定要唸（或 force：「再唸一次」）就用 iPad 的喇叭唸
    func announceQueue(_ n: Int, prefix: String = "", force: Bool = false) {
        show("\(prefix)叫號 \(n) 號")
        guard force || settings.queueSpeaks else { return }
        let u = AVSpeechUtterance(string: "請 \(n) 號取餐")
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
            let ticket = QueueTicket(layout: layout, number: n, waiting: waiting, link: queueConfig?.customerLink(number: n, waiting: waiting),
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
