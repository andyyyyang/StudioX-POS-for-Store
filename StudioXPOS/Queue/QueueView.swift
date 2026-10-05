import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 叫號（號碼牌）：取代原本的 TicketSystem App（黃毛丫頭的叫號系統）。號碼在後台，這一頁每 2 秒抓一次。
///
///   ┌ Now *serving* ─────────────────────── [● 後台・即時] ┐ 右欄 ───────────────┐
///   │ ┌ ● 現在叫到 ─────────────────────────────────────┐ │ [取號]   [取幾張…]  │
///   │ │ Nº 23                               下一號 24    │ │ [過號]   [返回前一號]│
///   │ │ 14:05 叫的・2 分鐘前                    等候 8 位   │ │ [歸零]              │
///   │ └─────────────────────────────────────────────────┘ │ ■ 叫號  8 位等候中… │
///   │ ■ 等候中 8 位                                        │  1   2   3          │
///   │ [24 下一號][25 ★][26][27][28] …                      │  …                  │
///   │ ■ 過號 2   [19][21]                                  │ [   下一號 24   → ] │
///   │ ┌ 今天取號 31 │ 已服務 22 │ 平均等候 6 分 ┐            │                     │
///   └─────────────────────────────────────────────────────┴─────────────────────┘
///
/// 左邊選、右邊做：號碼（現在叫到、等候、過號）點一下選起來，再點一下取消；動作都在右欄。
/// 沒選東西時右欄是這一頁的動作：大鍵「下一號」，動作鍵取號、取幾張（右欄的鍵盤問 1–20）、過號、返回前一號、歸零。
/// 叫號要網路（和原本的 App 一樣）：連不上時上面一條提示，這一頁只能看、不能按。
struct QueueView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 選起來的號碼（動作在右欄）
    @State private var picked: QueuePick?
    @State private var didPreselect = false
    @State private var confirmReset = false
    @State private var confirmUnmiss: Int?
    /// 叫到新的號碼時，大號碼的框亮一下
    @State private var glow = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if let p = model.queue.problem {
                Banner(text: p.message, tone: p.blocksPage ? .danger : .warning)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // 每 15 秒重畫：等了幾分、幾分鐘前叫的
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                content(now: ctx.date)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : Motion.ease, value: model.queue.problem)
        .dockSelection(dockItem)
        .task { await model.queuePageLoop() }
        .onChange(of: model.queue.state, initial: true) { _, s in
            // 截圖：一打開就選起現在叫到的號碼
            if LaunchArguments.preselect, !didPreselect, let c = s?.current {
                didPreselect = true
                picked = .current(c)
            }
            dropStalePick(s)
        }
        .onChange(of: model.queue.state?.current) { old, new in
            if old != nil, old != new { flash() }
        }
        .alert("全部歸零？", isPresented: $confirmReset) {
            Button("歸零", role: .destructive) { Task { await model.resetQueue() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("等候中、過號、標記都會清掉，下一張從 1 號開始。店長以上才能歸零。")
        }
        .alert("從過號刪掉？", isPresented: unmissBinding, presenting: confirmUnmiss) { n in
            Button("刪掉 \(n) 號", role: .destructive) { Task { await model.unmissQueue(n) } }
            Button("取消", role: .cancel) {}
        } message: { n in
            Text("\(n) 號會從過號清單拿掉，之後不能再叫一次。")
        }
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.spring }

    private var unmissBinding: Binding<Bool> {
        Binding(get: { confirmUnmiss != nil }, set: { if !$0 { confirmUnmiss = nil } })
    }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            PageTitle(title: "Now *serving*", subtitle: "叫號・號碼牌")
            Spacer(minLength: 12)
            QueueModeChip(mode: model.queueMode, problem: model.queue.problem, syncedAt: model.queue.syncedAt)
                .frame(height: 44)
        }
    }

    // MARK: - 內容

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let s = model.queue.state {
            if s.isEmpty {
                empty(s)
            } else {
                board(s, now: now)
            }
        } else if model.queue.problem == nil {
            EmptyState(icon: "arrow-path", title: "正在抓號碼…", message: "連上後台後，現在叫到幾號、誰在等會出現在這裡。")
        } else {
            EmptyState(icon: "ticket", title: "看不到號碼", message: "連上之後號碼會自動出現（每 2 秒試一次）。")
        }
    }

    /// 沒有人取號、也沒有過號
    private func empty(_ s: QueueState) -> some View {
        let taken = s.takenToday ?? 0
        return VStack(alignment: .leading, spacing: 20) {
            EmptyState(
                icon: "ticket",
                title: taken > 0 ? "現在沒有人在等" : "還沒有人取號",
                message: taken > 0
                    ? "今天已經取了 \(taken) 張\(s.servedToday.map { "、服務了 \($0) 位" } ?? "")。\(howToTake)"
                    : "\(howToTake)這台有號碼牌出單機就會馬上印出來。"
            )
            .frame(maxHeight: 360)
            if model.queueMode == .native, taken > 0 {
                stats(s, now: Date())
            }
        }
    }

    /// 怎麼取號（看叫號用在哪裡）
    private var howToTake: String {
        if model.queueForDineIn { return "客人來了按右邊的「排隊取號」（鍵盤問幾位）。" }
        if model.queueForTakeout { return "外帶單結帳完成時會自動取號；也可以按右邊的「取號」。" }
        return "客人來了按右邊的「取號」（一次多張按「取幾張…」）。"
    }

    private func board(_ s: QueueState, now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                QueueHero(
                    state: s,
                    mode: model.queueMode,
                    now: now,
                    selected: s.current.map { picked == .current($0) } ?? false,
                    glow: glow,
                    onSelect: { if let c = s.current { toggle(.current(c)) } }
                )
                waitingSection(s, now: now)
                if !s.missed.isEmpty {
                    missedSection(s)
                }
                if model.queueMode == .native, s.servedToday != nil || s.takenToday != nil {
                    stats(s, now: now)
                }
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: 等候中

    private func waitingSection(_ s: QueueState, now: Date) -> some View {
        let native = model.queueMode == .native
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow("等候中")
                Text("\(s.waiting.count) 位")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                if !s.waiting.isEmpty {
                    Text("點號碼選起來：標記在右邊")
                        .textRole(.xs)
                        .foregroundStyle(Theme.faint)
                }
            }
            if s.waiting.isEmpty {
                Text(s.current == nil ? "沒有人在等" : "叫到的是最後一位了，沒有人在等")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 168), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Array(s.waiting.enumerated()), id: \.element) { i, n in
                        let minutes = native ? s.waitMinutes(n, now: now) : nil
                        QueueTile(
                            number: n,
                            caption: waitingCaption(index: i, minutes: minutes, tag: model.queueTag(n)),
                            style: i == 0 ? .next : .waiting,
                            late: (minutes ?? 0) >= 20,
                            marked: s.isMarked(n),
                            selected: picked == .waiting(n),
                            onSelect: { toggle(.waiting(n)) }
                        )
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
                .animation(anim, value: s.waiting)
                .animation(anim, value: s.marked)
            }
        }
    }

    /// 「下一號・等 6 分」「等 12 分」；舊伺服器沒有取號時間：「第 3 位」。
    /// 排隊等內用的人數、外帶單做好了放最前面：「4 位・等 6 分」「好了・等 3 分」
    private func waitingCaption(index: Int, minutes: Int?, tag: String?) -> String {
        let wait = minutes.map { $0 == 0 ? "剛取" : "等 \($0) 分" }
        let base: String
        if index == 0 {
            base = tag == nil ? (wait.map { "下一號・\($0)" } ?? "下一號") : "下一號"
        } else {
            base = wait ?? "第 \(index + 1) 位"
        }
        return tag.map { "\($0)・\(base)" } ?? base
    }

    // MARK: 過號

    private func missedSection(_ s: QueueState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow("過號")
                Text("\(s.missed.count) 位")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Text(model.queueMode.canRecall ? "點號碼：再叫一次、刪掉" : "點號碼：刪掉、標記")
                    .textRole(.xs)
                    .foregroundStyle(Theme.faint)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(s.missed, id: \.self) { n in
                        QueueTile(
                            number: n,
                            caption: "過號",
                            style: .missed,
                            late: false,
                            marked: s.isMarked(n),
                            selected: picked == .missed(n),
                            onSelect: { toggle(.missed(n)) }
                        )
                        .frame(width: 112)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 2)
                .animation(anim, value: s.missed)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 今天（後台自己存號碼時才有）

    private func stats(_ s: QueueState, now: Date) -> some View {
        HStack(spacing: 0) {
            QueueStat(label: "今天取號", value: s.takenToday.map { "\($0)" } ?? "—", unit: "張")
            Rule(vertical: true)
            QueueStat(label: "已服務", value: s.servedToday.map { "\($0)" } ?? "—", unit: "位")
            Rule(vertical: true)
            QueueStat(label: "平均等候", value: s.averageWaitMinutes(now: now).map { "\($0)" } ?? "—", unit: "分")
        }
        .fixedSize(horizontal: false, vertical: true)
        .panel(padding: 0)
    }

    // MARK: - 選取

    private func toggle(_ p: QueuePick) {
        model.touch()
        withAnimation(reduceMotion ? nil : Motion.fast) { picked = picked == p ? nil : p }
    }

    private func select(_ p: QueuePick?) {
        withAnimation(reduceMotion ? nil : Motion.fast) { picked = p }
    }

    /// 選起來的號碼已經不在那裡了（過號了、叫走了、別台刪掉了）：取消選取
    private func dropStalePick(_ s: QueueState?) {
        guard let p = picked else { return }
        guard let s, p.isValid(in: s) else {
            select(nil)
            return
        }
    }

    private func flash() {
        guard !reduceMotion else { return }
        glow = 1
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(.easeOut(duration: 1.1)) { glow = 0 }
        }
    }

    // MARK: - 右欄

    private var dockItem: DockSelection? {
        guard let s = model.queue.state else { return pageDock(nil) }
        switch picked {
        case .current(let n)? where s.current == n: return currentDock(n, s)
        case .waiting(let n)? where s.waiting.contains(n): return waitingDock(n, s)
        case .missed(let n)? where s.missed.contains(n): return missedDock(n, s)
        default: return pageDock(s)
        }
    }

    /// 沒選東西：大鍵「下一號 24」（品牌橘）；取號、取幾張…、過號、返回前一號、歸零。
    /// 排隊等內用：大鍵「叫號入座 31（4 位）」、取號是「排隊取號」（鍵盤問幾位）
    private func pageDock(_ s: QueueState?) -> DockSelection {
        let can = model.queueCanAct
        let next = s?.waiting.first
        let calling = s?.current != nil
        if model.queueForDineIn {
            return DockSelection.page(
                "queue",
                primary: POSAction(model.queueSeatNextTitle, icon: "users", enabled: can && next != nil && !model.queueCooling(.next)) {
                    Task { await model.callToSeat() }
                },
                accent: true,
                actions: [
                    POSAction("排隊取號", icon: "ticket", enabled: can && !model.queueCooling(.take)) { Task { await model.askTakeDineIn() } },
                    POSAction(next.map { "只叫號 \($0)" } ?? "只叫號", icon: "megaphone", enabled: can && next != nil && !model.queueCooling(.next)) {
                        Task { await model.nextQueue() }
                    },
                    POSAction("取幾張…", icon: "rectangle-stack", enabled: can && !model.queueCooling(.take)) { Task { await model.askTakeQueue() } },
                    POSAction("過號", icon: "minus-circle", enabled: can && calling && !model.queueCooling(.miss)) { Task { await model.missQueue() } },
                    POSAction("返回前一號", icon: "arrow-uturn-left", enabled: can && calling) { Task { await model.previousQueue() } },
                    POSAction("歸零", icon: "arrow-path", destructive: true, enabled: can) { confirmReset = true },
                ]
            )
        }
        // 外帶叫號：號碼是結帳時自動取的（一張單一個號碼），這裡不手動取號；叫下一號是手動
        var manualTake: [POSAction] = []
        if !model.queueForTakeout {
            manualTake.append(POSAction("取號", icon: "ticket", enabled: can && !model.queueCooling(.take)) { Task { await model.takeQueue(1) } })
            manualTake.append(POSAction("取幾張…", icon: "rectangle-stack", enabled: can && !model.queueCooling(.take)) { Task { await model.askTakeQueue() } })
        }
        return DockSelection.page(
            "queue",
            primary: POSAction(next.map { "下一號 \($0)" } ?? "下一號", icon: "megaphone",
                               enabled: can && next != nil && !model.queueCooling(.next)) {
                Task { await model.nextQueue() }
            },
            accent: true,
            actions: manualTake + [
                POSAction("過號", icon: "minus-circle", enabled: can && calling && !model.queueCooling(.miss)) { Task { await model.missQueue() } },
                POSAction("返回前一號", icon: "arrow-uturn-left", enabled: can && calling) { Task { await model.previousQueue() } },
                POSAction("歸零", icon: "arrow-path", destructive: true, enabled: can) { confirmReset = true },
            ]
        )
    }

    /// 現在叫到的：大鍵「過號」（墨色）；返回前一號、標記、開單（已經有單的外帶號碼不用）、入座（排隊等內用）、再唸一次
    private func currentDock(_ n: Int, _ s: QueueState) -> DockSelection {
        let can = model.queueCanAct
        let marked = s.isMarked(n)
        let ticket = model.queueTicket(n)
        var actions = [
            POSAction("返回前一號", icon: "arrow-uturn-left", enabled: can) { Task { await model.previousQueue() } },
            POSAction(marked ? "取消標記" : "標記", icon: "star", enabled: can) { Task { await model.toggleQueueMark(n) } },
        ]
        if model.queueForDineIn && ticket == nil {
            actions.append(POSAction("入座", icon: "users") { Task { await model.seatCalled(n) } })
        }
        if model.queueCanOpenTicket && ticket == nil {
            actions.append(POSAction("開單", icon: "shopping-bag") { model.openQueueTicket(n) })
        }
        actions.append(POSAction("再唸一次", icon: "speaker-wave") { model.announceQueue(n, prefix: "再唸一次・", force: true) })
        var parts: [String] = []
        if let d = model.queueDetail(n) { parts.append(d) }
        if let at = s.calledAt { parts.append("\(at.clockText) 叫的（\(Self.ago(at))）") }
        parts.append(s.waiting.isEmpty ? "後面沒有人在等" : "後面還有 \(s.waiting.count) 位")
        return DockSelection(
            id: "queue-current-\(n)", kind: "現在叫到", title: "\(n) 號", detail: parts.joined(separator: "・"),
            badge: marked ? DockBadge("★ 標記", tone: .gold) : DockBadge("叫號中", tone: .active),
            primary: POSAction("過號", icon: "minus-circle", enabled: can && !model.queueCooling(.miss)) { Task { await model.missQueue() } },
            accent: false,
            actions: actions,
            clear: { select(nil) }
        )
    }

    /// 等候中的：大鍵「叫這一號」（外帶：先做好的先叫）或「叫號入座」（排隊等內用）；標記。
    /// 原本的叫號伺服器只能照順序叫：不是第一位的沒有大鍵，說明要改成後台叫號
    private func waitingDock(_ n: Int, _ s: QueueState) -> DockSelection {
        let marked = s.isMarked(n)
        let position = (s.waiting.firstIndex(of: n) ?? 0) + 1
        let canCall = model.queueCanCall(n) && !model.queueCooling(.call) && !model.queueCooling(.next)
        var parts = [position == 1 ? "下一個就是他" : "前面還有 \(position - 1) 位"]
        if let d = model.queueDetail(n) { parts.insert(d, at: 0) }
        if let at = s.takenTime(of: n) { parts.append("\(at.clockText) 取號（等了 \(Self.minutes(since: at)) 分）") }
        if position > 1 && model.queueMode != .native { parts.append("原本的叫號伺服器只能照順序叫：要叫指定的號碼請在後台把號碼改存在後台") }
        let seats = model.queueForDineIn && model.queueTicket(n) == nil
        let primary: POSAction? = position == 1 || model.queueMode == .native
            ? (seats
                ? POSAction("叫號入座", icon: "users", enabled: canCall) { Task { await model.callToSeat(n) } }
                : POSAction("叫這一號", icon: "megaphone", enabled: canCall) { Task { await model.callQueue(n) } })
            : nil
        return DockSelection(
            id: "queue-waiting-\(n)", kind: "等候中・第 \(position) 位", title: "\(n) 號", detail: parts.joined(separator: "・"),
            badge: marked ? DockBadge("★ 標記", tone: .gold) : (position == 1 ? DockBadge("下一號", tone: .info) : nil),
            primary: primary,
            accent: true,
            actions: [POSAction(marked ? "取消標記" : "標記", icon: "star", enabled: model.queueCanAct) { Task { await model.toggleQueueMark(n) } }],
            clear: { select(nil) }
        )
    }

    /// 過號的：大鍵「再叫一次」（原本的叫號伺服器沒有這個動作，就不出現）；從過號刪掉、標記
    private func missedDock(_ n: Int, _ s: QueueState) -> DockSelection {
        let can = model.queueCanAct
        let marked = s.isMarked(n)
        let recall = model.queueMode.canRecall
        return DockSelection(
            id: "queue-missed-\(n)", kind: "過號", title: "\(n) 號",
            detail: recall ? "客人回來了：再叫一次，他就變成現在叫到的" : "原本的叫號伺服器不能再叫一次：客人回來了直接服務，或請他重新取號",
            badge: marked ? DockBadge("★ 標記", tone: .gold) : DockBadge("過號", tone: .warning),
            primary: recall ? POSAction("再叫一次", icon: "megaphone", enabled: can) { Task { await model.recallQueue(n) } } : nil,
            actions: [
                POSAction("從過號刪掉", icon: "trash", destructive: true, enabled: can) { confirmUnmiss = n },
                POSAction(marked ? "取消標記" : "標記", icon: "star", enabled: can) { Task { await model.toggleQueueMark(n) } },
            ],
            clear: { select(nil) }
        )
    }

    static func minutes(since d: Date) -> Int { max(Int(Date().timeIntervalSince(d) / 60), 0) }

    static func ago(_ d: Date) -> String {
        let m = minutes(since: d)
        return m == 0 ? "剛剛" : "\(m) 分鐘前"
    }
}

