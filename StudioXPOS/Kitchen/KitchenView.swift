import AVFoundation
import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 廚房螢幕（KDS）：每張單一張卡，最久的在最前面。可能掛在熱烘烘的廚房牆上，所以字大、狀態一眼看得懂。
///
///   ┌ On the pass ──────────────────── 6 張單  14 份待做  1 張超過 20 分   14:32 ┐
///   │ [全部 14] [廚房 9] [吧台 5]                                                │
///   │ ▸ ■ 剛出餐  2 張・10 分鐘內的，按錯可以復原                                  │
///   │ ┌ A2 ────────── 23 分 ┐ ┌ 外帶 A023 ──── 8 分 ┐                           │
///   │ │ 2  鮭魚貝果   製作中 │ │ 1  拿鐵        待做 │                           │
///   │ │    半熟・換沙拉       │ │    冰・燕麥奶       │                           │
///   │ │ 1  酥皮鬆餅   可出餐 │ │                    │                           │
///   └──────────────────────────────────────────────────────────────────────────┘
///
/// 左邊選、右邊做：卡片上沒有按鈕。點一行＝那一行換下一個狀態（待做 → 製作中 → 可出餐 → 待做）；
/// 點卡片上方的桌號＝選起來，這張單的動作都在右欄：大鍵「好了」（整張好了）或「已上菜」，
/// 動作鍵有全部開始做、退回製作中、叫號、重印廚房單。
/// 收掉的 10 分鐘內留在上面那條「剛出餐」，點一張選起來，右欄可以復原（改回可出餐）。
///
/// 出餐口（崗位）：看所有出單站；整張都好了的單浮到最上面，大大的取餐號碼；選起來後大鍵是「叫號」（唸出來），叫過是「已出餐」。
///
/// 叫號用在外帶取餐（結帳時取了號碼、掛在單子上）：卡片最上面是大大的號碼；全好了大鍵是「叫號 24」（廚房也是），
/// 出餐口還沒全好時大鍵是「好了・叫號 24」（一次按完）。叫號走叫號系統：後台存號碼的直接叫那一號（先做好的先叫），
/// 原本的叫號伺服器只能叫排第一的（不是的話跳一句說明）。
struct KitchenView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 篩選的出單站（空的＝全部）
    @State private var stations: Set<String> = []
    @State private var appliedDefault = false
    @State private var showBumped = false
    /// 出餐口叫過號的單（什麼時候叫的）
    @State private var called: [String: Date] = [:]
    @State private var speaker = AVSpeechSynthesizer()
    /// 選起來的單（動作在右欄）
    @State private var selected: KitchenPick?

    var body: some View {
        // 每 15 秒重畫：等了幾分鐘、顏色變不變
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            content(now: ctx.date)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            applyDefaultStations()
            // 截圖：先選最久的那張
            if LaunchArguments.preselect, let c = makeCards(relevantTickets(now: Date()), hasStations: !allStations.isEmpty).first { selected = .card(c.id) }
        }
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.ease }

    private func content(now: Date) -> some View {
        let hasStations = !allStations.isEmpty
        let tickets = relevantTickets(now: now)
        let cards = makeCards(tickets, hasStations: hasStations)
        let bumps = makeBumps(now: now, hasStations: hasStations)
        // 出餐口：整張都好了的單另外放在最上面
        let isExpo = model.role == .expo
        let ready = isExpo ? cards.filter { $0.allReady } : []
        let working = isExpo ? cards.filter { !$0.allReady } : cards
        return VStack(alignment: .leading, spacing: 18) {
            header(cards: cards, now: now)
            if hasStations {
                stationBar(tickets, hasStations: hasStations)
            }
            if !bumps.isEmpty {
                bumpStrip(bumps, now: now)
            }
            if cards.isEmpty {
                EmptyState(icon: "fire", title: "沒有要做的", message: "新的單送出後會出現在這裡。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !ready.isEmpty {
                            expoReady(ready, now: now)
                        }
                        if !working.isEmpty {
                            if !ready.isEmpty {
                                Eyebrow("製作中")
                            }
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 16, alignment: .top)],
                                alignment: .leading,
                                spacing: 16
                            ) {
                                ForEach(working) { c in
                                    KitchenTicketCard(card: c, now: now, showsStation: hasStations && stations.count != 1,
                                                      selected: selected == .card(c.id), onSelect: { toggle(.card(c.id)) })
                                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                                }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
        .dockSelection(dockItem(cards: cards, bumps: bumps, now: now))
    }

    // MARK: - 出餐口

    private func expoReady(_ ready: [KitchenCardModel], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow("可以出餐", color: Theme.successFG)
                Text("\(ready.count) 張・選起來，右邊叫號；客人拿走按「已出餐」")
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(ready) { c in
                    KitchenExpoCard(
                        card: c,
                        pickup: pickupLabel(c.ticket),
                        title: c.ticket.title(floor: model.floor),
                        now: now,
                        calledAt: calledTime(c.ticket),
                        selected: selected == .card(c.id),
                        onSelect: { toggle(.card(c.id)) }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
    }

    /// 外帶單有叫號的號碼（結帳時取的）就用它；否則櫃台、咖啡模式的外帶單用取餐號碼（A023 → 23）；內用、其他模式用桌號或單名
    private func pickupLabel(_ t: Ticket) -> String? {
        if let q = t.queueNumber, t.orderType != .dineIn { return String(q) }
        guard model.mode.printsPickupNumber, t.tableIds.isEmpty else { return nil }
        return Templates.pickupNumber(t.number)
    }

    /// 這張單掛著叫號的號碼（外帶結帳時取的）：叫號走叫號系統（叫號螢幕、客人的手機一起跳）
    private func queueNumber(_ t: Ticket) -> Int? {
        guard model.features.queue, t.orderType != .dineIn else { return nil }
        return t.queueNumber
    }

    /// 叫過了：這台按過，或叫號系統上現在叫的就是它（別台叫的也算）
    private func calledTime(_ t: Ticket) -> Date? {
        if let at = called[t.id] { return at }
        if let n = queueNumber(t), model.queue.state?.current == n { return model.queue.state?.calledAt ?? Date() }
        return nil
    }

    /// 叫號：有叫號的號碼＝叫那一號（先做好的先叫；原本的叫號伺服器只能叫排第一的，不是的話跳一句說明）；
    /// 沒有＝唸出來（「二十三號，請取餐」）。記下叫過了
    private func call(_ c: KitchenCardModel) {
        let t = c.ticket
        if queueNumber(t) != nil {
            Task {
                if await model.callTicketNumber(t) {
                    withAnimation(anim) { called[t.id] = Date() }
                }
            }
            return
        }
        let label = pickupLabel(t).map { "\($0) 號" } ?? t.title(floor: model.floor)
        withAnimation(anim) { called[t.id] = Date() }
        model.show("叫號 \(label)")
        let utterance = AVSpeechUtterance(string: "\(label)，請取餐")
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        speaker.speak(utterance)
    }

    /// 出餐口：整張好了＋叫號一次按完（叫號的外帶單）
    private func readyAndCall(_ c: KitchenCardModel) {
        setAll(.ready, c)
        call(c)
    }

    private func served(_ c: KitchenCardModel) {
        withAnimation(anim) {
            model.kitchen(.served, lines: c.lines, in: c.ticket)
            called[c.ticket.id] = nil
            if selected == .card(c.id) { selected = nil }
        }
    }

    // MARK: - 右欄：選起來的單

    private func toggle(_ p: KitchenPick) {
        model.touch()
        withAnimation(reduceMotion ? nil : Motion.fast) { selected = selected == p ? nil : p }
    }

    private func dockItem(cards: [KitchenCardModel], bumps: [KitchenBump], now: Date) -> DockSelection? {
        guard let selected else { return nil }
        switch selected {
        case .card(let id):
            guard let c = cards.first(where: { $0.id == id }) else { return nil }
            return cardDock(c, now: now)
        case .bump(let id):
            guard let b = bumps.first(where: { $0.id == id }) else { return nil }
            let minutes = max(0, Int(now.timeIntervalSince(b.at) / 60))
            return DockSelection(
                id: "kitchen-bump-\(b.id)", kind: "剛出餐", title: b.ticket.title(floor: model.floor),
                detail: b.lines.map { "\($0.name) ×\($0.quantity)" }.joined(separator: "、") + "・" + (minutes == 0 ? "剛剛" : "\(minutes) 分鐘前"),
                badge: DockBadge("已上菜", tone: .neutral),
                primary: POSAction("復原（改回可出餐）", icon: "arrow-uturn-left") { undoBump(b) },
                accent: false,
                clear: { toggle(.bump(b.id)) }
            )
        }
    }

    /// 大鍵：還沒全好 →「好了」；全好了 →「已上菜」（出餐口：還沒叫 →「叫號」、叫過 →「已出餐」）。
    /// 叫號的外帶單（掛著號碼）：全好了還沒叫 →「叫號 24」（廚房也是）；出餐口的「好了」順便叫號
    private func cardDock(_ c: KitchenCardModel, now: Date) -> DockSelection {
        let title = c.ticket.title(floor: model.floor)
        let isExpo = model.role == .expo
        let calledAt = calledTime(c.ticket)
        let pickup = pickupLabel(c.ticket)
        let queued = queueNumber(c.ticket)
        let count = c.lines.reduce(0) { $0 + $1.quantity }
        let readyCount = c.lines.filter { $0.kitchen == .ready }.reduce(0) { $0 + $1.quantity }
        let minutes = c.minutes(at: now)
        let servedAction = POSAction(isExpo ? "已出餐" : "已上菜", icon: "check-circle") { served(c) }
        let callTitle = calledAt == nil ? (queued.map { "叫號 \($0)" } ?? "叫號") : "再叫一次"
        // 原本的叫號伺服器叫不了排在後面的號碼：照樣按得下去，跳一句說明（POSModel.callQueue）
        let callAction = POSAction(callTitle, icon: "megaphone") { call(c) }
        let waiting = c.lines.filter { $0.kitchen == .sent }
        let readyLines = c.lines.filter { $0.kitchen == .ready }

        let primary: POSAction
        var actions: [POSAction] = []
        // 大鍵已經是叫號：動作鍵不重複
        var callIsPrimary = false
        if !c.allReady {
            if isExpo, let q = queued, calledAt == nil {
                // 出餐口：好了就叫號（一次按完）
                primary = POSAction("好了・叫號 \(q)", icon: "megaphone") { readyAndCall(c) }
                callIsPrimary = true
            } else {
                primary = POSAction("好了", icon: "check") { setAll(.ready, c) }
            }
            actions.append(servedAction)
        } else if calledAt == nil && (isExpo || queued != nil) {
            primary = callAction
            callIsPrimary = true
            actions.append(servedAction)
        } else {
            primary = servedAction
        }
        // 叫號：出餐口、或有取餐號碼的外帶單
        if (isExpo || pickup != nil) && !callIsPrimary {
            actions.append(callAction)
        }
        actions.append(POSAction("全部開始做", icon: "fire", enabled: !waiting.isEmpty) { setLines(.preparing, waiting, c) })
        actions.append(POSAction("退回製作中", icon: "arrow-uturn-left", enabled: !readyLines.isEmpty) { setLines(.preparing, readyLines, c) })
        actions.append(POSAction("重印廚房單", icon: "printer") { reprint(c) })

        var parts = ["\(count) 份", "好了 \(readyCount)", "等了 \(minutes) 分"]
        if let pickup { parts.insert("取餐 \(pickup) 號", at: 0) }
        if let calledAt { parts.append("\(calledAt.clockText) 叫過") }
        if let q = queued, calledAt == nil, !model.queueCanCall(q), model.queue.state?.waiting.contains(q) == true {
            // 原本的叫號伺服器只能照順序叫
            parts.append("前面還有人：叫號照順序")
        }
        let badge: DockBadge
        if c.allReady {
            badge = DockBadge("可出餐", tone: .active)
        } else {
            switch KitchenUrgency(minutes: minutes) {
            case .hot: badge = DockBadge("超過 20 分", tone: .danger)
            case .warm: badge = DockBadge("超過 10 分", tone: .warning)
            case .calm: badge = DockBadge("製作中", tone: .neutral)
            }
        }
        return DockSelection(id: "kitchen-\(c.id)", kind: isExpo && c.allReady ? "出餐" : "廚房", title: title,
                             detail: parts.joined(separator: "・"), badge: badge,
                             primary: primary, actions: actions, clear: { toggle(.card(c.id)) })
    }

    private func setAll(_ status: KitchenStatus, _ c: KitchenCardModel) {
        setLines(status, c.lines.filter { $0.kitchen != status }, c)
    }

    private func setLines(_ status: KitchenStatus, _ lines: [TicketLine], _ c: KitchenCardModel) {
        guard !lines.isEmpty else { return }
        withAnimation(anim) {
            model.kitchen(status, lines: lines, in: c.ticket)
        }
    }

    private func reprint(_ c: KitchenCardModel) {
        model.printKitchen(c.ticket, lines: c.lines, mode: .reprint)
        model.show("已重印 \(c.ticket.title(floor: model.floor)) 的廚房單")
    }

    private func undoBump(_ b: KitchenBump) {
        withAnimation(anim) {
            model.kitchen(.ready, lines: b.lines, in: b.ticket)
            selected = nil
        }
    }

    // MARK: - 資料

    /// 這家店有哪些出單站（菜單上的、這台被指定的）
    private var allStations: [String] {
        var set = Set<String>()
        for c in model.catalog.categories {
            if let s = c.station, !s.isEmpty { set.insert(s) }
        }
        for i in model.catalog.items {
            if let s = i.station, !s.isEmpty { set.insert(s) }
        }
        for s in model.device.stations where !s.isEmpty {
            set.insert(s)
        }
        return set.sorted()
    }

    /// 後廚預設只看後台指定給這台的出單站；出餐口看全部
    private func applyDefaultStations() {
        guard !appliedDefault else { return }
        appliedDefault = true
        switch model.role {
        case .kitchen:
            if !model.device.stations.isEmpty { stations = Set(model.device.stations) }
        case .expo, .register, .handheld, .reception:
            stations = []
        }
    }

    private func toggleStation(_ s: String) {
        var next = stations
        next.formSymmetricDifference([s])
        withAnimation(anim) { stations = next }
    }

    /// 要做、在做、做好等上菜的
    private static func isPending(_ line: TicketLine) -> Bool {
        guard line.isActive else { return false }
        switch line.kitchen {
        case .sent, .preparing, .ready: return true
        case .new, .served: return false
        }
    }

    /// 這一行要不要出現在畫面上（出單站篩選）。菜單有分出單站時，沒有出單站的品項（麵包、提袋）不進廚房
    private func shows(_ line: TicketLine, hasStations: Bool) -> Bool {
        let station = line.station ?? ""
        if stations.isEmpty { return !hasStations || !station.isEmpty }
        return stations.contains(station)
    }

    private func relevantTickets(now: Date) -> [Ticket] { model.kitchenTickets(now: now) }

    private func makeCards(_ tickets: [Ticket], hasStations: Bool) -> [KitchenCardModel] {
        var out: [KitchenCardModel] = []
        for t in tickets {
            let lines = t.lines.filter { Self.isPending($0) && shows($0, hasStations: hasStations) }
            guard !lines.isEmpty else { continue }
            let sorted = lines.sorted { ($0.course, $0.addedAt) < ($1.course, $1.addedAt) }
            let first = lines.compactMap(\.sentAt).min() ?? t.openedAt
            out.append(KitchenCardModel(ticket: t, lines: sorted, firstSent: first))
        }
        // 最久的在最前面
        return out.sorted { $0.firstSent < $1.firstSent }
    }

    /// 各出單站還沒做好的份數（篩選鈕上的數字）
    private func stationCounts(_ tickets: [Ticket]) -> [String: Int] {
        var out: [String: Int] = [:]
        for t in tickets {
            for l in t.lines where Self.isPending(l) && l.kitchen != .ready {
                if let s = l.station, !s.isEmpty { out[s, default: 0] += l.quantity }
            }
        }
        return out
    }

    /// 10 分鐘內收掉、現在還是「已上菜」的（被復原的就不列）：照每一行最後一次改出餐進度的時間（kitchenAt）
    private func makeBumps(now: Date, hasStations: Bool) -> [KitchenBump] {
        let cutoff = now.addingTimeInterval(-10 * 60)
        // 兩小時前就結帳的單不會剛出餐（外帶先結帳也不會等那麼久才出），不用每次掃全部的單
        let closedCutoff = now.addingTimeInterval(-2 * 3600)
        var out: [KitchenBump] = []
        for t in model.state.tickets.values {
            switch t.status {
            case .open: break
            case .closed: if (t.closedAt ?? .distantPast) < closedCutoff { continue }
            case .voided: continue
            }
            var lines: [TicketLine] = []
            var latest = Date.distantPast
            for line in t.lines where line.isActive && line.kitchen == .served && shows(line, hasStations: hasStations) {
                guard let at = line.kitchenAt, at > cutoff else { continue }
                lines.append(line)
                latest = max(latest, at)
            }
            if !lines.isEmpty { out.append(KitchenBump(ticket: t, lines: lines, at: latest)) }
        }
        return out.sorted { $0.at > $1.at }
    }

    // MARK: - 上面

    private func header(cards: [KitchenCardModel], now: Date) -> some View {
        var todo = 0
        var late = 0
        for c in cards {
            todo += c.lines.filter { $0.kitchen != .ready }.reduce(0) { sum, line in sum + line.quantity }
            if KitchenUrgency(minutes: c.minutes(at: now)) == .hot { late += 1 }
        }
        return HStack(alignment: .bottom, spacing: 26) {
            PageTitle(title: "On the *pass*", subtitle: "廚房・出餐")
            Spacer(minLength: 12)
            KitchenStat(value: cards.count, label: "張單", color: Theme.ink)
            KitchenStat(value: todo, label: "份待做", color: Theme.ink)
            if late > 0 {
                KitchenStat(value: late, label: "張超過 20 分", color: Theme.dangerFG)
            }
            Text(now.clockText)
                .font(.brand(34, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
                .accessibilityLabel("現在 \(now.clockText)")
        }
    }

    private func stationBar(_ tickets: [Ticket], hasStations: Bool) -> some View {
        let counts = stationCounts(tickets)
        let total = counts.values.reduce(0, +)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                OptionChip(title: "全部", detail: "\(total)", selected: stations.isEmpty) {
                    withAnimation(anim) { stations = [] }
                }
                ForEach(allStations, id: \.self) { s in
                    OptionChip(title: s, detail: "\(counts[s] ?? 0)", selected: stations.contains(s)) {
                        toggleStation(s)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: 剛出餐（可以復原）

    private func bumpStrip(_ bumps: [KitchenBump], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(anim) { showBumped.toggle() }
            } label: {
                HStack(spacing: 10) {
                    HeroIcon("chevron-right", size: 14)
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(showBumped ? 90 : 0))
                    Eyebrow("剛出餐")
                    Text("\(bumps.count) 張・10 分鐘內的，按錯可以復原")
                        .font(.brand(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showBumped ? .isSelected : [])
            if showBumped {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(bumps) { b in
                            bumpChip(b, now: now)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
            }
        }
    }

    /// 一張剛出餐的：點一下選起來，右欄可以復原
    private func bumpChip(_ b: KitchenBump, now: Date) -> some View {
        let minutes = max(0, Int(now.timeIntervalSince(b.at) / 60))
        let summary = b.lines.map { "\($0.name) ×\($0.quantity)" }.joined(separator: "、")
        let isSelected = selected == .bump(b.id)
        return Button {
            toggle(.bump(b.id))
        } label: {
            bumpChipBody(b, summary: summary, minutes: minutes, selected: isSelected)
        }
        .buttonStyle(PressScale(scale: 0.97))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("點一下選起來，右邊可以復原")
    }

    private func bumpChipBody(_ b: KitchenBump, summary: String, minutes: Int, selected: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(b.ticket.title(floor: model.floor))
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(summary)
                    .font(.brand(13.5, .regular))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(minutes == 0 ? "剛剛" : "\(minutes) 分鐘前")
                    .textRole(.xs)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(12)
        .background(selected ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: Metric.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1)
        }
        .contentShape(.rect)
    }
}

// MARK: - 資料

private struct KitchenCardModel: Identifiable {
    let ticket: Ticket
    /// 要顯示的品項（已經篩過出單站、照道次與加點順序）
    let lines: [TicketLine]
    /// 最早送進廚房的時間（等了多久從這裡算）
    let firstSent: Date

    var id: String { ticket.id }

    func minutes(at now: Date) -> Int { max(0, Int(now.timeIntervalSince(firstSent) / 60)) }

    /// 這張（篩過出單站的）全部做好了
    var allReady: Bool { lines.allSatisfy { $0.kitchen == .ready } }
}

/// 選起來的是哪一張：做的單、或剛出餐的
private enum KitchenPick: Equatable {
    case card(String)
    case bump(String)
}

private struct KitchenBump: Identifiable {
    let ticket: Ticket
    let lines: [TicketLine]
    let at: Date

    var id: String { ticket.id }
}

/// 等多久了：10 分鐘以上變黃、20 分鐘以上變紅
private enum KitchenUrgency: Equatable {
    case calm, warm, hot

    init(minutes: Int) {
        if minutes > 20 {
            self = .hot
        } else if minutes > 10 {
            self = .warm
        } else {
            self = .calm
        }
    }

    var band: Color {
        switch self {
        case .calm: Theme.press
        case .warm: Tone.warning.background
        case .hot: Tone.danger.background
        }
    }

    var text: Color {
        switch self {
        case .calm: Theme.ink
        case .warm: Theme.warningFG
        case .hot: Theme.dangerFG
        }
    }
}

// MARK: - 一張單

private struct KitchenTicketCard: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: KitchenCardModel
    let now: Date
    /// 看「全部」或好幾個出單站時，每一行標出單站
    let showsStation: Bool
    /// 選起來了（動作在右欄）
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
        VStack(spacing: 0) {
            // 點上面（桌號、分鐘）＝選起來；點一行＝那一行換狀態
            Button(action: onSelect) {
                header
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint("點一下選起來，動作在右邊")
            Rule()
            if !card.ticket.note.isEmpty {
                Text("※ 整張單：\(card.ticket.note)")
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.warningFG)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Rule(color: Theme.hair)
            }
            VStack(spacing: 0) {
                ForEach(card.lines) { line in
                    lineRow(line)
                    if line.id != card.lines.last?.id {
                        Rule(color: Theme.hair)
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .background(Theme.surface)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(borderColor, lineWidth: selected ? 3 : (allReady || urgency == .hot ? 2 : 1))
        }
    }

    // MARK: 資料

    private var title: String { card.ticket.title(floor: model.floor) }

    /// 叫號的號碼（外帶結帳時取的）：卡片上面最大的字
    private var queueNumber: Int? {
        card.ticket.orderType == .dineIn ? nil : card.ticket.queueNumber
    }

    private var subtitle: String {
        let t = card.ticket
        var parts: [String] = []
        if queueNumber != nil {
            // 上面已經是號碼：這裡是「外帶・A023・已結帳」
            parts = [t.orderType.label, t.number]
            if t.status == .closed { parts.append("已結帳") }
            return parts.joined(separator: "・")
        }
        if !title.contains(t.number) { parts.append(t.number) }
        if t.orderType == .dineIn && t.guests > 0 { parts.append("\(t.guests) 位") }
        if t.orderType != .dineIn && !title.hasPrefix(t.orderType.label) { parts.append(t.orderType.label) }
        if t.status == .closed { parts.append("已結帳") }
        return parts.joined(separator: "・")
    }

    private var minutes: Int { card.minutes(at: now) }

    private var urgency: KitchenUrgency { KitchenUrgency(minutes: minutes) }

    private var allReady: Bool { card.lines.allSatisfy { $0.kitchen == .ready } }

    private var borderColor: Color {
        if selected { return Theme.accent }
        if allReady { return Theme.successFG }
        switch urgency {
        case .hot: return Theme.dangerFG.opacity(0.7)
        case .warm, .calm: return Theme.line
        }
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.fast }

    // MARK: 上面：桌號、單號、等了幾分鐘

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let q = queueNumber {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(q)")
                            .font(.brand(40, .semibold))
                            .tracking(-1)
                            .monospacedDigit()
                        Text("號")
                            .font(.brand(18, .semibold))
                    }
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(q) 號")
                } else {
                    Text(title)
                        .font(.brand(26, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.brand(14, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 外送平台的單：哪個平台、幾點要好／外送員到了沒（打包時對短碼）
                if let d = card.ticket.delivery {
                    DeliveryHeadline(delivery: d, tagSize: 13, clockSize: 13)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(minutes)")
                        .font(.brand(32, .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(minutes)))
                    Text("分")
                        .font(.brand(15, .medium))
                }
                .foregroundStyle(urgency.text)
                Text("\(card.firstSent.clockText) 送單")
                    .textRole(.xs)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(16)
        .background(urgency.band)
    }

    // MARK: 一行

    private func lineRow(_ line: TicketLine) -> some View {
        Button {
            advance(line)
        } label: {
            // 第一行：份數、品名、狀態；加料、備註、出單站在下一行，用整張卡的寬度（不會被狀態擠到斷在詞中間：「半糖・少／冰」）
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(line.quantity)")
                        .font(.brand(30, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(minWidth: 34, alignment: .trailing)
                    nameRow(line)
                    Spacer(minLength: 8)
                    KitchenStatusPill(status: line.kitchen)
                }
                details(line)
                    .padding(.leading, 34 + 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(line.kitchen == .ready ? Theme.successFG.opacity(0.07) : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .accessibilityLabel("\(line.quantity) 份 \(line.name)，\(KitchenStatusPill.label(line.kitchen))")
        .accessibilityHint("點一下換下一個狀態")
    }

    private func nameRow(_ line: TicketLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.name)
                .font(.brand(21, .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if line.course > 0 {
                Text("第 \(line.course) 道")
                    .font(.brand(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.infoFG)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay { RoundedRectangle(cornerRadius: Metric.chip).strokeBorder(Theme.infoFG.opacity(0.5), lineWidth: 1) }
            }
        }
    }

    @ViewBuilder
    private func details(_ line: TicketLine) -> some View {
        let info = meta(line)
        if !line.modifierText.isEmpty || !line.note.isEmpty || info != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !line.modifierText.isEmpty {
                    Text(line.modifierText)
                        .font(.brand(16, .regular))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !line.note.isEmpty {
                    Text("※ \(line.note)")
                        .font(.brand(16, .semibold))
                        .foregroundStyle(Theme.warningFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let info {
                    Text(info)
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func meta(_ line: TicketLine) -> String? {
        var parts: [String] = []
        if showsStation, let s = line.station, !s.isEmpty { parts.append(s) }
        if let seat = line.seat { parts.append("第 \(seat) 位客人") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    // MARK: 動作

    /// 待做 → 製作中 → 可出餐 → 待做（按錯再點下去就回來了）
    static func next(_ s: KitchenStatus) -> KitchenStatus? {
        switch s {
        case .sent: .preparing
        case .preparing: .ready
        case .ready: .sent
        case .new, .served: nil
        }
    }

    private func advance(_ line: TicketLine) {
        guard let next = Self.next(line.kitchen) else { return }
        model.touch()
        withAnimation(anim) {
            model.kitchen(next, lines: [line], in: card.ticket)
        }
    }

}

/// 一行的狀態：顏色＋字（待做／製作中／可出餐）
private struct KitchenStatusPill: View {
    let status: KitchenStatus

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .ready:
                HeroIcon("check", size: 13)
            case .preparing:
                LiveDot(color: Theme.accent)
            case .new, .sent, .served:
                Circle()
                    .fill(tone.dot)
                    .frame(width: 7, height: 7)
            }
            Text(Self.label(status))
        }
        .font(.brand(14, .semibold))
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tone.background, in: .rect(cornerRadius: Metric.chip))
        .fixedSize()
    }

    /// 廚房的說法（比「已送單」直接）
    static func label(_ s: KitchenStatus) -> String {
        switch s {
        case .sent: "待做"
        case .preparing: "製作中"
        case .ready: "可出餐"
        case .new, .served: s.label
        }
    }

    private var tone: Tone {
        switch status {
        case .sent: .info
        case .preparing: .gold
        case .ready: .active
        case .new, .served: .neutral
        }
    }
}

/// 上面的大數字（6 張單）
private struct KitchenStat: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.brand(30, .medium))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(value)))
            Text(label)
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// 出餐口：整張好了的單。大大的取餐號碼（或桌號）、品項一行、「叫號」與「已出餐」
private struct KitchenExpoCard: View {
    let card: KitchenCardModel
    /// 取餐號碼（櫃台、咖啡的外帶單）；沒有就用單名
    let pickup: String?
    let title: String
    let now: Date
    let calledAt: Date?
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            cardBody
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pickup.map { "\($0) 號" } ?? title)，可以出餐")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("點一下選起來，右邊叫號、出餐")
    }

    private var cardBody: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(pickup ?? title)
                    .font(.brand(pickup == nil ? 34 : 56, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(card.minutes(at: now)) 分")
                        .font(.brand(18, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                    if let calledAt {
                        Text("\(calledAt.clockText) 叫過")
                            .font(.brand(12, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.accentText)
                    }
                }
            }
            if pickup != nil {
                Text(title)
                    .font(.brand(14, .medium))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(card.lines.map { "\($0.name) ×\($0.quantity)" }.joined(separator: "、"))
                .font(.brand(16, .regular))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.successFG.opacity(0.07), in: shape)
        .background(Theme.surface, in: shape)
        .overlay { shape.strokeBorder(selected ? Theme.accent : Theme.successFG, lineWidth: selected ? 3 : 2) }
        .contentShape(shape)
    }
}

extension POSModel {
    /// 廚房看得到的單：還沒結帳的；外帶先結帳後出餐很常見，所以 30 分鐘內結帳的也算（右邊的出餐數字也照這個算）
    func kitchenTickets(now: Date = Date()) -> [Ticket] {
        let cutoff = now.addingTimeInterval(-30 * 60)
        // 外送平台的單接單就結帳了（先付的），外送員拿走之前都還在廚房（最多 3 小時，避免平台沒通知「拿走了」就一直掛著）
        let deliveryCutoff = now.addingTimeInterval(-3 * 3600)
        return state.tickets.values.filter { t in
            switch t.status {
            case .open: return t.delivery?.status != .pending
            case .closed:
                if let d = t.delivery, !d.status.isFinal { return (t.closedAt ?? .distantPast) > deliveryCutoff }
                return (t.closedAt ?? .distantPast) > cutoff
            case .voided: return false
            }
        }
    }
}
