import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 訂位與候位：左邊是今天的訂位（照時間、一小時一組），右邊是現場候位（號碼牌）。
///
///   ┌ Guest book ──────────────────────────────────── ⟳ 14:05  [＋ 新增 ▾] ┐
///   │ ■ 今天的訂位  3 組待到・14 位      │ ■ 現場候位  2 組等待中            │
///   │ 18:00 ┃18:30 林小涵                │  12  張家豪                [入座] │
///   │       ┃4 位・已預約・0912-***-678  │      3 位・等了 18 分             │
///   ├────────────────────────────────────────────────────────────────────────┤
///   │ 選起來的那一筆：林小涵 4 位・已預約     [⋯] [已到]  [入座 ────────]  ✕ │
///   └────────────────────────────────────────────────────────────────────────┘
///
/// 卡片上不放按鈕列：點一下選起來，動作都在下面固定的動作列（候位卡片只留一個「入座」快捷）。
/// 資料在後台（網站、電話訂的也在這裡）：進來先抓一次、之後每分鐘更新。
/// 新增、編輯、選桌入座是從右邊滑出來的面板（不是系統的 sheet：人數、電話要用右側鍵盤打，sheet 會擋住鍵盤）。
struct ReservationsView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var form: ResvFormRequest?
    @State private var seating: Reservation?
    @State private var confirming: ResvStatusRequest?
    /// 選起來的那一筆（動作在下面的動作列）
    @State private var selectedId: String?
    @State private var showFinished = true
    @State private var loadedAt: Date?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            // 每 30 秒重畫：快到了、晚了、等了幾分鐘
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                columns(now: ctx.date)
            }
            if let r = selected {
                ResvSelectionBar(
                    reservation: r,
                    tables: model.floor.tableNames(r.tableIds),
                    primary: primaryAction(r),
                    secondary: secondaryActions(r),
                    more: moreActions(r),
                    onClose: { select(nil) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, selected == nil ? 0 : 16)
        // 選起來的那一筆剛入座：事情做完了，動作列跟著收起來（點已入座的那筆不算）
        .onChange(of: ResvSelectionKey(id: selectedId, status: selected?.status)) { old, new in
            if old.id == new.id && old.status != .seated && new.status == .seated { select(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if panelOpen {
                Theme.page.opacity(0.6)
                    .contentShape(.rect)
                    .onTapGesture { closePanels() }
                    .transition(.opacity)
                    .accessibilityLabel("關閉")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .overlay(alignment: .trailing) { panel }
        .task { await refreshLoop() }
        .alert(confirmTitle, isPresented: confirmBinding, presenting: confirming) { req in
            Button(confirmButton(req), role: .destructive) {
                Task { await model.setStatus(req.status, for: req.reservation) }
            }
            Button("返回", role: .cancel) {}
        } message: { req in
            Text(confirmMessage(req))
        }
    }

    // MARK: - 資料

    private var anim: Animation? { reduceMotion ? nil : Motion.ease }

    private var panelOpen: Bool { form != nil || seating != nil }

    /// 今天（營業日）的訂位，照時間
    private var todaysBookings: [Reservation] {
        let today = model.businessDate
        let cutoff = model.store.businessDayCutoffHour
        return model.reservations
            .filter { $0.kind == .reservation && TaipeiTime.businessDate($0.startsAt, cutoffHour: cutoff) == today }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func reload() async {
        loading = true
        await model.loadReservations()
        loading = false
        loadedAt = Date()
    }

    /// 一小時一組（台北是整點時區，UTC 的整點就是台北的整點）
    private func hourGroups(_ list: [Reservation]) -> [ResvHourGroup] {
        var out: [ResvHourGroup] = []
        for r in list {
            let hour = Date(timeIntervalSince1970: (r.startsAt.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            if let last = out.last, last.id == hour {
                out[out.count - 1].items.append(r)
            } else {
                out.append(ResvHourGroup(id: hour, items: [r]))
            }
        }
        return out
    }

    // MARK: - 動作

    private func openForm(_ kind: ReservationKind, editing r: Reservation? = nil) {
        model.keypad.cancel()
        withAnimation(anim) {
            seating = nil
            form = ResvFormRequest(kind: r?.kind ?? kind, existing: r)
        }
    }

    private func openSeating(_ r: Reservation) {
        model.keypad.cancel()
        withAnimation(anim) {
            form = nil
            seating = r
        }
    }

    private func closePanels() {
        model.keypad.cancel()
        withAnimation(anim) {
            form = nil
            seating = nil
        }
    }

    private func confirm(_ status: ReservationStatus, _ r: Reservation) {
        confirming = ResvStatusRequest(reservation: r, status: status)
    }

    private var selected: Reservation? {
        guard let selectedId else { return nil }
        return model.reservations.first(where: { $0.id == selectedId })
    }

    /// 再點一次同一張就取消選取
    private func select(_ r: Reservation?) {
        withAnimation(reduceMotion ? nil : Motion.fast) {
            selectedId = (r?.id == selectedId) ? nil : r?.id
        }
    }

    private func toggle(_ r: Reservation) { select(r) }

    private func setStatus(_ status: ReservationStatus, _ r: Reservation) {
        Task { await model.setStatus(status, for: r) }
    }

    // MARK: 選起來那一筆的動作（主要「入座」、次要最多兩個、其他收進「⋯」；取消、未到要確認）

    private func primaryAction(_ r: Reservation) -> POSAction? {
        guard r.status.isActive else { return nil }
        return POSAction("入座", icon: "users") { openSeating(r) }
    }

    private func secondaryActions(_ r: Reservation) -> [POSAction] {
        var list: [POSAction] = []
        if r.status.isActive {
            if r.kind == .waitlist {
                if model.features.waitlistSMS {
                    // 有簡訊：傳「您的位子好了」
                    list.append(POSAction(r.status == .notified ? "再通知" : "通知", icon: "bell-alert") {
                        Task { await model.notify(r) }
                    })
                } else if r.status == .booked {
                    // 沒有簡訊：喊號之後記一下，免得重複叫
                    list.append(POSAction("叫號了", icon: "speaker-wave") { setStatus(.notified, r) })
                }
            } else if r.status != .arrived {
                list.append(POSAction("已到", icon: "check") { setStatus(.arrived, r) })
            }
        } else if r.status == .cancelled || r.status == .noShow {
            // 按錯了：改回來
            list.append(POSAction(r.kind == .waitlist ? "改回候位" : "改回已預約", icon: "arrow-uturn-left") {
                setStatus(.booked, r)
            })
        }
        return list
    }

    private func moreActions(_ r: Reservation) -> [POSAction] {
        guard r.status.isActive else { return [] }
        let queued = r.kind == .waitlist
        var list: [POSAction] = []
        if queued && r.status != .arrived {
            list.append(POSAction("已到", icon: "check") { setStatus(.arrived, r) })
        }
        list.append(POSAction("編輯", icon: "pencil-square") { openForm(r.kind, editing: r) })
        list.append(POSAction(queued ? "沒等到（離開了）" : "未到", icon: "no-symbol", destructive: true) { confirm(.noShow, r) })
        list.append(POSAction(queued ? "取消候位" : "取消訂位", icon: "x-circle", destructive: true) { confirm(.cancelled, r) })
        return list
    }

    private var confirmTitle: String {
        guard let c = confirming else { return "" }
        guard c.status == .cancelled else { return "\(c.reservation.name) 沒有來？" }
        return c.reservation.kind == .waitlist ? "取消 \(c.reservation.name) 的候位？" : "取消 \(c.reservation.name) 的訂位？"
    }

    private func confirmButton(_ req: ResvStatusRequest) -> String {
        req.status == .cancelled ? "取消\(req.reservation.kind == .waitlist ? "候位" : "訂位")" : "標示未到"
    }

    private func confirmMessage(_ req: ResvStatusRequest) -> String {
        let r = req.reservation
        if req.status == .cancelled { return "\(r.name) \(r.partySize) 位，取消後桌子會空出來。" }
        return "\(r.name) 沒有來，標示未到（後台會記在客人資料上）。"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            PageTitle(title: "Guest *book*", subtitle: "訂位與候位・\(Date().dayTitle)")
            Spacer(minLength: 12)
            Button {
                Task { await reload() }
            } label: {
                HStack(spacing: 6) {
                    HeroIcon("arrow-path", size: 15)
                        .rotationEffect(.degrees(loading ? 180 : 0))
                        .animation(reduceMotion ? nil : Motion.ease, value: loading)
                    if let loadedAt {
                        Text(loadedAt.clockText)
                            .font(.brand(12.5, .medium))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.press)
            .accessibilityLabel("重新整理")
            // 同一類的新增合成一個：點了選訂位或候位
            Menu {
                Button {
                    openForm(.reservation)
                } label: {
                    Label { Text("訂位") } icon: { Image("hi-calendar-days").renderingMode(.template) }
                }
                Button {
                    openForm(.waitlist)
                } label: {
                    Label { Text("候位（抽號碼）") } icon: { Image("hi-user-group").renderingMode(.template) }
                }
            } label: {
                Label {
                    Text("新增")
                } icon: {
                    HeroIcon("plus", size: 15)
                }
            }
            .menuStyle(.button)
            .menuOrder(.fixed)
            .buttonStyle(.brand(.primary, size: .md))
        }
    }

    // MARK: - 兩欄

    private func columns(now: Date) -> some View {
        HStack(alignment: .top, spacing: 24) {
            bookings(now: now)
                .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
            Rule(vertical: true)
            waitlist(now: now)
                .frame(minWidth: 280, maxWidth: 340, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 今天的訂位

    private func bookings(now: Date) -> some View {
        let all = todaysBookings
        let active = all.filter { $0.status.isActive }
        let visible = showFinished ? all : active
        let groups = hourGroups(visible)
        let guests = active.reduce(0) { sum, r in sum + r.partySize }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow("今天的訂位")
                Text("\(active.count) 組待到・\(guests) 位")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                if all.contains(where: { !$0.status.isActive }) {
                    Button(showFinished ? "隱藏已結束" : "顯示已結束") {
                        withAnimation(anim) { showFinished.toggle() }
                    }
                    .buttonStyle(.brand(.quiet, size: .sm))
                }
            }
            if groups.isEmpty {
                EmptyState(
                    icon: "calendar-days",
                    title: all.isEmpty ? "今天還沒有訂位" : "訂位都處理完了",
                    message: all.isEmpty ? "網站、電話的訂位會自動出現在這裡；也可以按右上角「＋ 新增」。" : "已入座、取消、未到的按「顯示已結束」看。"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(groups) { g in
                            hourBlock(g, now: now)
                        }
                    }
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func hourBlock(_ g: ResvHourGroup, now: Date) -> some View {
        let current = now >= g.id && now < g.id.addingTimeInterval(3600)
        let seats = g.items.filter { $0.status.isActive }.reduce(0) { sum, r in sum + r.partySize }
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(g.id.clockText)
                    .font(.brand(22, .medium))
                    .monospacedDigit()
                    .foregroundStyle(current ? Theme.ink : Theme.muted)
                Text("\(seats) 位")
                    .textRole(.xs)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .frame(width: 62, alignment: .leading)
            VStack(spacing: 10) {
                ForEach(g.items) { r in
                    ResvBookingRow(
                        reservation: r,
                        now: now,
                        selected: r.id == selectedId,
                        onSelect: { toggle(r) }
                    )
                }
            }
        }
    }

    // MARK: 現場候位

    private func waitlist(now: Date) -> some View {
        let all = model.reservations.filter { $0.kind == .waitlist }
        let waiting = all.filter { $0.status.isActive }.sorted(by: Self.queueOrder)
        let done = Array(all.filter { !$0.status.isActive }.sorted { $0.startsAt > $1.startsAt }.prefix(8))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow("現場候位")
                Text("\(waiting.count) 組等待中")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            if waiting.isEmpty && done.isEmpty {
                EmptyState(icon: "user-group", title: "沒有人在候位", message: "客人到了沒位子，按右上角「＋ 新增」→「候位」抽號碼。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if waiting.isEmpty {
                            Text("現在沒有人在等")
                                .textRole(.small)
                                .foregroundStyle(Theme.muted)
                                .padding(.vertical, 18)
                        }
                        ForEach(waiting) { r in
                            ResvWaitCard(
                                reservation: r,
                                now: now,
                                selected: r.id == selectedId,
                                onSelect: { toggle(r) },
                                onSeat: { openSeating(r) }
                            )
                        }
                        if !done.isEmpty {
                            Eyebrow("今天叫過的")
                                .padding(.top, 16)
                            VStack(spacing: 0) {
                                ForEach(done) { r in
                                    ResvDoneRow(reservation: r, selected: r.id == selectedId, onSelect: { toggle(r) })
                                    Rule(color: Theme.hair)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// 候位照號碼（沒有號碼的排後面），同號照抽號時間
    private static func queueOrder(_ a: Reservation, _ b: Reservation) -> Bool {
        let qa = a.queueNumber ?? Int.max
        let qb = b.queueNumber ?? Int.max
        if qa != qb { return qa < qb }
        return a.startsAt < b.startsAt
    }

    // MARK: - 右邊滑出來的面板

    @ViewBuilder
    private var panel: some View {
        if let f = form {
            ResvFormPanel(request: f, onClose: { closePanels() })
                .id(f.id)
                .modifier(ResvPanelChrome())
                .transition(.move(edge: .trailing))
        } else if let r = seating {
            ResvSeatPanel(reservation: r, onClose: { closePanels() })
                .id(r.id)
                .modifier(ResvPanelChrome())
                .transition(.move(edge: .trailing))
        }
    }
}

// MARK: - 資料

private struct ResvFormRequest: Identifiable {
    let id = UUID()
    var kind: ReservationKind
    var existing: Reservation?
}

private struct ResvStatusRequest: Identifiable {
    let reservation: Reservation
    let status: ReservationStatus
    var id: String { reservation.id + status.rawValue }
}

/// 選取的是哪一筆、狀態是什麼（用來看「剛入座」）
private struct ResvSelectionKey: Equatable {
    let id: String?
    let status: ReservationStatus?
}

private struct ResvHourGroup: Identifiable {
    let id: Date
    var items: [Reservation]
}

/// 狀態的顏色（一定配字）
private func resvTone(_ s: ReservationStatus) -> Tone {
    switch s {
    case .booked: .info
    case .notified: .gold
    case .arrived: .active
    case .seated: .neutral
    case .cancelled: .neutral
    case .noShow: .danger
    }
}

/// 訂位從哪裡來
private func resvSourceLabel(_ s: String) -> String {
    switch s {
    case "web": "網站"
    case "phone": "電話"
    case "pos": "現場"
    case "admin": "後台"
    default: s
    }
}

/// 0912-***-678（清單上不露完整電話；編輯時才看得到）
private func resvMaskedPhone(_ phone: String) -> String {
    phone.isEmpty ? "沒留電話" : MemberRef(phone: phone).maskedPhone
}

/// 0912 345 678
private func resvGroupedPhone(_ d: String) -> String {
    guard d.count == 10 else { return d }
    return "\(d.prefix(4)) \(d.dropFirst(4).prefix(3)) \(d.suffix(3))"
}

// MARK: - 一筆訂位

/// 卡片的外框：選起來是墨色粗框
private struct ResvCardChrome: ViewModifier {
    let selected: Bool
    let highlight: Bool

    func body(content: Content) -> some View {
        content
            .background(highlight ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: Metric.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(selected ? Theme.ink : (highlight ? Theme.accent.opacity(0.45) : Theme.line), lineWidth: selected ? 2 : 1)
            }
    }
}

/// 一筆訂位：整張可以點（選起來），卡片上沒有按鈕
private struct ResvBookingRow: View {
    @Environment(POSModel.self) private var model
    let reservation: Reservation
    let now: Date
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        let r = reservation
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 14) {
                // 左邊的色條：快到了是品牌橘、晚了是黃
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    titleRow
                    meta
                    if !r.note.isEmpty {
                        Text("※ \(r.note)")
                            .textRole(.small)
                            .foregroundStyle(Theme.warningFG)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .modifier(ResvCardChrome(selected: selected, highlight: soon))
            .opacity(r.status.isActive || selected ? 1 : 0.55)
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("點一下選起來，動作在下面")
    }

    /// 前後 15～30 分鐘內要到的
    private var soon: Bool {
        let r = reservation
        return r.status.isActive && r.startsAt > now.addingTimeInterval(-15 * 60) && r.startsAt <= now.addingTimeInterval(30 * 60)
    }

    private var lateMinutes: Int? {
        let r = reservation
        guard r.status == .booked || r.status == .notified else { return nil }
        let m = Int(now.timeIntervalSince(r.startsAt) / 60)
        return m > 15 ? m : nil
    }

    private var barColor: Color {
        if soon { return Theme.accent }
        if lateMinutes != nil { return Theme.warningFG }
        return reservation.status.isActive ? Theme.line : Color.clear
    }

    /// 時間＋名字一行（名字太長就換行，不截斷）；人數、狀態放到下一行
    private var titleRow: some View {
        let r = reservation
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(r.startsAt.clockText)
                .font(.brand(17, .semibold))
                .monospacedDigit()
                .foregroundStyle(soon ? Theme.accentText : Theme.ink)
                .fixedSize()
            Text(r.name)
                .font(.brand(18, .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var meta: some View {
        let r = reservation
        let tables = model.floor.tableNames(r.tableIds)
        return FlowLayout(spacing: 10, rowSpacing: 6) {
            Text("\(r.partySize) 位")
                .font(.brand(14, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
            StatusBadge(r.status.label, tone: resvTone(r.status))
            if soon {
                StatusBadge("快到了", tone: .gold)
            } else if let late = lateMinutes {
                StatusBadge("晚了 \(late) 分", tone: .warning)
            }
            ResvMeta(icon: "phone", text: resvMaskedPhone(r.phone))
            ResvMeta(icon: "table-cells", text: tables.isEmpty ? "未排桌" : tables)
            ResvMeta(icon: "clock", text: "\(r.durationMinutes) 分")
            ResvSourceTag(source: r.source)
        }
    }
}

// MARK: - 一組候位

/// 一組候位：整張可以點（選起來）；只留一個「入座」快捷（最常用的那一步）
private struct ResvWaitCard: View {
    let reservation: Reservation
    let now: Date
    let selected: Bool
    let onSelect: () -> Void
    let onSeat: () -> Void

    var body: some View {
        let r = reservation
        HStack(alignment: .top, spacing: 14) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Text("號")
                            .textRole(.xs)
                            .foregroundStyle(Theme.muted)
                        Text(r.queueNumber.map { String($0) } ?? "—")
                            .font(.brand(40, .medium))
                            .monospacedDigit()
                            .foregroundStyle(r.status == .notified ? Theme.accentText : Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 56)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(r.name)
                            .font(.brand(18, .medium))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        FlowLayout(spacing: 10, rowSpacing: 6) {
                            Text("\(r.partySize) 位")
                                .font(.brand(14, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink2)
                            StatusBadge(r.status.label, tone: resvTone(r.status))
                            HStack(spacing: 5) {
                                HeroIcon("clock", size: 13)
                                Text("等了 \(waited) 分")
                                    .monospacedDigit()
                            }
                            .font(.brand(13, .medium))
                            .foregroundStyle(waited >= 20 ? Theme.warningFG : Theme.muted)
                            ResvMeta(icon: "phone", text: resvMaskedPhone(r.phone))
                            if let at = r.notifiedAt {
                                ResvMeta(icon: "bell-alert", text: "\(at.clockText) 叫過")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.press)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint("點一下選起來，其他動作在下面")
            if r.status.isActive {
                // 唯一的快捷：有位子了直接帶進去
                Button(action: onSeat) {
                    Label {
                        Text("入座")
                    } icon: {
                        HeroIcon("users", size: 14)
                    }
                }
                .buttonStyle(.brand(.ghost, size: .sm))
                .fixedSize()
            }
        }
        .padding(14)
        .modifier(ResvCardChrome(selected: selected, highlight: false))
        .overlay {
            if r.status == .notified && !selected {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
            }
        }
    }

    private var waited: Int { max(0, Int(now.timeIntervalSince(reservation.startsAt) / 60)) }
}

/// 叫過的候位（入座、取消、離開）：一行，點了選起來（按錯可以在下面改回來）
private struct ResvDoneRow: View {
    let reservation: Reservation
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        let r = reservation
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text(r.queueNumber.map { "#\($0)" } ?? "—")
                    .font(.brand(14, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .frame(width: 40, alignment: .leading)
                Text(r.name)
                    .font(.brand(14.5, .medium))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(r.partySize) 位")
                    .font(.brand(13, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                StatusBadge(r.status.label, tone: resvTone(r.status))
                    .fixedSize()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(selected ? Theme.press : Color.clear, in: .rect(cornerRadius: Metric.radiusSm))
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 選起來那一筆的動作列（固定在下面）

private struct ResvSelectionBar: View {
    let reservation: Reservation
    let tables: String
    let primary: POSAction?
    let secondary: [POSAction]
    let more: [POSAction]
    let onClose: () -> Void

    var body: some View {
        let r = reservation
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name)
                    .font(.brand(20, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                FlowLayout(spacing: 10, rowSpacing: 4) {
                    Text(summary)
                        .font(.brand(14, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                    StatusBadge(r.status.label, tone: resvTone(r.status))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if primary != nil || !secondary.isEmpty || !more.isEmpty {
                ActionBar(primary: primary, secondary: secondary, more: more, size: .lg, fillPrimary: false)
                    .fixedSize()
            } else {
                Text(r.status == .seated ? "已入座" : "沒有可以做的動作")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            Button(action: onClose) {
                HeroIcon("x-mark", size: 15)
            }
            .buttonStyle(SquareIconButtonStyle(size: 40))
            .accessibilityLabel("取消選取")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.dock, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: -4)
    }

    /// 訂位：18:30・4 位・A4；候位：12 號・3 位
    private var summary: String {
        let r = reservation
        var parts: [String] = []
        if r.kind == .waitlist {
            if let n = r.queueNumber { parts.append("\(n) 號") }
        } else {
            parts.append(r.startsAt.clockText)
        }
        parts.append("\(r.partySize) 位")
        if !tables.isEmpty { parts.append(tables) }
        return parts.joined(separator: "・")
    }
}

/// 圖示＋一小段字（電話、桌號、時間）
private struct ResvMeta: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            HeroIcon(icon, size: 13)
            Text(text)
                .monospacedDigit()
                .fixedSize()
        }
        .font(.brand(13, .medium))
        .foregroundStyle(Theme.muted)
    }
}

/// 來源（網站／電話／現場／後台）：細框小字
private struct ResvSourceTag: View {
    let source: String

    var body: some View {
        Text(resvSourceLabel(source))
            .font(.brand(11.5, .medium))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { RoundedRectangle(cornerRadius: Metric.chip).strokeBorder(Theme.line, lineWidth: 1) }
    }
}

// MARK: - 面板的外框

/// 右邊滑出來的面板：貼著右側鍵盤（人數、電話打在旁邊的鍵盤上）
private struct ResvPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: 440)
            .frame(maxHeight: .infinity)
            .background(Theme.dock)
            .overlay(alignment: .leading) { Rule(vertical: true) }
            .shadow(color: .black.opacity(0.18), radius: 24, x: -8)
    }
}

/// 面板上方：小標＋大標＋關閉
private struct ResvPanelHeader: View {
    let eyebrow: String
    let title: String
    var detail: String? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(eyebrow)
                Headline(title, role: .h3)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail)
                        .textRole(.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                HeroIcon("x-mark", size: 16)
            }
            .buttonStyle(SquareIconButtonStyle(size: 38))
            .accessibilityLabel("關閉")
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

// MARK: - 新增／編輯

/// 右側鍵盤正在問哪一欄（那一欄框成橘色）
private enum ResvField: Equatable {
    case party, phone
}

private struct ResvFormPanel: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: ResvFormRequest
    let onClose: () -> Void

    @State private var kind: ReservationKind
    @State private var name: String
    @State private var phone: String
    @State private var partySize: Int
    @State private var day: Date
    /// 一天中的第幾分鐘（台北時間；15 分鐘一格）
    @State private var minutes: Int
    @State private var duration: Int
    @State private var tables: Set<String>
    @State private var note: String
    @State private var asking: ResvField? = nil
    @State private var saving = false
    @State private var problem: String? = nil
    @FocusState private var nameFocused: Bool

    init(request: ResvFormRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        let r = request.existing
        let start = r?.startsAt ?? Self.defaultStart()
        _kind = State(initialValue: r?.kind ?? request.kind)
        _name = State(initialValue: r?.name ?? "")
        _phone = State(initialValue: r?.phone ?? "")
        _partySize = State(initialValue: r?.partySize ?? 2)
        _day = State(initialValue: Calendar.taipei.startOfDay(for: start))
        _minutes = State(initialValue: Self.minuteOfDay(start))
        _duration = State(initialValue: r?.durationMinutes ?? 90)
        _tables = State(initialValue: Set(r?.tableIds ?? []))
        _note = State(initialValue: r?.note ?? "")
    }

    /// 至少半小時後、對齊 15 分鐘（電話訂位通常是晚一點的時段）
    static func defaultStart() -> Date {
        let now = Date()
        let m = minuteOfDay(now) + 30
        let slot = ((m + 14) / 15) * 15
        return Calendar.taipei.startOfDay(for: now).addingTimeInterval(Double(slot) * 60)
    }

    static func minuteOfDay(_ d: Date) -> Int {
        let c = Calendar.taipei.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private var isNew: Bool { request.existing == nil }

    private var startsAt: Date {
        Calendar.taipei.startOfDay(for: day).addingTimeInterval(Double(minutes) * 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            ResvPanelHeader(eyebrow: eyebrow, title: headline, onClose: onClose)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if isNew {
                        kindPicker
                    }
                    nameField
                    HStack(spacing: 12) {
                        ResvKeypadField(label: "人數", value: "\(partySize) 位", placeholder: false, active: asking == .party) {
                            Task { await askParty() }
                        }
                        ResvKeypadField(label: "電話", value: phone.isEmpty ? "點一下輸入" : resvGroupedPhone(phone), placeholder: phone.isEmpty, active: asking == .phone) {
                            Task { await askPhone() }
                        }
                    }
                    if kind == .reservation {
                        timeFields
                        durationField
                        if !model.floor.allTables.isEmpty {
                            tableField
                        }
                        noteField
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            Rule()
            bottomBar
        }
        .task {
            // 新的一筆：直接從稱呼開始打（打完按 return 接著問人數、電話）
            guard isNew else { return }
            try? await Task.sleep(for: .milliseconds(350))
            nameFocused = true
        }
    }

    private var eyebrow: String {
        kind == .waitlist ? "現場候位" : "訂位"
    }

    private var headline: String {
        if !isNew { return kind == .waitlist ? "Edit *guest*" : "Edit *booking*" }
        return kind == .waitlist ? "New *guest*" : "New *booking*"
    }

    // MARK: 欄位

    private var kindPicker: some View {
        HStack(spacing: 8) {
            Button("訂位") {
                withAnimation(reduceMotion ? nil : Motion.fast) { kind = .reservation }
            }
            .buttonStyle(.choice(kind == .reservation, height: 44))
            Button("現場候位") {
                withAnimation(reduceMotion ? nil : Motion.fast) { kind = .waitlist }
            }
            .buttonStyle(.choice(kind == .waitlist, height: 44))
        }
    }

    private var nameField: some View {
        ResvFormRow(label: "稱呼") {
            TextField("王小姐", text: $name)
                .font(.brand(18, .medium))
                .focused($nameFocused)
                .submitLabel(.next)
                .autocorrectionDisabled()
                .onSubmit { Task { await afterName() } }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                        .strokeBorder(nameFocused ? Theme.accent : Theme.line, lineWidth: nameFocused ? 1.5 : 1)
                }
        }
    }

    private var timeFields: some View {
        ResvFormRow(label: "日期與時間") {
            HStack(spacing: 12) {
                DatePicker("日期", selection: $day, in: Calendar.taipei.startOfDay(for: Date())..., displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    Button {
                        step(-15)
                    } label: {
                        HeroIcon("minus", size: 15)
                            .frame(width: 46, height: 48)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("早 15 分鐘")
                    Text(clockString)
                        .font(.brand(22, .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 72)
                    Button {
                        step(15)
                    } label: {
                        HeroIcon("plus", size: 15)
                            .frame(width: 46, height: 48)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("晚 15 分鐘")
                }
                .buttonStyle(PressScale(scale: 0.94))
                .foregroundStyle(Theme.ink)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
            }
        }
    }

    private var clockString: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private func step(_ delta: Int) {
        withAnimation(reduceMotion ? nil : Motion.fast) {
            minutes = min(max(minutes + delta, 0), 23 * 60 + 45)
        }
    }

    private var durationField: some View {
        ResvFormRow(label: "用餐時間") {
            HStack(spacing: 8) {
                ForEach([60, 90, 120], id: \.self) { m in
                    Button("\(m) 分") { duration = m }
                        .buttonStyle(.choice(duration == m, height: 44))
                }
            }
        }
    }

    private var tableField: some View {
        ResvFormRow(label: tables.isEmpty ? "桌位（可以先不排）" : "桌位・\(model.floor.tableNames(orderedTables))") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.floor.areas) { area in
                    if !area.tables.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(area.name)
                                .textRole(.xs)
                                .foregroundStyle(Theme.muted)
                            FlowLayout(spacing: 8, rowSpacing: 8) {
                                ForEach(area.tables) { t in
                                    OptionChip(title: t.name, detail: "\(t.seats)人", selected: tables.contains(t.id)) {
                                        toggleTable(t.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var noteField: some View {
        ResvFormRow(label: "備註") {
            TextField("過敏、慶生、嬰兒椅…", text: $note, axis: .vertical)
                .font(.brand(16, .regular))
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
        }
    }

    private func toggleTable(_ id: String) {
        tables.formSymmetricDifference([id])
    }

    private var orderedTables: [String] {
        model.floor.allTables.map(\.id).filter { tables.contains($0) }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let problem {
                Text(problem)
                    .textRole(.small)
                    .foregroundStyle(Theme.dangerFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("取消") { onClose() }
                .buttonStyle(.brand(.ghost, size: .lg))
            Button {
                save()
            } label: {
                Text(saving ? "儲存中…" : saveTitle)
            }
            .buttonStyle(.brand(.accent, size: .lg, arrow: true))
            .disabled(saving)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var saveTitle: String {
        if !isNew { return "儲存" }
        return kind == .waitlist ? "抽號碼" : "建立訂位"
    }

    // MARK: 右側鍵盤

    @discardableResult
    private func askParty() async -> Bool {
        nameFocused = false
        asking = .party
        var spec = KeypadSpec.partySize()
        spec.subtitle = name.isEmpty ? nil : name
        spec.initial = String(partySize)
        let n = await model.keypad.askNumber(spec)
        if asking == .party { asking = nil }
        guard let n else { return false }
        partySize = n
        problem = nil
        return true
    }

    private func askPhone() async {
        nameFocused = false
        asking = .phone
        var spec = KeypadSpec.phone
        spec.title = "電話"
        spec.subtitle = kind == .waitlist ? "叫號時傳簡訊用（可以按 × 跳過）" : "有事聯絡用"
        spec.initial = phone
        spec.confirmLabel = "確定"
        let entry = await model.keypad.ask(spec)
        if asking == .phone { asking = nil }
        if let entry { phone = entry.digits }
    }

    /// 稱呼打完按 return：接著問人數、再問電話（新的一筆才這樣串）
    private func afterName() async {
        guard isNew else { return }
        guard await askParty() else { return }
        if phone.isEmpty { await askPhone() }
    }

    // MARK: 存

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            problem = "請填稱呼"
            nameFocused = true
            return
        }
        guard !saving else { return }
        model.keypad.cancel()
        asking = nil
        problem = nil
        saving = true

        let existing = request.existing
        let isWait = kind == .waitlist
        // 候位：抽號碼的時間就是現在（編輯時不動）
        let start: Date?
        if isWait {
            start = existing == nil ? Date() : nil
        } else {
            start = startsAt
        }
        let input = ReservationInput(
            kind: existing == nil ? kind : nil,
            name: trimmed,
            phone: phone,
            partySize: partySize,
            startsAt: start,
            durationMinutes: isWait ? nil : duration,
            tableIds: isWait ? nil : orderedTables,
            status: nil,
            note: isWait ? nil : note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            let saved = await model.saveReservation(id: existing?.id, input)
            saving = false
            guard let saved else { return }
            model.show(doneMessage(saved))
            onClose()
        }
    }

    private func doneMessage(_ r: Reservation) -> String {
        let isWait = r.kind == .waitlist
        if !isNew { return "已更新 \(r.name) 的\(isWait ? "候位" : "訂位")" }
        if isWait {
            // 號碼是後台給的
            if let n = r.queueNumber { return "候位 \(n) 號・\(r.name) \(r.partySize) 位" }
            return "已抽號碼・\(r.name) \(r.partySize) 位"
        }
        return "已訂 \(r.startsAt.shortText)・\(r.name) \(r.partySize) 位"
    }
}

/// 表單的一欄：小字標題＋內容
private struct ResvFormRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .textRole(.label)
                .foregroundStyle(Theme.muted)
            content
        }
    }
}

/// 要用右側鍵盤打的欄位（人數、電話）：點了右邊鍵盤換成這一題，這一格框成橘色
private struct ResvKeypadField: View {
    let label: String
    let value: String
    let placeholder: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(label)
                        .textRole(.label)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    HeroIcon("calculator", size: 13)
                        .foregroundStyle(active ? Theme.accent : Theme.faint)
                }
                Text(value)
                    .font(.brand(placeholder ? 15 : 20, .medium))
                    .monospacedDigit()
                    .foregroundStyle(placeholder ? Theme.muted : Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(active ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: Metric.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(active ? Theme.accent : Theme.line, lineWidth: active ? 1.5 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityLabel("\(label)：\(value)")
        .accessibilityHint("用右邊的數字鍵盤輸入")
    }
}

// MARK: - 入座：選桌

private struct ResvSeatPanel: View {
    @Environment(POSModel.self) private var model
    let reservation: Reservation
    let onClose: () -> Void

    @State private var selected: Set<String> = []

    var body: some View {
        let r = reservation
        VStack(spacing: 0) {
            ResvPanelHeader(eyebrow: "入座", title: r.name, detail: detail, onClose: onClose)
            Rule()
            if model.floor.allTables.isEmpty {
                EmptyState(icon: "table-cells", title: "沒有桌位圖", message: "直接開一張內用單，帶 \(r.partySize) 位、稱呼 \(r.name)。")
            } else if freeTables.isEmpty {
                EmptyState(icon: "table-cells", title: "現在沒有空桌", message: "先清桌，或請客人稍等一下。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(model.floor.areas) { area in
                            let free = area.tables.filter { isFree($0) }
                            if !free.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(area.name)
                                        .textRole(.xs)
                                        .foregroundStyle(Theme.muted)
                                    FlowLayout(spacing: 8, rowSpacing: 8) {
                                        ForEach(free) { t in
                                            OptionChip(title: t.name, detail: chipDetail(t), selected: selected.contains(t.id)) {
                                                toggle(t.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Text("只列出空桌（和這筆訂位排好的桌子）。人多可以選好幾張併在一起。")
                            .textRole(.xs)
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(22)
                }
                .scrollIndicators(.hidden)
            }
            Rule()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedNames)
                        .font(.brand(16, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(seatsNote)
                        .textRole(.xs)
                        .monospacedDigit()
                        .foregroundStyle(seatsShort ? Theme.warningFG : Theme.muted)
                }
                Spacer(minLength: 8)
                Button {
                    seat()
                } label: {
                    Text("入座、開單")
                }
                .buttonStyle(.brand(.accent, size: .lg, arrow: true))
                .disabled(!canSeat)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .onAppear {
            // 訂位排好的桌子如果空著，先幫忙選起來
            selected = Set(reservation.tableIds.filter { id in
                guard let t = model.floor.table(id) else { return false }
                return isFree(t)
            })
        }
    }

    private var detail: String {
        let r = reservation
        if r.kind == .waitlist {
            let number = r.queueNumber.map { String($0) } ?? "—"
            return "\(r.partySize) 位・候位 \(number) 號"
        }
        return "\(r.partySize) 位・\(r.startsAt.clockText) 訂位"
    }

    /// 空桌；或這筆訂位自己排的桌（它被標成「已預約」）
    private func isFree(_ t: DiningTable) -> Bool {
        let s = model.tableStatus(t.id)
        return s == .available || (s == .reserved && reservation.tableIds.contains(t.id))
    }

    private var freeTables: [DiningTable] { model.floor.allTables.filter { isFree($0) } }

    private func chipDetail(_ t: DiningTable) -> String {
        reservation.tableIds.contains(t.id) ? "\(t.seats)人・訂的" : "\(t.seats)人"
    }

    private func toggle(_ id: String) {
        selected.formSymmetricDifference([id])
    }

    private var orderedSelection: [String] {
        model.floor.allTables.map(\.id).filter { selected.contains($0) }
    }

    private var seatsTotal: Int {
        model.floor.allTables.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.seats }
    }

    private var seatsShort: Bool { !selected.isEmpty && seatsTotal < reservation.partySize }

    private var selectedNames: String {
        if model.floor.allTables.isEmpty { return "不排桌" }
        return selected.isEmpty ? "選一張桌子" : model.floor.tableNames(orderedSelection)
    }

    private var seatsNote: String {
        if selected.isEmpty { return "\(reservation.partySize) 位" }
        return seatsShort ? "\(seatsTotal) 個座位，坐 \(reservation.partySize) 位會擠" : "\(seatsTotal) 個座位・\(reservation.partySize) 位"
    }

    private var canSeat: Bool { model.floor.allTables.isEmpty || !selected.isEmpty }

    private func seat() {
        let r = reservation
        let ids = orderedSelection
        onClose()
        Task { await model.seat(r, at: ids) }
    }
}