// MARK: - 選取

private enum QueuePick: Hashable {
    case current(Int)
    case waiting(Int)
    case missed(Int)

    func isValid(in s: QueueState) -> Bool {
        switch self {
        case .current(let n): s.current == n
        case .waiting(let n): s.waiting.contains(n)
        case .missed(let n): s.missed.contains(n)
        }
    }
}

// MARK: - 頁首：號碼存在哪裡、連線

/// 「● 後台・即時」「● 原本的叫號伺服器・14:05 更新」
private struct QueueModeChip: View {
    let mode: QueueMode
    let problem: QueueProblem?
    let syncedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            if problem == nil && syncedAt != nil {
                LiveDot()
            } else {
                Circle()
                    .fill(problem?.blocksPage == true ? Theme.dangerFG : Theme.warningFG)
                    .frame(width: 7, height: 7)
            }
            HeroIcon(mode == .legacy ? "server-stack" : "cloud", size: 14)
                .foregroundStyle(Theme.ink2)
            Text(mode.label)
                .font(.brand(13, .semibold))
                .foregroundStyle(Theme.ink)
            Text(status)
                .font(.brand(12.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.surface, in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("號碼存在\(mode.label)，\(status)")
    }

    private var status: String {
        if problem?.blocksPage == true { return syncedAt.map { "\($0.clockText) 之後連不上" } ?? "連不上" }
        guard let syncedAt else { return "連線中" }
        return Date().timeIntervalSince(syncedAt) < 10 ? "即時" : "\(syncedAt.clockText) 更新"
    }
}

// MARK: - 現在叫到（大號碼）

/// 頁面的主角：反白的大卡、很大的號碼（換號時數字滾動、框亮一下）。點一下選起來，右欄是它的動作
private struct QueueHero: View {
    let state: QueueState
    let mode: QueueMode
    let now: Date
    let selected: Bool
    /// 叫到新號碼時亮一下（0–1）
    let glow: Double
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = state.current
        let shape = RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
        Button(action: onSelect) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if current != nil {
                            LiveDot(color: Theme.accent)
                        } else {
                            Circle().fill(Theme.inverseMuted).frame(width: 7, height: 7)
                        }
                        Text("現在叫到")
                            .font(.brand(13, .medium))
                            .tracking(0.3)
                            .foregroundStyle(Theme.inverseMuted)
                        if let current, state.isMarked(current) {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("標記")
                                    .font(.brand(11.5, .semibold))
                            }
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.accent, in: .capsule)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Nº")
                            .font(.serif(58, italic: true))
                            .foregroundStyle(Theme.accent)
                        Text(current.map { String($0) } ?? "—")
                            .font(.brand(160, .semibold))
                            .tracking(-8)
                            .monospacedDigit()
                            .foregroundStyle(current == nil ? Theme.inverseMuted : Theme.onInverse)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .contentTransition(.numericText(value: Double(current ?? 0)))
                    }
                    Text(caption)
                        .font(.brand(15, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inverseMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 18) {
                    fact("下一號", state.waiting.first.map { String($0) } ?? "—", accent: state.waiting.first != nil)
                    fact("等候", "\(state.waiting.count) 位", accent: false)
                }
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 30)
            .padding(.top, 24)
            .padding(.bottom, 26)
            .background(Theme.inverse, in: shape)
            .overlay {
                shape.strokeBorder(Theme.accent.opacity(selected ? 1 : glow), lineWidth: selected ? 3 : 2)
            }
            .contentShape(shape)
        }
        .buttonStyle(PressScale(scale: 0.99))
        .disabled(current == nil)
        .animation(reduceMotion ? nil : Motion.spring, value: current)
        .animation(reduceMotion ? nil : Motion.spring, value: state.waiting.first)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(current.map { "現在叫到 \($0) 號" } ?? "還沒叫號")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(current == nil ? "" : "點一下選起來，過號、標記、開單在右邊")
    }

    private var caption: String {
        guard state.current != nil else { return "還沒叫號：按右邊的「下一號」叫第一位" }
        if let at = state.calledAt {
            return "\(at.clockText) 叫的・\(QueueView.ago(at))"
        }
        return mode == .legacy ? "點一下選起來：過號、標記、開單在右邊" : "叫號中"
    }

    private func fact(_ label: String, _ value: String, accent: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.brand(36, .semibold))
                .tracking(-1)
                .monospacedDigit()
                .foregroundStyle(accent ? Theme.accent : Theme.onInverse)
                .contentTransition(.numericText())
                .lineLimit(1)
            Text(label)
                .font(.brand(12.5, .medium))
                .foregroundStyle(Theme.inverseMuted)
        }
    }
}

