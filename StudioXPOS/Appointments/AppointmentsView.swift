import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 預約表（美業的設計師、私人教練）：一位服務人員一欄、一格是後台設的分鐘數，現在的時間是一條紅線。
///
///   ┌ Day book ─────────────────── ‹ 今天 10月4日 › [現場客] [新預約] ┐
///   │ 預約 8・已到 1・服務中 2                         顯示取消、未到 │
///   │        │ ⓛ Leslie 總監 ▇▇▇▁ 62% │ ⓙ Jacob ▇▁▁ 30% │ 不指定      │
///   │ 10:00  │ ┌ 10:00–11:30 ─────┐   │                 │             │
///   │ ───────│ │ 林小涵  剪髮・染髮 │   │ ┌ 10:30 王先生 ┐ │             │
///   │ 11:00 ━━━━━━━━━━━━━━━━━━━━━━━━ 現在                               │
///   └──────────────────────────────────────────────────────────────────┘
///
/// 點空格＝新預約（右邊滑出面板；電話、時間長度都用右側鍵盤打，所以不是 sheet）。
/// 點預約＝旁邊跳出卡片：到店、開始服務（開單、帶入服務與設計師）、去結帳、改時間、未到、取消。
struct AppointmentsView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 看哪一天（台北時間的 00:00）
    @State private var day = Calendar.taipei.startOfDay(for: Date())
    @State private var selectedId: String?
    @State private var showInactive = false
    @State private var form: ApptFormRequest?
    @State private var confirming: ApptStatusRequest?
    @State private var cardSize = CGSize(width: 300, height: 360)

    /// 一分鐘幾點高（一小時 96 點：15 分鐘一格 24 點，手指點得到）
    fileprivate static let ppm: CGFloat = 1.6
    private static let gutter: CGFloat = 58
    private static let headerHeight: CGFloat = 66
    private static let cardWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summary
            board
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if form != nil {
                Theme.page.opacity(0.6)
                    .contentShape(.rect)
                    .onTapGesture { closeForm() }
                    .transition(.opacity)
                    .accessibilityLabel("關閉")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .overlay(alignment: .trailing) { formPanel }
        .task(id: dayKey) { await refreshLoop() }
        .alert(confirmTitle, isPresented: confirmBinding, presenting: confirming) { req in
            Button(req.status == .cancelled ? "取消預約" : "標示未到", role: .destructive) {
                Task { await model.setStatus(req.status, for: req.reservation) }
                selectedId = nil
            }
            Button("返回", role: .cancel) {}
        } message: { req in
            Text(confirmMessage(req))
        }
    }

    // MARK: - 資料

    private var anim: Animation? { reduceMotion ? nil : Motion.ease }

    private var dayKey: String { TaipeiTime.dayString(day) }

    private var isToday: Bool { dayKey == TaipeiTime.dayString(Date()) }

    private var slot: Int { max(model.store.bookingSlotMinutes, 5) }

    private var columns: [ApptColumn] {
        model.bookableStaff.map { ApptColumn(id: $0.id, staff: $0) } + [ApptColumn(id: ApptColumn.unassigned, staff: nil)]
    }

    /// 這一天的預約（取消、未到的照開關）
    private var dayAppointments: [Reservation] {
        model.appointments(onDay: dayKey).filter { r in
            showInactive || (r.status != .cancelled && r.status != .noShow)
        }
    }

    /// 預約排在哪一欄（指定的人不在預約表上就放「不指定」）
    private func columnId(for r: Reservation) -> String {
        guard let s = r.staffId, model.bookableStaff.contains(where: { $0.id == s }) else { return ApptColumn.unassigned }
        return s
    }

    /// 從當天 00:00 算起第幾分鐘
    private func minuteOfDay(_ d: Date) -> Int { Int(d.timeIntervalSince(day) / 60) }

    /// 表從幾點到幾點：09:00–22:00，有預約在外面就撐開
    private func hours(_ list: [Reservation]) -> ApptHours {
        var start = 9
        var end = 22
        for r in list {
            start = min(start, max(minuteOfDay(r.startsAt) / 60, 0))
            end = max(end, min(Int((Double(minuteOfDay(r.endsAt)) / 60).rounded(.up)), 24))
        }
        return ApptHours(start: start, end: max(end, start + 1))
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await model.loadReservations(for: dayKey)
            try? await Task.sleep(for: .seconds(60))
        }
    }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            PageTitle(title: "Day *book*", subtitle: "預約表・\(model.mode.staffTitle)")
            Spacer(minLength: 12)
            daySwitcher
            Button {
                Task {
                    if await model.walkIn() != nil { model.go(.order) }
                }
            } label: {
                Label {
                    Text("現場客")
                } icon: {
                    HeroIcon("user", size: 15)
                }
            }
            .buttonStyle(.brand(.ghost, size: .md))
            Button {
                openNew(staffId: nil, start: defaultStart())
            } label: {
                Label {
                    Text("新預約")
                } icon: {
                    HeroIcon("plus", size: 15)
                }
            }
            .buttonStyle(.brand(.primary, size: .md))
        }
    }

    private var daySwitcher: some View {
        HStack(spacing: 4) {
            Button {
                shiftDay(-1)
            } label: {
                HeroIcon("chevron-right", size: 15)
                    .rotationEffect(.degrees(180))
            }
            .buttonStyle(SquareIconButtonStyle(size: 40))
            .accessibilityLabel("前一天")
            Button {
                withAnimation(anim) {
                    day = Calendar.taipei.startOfDay(for: Date())
                    selectedId = nil
                }
            } label: {
                VStack(spacing: 1) {
                    Text(isToday ? "今天" : day.weekdayText)
                        .font(.brand(15, .semibold))
                        .foregroundStyle(isToday ? Theme.accentText : Theme.ink)
                    Text(day.dayTitle)
                        .font(.brand(11.5, .medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .frame(minWidth: 112, minHeight: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.press)
            .accessibilityLabel(isToday ? "今天" : day.dayTitle)
            .accessibilityHint("回到今天")
            Button {
                shiftDay(1)
            } label: {
                HeroIcon("chevron-right", size: 15)
            }
            .buttonStyle(SquareIconButtonStyle(size: 40))
            .accessibilityLabel("後一天")
        }
    }

    private func shiftDay(_ delta: Int) {
        let next = Calendar.taipei.date(byAdding: .day, value: delta, to: day) ?? day.addingTimeInterval(Double(delta) * 86_400)
        withAnimation(anim) {
            day = Calendar.taipei.startOfDay(for: next)
            selectedId = nil
        }
    }

    private var summary: some View {
        let all = model.appointments(onDay: dayKey)
        let live = all.filter { $0.status != .cancelled && $0.status != .noShow }
        let arrived = all.filter { $0.status == .arrived }.count
        let serving = all.filter { $0.status == .seated && model.openTicket(for: $0) != nil }.count
        let hidden = all.count - live.count
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            ApptCount(label: "預約", value: live.count, color: Theme.ink)
            ApptCount(label: "已到", value: arrived, color: Theme.accentText)
            ApptCount(label: "服務中", value: serving, color: Theme.successFG)
            Spacer(minLength: 8)
            if hidden > 0 || showInactive {
                Button(showInactive ? "隱藏取消、未到" : "顯示取消、未到 \(hidden)") {
                    withAnimation(anim) { showInactive.toggle() }
                }
                .buttonStyle(.brand(.quiet, size: .sm))
            }
        }
    }

    // MARK: - 預約表

    private var board: some View {
        // 每分鐘重畫：現在的紅線、晚到
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            GeometryReader { geo in
                boardContent(size: geo.size, now: ctx.date)
            }
        }
        .background(Theme.surface.opacity(0.55), in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: Metric.radiusLg))
    }

    private func boardContent(size: CGSize, now: Date) -> some View {
        let cols = columns
        let list = dayAppointments
        let range = hours(list)
        let colW = max(150, (size.width - Self.gutter) / CGFloat(max(cols.count, 1)))
        let contentW = Self.gutter + colW * CGFloat(cols.count)
        let geometry = ApptGeometry(columns: cols, colW: colW, range: range, contentWidth: contentW)
        return ApptHScroll(enabled: contentW > size.width + 1) {
            VStack(spacing: 0) {
                staffHeader(geometry, list: list)
                    .frame(width: contentW, height: Self.headerHeight)
                Rule()
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid(geometry, list: list, now: now)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { scrollToStart(proxy, range: range, list: list) }
                    .onChange(of: dayKey) { _, _ in scrollToStart(proxy, range: range, list: list) }
                }
            }
            .frame(width: contentW, height: size.height)
        }
    }

    /// 打開時捲到現在（今天）或第一筆預約（別天）
    private func scrollToStart(_ proxy: ScrollViewProxy, range: ApptHours, list: [Reservation]) {
        let target: Int
        if isToday {
            target = minuteOfDay(Date()) / 60 - 1
        } else {
            target = (list.map { minuteOfDay($0.startsAt) }.min() ?? 10 * 60) / 60
        }
        let hour = min(max(target, range.start), max(range.end - 1, range.start))
        proxy.scrollTo(hour, anchor: .top)
    }

    // MARK: 欄頭：設計師、教練

    private func staffHeader(_ g: ApptGeometry, list: [Reservation]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter)
            ForEach(g.columns) { col in
                staffCell(col, list: list, range: g.range)
                    .frame(width: g.colW)
                    .overlay(alignment: .leading) { Rule(vertical: true) }
            }
        }
    }

    private func staffCell(_ col: ApptColumn, list: [Reservation], range: ApptHours) -> some View {
        let mine = list.filter { columnId(for: $0) == col.id && $0.status != .cancelled && $0.status != .noShow }
        let busy = mine.reduce(0) { sum, r in sum + r.durationMinutes }
        let open = max((range.end - range.start) * 60, 60)
        let ratio = min(Double(busy) / Double(open), 1)
        return HStack(spacing: 10) {
            if let s = col.staff {
                StaffAvatar(name: s.name, swatch: s.swatch, size: 32)
            } else {
                HeroIcon("user-circle", size: 28)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(col.staff?.name ?? "不指定")
                        .font(.brand(15, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let title = col.staff.map({ $0.title ?? model.mode.staffTitle }) {
                        Text(title)
                            .font(.brand(11.5, .medium))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                ApptUtilisation(ratio: ratio, count: mine.count)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: 格子

    private func grid(_ g: ApptGeometry, list: [Reservation], now: Date) -> some View {
        let height = CGFloat((g.range.end - g.range.start) * 60) * Self.ppm
        let placed = layout(list, g)
        let selected = placed.first { $0.id == selectedId }
        return ZStack(alignment: .topLeading) {
            ApptGridLines(columns: g.columns.count, colW: g.colW, gutter: Self.gutter, hours: g.range.end - g.range.start,
                          slot: slot, ppm: Self.ppm)
            hourLabels(g.range)
            Color.clear
                .frame(width: max(g.contentWidth - Self.gutter, 1), height: height)
                .contentShape(.rect)
                .onTapGesture(coordinateSpace: .local) { p in tapGrid(p, g) }
                .offset(x: Self.gutter)
            draftGhost(g)
            ForEach(placed) { p in
                block(p, now: now)
            }
            if isToday {
                nowLine(g, now: now)
            }
            if let s = selected {
                card(for: s, g: g, height: height, now: now)
                    .zIndex(10)
            }
        }
        .frame(width: g.contentWidth, height: height + 24, alignment: .topLeading)
    }

    private func hourLabels(_ range: ApptHours) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(range.start..<range.end, id: \.self) { h in
                Text(String(format: "%02d:00", h % 24))
                    .font(.brand(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 10)
                    .padding(.top, 4)
                    .frame(width: Self.gutter, height: 60 * Self.ppm, alignment: .topLeading)
                    .id(h)
            }
        }
    }

    /// 新預約的面板開著時，在表上標出那一格（橘色虛線）
    @ViewBuilder
    private func draftGhost(_ g: ApptGeometry) -> some View {
        if let f = form, f.existing == nil, TaipeiTime.dayString(f.start) == dayKey,
           let ci = g.columns.firstIndex(where: { $0.id == (f.staffId ?? ApptColumn.unassigned) }) {
            let y = CGFloat(minuteOfDay(f.start) - g.range.start * 60) * Self.ppm
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
                .frame(width: g.colW - 6, height: max(CGFloat(slot) * Self.ppm, 22))
                .offset(x: Self.gutter + CGFloat(ci) * g.colW + 3, y: y)
                .allowsHitTesting(false)
        }
    }

    private func nowLine(_ g: ApptGeometry, now: Date) -> some View {
        let y = CGFloat(minuteOfDay(now) - g.range.start * 60) * Self.ppm
        let visible = y >= 0 && y <= CGFloat((g.range.end - g.range.start) * 60) * Self.ppm
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.dangerFG)
                .frame(width: max(g.contentWidth - Self.gutter, 1), height: 1.5)
                .offset(x: Self.gutter)
            Circle()
                .fill(Theme.dangerFG)
                .frame(width: 8, height: 8)
                .offset(x: Self.gutter - 4)
            Text(now.clockText)
                .font(.brand(11, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.dangerFG, in: .capsule)
                .offset(x: 4)
        }
        .frame(height: 16)
        .offset(y: y - 8)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 預約的位置（同一欄重疊的平分寬度）

    private func layout(_ list: [Reservation], _ g: ApptGeometry) -> [ApptPlaced] {
        var out: [ApptPlaced] = []
        for (ci, col) in g.columns.enumerated() {
            let items = list.filter { columnId(for: $0) == col.id }.sorted { $0.startsAt < $1.startsAt }
            for cluster in Self.clusters(items) {
                let lanes = Self.lanes(cluster)
                let laneCount = max((lanes.values.max() ?? 0) + 1, 1)
                let width = (g.colW - 6) / CGFloat(laneCount)
                for r in cluster {
                    let lane = lanes[r.id] ?? 0
                    let y = CGFloat(minuteOfDay(r.startsAt) - g.range.start * 60) * Self.ppm
                    let h = max(CGFloat(r.durationMinutes) * Self.ppm - 2, 24)
                    let x = Self.gutter + CGFloat(ci) * g.colW + 3 + CGFloat(lane) * width
                    out.append(ApptPlaced(reservation: r, rect: CGRect(x: x, y: y + 1, width: max(width - 2, 20), height: h)))
                }
            }
        }
        return out
    }

    /// 互相重疊的連成一群
    private static func clusters(_ items: [Reservation]) -> [[Reservation]] {
        var out: [[Reservation]] = []
        var current: [Reservation] = []
        var end = Date.distantPast
        for r in items {
            if current.isEmpty || r.startsAt < end {
                current.append(r)
                end = max(end, r.endsAt)
            } else {
                out.append(current)
                current = [r]
                end = r.endsAt
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// 一群裡每一筆排第幾道（前一筆做完的道可以接著用）
    private static func lanes(_ cluster: [Reservation]) -> [String: Int] {
        var laneEnds: [Date] = []
        var out: [String: Int] = [:]
        for r in cluster {
            if let i = laneEnds.firstIndex(where: { $0 <= r.startsAt }) {
                laneEnds[i] = r.endsAt
                out[r.id] = i
            } else {
                laneEnds.append(r.endsAt)
                out[r.id] = laneEnds.count - 1
            }
        }
        return out
    }

    private func block(_ p: ApptPlaced, now: Date) -> some View {
        let r = p.reservation
        let staffName = columnId(for: r) == ApptColumn.unassigned && r.staffId != nil ? model.staffName(r.staffId) : nil
        return Button {
            model.touch()
            withAnimation(anim) { selectedId = selectedId == r.id ? nil : r.id }
        } label: {
            ApptBlock(
                reservation: r,
                look: look(for: r, now: now),
                lateMinutes: lateMinutes(r, now: now),
                staffName: staffName,
                selected: selectedId == r.id,
                height: p.rect.height
            )
        }
        .buttonStyle(PressScale(scale: 0.98))
        .frame(width: p.rect.width, height: p.rect.height)
        .position(x: p.rect.midX, y: p.rect.midY)
        .zIndex(selectedId == r.id ? 2 : 1)
    }

    private func look(for r: Reservation, now: Date) -> ApptLook {
        switch r.status {
        case .booked, .notified: return .booked
        case .arrived: return .arrived
        case .seated:
            if model.openTicket(for: r) != nil { return .serving }
            return r.ticketId == nil ? .serving : .done
        case .cancelled: return .cancelled
        case .noShow: return .missed
        }
    }

    private func lateMinutes(_ r: Reservation, now: Date) -> Int? {
        guard r.status == .booked || r.status == .notified else { return nil }
        let m = Int(now.timeIntervalSince(r.startsAt) / 60)
        return m >= 10 ? m : nil
    }

    // MARK: 點空格

    private func tapGrid(_ p: CGPoint, _ g: ApptGeometry) {
        model.touch()
        if selectedId != nil {
            withAnimation(anim) { selectedId = nil }
            return
        }
        let ci = min(max(Int(p.x / g.colW), 0), g.columns.count - 1)
        let minute = g.range.start * 60 + Int(p.y / Self.ppm)
        let snapped = (minute / slot) * slot
        let start = day.addingTimeInterval(Double(snapped) * 60)
        openNew(staffId: g.columns[ci].staff?.id, start: start)
    }

    /// 「新預約」按鈕：今天是下一格，別天是 10:00
    private func defaultStart() -> Date {
        if isToday {
            let m = minuteOfDay(Date())
            let next = ((m + slot - 1) / slot) * slot
            return day.addingTimeInterval(Double(next) * 60)
        }
        return day.addingTimeInterval(10 * 3600)
    }

    private func openNew(staffId: String?, start: Date) {
        model.keypad.cancel()
        withAnimation(anim) {
            selectedId = nil
            form = ApptFormRequest(existing: nil, staffId: staffId, start: start)
        }
    }

    private func openEdit(_ r: Reservation) {
        model.keypad.cancel()
        withAnimation(anim) {
            selectedId = nil
            form = ApptFormRequest(existing: r, staffId: r.staffId, start: r.startsAt)
        }
    }

    private func closeForm() {
        model.keypad.cancel()
        withAnimation(anim) { form = nil }
    }

    // MARK: 預約旁邊的卡片

    private func card(for p: ApptPlaced, g: ApptGeometry, height: CGFloat, now: Date) -> some View {
        let w = cardSize.width
        let h = cardSize.height
        let gap: CGFloat = 10
        let x: CGFloat
        if p.rect.maxX + gap + w <= g.contentWidth {
            x = p.rect.maxX + gap + w / 2
        } else if p.rect.minX - gap - w >= Self.gutter {
            x = p.rect.minX - gap - w / 2
        } else {
            x = min(max(p.rect.midX, Self.gutter + w / 2), max(g.contentWidth - w / 2, Self.gutter + w / 2))
        }
        let top = min(max(p.rect.minY, 6), max(height - h - 6, 6))
        return ApptCard(
            reservation: p.reservation,
            slot: slot,
            onClose: { withAnimation(anim) { selectedId = nil } },
            onEdit: { openEdit(p.reservation) },
            onConfirm: { status in confirming = ApptStatusRequest(reservation: p.reservation, status: status) }
        )
        .frame(width: Self.cardWidth)
        .onGeometryChange(for: CGSize.self, of: { proxy in proxy.size }, action: { newSize in cardSize = newSize })
        .position(x: x, y: top + h / 2)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    // MARK: 確認（未到、取消）

    private var confirmTitle: String {
        guard let c = confirming else { return "" }
        return c.status == .cancelled ? "取消 \(c.reservation.name) 的預約？" : "\(c.reservation.name) 沒有來？"
    }

    private func confirmMessage(_ req: ApptStatusRequest) -> String {
        let r = req.reservation
        let when = "\(r.startsAt.clockText)・\(ApptText.services(r))"
        if req.status == .cancelled { return "\(when)。取消後這段時間會空出來。" }
        return "\(when)。標示未到，後台會記在客人資料上。"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    // MARK: 新增／編輯面板

    @ViewBuilder
    private var formPanel: some View {
        if let f = form {
            ApptFormPanel(request: f, slot: slot, onChange: { staffId, start in
                // 面板裡換人、換時間：表上的虛線框跟著動
                form?.staffId = staffId
                form?.start = start
            }, onClose: { closeForm() })
            .id(f.id)
            .frame(width: 460)
            .frame(maxHeight: .infinity)
            .background(Theme.dock)
            .overlay(alignment: .leading) { Rule(vertical: true) }
            .shadow(color: .black.opacity(0.18), radius: 24, x: -8)
            .transition(.move(edge: .trailing))
        }
    }
}

// MARK: - 資料

private struct ApptColumn: Identifiable {
    static let unassigned = "_unassigned"
    let id: String
    let staff: StaffMember?
}

private struct ApptHours: Equatable {
    var start: Int
    var end: Int
}

private struct ApptGeometry {
    let columns: [ApptColumn]
    let colW: CGFloat
    let range: ApptHours
    let contentWidth: CGFloat
}

private struct ApptPlaced: Identifiable {
    let reservation: Reservation
    let rect: CGRect
    var id: String { reservation.id }
}

private struct ApptFormRequest: Identifiable {
    let id = UUID()
    var existing: Reservation?
    var staffId: String?
    var start: Date
}

private struct ApptStatusRequest: Identifiable {
    let reservation: Reservation
    let status: ReservationStatus
    var id: String { reservation.id + status.rawValue }
}

/// 預約在表上的樣子
private enum ApptLook: Equatable {
    case booked, arrived, serving, done, missed, cancelled

    var label: String {
        switch self {
        case .booked: "已預約"
        case .arrived: "已到店"
        case .serving: "服務中"
        case .done: "已結帳"
        case .missed: "未到"
        case .cancelled: "已取消"
        }
    }
}

/// 共用的文字
private enum ApptText {
    /// 「剪髮・染髮」
    static func services(_ r: Reservation) -> String {
        let names = (r.services ?? []).map(\.name)
        return names.isEmpty ? "沒有指定服務" : names.joined(separator: "・")
    }

    /// 「10:00–11:30」
    static func timeRange(_ r: Reservation) -> String {
        "\(r.startsAt.clockText)–\(r.endsAt.clockText)"
    }

    /// 0912-***-678
    static func masked(_ phone: String) -> String {
        phone.isEmpty ? "沒留電話" : MemberRef(phone: phone).maskedPhone
    }

    /// 0912 345 678
    static func grouped(_ d: String) -> String {
        guard d.count == 10 else { return d }
        return "\(d.prefix(4)) \(d.dropFirst(4).prefix(3)) \(d.suffix(3))"
    }

    static func clock(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
}

/// 太寬才橫向捲（捲軸放在外面會吃掉裡面直向的捲動，所以不需要時不包）
private struct ApptHScroll<Content: View>: View {
    let enabled: Bool
    let content: Content

    init(enabled: Bool, @ViewBuilder content: () -> Content) {
        self.enabled = enabled
        self.content = content()
    }

    var body: some View {
        if enabled {
            ScrollView(.horizontal) { content }
                .scrollIndicators(.visible)
        } else {
            content
        }
    }
}

// MARK: - 小元件

/// 格線：整點深一點、每一格淡淡的，欄與欄之間一條直線
private struct ApptGridLines: View {
    let columns: Int
    let colW: CGFloat
    let gutter: CGFloat
    let hours: Int
    let slot: Int
    let ppm: CGFloat

    var body: some View {
        // 畫圖的 closure 只用這裡抄出來的值（不碰 self、不碰 Theme）
        let strong = Theme.line
        let faint = Theme.hair
        let minutes = hours * 60
        let step = max(slot, 5)
        let scale = ppm
        let left = gutter
        let cols = columns
        let colWidth = colW
        let total = CGFloat(minutes) * scale
        let width = left + colWidth * CGFloat(cols)
        Canvas { context, _ in
            var hourPath = Path()
            var slotPath = Path()
            var minute = 0
            while minute <= minutes {
                let y = CGFloat(minute) * scale
                if minute % 60 == 0 {
                    hourPath.move(to: CGPoint(x: left - 6, y: y))
                    hourPath.addLine(to: CGPoint(x: width, y: y))
                } else {
                    slotPath.move(to: CGPoint(x: left, y: y))
                    slotPath.addLine(to: CGPoint(x: width, y: y))
                }
                minute += step
            }
            var colPath = Path()
            for c in 0...max(cols, 0) {
                let x = left + CGFloat(c) * colWidth
                colPath.move(to: CGPoint(x: x, y: 0))
                colPath.addLine(to: CGPoint(x: x, y: total))
            }
            context.stroke(slotPath, with: .color(faint), lineWidth: 0.5)
            context.stroke(hourPath, with: .color(strong), lineWidth: 1)
            context.stroke(colPath, with: .color(strong), lineWidth: 0.5)
        }
        .frame(width: width, height: total)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 上面的數字（預約 8）
private struct ApptCount: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .textRole(.small)
                .foregroundStyle(Theme.muted)
            Text("\(value)")
                .font(.brand(22, .medium))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(value)))
        }
        .accessibilityElement(children: .combine)
    }
}

/// 這個人今天被約滿了幾成
private struct ApptUtilisation: View {
    let ratio: Double
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.press)
                    Capsule()
                        .fill(ratio >= 0.85 ? Theme.accent : Theme.ink2)
                        .frame(width: max(geo.size.width * ratio, ratio > 0 ? 3 : 0))
                }
            }
            .frame(width: 54, height: 4)
            Text("\(count) 位・\(Int((ratio * 100).rounded()))%")
                .font(.brand(11, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) 個預約，排滿 \(Int((ratio * 100).rounded()))%")
    }
}

/// 表上的一筆預約：顏色＋字表示狀態（已到店＝橘框呼吸、服務中＝實心橘、結完帳＝淡掉）
private struct ApptBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reservation: Reservation
    let look: ApptLook
    let lateMinutes: Int?
    /// 指定的人不在預約表上（放在「不指定」）：標出名字
    let staffName: String?
    let selected: Bool
    let height: CGFloat

    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
        content
            .padding(.horizontal, 8)
            .padding(.vertical, height < 40 ? 3 : 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill, in: shape)
            .overlay(alignment: .leading) {
                // 左邊的色條：晚到是黃、一般是藍
                if look == .booked {
                    Rectangle()
                        .fill(lateMinutes == nil ? Theme.infoFG : Theme.warningFG)
                        .frame(width: 3)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(stroke, style: strokeStyle) }
            .overlay {
                if selected {
                    shape.stroke(Theme.ink, lineWidth: 2).padding(-3)
                }
            }
            .opacity(look == .cancelled || look == .missed ? 0.65 : 1)
            .onChange(of: look == .arrived, initial: true) { _, arrived in
                guard arrived, !reduceMotion else {
                    pulse = false
                    return
                }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        let r = reservation
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ApptText.timeRange(r))
                    .font(.brand(11, .medium))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(statusText)
                    .font(.brand(10.5, .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            if height >= 40 {
                Text(r.name.isEmpty ? "未留名字" : r.name)
                    .font(.brand(15, .semibold))
                    .foregroundStyle(primary)
                    .strikethrough(look == .cancelled)
                    .lineLimit(1)
            }
            if height >= 62 {
                Text(ApptText.services(r))
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(secondary)
                    .lineLimit(height >= 100 ? 2 : 1)
            }
            if height >= 86 {
                Text(staffName.map { "\($0)・\(ApptText.masked(r.phone))" } ?? ApptText.masked(r.phone))
                    .font(.brand(11.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
        }
    }

    private var statusText: String {
        if let m = lateMinutes { return "晚 \(m) 分" }
        return look == .booked ? "" : look.label
    }

    private var fill: Color {
        switch look {
        case .booked: Theme.surface
        case .arrived: Theme.accentSoft
        case .serving: Theme.accent
        case .done: Theme.pageAlt
        case .missed: Theme.dangerFG.opacity(0.08)
        case .cancelled: Color.clear
        }
    }

    private var stroke: Color {
        switch look {
        case .booked: Theme.line
        case .arrived: Theme.accent.opacity(pulse ? 1 : 0.35)
        case .serving: Color.clear
        case .done: Theme.line
        case .missed: Theme.dangerFG.opacity(0.6)
        case .cancelled: Theme.line
        }
    }

    private var strokeStyle: StrokeStyle {
        switch look {
        case .arrived: StrokeStyle(lineWidth: 2)
        case .missed, .cancelled: StrokeStyle(lineWidth: 1, dash: [4, 3])
        case .booked, .serving, .done: StrokeStyle(lineWidth: 1)
        }
    }

    private var primary: Color {
        switch look {
        case .serving: Theme.onAccent
        case .done, .cancelled: Theme.muted
        case .booked, .arrived, .missed: Theme.ink
        }
    }

    private var secondary: Color {
        look == .serving ? Theme.onAccent.opacity(0.8) : Theme.muted
    }

    private var statusColor: Color {
        if lateMinutes != nil { return Theme.warningFG }
        switch look {
        case .booked: return Theme.infoFG
        case .arrived: return Theme.accentText
        case .serving: return Theme.onAccent
        case .done: return Theme.successFG
        case .missed: return Theme.dangerFG
        case .cancelled: return Theme.muted
        }
    }

    private var accessibilityText: String {
        let r = reservation
        var parts = [ApptText.timeRange(r), r.name, ApptText.services(r), look.label]
        if let m = lateMinutes { parts.append("晚了 \(m) 分鐘") }
        if let staffName { parts.append(staffName) }
        return parts.joined(separator: "，")
    }
}

// MARK: - 預約的卡片

private struct ApptCard: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reservation: Reservation
    let slot: Int
    let onClose: () -> Void
    let onEdit: () -> Void
    let onConfirm: (ReservationStatus) -> Void

    @State private var showPhone = false
    @State private var rescheduling = false
    @State private var draftStart = Date()
    @State private var draftMinutes = 60
    @State private var draftStaff: String?
    @State private var conflictAcknowledged = false
    @State private var busy = false
    @State private var lookingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if rescheduling {
                rescheduleSection
            } else {
                details
                memberSummary
                actions
            }
        }
        .padding(16)
        .background(Theme.dock, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.fast }

    private var ref: MemberRef? { model.memberRef(for: reservation) }

    private var member: Member? { model.member(for: ref) }

    private var ticket: Ticket? { model.openTicket(for: reservation) }

    private var closedTicket: Ticket? {
        guard ticket == nil, let id = reservation.ticketId, let t = model.state.tickets[id], t.status == .closed else { return nil }
        return t
    }

    // MARK: 上面

    private var header: some View {
        let r = reservation
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name.isEmpty ? "未留名字" : r.name)
                    .font(.brand(21, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(ApptText.timeRange(r))・\(r.durationMinutes) 分")
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            StatusBadge(r.status.label(for: .appointment), tone: tone(r.status))
            Button(action: onClose) {
                HeroIcon("x-mark", size: 14)
            }
            .buttonStyle(SquareIconButtonStyle(size: 30))
            .accessibilityLabel("關閉")
        }
    }

    private func tone(_ s: ReservationStatus) -> Tone {
        switch s {
        case .booked, .notified: .info
        case .arrived: .gold
        case .seated: .active
        case .cancelled: .neutral
        case .noShow: .danger
        }
    }

    // MARK: 內容

    private var details: some View {
        let r = reservation
        return VStack(alignment: .leading, spacing: 10) {
            ApptInfoRow(label: model.mode.staffTitle, value: r.staffId.map { model.staffName($0) } ?? "不指定")
            VStack(alignment: .leading, spacing: 4) {
                Text("服務")
                    .textRole(.label)
                    .foregroundStyle(Theme.muted)
                ForEach(Array((r.services ?? []).enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 6) {
                        Text(s.name)
                            .font(.brand(15, .medium))
                            .foregroundStyle(Theme.ink)
                        Text("\(s.durationMinutes) 分")
                            .font(.brand(12, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                        if let sid = s.staffId, sid != r.staffId {
                            Text(model.staffName(sid))
                                .font(.brand(12, .medium))
                                .foregroundStyle(Theme.ink2)
                        }
                        Spacer(minLength: 0)
                        if let p = s.price {
                            Text(p.formatted)
                                .font(.brand(12.5, .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink2)
                        }
                    }
                }
                if (r.services ?? []).isEmpty {
                    Text("沒有指定服務")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                ApptInfoRow(label: "電話", value: showPhone ? ApptText.grouped(r.phone) : ApptText.masked(r.phone))
                if !r.phone.isEmpty {
                    Button(showPhone ? "隱藏" : "顯示號碼") { showPhone.toggle() }
                        .buttonStyle(.brand(.quiet, size: .sm))
                }
            }
            if !r.note.isEmpty {
                Text("※ \(r.note)")
                    .textRole(.small)
                    .foregroundStyle(Theme.warningFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var memberSummary: some View {
        if let m = member {
            VStack(alignment: .leading, spacing: 8) {
                Rule()
                HStack(spacing: 8) {
                    Eyebrow(m.tierName ?? "會員")
                    Spacer(minLength: 0)
                    if let account = model.account(for: m.ref) {
                        Text("儲值金")
                            .textRole(.xs)
                            .foregroundStyle(Theme.muted)
                        MoneyText(money: account.wallet, role: .small)
                    }
                }
                if let account = model.account(for: m.ref) {
                    let passes = account.usablePasses(at: Date())
                    ForEach(passes.prefix(3)) { p in
                        HStack(spacing: 6) {
                            Circle().fill(Theme.live).frame(width: 6, height: 6)
                            Text(p.name)
                                .font(.brand(13.5, .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(p.statusText(at: Date()))
                                .font(.brand(12, .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                    }
                }
                if let v = m.recentVisits?.first {
                    Text(lastVisitText(v))
                        .textRole(.xs)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = m.note, !note.isEmpty {
                    Text("※ \(note)")
                        .textRole(.xs)
                        .foregroundStyle(Theme.warningFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if !reservation.phone.isEmpty {
            Button {
                lookUp()
            } label: {
                Label {
                    Text(lookingUp ? "查詢中…" : "查會員資料（儲值金、課程卡、上次做了什麼）")
                } icon: {
                    HeroIcon("magnifying-glass", size: 14)
                }
            }
            .buttonStyle(.brand(.quiet, size: .sm))
            .disabled(lookingUp)
        }
    }

    private func lastVisitText(_ v: MemberVisit) -> String {
        let who = v.staffNames.isEmpty ? "" : "・\(v.staffNames.joined(separator: "、"))"
        return "上次 \(v.at.shortText)・\(v.items.joined(separator: "、"))\(who)"
    }

    private func lookUp() {
        lookingUp = true
        Task {
            _ = await model.findMember(code: reservation.phone)
            lookingUp = false
        }
    }

    // MARK: 動作

    @ViewBuilder
    private var actions: some View {
        let r = reservation
        VStack(spacing: 8) {
            primaryAction(r)
            if r.status.isActive || r.status == .seated {
                HStack(spacing: 6) {
                    if r.status.isActive {
                        ApptMiniTool(title: "改時間", icon: "clock") { beginReschedule() }
                    }
                    ApptMiniTool(title: "編輯", icon: "pencil-square") { onEdit() }
                    if r.status.isActive {
                        ApptMiniTool(title: "未到", icon: "no-symbol") { onConfirm(.noShow) }
                        ApptMiniTool(title: "取消", icon: "x-circle") { onConfirm(.cancelled) }
                    }
                }
            } else if r.status == .cancelled || r.status == .noShow {
                Button("改回已預約") {
                    Task { await model.markAppointment(r, status: .booked) }
                }
                .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))
            }
        }
    }

    @ViewBuilder
    private func primaryAction(_ r: Reservation) -> some View {
        if let t = ticket {
            HStack(spacing: 8) {
                Button {
                    model.selectedTicketId = t.id
                } label: {
                    Text("看單 \(t.number)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
                if model.role.takesPayment {
                    Button {
                        model.beginCheckout(t)
                    } label: {
                        Text("去結帳")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.brand(.accent, size: .lg, fullWidth: true, arrow: true))
                }
            }
            if !model.role.takesPayment {
                // 報到接待不收錢：單子已經在結帳櫃台看得到
                ApptHandOffNote(text: "\(t.number)・\(t.totals.amountDue.formatted) 已同步到結帳櫃台")
            }
        } else if let t = closedTicket {
            ApptDoneNote(text: "已結帳 \(t.number)")
        } else if r.status == .seated && r.ticketId != nil {
            // 開過單、這台已經沒有那張單（iPad 只留最近兩天，或在別台結的）：不要再開一張
            ApptDoneNote(text: "服務完成・單子在結帳紀錄裡")
        } else if r.status.isActive || r.status == .seated {
            HStack(spacing: 8) {
                if r.status == .booked || r.status == .notified {
                    Button {
                        Task { await model.markAppointment(r, status: .arrived) }
                    } label: {
                        Text("到店")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
                }
                Button {
                    startService()
                } label: {
                    Text(busy ? "開單中…" : "開始服務")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.primary, size: .lg, fullWidth: true, arrow: true))
                .disabled(busy)
            }
        }
    }

    private func startService() {
        busy = true
        Task {
            await model.startService(reservation)
            busy = false
        }
    }

    // MARK: 改時間

    private func beginReschedule() {
        draftStart = reservation.startsAt
        draftMinutes = reservation.durationMinutes
        draftStaff = reservation.staffId
        conflictAcknowledged = false
        withAnimation(anim) { rescheduling = true }
    }

    private var conflicts: [Reservation] {
        model.appointmentConflicts(staffId: draftStaff, start: draftStart, minutes: draftMinutes, ignoring: reservation.id)
    }

    private var rescheduleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ApptStepper(label: "開始", value: draftStart.clockText,
                        minus: { shiftStart(-slot) }, plus: { shiftStart(slot) })
            ApptStepper(label: "時間", value: "\(draftMinutes) 分",
                        minus: { draftMinutes = max(draftMinutes - slot, slot); conflictAcknowledged = false },
                        plus: { draftMinutes = min(draftMinutes + slot, 600); conflictAcknowledged = false })
            VStack(alignment: .leading, spacing: 6) {
                Text(model.mode.staffTitle)
                    .textRole(.label)
                    .foregroundStyle(Theme.muted)
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(model.bookableStaff) { s in
                        OptionChip(title: s.name, selected: draftStaff == s.id) {
                            draftStaff = s.id
                            conflictAcknowledged = false
                        }
                    }
                }
            }
            if let c = conflicts.first {
                Text("\(model.staffName(draftStaff)) \(ApptText.timeRange(c)) 已經有 \(c.name)（\(ApptText.services(c))）")
                    .textRole(.small)
                    .foregroundStyle(Theme.warningFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("返回") {
                    withAnimation(anim) { rescheduling = false }
                }
                .buttonStyle(.brand(.ghost, size: .md))
                Button {
                    saveReschedule()
                } label: {
                    Text(saveLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.primary, size: .md, fullWidth: true))
                .disabled(busy)
            }
        }
    }

    private var saveLabel: String {
        if busy { return "儲存中…" }
        return !conflicts.isEmpty && conflictAcknowledged ? "撞到了，還是要改" : "改好了"
    }

    private func shiftStart(_ minutes: Int) {
        draftStart = draftStart.addingTimeInterval(Double(minutes) * 60)
        conflictAcknowledged = false
    }

    private func saveReschedule() {
        // 撞到別的預約：先提醒一次（不擋），再按一次才存
        if !conflicts.isEmpty && !conflictAcknowledged {
            conflictAcknowledged = true
            return
        }
        busy = true
        let r = reservation
        let start = draftStart
        let minutes = draftMinutes
        let staff = draftStaff
        Task {
            let saved = await model.reschedule(r, to: start, minutes: minutes, staffId: staff)
            busy = false
            guard saved != nil else { return }
            model.show("\(r.name) 改到 \(start.clockText)・\(model.staffName(staff))")
            withAnimation(anim) { rescheduling = false }
        }
    }
}

/// 卡片上的一列：小字標題＋值
private struct ApptInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .textRole(.label)
                .foregroundStyle(Theme.muted)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.brand(15, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// 卡片下面一排小動作：圖示在上、字在下
private struct ApptMiniTool: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HeroIcon(icon, size: 17)
                Text(title)
                    .font(.brand(11.5, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.95))
    }
}

/// −／＋ 一格（開始時間、時間長度）
private struct ApptStepper: View {
    let label: String
    let value: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .textRole(.label)
                .foregroundStyle(Theme.muted)
                .frame(width: 52, alignment: .leading)
            HStack(spacing: 0) {
                Button(action: minus) {
                    HeroIcon("minus", size: 14)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("\(label)減少")
                Text(value)
                    .font(.brand(18, .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                Button(action: plus) {
                    HeroIcon("plus", size: 14)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("\(label)增加")
            }
            .buttonStyle(PressScale(scale: 0.94))
            .foregroundStyle(Theme.ink)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
            .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
        }
    }
}

// MARK: - 新增／編輯預約

/// 選好的一項服務（時間可以改）
private struct ApptPicked: Identifiable, Equatable {
    let id: String
    let itemId: String
    let name: String
    var minutes: Int
    var price: Money?
}

/// 查會員的進度
private enum ApptMemberState: Equatable {
    case idle
    case searching
    case found(String)
    case notFound
    case offline
    case failed(String)
}

private struct ApptFormPanel: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: ApptFormRequest
    let slot: Int
    /// 換人、換時間時告訴預約表（虛線框跟著動）
    let onChange: (String?, Date) -> Void
    let onClose: () -> Void

    @State private var phone: String
    @State private var name: String
    @State private var memberId: String?
    @State private var memberState: ApptMemberState
    @State private var joinAsMember = true
    @State private var picked: [ApptPicked]
    @State private var staffId: String?
    @State private var start: Date
    @State private var note: String
    @State private var askingPhone = false
    @State private var saving = false
    @State private var problem: String? = nil
    @FocusState private var nameFocused: Bool

    init(request: ApptFormRequest, slot: Int, onChange: @escaping (String?, Date) -> Void, onClose: @escaping () -> Void) {
        self.request = request
        self.slot = slot
        self.onChange = onChange
        self.onClose = onClose
        let r = request.existing
        _phone = State(initialValue: r?.phone ?? "")
        _name = State(initialValue: r?.name ?? "")
        _memberId = State(initialValue: r?.memberId)
        var state = ApptMemberState.idle
        if let id = r?.memberId { state = .found(id) }
        _memberState = State(initialValue: state)
        var services: [ApptPicked] = []
        for (i, s) in (r?.services ?? []).enumerated() {
            services.append(ApptPicked(id: "\(s.itemId)#\(i)", itemId: s.itemId, name: s.name, minutes: s.durationMinutes, price: s.price))
        }
        _picked = State(initialValue: services)
        _staffId = State(initialValue: r?.staffId ?? request.staffId)
        _start = State(initialValue: r?.startsAt ?? request.start)
        _note = State(initialValue: r?.note ?? "")
    }

    private var isNew: Bool { request.existing == nil }

    private var anim: Animation? { reduceMotion ? nil : Motion.fast }

    private var totalMinutes: Int {
        let sum = picked.reduce(0) { $0 + $1.minutes }
        if sum > 0 { return sum }
        return request.existing?.durationMinutes ?? max(slot * 4, 60)
    }

    private var totalPrice: Money { Money.sum(picked.compactMap { $0.price }) }

    private var member: Member? { memberId.flatMap { model.members[$0] } }

    private var conflicts: [Reservation] {
        model.appointmentConflicts(staffId: staffId, start: start, minutes: totalMinutes, ignoring: request.existing?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    customerSection
                    servicesSection
                    staffSection
                    timeSection
                    if let c = conflicts.first {
                        Banner(text: "\(model.staffName(staffId)) \(ApptText.timeRange(c)) 已經有 \(c.name)（\(ApptText.services(c))），還是可以存", tone: .warning)
                    }
                    noteSection
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            Rule()
            bottomBar
        }
        .task {
            // 新的一筆：先問電話（右側鍵盤），查到會員就帶出名字
            guard isNew, phone.isEmpty else { return }
            await askPhone()
        }
    }

    // MARK: 上面

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("預約・\(start.dayTitle)")
                Headline(isNew ? "New *booking*" : "Edit *booking*", role: .h3)
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

    // MARK: 客人

    private var customerSection: some View {
        ApptField(label: "客人") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ApptKeypadField(label: "電話", value: phone.isEmpty ? "點一下輸入" : ApptText.grouped(phone), placeholder: phone.isEmpty, active: askingPhone) {
                        Task { await askPhone() }
                    }
                    TextField("稱呼（王小姐）", text: $name)
                        .font(.brand(17, .medium))
                        .focused($nameFocused)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .frame(height: 72)
                        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                        .overlay {
                            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                                .strokeBorder(nameFocused ? Theme.accent : Theme.line, lineWidth: nameFocused ? 1.5 : 1)
                        }
                }
                memberLine
            }
        }
    }

    @ViewBuilder
    private var memberLine: some View {
        switch memberState {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                Text("查會員中…")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
        case .found:
            if let m = member {
                ApptMemberChip(member: m, account: model.account(for: m.ref))
            } else {
                Text("會員")
                    .textRole(.small)
                    .foregroundStyle(Theme.successFG)
            }
        case .notFound:
            Toggle(isOn: $joinAsMember) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("還不是會員")
                        .font(.brand(14.5, .medium))
                        .foregroundStyle(Theme.ink)
                    Text("存預約時用這支電話加入會員（下次查得到、可以儲值）")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
            }
            .tint(Theme.primary)
        case .offline:
            Text("離線，查不到會員；先記電話，連上網路後再對")
                .textRole(.small)
                .foregroundStyle(Theme.warningFG)
        case .failed(let message):
            Text(message)
                .textRole(.small)
                .foregroundStyle(Theme.dangerFG)
        }
    }

    // MARK: 服務

    private var serviceItems: [MenuItem] {
        model.catalog.items.filter { $0.itemKind == .service && model.isAvailable($0) }
    }

    private var servicesSection: some View {
        let items = serviceItems
        return ApptField(label: picked.isEmpty ? "服務" : "服務・共 \(totalMinutes) 分・\(totalPrice.formatted)") {
            VStack(alignment: .leading, spacing: 14) {
                if !picked.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(picked) { p in
                            pickedRow(p)
                            Rule(color: Theme.hair)
                        }
                    }
                }
                if items.isEmpty {
                    Text("菜單上還沒有「服務」類的品項（到後台菜單把品項種類設成服務、填上時間）")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.catalog.categories) { c in
                        let inCategory = items.filter { $0.categoryId == c.id }
                        if !inCategory.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(c.name)
                                    .textRole(.xs)
                                    .foregroundStyle(Theme.muted)
                                FlowLayout(spacing: 6, rowSpacing: 6) {
                                    ForEach(inCategory) { item in
                                        OptionChip(title: item.name, detail: item.durationMinutes.map { "\($0)分" }, selected: picked.contains { $0.itemId == item.id }) {
                                            toggle(item)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func pickedRow(_ p: ApptPicked) -> some View {
        HStack(spacing: 10) {
            Text(p.name)
                .font(.brand(15, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                askMinutes(p)
            } label: {
                HStack(spacing: 4) {
                    Text("\(p.minutes) 分")
                        .font(.brand(14, .medium))
                        .monospacedDigit()
                    HeroIcon("calculator", size: 12)
                        .foregroundStyle(Theme.faint)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .overlay { RoundedRectangle(cornerRadius: Metric.radiusSm).strokeBorder(Theme.line) }
                .contentShape(.rect)
            }
            .buttonStyle(.press)
            .accessibilityLabel("\(p.name) 時間 \(p.minutes) 分鐘")
            if let price = p.price {
                Text(price.formatted)
                    .font(.brand(13.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            Button {
                remove(p)
            } label: {
                HeroIcon("x-mark", size: 13)
            }
            .buttonStyle(SquareIconButtonStyle(size: 30))
            .accessibilityLabel("拿掉 \(p.name)")
        }
        .padding(.vertical, 8)
    }

    private func toggle(_ item: MenuItem) {
        withAnimation(anim) {
            if let i = picked.firstIndex(where: { $0.itemId == item.id }) {
                picked.remove(at: i)
            } else {
                picked.append(ApptPicked(id: "\(item.id)#\(UUID().uuidString)", itemId: item.id, name: item.name,
                                         minutes: item.durationMinutes ?? 60, price: item.openPrice ? nil : item.price))
            }
        }
        problem = nil
    }

    private func remove(_ p: ApptPicked) {
        withAnimation(anim) { picked.removeAll { $0.id == p.id } }
    }

    private func askMinutes(_ p: ApptPicked) {
        nameFocused = false
        Task {
            guard let m = await model.keypad.askNumber(.duration(name: p.name, current: p.minutes)) else { return }
            if let i = picked.firstIndex(where: { $0.id == p.id }) { picked[i].minutes = m }
        }
    }

    // MARK: 服務人員、時間

    private var staffSection: some View {
        ApptField(label: model.mode.staffTitle) {
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(model.bookableStaff) { s in
                    OptionChip(title: s.name, detail: busyDetail(s.id), selected: staffId == s.id) {
                        staffId = s.id
                        onChange(staffId, start)
                    }
                }
                // 已經指定了人的預約，後台不能改回「不指定」（只送要改的欄位）
                if isNew || request.existing?.staffId == nil {
                    OptionChip(title: "不指定", selected: staffId == nil) {
                        staffId = nil
                        onChange(staffId, start)
                    }
                }
            }
        }
    }

    /// 這個時段這個人有約了嗎（選人時看得到）
    private func busyDetail(_ id: String) -> String? {
        let c = model.appointmentConflicts(staffId: id, start: start, minutes: totalMinutes, ignoring: request.existing?.id)
        return c.isEmpty ? nil : "有約"
    }

    private var timeSection: some View {
        let end = start.addingTimeInterval(Double(totalMinutes) * 60)
        return ApptField(label: "時間・\(start.dayTitle)") {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    Button {
                        shift(-slot)
                    } label: {
                        HeroIcon("minus", size: 15)
                            .frame(width: 46, height: 50)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("早 \(slot) 分鐘")
                    Text(start.clockText)
                        .font(.brand(24, .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 84)
                    Button {
                        shift(slot)
                    } label: {
                        HeroIcon("plus", size: 15)
                            .frame(width: 46, height: 50)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("晚 \(slot) 分鐘")
                }
                .buttonStyle(PressScale(scale: 0.94))
                .foregroundStyle(Theme.ink)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("到 \(end.clockText)")
                        .font(.brand(15, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                    if start < Date().addingTimeInterval(-5 * 60) {
                        Text("這個時間已經過了")
                            .textRole(.xs)
                            .foregroundStyle(Theme.warningFG)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func shift(_ minutes: Int) {
        withAnimation(anim) { start = start.addingTimeInterval(Double(minutes) * 60) }
        onChange(staffId, start)
    }

    private var noteSection: some View {
        ApptField(label: "備註") {
            TextField("過敏、指定助理、上次的染膏配方…", text: $note, axis: .vertical)
                .font(.brand(16, .regular))
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
        }
    }

    // MARK: 下面

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let problem {
                Text(problem)
                    .textRole(.small)
                    .foregroundStyle(Theme.dangerFG)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("取消") { onClose() }
                .buttonStyle(.brand(.ghost, size: .lg))
            Button {
                save()
            } label: {
                Text(saving ? "儲存中…" : (isNew ? "建立預約" : "儲存"))
            }
            .buttonStyle(.brand(.accent, size: .lg, arrow: true))
            .disabled(saving)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: 右側鍵盤

    private func askPhone() async {
        nameFocused = false
        askingPhone = true
        var spec = KeypadSpec.phone
        spec.title = "客人電話"
        spec.subtitle = "查會員；沒有電話按 × 跳過"
        spec.initial = phone
        let entry = await model.keypad.ask(spec)
        askingPhone = false
        guard let entry else {
            if name.isEmpty { nameFocused = true }
            return
        }
        phone = entry.digits
        await lookUp(entry.digits)
    }

    private func lookUp(_ digits: String) async {
        withAnimation(anim) { memberState = .searching }
        let result = await model.findMember(code: digits)
        withAnimation(anim) {
            switch result {
            case .found(let m), .cached(let m):
                memberId = m.id
                memberState = .found(m.id)
                if name.trimmingCharacters(in: .whitespaces).isEmpty, let n = m.name { name = n }
            case .notFound:
                memberId = nil
                memberState = .notFound
            case .offline:
                memberId = nil
                memberState = .offline
            case .failed(let message):
                memberId = nil
                memberState = .failed(message)
            }
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { nameFocused = true }
    }

    // MARK: 存

    private func save() {
        guard !saving else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !phone.isEmpty else {
            problem = "請填稱呼或電話"
            nameFocused = true
            return
        }
        model.keypad.cancel()
        askingPhone = false
        problem = nil
        saving = true
        let existing = request.existing
        let wantsJoin = memberState == .notFound && joinAsMember && phone.count == 10
        let services = picked.map { BookedService(itemId: $0.itemId, name: $0.name, durationMinutes: $0.minutes, price: $0.price) }
        let minutes = max(totalMinutes, slot)
        let when = start
        let staff = staffId
        let notes = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = phone
        Task {
            var memberId = self.memberId
            var display = trimmed
            if wantsJoin, let m = await model.createMember(phone: digits, name: trimmed) {
                memberId = m.id
            }
            if display.isEmpty {
                display = member?.name ?? MemberRef(phone: digits).maskedPhone
            }
            let input = ReservationInput(
                kind: existing == nil ? .appointment : nil, name: display, phone: digits, partySize: 1, startsAt: when,
                durationMinutes: minutes, note: notes, staffId: staff, services: services, memberId: memberId
            )
            let saved = await model.saveReservation(id: existing?.id, input)
            saving = false
            guard let saved else { return }
            let who = staff.map { "・\(model.staffName($0))" } ?? ""
            model.show(existing == nil ? "已預約 \(saved.startsAt.shortText)・\(saved.name)\(who)" : "已更新 \(saved.name) 的預約")
            onClose()
        }
    }
}

/// 表單的一欄：小字標題＋內容
private struct ApptField<Content: View>: View {
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

/// 用右側鍵盤打的欄位：點了右邊鍵盤換成這一題，這一格框成橘色
private struct ApptKeypadField: View {
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
                    .font(.brand(placeholder ? 15 : 19, .medium))
                    .monospacedDigit()
                    .foregroundStyle(placeholder ? Theme.muted : Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 170, height: 72, alignment: .leading)
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

/// 查到的會員：名字、等級、儲值金、能用的卡、上次做了什麼
private struct ApptMemberChip: View {
    let member: Member
    let account: MemberAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HeroIcon("check-circle", size: 15)
                    .foregroundStyle(Theme.successFG)
                Text(member.name ?? "會員")
                    .font(.brand(15, .semibold))
                    .foregroundStyle(Theme.ink)
                if let tier = member.tierName {
                    StatusBadge(tier, tone: .gold)
                }
                Spacer(minLength: 0)
                if let account {
                    MoneyText(money: account.wallet, role: .small)
                }
            }
            if let account {
                let passes = account.usablePasses(at: Date())
                if !passes.isEmpty {
                    Text(passes.prefix(3).map { "\($0.name) \($0.statusText(at: Date()))" }.joined(separator: "／"))
                        .textRole(.xs)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let v = member.recentVisits?.first {
                Text("上次 \(v.at.shortText)・\(v.items.joined(separator: "、"))")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            if let note = member.note, !note.isEmpty {
                Text("※ \(note)")
                    .textRole(.xs)
                    .foregroundStyle(Theme.warningFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Theme.successFG.opacity(0.07), in: .rect(cornerRadius: Metric.radius))
    }
}

/// 報到接待（不收錢）：告訴櫃台人員單子去哪了
private struct ApptHandOffNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            HeroIcon("arrow-top-right-on-square", size: 14)
                .foregroundStyle(Theme.infoFG)
            Text(text)
                .font(.brand(13, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.infoFG)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Tone.info.background, in: .rect(cornerRadius: Metric.radiusSm))
    }
}

/// 這筆預約做完、結完帳了
private struct ApptDoneNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            HeroIcon("check-circle", size: 18)
                .foregroundStyle(Theme.successFG)
            Text(text)
                .font(.brand(15, .medium))
                .foregroundStyle(Theme.successFG)
            Spacer(minLength: 0)
        }
    }
}