// MARK: - 一個號碼

/// 一個號碼的方塊：整塊可以點（選起來），上面沒有按鈕。下一號淡橘框、標記淡橘底＋星號、過號虛線框
private struct QueueTile: View {
    enum Style {
        case next, waiting, missed
    }

    let number: Int
    let caption: String
    let style: Style
    /// 等很久了（20 分以上）
    let late: Bool
    let marked: Bool
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(number)")
                        .font(.brand(style == .missed ? 28 : 34, .semibold))
                        .tracking(-1)
                        .monospacedDigit()
                        .foregroundStyle(style == .missed ? Theme.ink2 : Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 2)
                    if marked {
                        Image(systemName: "star.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                    }
                }
                Text(caption)
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(captionColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(marked ? Theme.accentSoft : (style == .missed ? Theme.pageAlt : Theme.surface), in: shape)
            .overlay { border(shape) }
            .contentShape(shape)
        }
        .buttonStyle(PressScale(scale: 0.97))
        .animation(Motion.fast, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number) 號，\(caption)\(marked ? "，標記" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("點一下選起來，動作在右邊")
    }

    private var captionColor: Color {
        if style == .next { return Theme.accentText }
        if late { return Theme.warningFG }
        return Theme.muted
    }

    @ViewBuilder
    private func border(_ shape: RoundedRectangle) -> some View {
        if selected {
            shape.strokeBorder(Theme.accent, lineWidth: 2)
        } else if style == .missed {
            shape.strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else if style == .next {
            shape.strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
        } else {
            shape.strokeBorder(Theme.line, lineWidth: 1)
        }
    }
}

// MARK: - 今天的數字

private struct QueueStat: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.brand(12.5, .medium))
                .foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .textRole(.number)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
