import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 預約表（美業的設計師、私人教練）：一位一欄、每人一個顏色，一格是後台設的分鐘數，現在的時間是一條紅線。
///
///   ┌ Day book ─────────────────────────── ‹ 今天 10月4日 › [現場客] [新預約] ┐
///   │ 預約 8・已到 1・服務中 2                                 顯示取消、未到 │
///   │        │ (L) Leslie 總監 ▇▇▇▁ 62% │ (J) Jacob ▇▁▁ 30% │ (?) 不指定      │
///   │ 10:00  │ ▌10:00–11:30   已到店    │                   │                 │
///   │ ───────│ ▌林小涵                  │ ▌10:30  王先生    │                 │
///   │        │ ▌[剪髮][染髮]   90 分    │ ▌[私人教練]       │                 │
///   │ 11:00 ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 現在                               │
///   └──────────────────────────────────────────────────────────────────────────┘
///
/// 點空格＝標出那一格、再點「新預約」；長按空格＝直接新預約（右邊滑出面板：電話、時間用右側鍵盤打，所以不是 sheet）。
/// 點預約＝旁邊跳出卡片（到店、開始服務、去結帳、改時間、未到、取消）；長按預約再拖＝改時間、換人（放開時對齊格子）。
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
    /// 點了空格：先標出來（再點一次「新預約」才開面板，避免點掉卡片時誤開）
    @State private var pending: ApptSlot?
    /// 正在拖的預約
    @State private var drag: ApptDrag?
    /// 拖到撞到別人的時段：問一次
    @State private var moveRequest: ApptMoveRequest?
    /// 觸覺回饋：拖過一格、長按成功
    @State private var snapTick = 0
    @State private var liftTick = 0
    @State private var lastLongPress = Date.distantPast

    /// 一分鐘幾點高（一小時 108 點：15 分鐘一格 27 點，手指點得到）
    fileprivate static let ppm: CGFloat = 1.8
    private static let gutter: CGFloat = 60
    private static let headerHeight: CGFloat = 78
    private static let cardWidth: CGFloat = 304
    private static let space = "apptGrid"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summary
            if model.bookableStaff.isEmpty && model.appointments(onDay: dayKey).isEmpty {
                ApptNoStaff(title: model.mode.staffTitle)
            } else {
                board
            }
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
        .sensoryFeedback(.selection, trigger: snapTick)
        .sensoryFeedback(.impact(weight: .medium), trigger: liftTick)
        .alert(confirmTitle, isPresented: confirmBinding, presenting: confirming) { req in
            Button(req.status == .cancelled ? "取消預約" : "標示未到", role: .destructive) {
                Task { await model.setStatus(req.status, for: req.reservation) }
                selectedId = nil
            }
            Button("返回", role: .cancel) {}
        } message: { req in
            Text(confirmMessage(req))
        }
        .alert("時間撞到了", isPresented: moveBinding, presenting: moveRequest) { req in
            Button("還是要改") { commitMove(req) }
            Button("返回", role: .cancel) {}
        } message: { req in
            Text(moveMessage(req))
        }
    }

    // MARK: - 資料

    private var anim: Animation? { reduceMotion ? nil : Motion.ease }
    private var spring: Animation? { reduceMotion ? nil : Motion.spring }

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
            // 頁首只有一個主要按鈕：新增預約、現場客合成「＋ 新增」
            Menu {
                Button {
                    openNew(staffId: nil, start: defaultStart())
                } label: {
                    Label { Text("預約") } icon: { Image("hi-calendar-days").renderingMode(.template) }
                }
                Button {
                    walkIn()
                } label: {
                    Label { Text("現場客（直接開單）") } icon: { Image("hi-user").renderingMode(.template) }
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

    private func walkIn() {
        Task {
            if await model.walkIn() != nil { model.go(.order) }
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
                    pending = nil
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
            pending = nil
        }
    }

    private var summary: some View {
        let all = model.appointments(onDay: dayKey)
        let live = all.filter { $0.status != .cancelled && $0.status != .noShow }
        let arrived = all.filter { $0.status == .arrived }.count
        let serving = all.filter { $0.status == .seated && model.openTicket(for: $0) != nil }.count
        let hidden = all.count - live.count
        return HStack(alignment: .firstTextBaseline, spacing: 22) {
            ApptCount(label: "預約", value: live.count, color: Theme.ink)
            ApptCount(label: "已到", value: arrived, color: Theme.accentText)
            ApptCount(label: "服務中", value: serving, color: Theme.successFG)
            Spacer(minLength: 8)
            // 放不下就換短的、再放不下就不顯示（不截斷）
            ViewThatFits(in: .horizontal) {
                Text("長按空格新增・長按預約拖曳改時間")
                Text("長按空格新增")
                Color.clear.frame(width: 0, height: 0)
            }
            .textRole(.xs)
            .foregroundStyle(Theme.faint)
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
        // 每分鐘重畫：現在的紅線、晚到、服務的進度
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
        .overlay {
            if dayAppointments.isEmpty && pending == nil && form == nil {
                ApptQuietDay(colors: model.bookableStaff.prefix(3).map { Theme.swatch($0.swatch) }, isToday: isToday)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    private func boardContent(size: CGSize, now: Date) -> some View {
        let cols = columns
        let list = dayAppointments
        let range = hours(list)
        let colW = max(170, (size.width - Self.gutter) / CGFloat(max(cols.count, 1)))
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

    // MARK: 欄頭：設計師、教練（大頭貼的顏色就是這個人在表上的顏色）

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
        let color = col.staff.map { Theme.swatch($0.swatch) }
        return HStack(spacing: 12) {
            if let s = col.staff {
                StaffAvatar(name: s.name, swatch: s.swatch, size: 44)
            } else {
                Circle()
                    .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 44, height: 44)
                    .overlay { HeroIcon("user", size: 18).foregroundStyle(Theme.muted) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(col.staff?.name ?? "不指定")
                    .font(.brand(17, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(col.staff.map { $0.title ?? model.mode.staffTitle } ?? "還沒排人")
                    .font(.brand(12, .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                ApptUtilisation(ratio: ratio, count: mine.count, color: color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(color?.opacity(0.07) ?? Color.clear)
        .accessibilityElement(children: .combine)
    }

    // MARK: 格子

    private func grid(_ g: ApptGeometry, list: [Reservation], now: Date) -> some View {
        let height = CGFloat((g.range.end - g.range.start) * 60) * Self.ppm
        let placed = layout(list, g)
        let selected: ApptPlaced? = drag == nil ? placed.first(where: { $0.id == selectedId }) : nil
        let dragged: ApptPlaced? = drag.flatMap { d in placed.first(where: { $0.id == d.id }) }
        return ZStack(alignment: .topLeading) {
            columnTints(g, height: height)
            ApptGridLines(columns: g.columns.count, colW: g.colW, gutter: Self.gutter, hours: g.range.end - g.range.start,
                          slot: slot, ppm: Self.ppm)
            hourLabels(g.range)
            tapLayer(g, height: height)
            pendingGhost(g)
            draftGhost(g)
            ForEach(placed) { p in
                block(p, g: g, now: now)
            }
            if let dragged, let d = drag {
                dropGhost(dragged, translation: d.translation, g: g)
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
        .coordinateSpace(.named(Self.space))
    }

    /// 每一欄淡淡的設計師顏色
    private func columnTints(_ g: ApptGeometry, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter)
            ForEach(g.columns) { col in
                (col.staff.map { Theme.swatch($0.swatch).opacity(0.045) } ?? Color.clear)
                    .frame(width: g.colW, height: height)
            }
        }
        .allowsHitTesting(false)
    }

    private func hourLabels(_ range: ApptHours) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(range.start..<range.end, id: \.self) { h in
                Text(String(format: "%02d:00", h % 24))
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 12)
                    .padding(.top, 5)
                    .frame(width: Self.gutter, height: 60 * Self.ppm, alignment: .topLeading)
                    .id(h)
            }
        }
    }

    /// 空格：點一下標出來、長按直接新預約
    private func tapLayer(_ g: ApptGeometry, height: CGFloat) -> some View {
        Color.clear
            .frame(width: max(g.contentWidth - Self.gutter, 1), height: height)
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { p in tapGrid(p, g) }
            .gesture(
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let d?) = value else { return }
                        longPressGrid(d.startLocation, g)
                    }
            )
            .offset(x: Self.gutter)
            .accessibilityHidden(true)
    }

    /// 點了空格：那一格框起來＋「新預約」
    @ViewBuilder
    private func pendingGhost(_ g: ApptGeometry) -> some View {
        if let p = pending, let ci = g.columns.firstIndex(where: { $0.id == p.columnId }) {
            let y = CGFloat(minuteOfDay(p.start) - g.range.start * 60) * Self.ppm
            let h = max(CGFloat(slot * 2) * Self.ppm, 44)
            Button {
                openNew(staffId: p.staffId, start: p.start)
            } label: {
                HStack(spacing: 6) {
                    HeroIcon("plus", size: 14)
                    Text("新預約 \(p.start.clockText)")
                        .font(.brand(14, .semibold))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 12)
                .frame(width: g.colW - 8, height: h, alignment: .leading)
                .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressScale(scale: 0.97))
            .offset(x: Self.gutter + CGFloat(ci) * g.colW + 4, y: y + 1)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .accessibilityLabel("新預約 \(p.start.clockText)")
        }
    }

    /// 新預約的面板開著時，在表上標出那一格（跟著面板裡選的人、時間動）
    @ViewBuilder
    private func draftGhost(_ g: ApptGeometry) -> some View {
        if let f = form, f.existing == nil, TaipeiTime.dayString(f.start) == dayKey,
           let ci = g.columns.firstIndex(where: { $0.id == (f.staffId ?? ApptColumn.unassigned) }) {
            let y = CGFloat(minuteOfDay(f.start) - g.range.start * 60) * Self.ppm
            let h = max(CGFloat(f.minutes) * Self.ppm - 2, 26)
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
                .overlay(alignment: .topLeading) {
                    Text("\(f.start.clockText) 新預約")
                        .font(.brand(12.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accentText)
                        .padding(8)
                }
                .frame(width: g.colW - 8, height: h)
                .offset(x: Self.gutter + CGFloat(ci) * g.colW + 4, y: y + 1)
                .allowsHitTesting(false)
                .animation(spring, value: f.start)
                .animation(spring, value: f.staffId)
        }
    }

    private func nowLine(_ g: ApptGeometry, now: Date) -> some View {
        let y = CGFloat(minuteOfDay(now) - g.range.start * 60) * Self.ppm
        let visible = y >= 0 && y <= CGFloat((g.range.end - g.range.start) * 60) * Self.ppm
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.dangerFG)
                .frame(width: max(g.contentWidth - Self.gutter, 1), height: 1.5)
                .shadow(color: Theme.dangerFG.opacity(0.5), radius: 3)
                .offset(x: Self.gutter)
            LiveDot(color: Theme.dangerFG)
                .offset(x: Self.gutter - 3.5)
            Text(now.clockText)
                .font(.brand(11, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.dangerFG, in: .capsule)
                .offset(x: 6)
        }
        .frame(height: 18)
        .offset(y: y - 9)
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
                let width = (g.colW - 8) / CGFloat(laneCount)
                for r in cluster {
                    let lane = lanes[r.id] ?? 0
                    let y = CGFloat(minuteOfDay(r.startsAt) - g.range.start * 60) * Self.ppm
                    let h = max(CGFloat(r.durationMinutes) * Self.ppm - 3, 28)
                    let x = Self.gutter + CGFloat(ci) * g.colW + 4 + CGFloat(lane) * width
                    let rect = CGRect(x: x, y: y + 1.5, width: max(width - 3, 24), height: h)
                    out.append(ApptPlaced(reservation: r, rect: rect, column: ci))
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

    // MARK: 一筆預約（點＝卡片、長按拖＝改時間）

    private func block(_ p: ApptPlaced, g: ApptGeometry, now: Date) -> some View {
        let r = p.reservation
        let col = g.columns[p.column]
        let staffName = col.staff == nil && r.staffId != nil ? model.staffName(r.staffId) : nil
        let color = col.staff.map { Theme.swatch($0.swatch) } ?? model.staffMember(r.staffId).map { Theme.swatch($0.swatch) }
        let isDragging = drag?.id == r.id
        let movable = r.status.isActive
        return ApptBlock(
            reservation: r,
            look: look(for: r),
            lateMinutes: lateMinutes(r, now: now),
            staffName: staffName,
            stylist: color,
            progress: progress(r, now: now),
            selected: selectedId == r.id,
            lifted: isDragging,
            size: p.rect.size
        )
        .frame(width: p.rect.width, height: p.rect.height)
        .contentShape(.rect)
        .onTapGesture { tapBlock(r) }
        // 只有還沒開始的預約可以拖（.subviews＝關掉這個手勢、點一下照常）
        .gesture(moveGesture(p, g: g), including: movable ? .all : .subviews)
        .offset(isDragging ? (drag?.translation ?? .zero) : .zero)
        .position(x: p.rect.midX, y: p.rect.midY)
        .zIndex(isDragging ? 20 : (selectedId == r.id ? 3 : 1))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "打開") { tapBlock(r) }
    }

    /// 長按 0.35 秒拿起來，再拖（在捲動的表上：沒長按就是捲動）
    private func moveGesture(_ p: ApptPlaced, g: ApptGeometry) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                switch value {
                case .first(true):
                    if drag?.id != p.id {
                        withAnimation(spring) {
                            drag = ApptDrag(id: p.id, translation: .zero, snap: "")
                            selectedId = nil
                            pending = nil
                        }
                        liftTick += 1
                    }
                case .second(true, let d?):
                    let target = dropTarget(p, translation: d.translation, g: g)
                    let key = "\(target.column)-\(target.start.timeIntervalSince1970)"
                    if drag?.snap != key { snapTick += 1 }
                    drag = ApptDrag(id: p.id, translation: d.translation, snap: key)
                default:
                    break
                }
            }
            .onEnded { value in
                guard case .second(true, let d?) = value else {
                    withAnimation(spring) { drag = nil }
                    return
                }
                finishMove(p, translation: d.translation, g: g)
            }
    }

    /// 拖到哪一欄、幾點（對齊格子；拖到「不指定」不換人：後台不能把指定的人拿掉）
    private func dropTarget(_ p: ApptPlaced, translation: CGSize, g: ApptGeometry) -> (column: Int, start: Date) {
        let r = p.reservation
        var ci = Int((p.rect.midX + translation.width - Self.gutter) / g.colW)
        ci = min(max(ci, 0), g.columns.count - 1)
        if g.columns[ci].staff == nil && r.staffId != nil { ci = p.column }
        let steps = (translation.height / Self.ppm / CGFloat(slot)).rounded()
        let start = r.startsAt.addingTimeInterval(Double(steps) * Double(slot) * 60)
        return (ci, start)
    }

    /// 拖的時候：放下去會在哪（虛線框＋時間、人）
    private func dropGhost(_ p: ApptPlaced, translation: CGSize, g: ApptGeometry) -> some View {
        let target = dropTarget(p, translation: translation, g: g)
        let r = p.reservation
        let y = CGFloat(minuteOfDay(target.start) - g.range.start * 60) * Self.ppm
        let who = g.columns[target.column].staff?.name ?? "不指定"
        let end = target.start.addingTimeInterval(Double(r.durationMinutes) * 60)
        let clash = !model.appointmentConflicts(staffId: g.columns[target.column].staff?.id ?? r.staffId, start: target.start,
                                                minutes: r.durationMinutes, ignoring: r.id).isEmpty
        let color = clash ? Theme.dangerFG : Theme.accent
        return RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(color.opacity(0.08), in: .rect(cornerRadius: Metric.radius))
            .overlay(alignment: .bottomLeading) {
                Text("\(target.start.clockText)–\(end.clockText)・\(who)\(clash ? "・撞到了" : "")")
                    .font(.brand(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color, in: .capsule)
                    .padding(6)
            }
            .frame(width: g.colW - 8, height: max(CGFloat(r.durationMinutes) * Self.ppm - 3, 28))
            .offset(x: Self.gutter + CGFloat(target.column) * g.colW + 4, y: y + 1.5)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : Motion.fast, value: target.start)
            .animation(reduceMotion ? nil : Motion.fast, value: target.column)
    }

    private func finishMove(_ p: ApptPlaced, translation: CGSize, g: ApptGeometry) {
        let target = dropTarget(p, translation: translation, g: g)
        let r = p.reservation
        let staffId = g.columns[target.column].staff?.id ?? r.staffId
        withAnimation(spring) { drag = nil }
        guard target.start != r.startsAt || staffId != r.staffId else { return }
        let request = ApptMoveRequest(reservation: r, start: target.start, staffId: staffId)
        let clash = model.appointmentConflicts(staffId: staffId, start: target.start, minutes: r.durationMinutes, ignoring: r.id)
        if clash.isEmpty {
            commitMove(request)
        } else {
            moveRequest = request
        }
    }

    private func commitMove(_ req: ApptMoveRequest) {
        let r = req.reservation
        Task {
            guard await model.reschedule(r, to: req.start, minutes: r.durationMinutes, staffId: req.staffId) != nil else { return }
            model.show("\(r.name) 改到 \(req.start.clockText)・\(model.staffName(req.staffId))")
        }
    }

    private func look(for r: Reservation) -> ApptLook {
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

    /// 服務中：做到哪了（開單的時間到預約的長度）
    private func progress(_ r: Reservation, now: Date) -> Double? {
        guard r.status == .seated, let t = model.openTicket(for: r) else { return nil }
        let elapsed = now.timeIntervalSince(t.openedAt) / 60
        return min(max(elapsed / Double(max(r.durationMinutes, 1)), 0), 1)
    }

    // MARK: 點空格、點預約

    private func tapBlock(_ r: Reservation) {
        model.touch()
        withAnimation(spring) {
            pending = nil
            selectedId = selectedId == r.id ? nil : r.id
        }
    }

    private func slotAt(_ p: CGPoint, _ g: ApptGeometry) -> ApptSlot {
        let ci = min(max(Int(p.x / g.colW), 0), g.columns.count - 1)
        let minute = g.range.start * 60 + Int(p.y / Self.ppm)
        let snapped = (minute / slot) * slot
        let col = g.columns[ci]
        return ApptSlot(columnId: col.id, staffId: col.staff?.id, start: day.addingTimeInterval(Double(snapped) * 60))
    }

    private func tapGrid(_ p: CGPoint, _ g: ApptGeometry) {
        model.touch()
        // 長按放開時也會算一次點：剛長按過就不理
        guard form == nil, Date().timeIntervalSince(lastLongPress) > 0.8 else { return }
        if selectedId != nil || pending != nil {
            withAnimation(spring) {
                selectedId = nil
                pending = nil
            }
            return
        }
        withAnimation(spring) { pending = slotAt(p, g) }
    }

    private func longPressGrid(_ p: CGPoint, _ g: ApptGeometry) {
        lastLongPress = Date()
        let s = slotAt(p, g)
        liftTick += 1
        openNew(staffId: s.staffId, start: s.start)
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
            pending = nil
            form = ApptFormRequest(existing: nil, staffId: staffId, start: start, minutes: max(slot * 4, 60))
        }
    }

    private func openEdit(_ r: Reservation) {
        model.keypad.cancel()
        withAnimation(anim) {
            selectedId = nil
            pending = nil
            form = ApptFormRequest(existing: r, staffId: r.staffId, start: r.startsAt, minutes: r.durationMinutes)
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
        let gap: CGFloat = 12
        let x: CGFloat
        if p.rect.maxX + gap + w <= g.contentWidth {
            x = p.rect.maxX + gap + w / 2
        } else if p.rect.minX - gap - w >= Self.gutter {
            x = p.rect.minX - gap - w / 2
        } else {
            x = min(max(p.rect.midX, Self.gutter + w / 2), max(g.contentWidth - w / 2, Self.gutter + w / 2))
        }
        let top = min(max(p.rect.minY, 6), max(height - h - 6, 6))
        let stylist = model.staffMember(p.reservation.staffId)
        return ApptCard(
            reservation: p.reservation,
            stylist: stylist,
            slot: slot,
            onClose: { withAnimation(spring) { selectedId = nil } },
            onEdit: { openEdit(p.reservation) },
            onConfirm: { status in confirming = ApptStatusRequest(reservation: p.reservation, status: status) }
        )
        .frame(width: Self.cardWidth)
        .onGeometryChange(for: CGSize.self, of: { proxy in proxy.size }, action: { newSize in cardSize = newSize })
        .position(x: x, y: top + h / 2)
        .transition(.scale(scale: 0.96, anchor: .leading).combined(with: .opacity))
    }

    // MARK: 確認（未到、取消、撞時間）

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

    private var moveBinding: Binding<Bool> {
        Binding(get: { moveRequest != nil }, set: { if !$0 { moveRequest = nil } })
    }

    private func moveMessage(_ req: ApptMoveRequest) -> String {
        let r = req.reservation
        let clash = model.appointmentConflicts(staffId: req.staffId, start: req.start, minutes: r.durationMinutes, ignoring: r.id)
        let names = clash.map { "\($0.startsAt.clockText) \($0.name)" }.joined(separator: "、")
        return "\(model.staffName(req.staffId)) 在 \(req.start.clockText) 已經有 \(names)。"
    }

    // MARK: 新增／編輯面板

    @ViewBuilder
    private var formPanel: some View {
        if let f = form {
            ApptFormPanel(request: f, slot: slot, onDraft: { staffId, start, minutes in
                // 面板裡換人、換時間：表上的虛線框跟著動
                form?.staffId = staffId
                form?.start = start
                form?.minutes = minutes
            }, onClose: { closeForm() })
            .id(f.id)
            .frame(width: 480)
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
    /// 第幾欄
    let column: Int
    var id: String { reservation.id }
}

private struct ApptSlot: Equatable {
    let columnId: String
    let staffId: String?
    let start: Date
}

private struct ApptDrag: Equatable {
    let id: String
    var translation: CGSize
    /// 放下去會落在哪一格（換格時震一下）
    var snap: String
}

private struct ApptMoveRequest: Identifiable {
    let reservation: Reservation
    let start: Date
    let staffId: String?
    var id: String { reservation.id }
}

private struct ApptFormRequest: Identifiable {
    let id = UUID()
    var existing: Reservation?
    var staffId: String?
    var start: Date
    var minutes: Int
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

    /// 左邊那條狀態色
    var edge: Color {
        switch self {
        case .booked: Theme.infoFG
        case .arrived: Theme.accent
        case .serving: Theme.successFG
        case .done: Theme.faint
        case .missed: Theme.dangerFG
        case .cancelled: Theme.faint
        }
    }
}

/// 共用的文字
private enum ApptText {
    /// 「剪髮・染髮」
    static func services(_ r: Reservation) -> String {
        let names = (r.services ?? []).map { $0.name }
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

    /// 「1 小時 30 分」
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) 分" }
        return m == 0 ? "\(h) 小時" : "\(h) 小時 \(m) 分"
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

// MARK: - 空的時候

/// 還沒有人可以排：請後台設定
private struct ApptNoStaff: View {
    let title: String

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: -12) {
                ForEach(Array([Swatch.rose, .lavender, .mint].enumerated()), id: \.offset) { _, s in
                    Circle()
                        .fill(Theme.swatch(s))
                        .frame(width: 56, height: 56)
                        .overlay { Circle().strokeBorder(Theme.page, lineWidth: 3) }
                }
            }
            Headline("Who's on *today*?", role: .h3)
            Text("還沒有可以排預約的\(title)。到後台「門市 POS → 人員」勾選「排進預約表」，這裡會一人一欄。")
                .textRole(.body)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface.opacity(0.55), in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
    }
}

/// 這一天還沒有預約：一張安靜的卡（三條淡淡的預約示意，用設計師的顏色）
private struct ApptQuietDay: View {
    let colors: [Color]
    let isToday: Bool

    private static let heights: [CGFloat] = [64, 40, 52]
    private static let offsets: [CGFloat] = [0, 18, 8]

    var body: some View {
        let palette = colors.isEmpty ? [Theme.swatch(.rose), Theme.swatch(.sky), Theme.swatch(.sage)] : colors
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(palette.prefix(3).enumerated()), id: \.offset) { i, c in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(c.opacity(0.55))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.ink.opacity(0.18)).frame(width: 3)
                        }
                        .clipShape(.rect(cornerRadius: 6))
                        .frame(width: 54, height: Self.heights[i % 3])
                        .offset(y: Self.offsets[i % 3])
                }
            }
            .frame(height: 86, alignment: .top)
            Headline(isToday ? "A quiet *day*" : "Nothing *booked*", role: .h3)
            Text("點一下空格、或長按空格直接新增預約")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .background(Theme.dock.opacity(0.92), in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
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
                    hourPath.move(to: CGPoint(x: left - 8, y: y))
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .textRole(.small)
                .foregroundStyle(Theme.muted)
            Text("\(value)")
                .font(.brand(26, .medium))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(value)))
        }
        .accessibilityElement(children: .combine)
    }
}

/// 這個人今天被約滿了幾成（用這個人的顏色）
private struct ApptUtilisation: View {
    let ratio: Double
    let count: Int
    let color: Color?

    var body: some View {
        let percent = Int((ratio * 100).rounded())
        HStack(spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.press)
                    Capsule()
                        .fill(color ?? Theme.ink2)
                        .overlay { Capsule().strokeBorder(Theme.ink.opacity(0.15), lineWidth: 0.5) }
                        .frame(width: max(geo.size.width * ratio, ratio > 0 ? 6 : 0))
                }
            }
            .frame(width: 64, height: 6)
            Text("\(count) 位・\(percent)%")
                .font(.brand(11.5, .medium))
                .monospacedDigit()
                .foregroundStyle(ratio >= 0.85 ? Theme.accentText : Theme.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) 個預約，排滿 \(percent)%")
    }
}

/// 表上的一筆預約：設計師顏色的底、左邊一條狀態色、客人名字大大的、服務一顆一顆、服務中有進度條
private struct ApptBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reservation: Reservation
    let look: ApptLook
    let lateMinutes: Int?
    /// 指定的人不在預約表上（放在「不指定」）：標出名字
    let staffName: String?
    /// 設計師的顏色
    let stylist: Color?
    /// 服務中：做到幾成
    let progress: Double?
    let selected: Bool
    /// 正在拖
    let lifted: Bool
    let size: CGSize

    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
        content
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .padding(.vertical, size.height < 48 ? 4 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { fillLayer(shape) }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(lateMinutes == nil ? look.edge : Theme.warningFG)
                    .frame(width: 4)
            }
            .overlay(alignment: .bottom) {
                if let progress {
                    ApptProgress(value: progress)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(stroke, style: strokeStyle) }
            .overlay {
                if selected {
                    shape.stroke(Theme.ink, lineWidth: 2).padding(-3)
                }
            }
            .opacity(look == .cancelled || look == .missed ? 0.62 : 1)
            .scaleEffect(lifted ? 1.03 : 1)
            .shadow(color: .black.opacity(lifted ? 0.3 : (selected ? 0.16 : 0)), radius: lifted ? 18 : 10, y: lifted ? 10 : 4)
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
    private func fillLayer(_ shape: RoundedRectangle) -> some View {
        switch look {
        case .booked:
            ZStack {
                shape.fill(Theme.surface)
                shape.fill((stylist ?? Theme.swatch(.sand)).opacity(0.32))
            }
        case .arrived:
            ZStack {
                shape.fill(Theme.surface)
                shape.fill(Theme.accentSoft)
            }
        case .serving:
            ZStack {
                shape.fill(Theme.surface)
                shape.fill(Theme.successFG.opacity(0.1))
            }
        case .done:
            shape.fill(Theme.pageAlt)
        case .missed:
            shape.fill(Theme.dangerFG.opacity(0.07))
        case .cancelled:
            shape.fill(Theme.page.opacity(0.6))
        }
    }

    @ViewBuilder
    private var content: some View {
        let r = reservation
        if size.height < 48 {
            HStack(spacing: 6) {
                Text(r.startsAt.clockText)
                    .font(.brand(11.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                Text(r.name.isEmpty ? "未留名字" : r.name)
                    .font(.brand(14, .semibold))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ApptText.timeRange(r))
                        .font(.brand(11.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.brand(10.5, .semibold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.14), in: .capsule)
                            .lineLimit(1)
                    }
                }
                Text(r.name.isEmpty ? "未留名字" : r.name)
                    .font(.brand(size.height >= 90 ? 18 : 16, .semibold))
                    .foregroundStyle(primary)
                    .strikethrough(look == .cancelled)
                    .lineLimit(1)
                if size.height >= 76 {
                    serviceChips
                }
                if size.height >= 120 {
                    Spacer(minLength: 0)
                    Text(footer)
                        .font(.brand(11.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 服務一顆一顆（放不下就「＋2」）
    private var serviceChips: some View {
        let names = (reservation.services ?? []).map { $0.name }
        let shown = Array(names.prefix(size.width >= 170 ? 2 : 1))
        let more = names.count - shown.count
        return HStack(spacing: 4) {
            if names.isEmpty {
                Text("沒有指定服務")
                    .font(.brand(11.5, .medium))
                    .foregroundStyle(Theme.muted)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, n in
                Text(n)
                    .font(.brand(11.5, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.page.opacity(0.55), in: .capsule)
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.brand(11, .semibold))
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    private var footer: String {
        var parts = [ApptText.duration(reservation.durationMinutes)]
        if let staffName { parts.append(staffName) }
        parts.append(ApptText.masked(reservation.phone))
        return parts.joined(separator: "・")
    }

    private var statusText: String {
        if let m = lateMinutes { return "晚 \(m) 分" }
        switch look {
        case .booked: return ""
        case .serving:
            if let p = progress { return "服務中 \(Int((p * 100).rounded()))%" }
            return look.label
        case .arrived, .done, .missed, .cancelled: return look.label
        }
    }

    private var stroke: Color {
        switch look {
        case .booked: Theme.line
        case .arrived: Theme.accent.opacity(pulse ? 1 : 0.35)
        case .serving: Theme.successFG.opacity(0.45)
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
        case .done, .cancelled: Theme.muted
        case .booked, .arrived, .serving, .missed: Theme.ink
        }
    }

    private var statusColor: Color {
        if lateMinutes != nil { return Theme.warningFG }
        switch look {
        case .booked: return Theme.infoFG
        case .arrived: return Theme.accentText
        case .serving: return Theme.successFG
        case .done: return Theme.muted
        case .missed: return Theme.dangerFG
        case .cancelled: return Theme.muted
        }
    }

    private var accessibilityText: String {
        let r = reservation
        var parts = [ApptText.timeRange(r), r.name, ApptText.services(r), look.label]
        if let m = lateMinutes { parts.append("晚了 \(m) 分鐘") }
        if let p = progress { parts.append("做了 \(Int((p * 100).rounded()))%") }
        if let staffName { parts.append(staffName) }
        return parts.joined(separator: "，")
    }
}

/// 服務中的進度（卡片最下面一條細線）
private struct ApptProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.successFG.opacity(0.18))
                Rectangle().fill(Theme.successFG).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

// MARK: - 預約的卡片

private struct ApptCard: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reservation: Reservation
    let stylist: StaffMember?
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
        .background(Theme.dock)
        .overlay(alignment: .top) {
            // 上緣一條設計師的顏色
            Rectangle()
                .fill(stylist.map { Theme.swatch($0.swatch) } ?? Theme.line)
                .frame(height: 4)
        }
        .clipShape(.rect(cornerRadius: Metric.radiusLg))
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
        return HStack(alignment: .center, spacing: 12) {
            ApptInitial(name: r.name.isEmpty ? "客" : r.name, swatch: stylist?.swatch ?? .sand, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name.isEmpty ? "未留名字" : r.name)
                    .font(.brand(21, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text("\(ApptText.timeRange(r))・\(ApptText.duration(r.durationMinutes))")
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
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
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusBadge(r.status.label(for: .appointment), tone: tone(r.status))
                if let s = stylist {
                    HStack(spacing: 6) {
                        StaffAvatar(name: s.name, swatch: s.swatch, size: 20)
                        Text(s.name)
                            .font(.brand(13, .medium))
                            .foregroundStyle(Theme.ink2)
                    }
                } else {
                    Text("不指定\(model.mode.staffTitle)")
                        .font(.brand(13, .medium))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(Array((r.services ?? []).enumerated()), id: \.offset) { _, s in
                    ApptServicePill(name: s.name, minutes: s.durationMinutes, price: s.price,
                                    staff: s.staffId.flatMap { $0 == r.staffId ? nil : model.staffName($0) })
                }
                if (r.services ?? []).isEmpty {
                    Text("沒有指定服務")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                HeroIcon("phone", size: 14)
                    .foregroundStyle(Theme.muted)
                Text(showPhone ? ApptText.grouped(r.phone) : ApptText.masked(r.phone))
                    .font(.brand(15, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
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
                    ForEach(account.usablePasses(at: Date()).prefix(3)) { p in
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

    // MARK: 動作（一個主要、最多兩個次要，其他收進「⋯」；取消、未到在「⋯」裡、要確認）

    private var actions: some View {
        let r = reservation
        return VStack(alignment: .leading, spacing: 8) {
            if let t = ticket {
                // 服務中：收錢的崗位主要是「去結帳」；報到接待只看單（結帳在櫃台）
                if model.role.takesPayment {
                    Button {
                        model.beginCheckout(t)
                    } label: {
                        Text("去結帳")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.brand(.accent, size: .lg, fullWidth: true, arrow: true))
                    ApptActionRow(secondary: [viewTicketAction(t)], more: [editAction])
                } else {
                    Button {
                        model.selectedTicketId = t.id
                    } label: {
                        Text("看單 \(t.number)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.brand(.primary, size: .lg, fullWidth: true))
                    ApptHandOffNote(text: "\(t.number)・\(t.totals.amountDue.formatted) 已同步到結帳櫃台")
                    ApptActionRow(secondary: [], more: [editAction])
                }
            } else if let t = closedTicket {
                HStack(spacing: 10) {
                    ApptDoneNote(text: "已結帳 \(t.number)")
                    MoreMenu(actions: [editAction])
                }
            } else if r.status == .seated && r.ticketId != nil {
                // 開過單、這台已經沒有那張單（iPad 只留最近兩天，或在別台結的）：不要再開一張
                HStack(spacing: 10) {
                    ApptDoneNote(text: "服務完成・單子在結帳紀錄裡")
                    MoreMenu(actions: [editAction])
                }
            } else if r.status.isActive || r.status == .seated {
                Button {
                    startService()
                } label: {
                    Text(busy ? "開單中…" : "開始服務")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.primary, size: .lg, fullWidth: true, arrow: true))
                .disabled(busy)
                ApptActionRow(secondary: activeSecondary(r), more: activeMore(r))
            } else if r.status == .cancelled || r.status == .noShow {
                // 按錯了：改回來（這時候只有這一個動作）
                Button {
                    Task { await model.markAppointment(r, status: .booked) }
                } label: {
                    Label {
                        Text("改回已預約")
                    } icon: {
                        HeroIcon("arrow-uturn-left", size: 15)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))
            }
        }
    }

    private var editAction: POSAction {
        POSAction("編輯", icon: "pencil-square") { onEdit() }
    }

    private func viewTicketAction(_ t: Ticket) -> POSAction {
        POSAction("看單 \(t.number)", icon: "squares-2x2") { model.selectedTicketId = t.id }
    }

    /// 次要：還沒到 →「到店」；可以改的 →「改時間」
    private func activeSecondary(_ r: Reservation) -> [POSAction] {
        var list: [POSAction] = []
        if r.status == .booked || r.status == .notified {
            list.append(POSAction("到店", icon: "check") { Task { await model.markAppointment(r, status: .arrived) } })
        }
        if r.status.isActive {
            list.append(POSAction("改時間", icon: "clock") { beginReschedule() })
        }
        return list
    }

    private func activeMore(_ r: Reservation) -> [POSAction] {
        var list = [editAction]
        if r.status.isActive {
            list.append(POSAction("未到", icon: "no-symbol", destructive: true) { onConfirm(.noShow) })
            list.append(POSAction("取消預約", icon: "x-circle", destructive: true) { onConfirm(.cancelled) })
        }
        return list
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
            ApptStepper(label: "時間", value: ApptText.duration(draftMinutes),
                        minus: { resize(-slot) }, plus: { resize(slot) })
            VStack(alignment: .leading, spacing: 8) {
                Text(model.mode.staffTitle)
                    .textRole(.label)
                    .foregroundStyle(Theme.muted)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.bookableStaff) { s in
                            ApptStaffPick(staff: s, selected: draftStaff == s.id, busy: false) {
                                draftStaff = s.id
                                conflictAcknowledged = false
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
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

    private func resize(_ minutes: Int) {
        draftMinutes = min(max(draftMinutes + minutes, slot), 600)
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

/// 客人的頭像（名字第一個字，設計師的顏色）
private struct ApptInitial: View {
    let name: String
    let swatch: Swatch
    var size: CGFloat = 40

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.brand(size * 0.42, .semibold))
            .foregroundStyle(Theme.tileInk)
            .frame(width: size, height: size)
            .background(Theme.swatch(swatch), in: .circle)
            .accessibilityHidden(true)
    }
}

/// 一項服務：名字、時間、（另外指定的人）、價格
private struct ApptServicePill: View {
    let name: String
    let minutes: Int
    let price: Money?
    let staff: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.brand(13.5, .semibold))
                .foregroundStyle(Theme.ink)
            Text("\(minutes) 分")
                .font(.brand(12, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            if let staff {
                Text(staff)
                    .font(.brand(12, .medium))
                    .foregroundStyle(Theme.ink2)
            }
            if let price {
                Text(price.short)
                    .font(.brand(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.surface, in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
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

/// 卡片下面的次要動作：「⋯」＋最多兩個細框按鈕（撐滿寬度，字不截斷）
private struct ApptActionRow: View {
    let secondary: [POSAction]
    let more: [POSAction]

    var body: some View {
        HStack(spacing: 8) {
            if !overflow.isEmpty {
                MoreMenu(actions: overflow)
            }
            ForEach(Array(secondary.prefix(2))) { a in
                Button(action: a.perform) {
                    HStack(spacing: 6) {
                        if let icon = a.icon { HeroIcon(icon, size: 15) }
                        Text(a.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))
                .disabled(!a.isEnabled)
            }
            if secondary.isEmpty {
                Spacer(minLength: 0)
            }
        }
    }

    private var overflow: [POSAction] { Array(secondary.dropFirst(2)) + more }
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

/// 選設計師：大頭貼（這個人的顏色）＋名字；這個時段有約的右上角一個點
private struct ApptStaffPick: View {
    let staff: StaffMember?
    let selected: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    if let s = staff {
                        StaffAvatar(name: s.name, swatch: s.swatch, size: 52, active: selected)
                    } else {
                        Circle()
                            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: 52, height: 52)
                            .overlay { HeroIcon("user", size: 20).foregroundStyle(Theme.muted) }
                            .overlay {
                                if selected { Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3) }
                            }
                    }
                    if busy {
                        Circle()
                            .fill(Theme.warningFG)
                            .frame(width: 10, height: 10)
                            .overlay { Circle().strokeBorder(Theme.dock, lineWidth: 2) }
                    }
                }
                Text(staff?.name ?? "不指定")
                    .font(.brand(12.5, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
                Text(busy ? "這時段有約" : (staff?.title ?? " "))
                    .font(.brand(10.5, .medium))
                    .foregroundStyle(busy ? Theme.warningFG : Theme.muted)
                    .lineLimit(1)
            }
            .frame(width: 76)
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.95))
        .accessibilityLabel((staff?.name ?? "不指定") + (busy ? "，這個時段有約" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    /// 換人、換時間、換長度時告訴預約表（虛線框跟著動）
    let onDraft: (String?, Date, Int) -> Void
    let onClose: () -> Void

    @State private var phone: String
    @State private var name: String
    @State private var memberId: String?
    @State private var memberState: ApptMemberState
    @State private var joinAsMember = true
    @State private var picked: [ApptPicked]
    @State private var categoryId: String?
    @State private var staffId: String?
    @State private var start: Date
    @State private var note: String
    @State private var askingPhone = false
    @State private var saving = false
    @State private var problem: String? = nil
    @FocusState private var nameFocused: Bool

    init(request: ApptFormRequest, slot: Int, onDraft: @escaping (String?, Date, Int) -> Void, onClose: @escaping () -> Void) {
        self.request = request
        self.slot = slot
        self.onDraft = onDraft
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
        _categoryId = State(initialValue: nil)
        _staffId = State(initialValue: r?.staffId ?? request.staffId)
        _start = State(initialValue: r?.startsAt ?? request.start)
        _note = State(initialValue: r?.note ?? "")
    }

    private var isNew: Bool { request.existing == nil }

    private var anim: Animation? { reduceMotion ? nil : Motion.fast }
    private var spring: Animation? { reduceMotion ? nil : Motion.spring }

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
                VStack(alignment: .leading, spacing: 26) {
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
        .onChange(of: totalMinutes) { _, m in onDraft(staffId, start, m) }
        .task {
            onDraft(staffId, start, totalMinutes)
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
                if case .found = memberState, let m = member {
                    ApptMemberChip(member: m, account: model.account(for: m.ref), onSwitch: {
                        Task { await askPhone() }
                    })
                } else {
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
    }

    @ViewBuilder
    private var memberLine: some View {
        switch memberState {
        case .idle, .found:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                Text("查會員中…")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
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

    // MARK: 服務（一格一格挑，像菜單）

    private var serviceItems: [MenuItem] {
        model.catalog.items.filter { $0.itemKind == .service && model.isAvailable($0) }
    }

    private var serviceCategories: [MenuCategory] {
        let ids = Set(serviceItems.map { $0.categoryId })
        return model.catalog.categories.filter { ids.contains($0.id) }
    }

    private var servicesSection: some View {
        let items = serviceItems
        let cats = serviceCategories
        let current = categoryId ?? cats.first?.id
        let shown = items.filter { current == nil || $0.categoryId == current }
        return ApptField(label: picked.isEmpty ? "服務" : "服務・共 \(ApptText.duration(totalMinutes))・\(totalPrice.formatted)") {
            VStack(alignment: .leading, spacing: 14) {
                if !picked.isEmpty {
                    FlowLayout(spacing: 6, rowSpacing: 6) {
                        ForEach(picked) { p in
                            pickedChip(p)
                        }
                    }
                }
                if items.isEmpty {
                    Text("菜單上還沒有「服務」類的品項（到後台菜單把品項種類設成服務、填上時間）")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if cats.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(cats) { c in
                                    categoryTab(c, selected: c.id == current)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                        ForEach(shown) { item in
                            ApptServiceTile(
                                item: item,
                                swatch: model.catalog.category(item.categoryId)?.swatch ?? .sand,
                                selected: picked.contains { $0.itemId == item.id }
                            ) {
                                toggle(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func categoryTab(_ c: MenuCategory, selected: Bool) -> some View {
        Button {
            withAnimation(anim) { categoryId = c.id }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.swatch(c.swatch))
                    .frame(width: 9, height: 9)
                Text(c.name)
                    .font(.brand(14, selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? Theme.page : Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(selected ? Theme.ink : Color.clear, in: .capsule)
            .overlay { Capsule().strokeBorder(selected ? Color.clear : Theme.line, lineWidth: 1) }
            .contentShape(.capsule)
        }
        .buttonStyle(.press)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pickedChip(_ p: ApptPicked) -> some View {
        HStack(spacing: 6) {
            Text(p.name)
                .font(.brand(14, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Button {
                askMinutes(p)
            } label: {
                Text("\(p.minutes) 分")
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accentText)
                    .underline()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(p.name) 時間 \(p.minutes) 分鐘，點一下用右邊鍵盤改")
            Button {
                remove(p)
            } label: {
                HeroIcon("x-mark", size: 11)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("拿掉 \(p.name)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(Theme.surface, in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func toggle(_ item: MenuItem) {
        withAnimation(spring) {
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
        withAnimation(spring) { picked.removeAll { $0.id == p.id } }
    }

    private func askMinutes(_ p: ApptPicked) {
        nameFocused = false
        Task {
            guard let m = await model.keypad.askNumber(.duration(name: p.name, current: p.minutes)) else { return }
            if let i = picked.firstIndex(where: { $0.id == p.id }) { picked[i].minutes = m }
        }
    }

    // MARK: 服務人員

    private var staffSection: some View {
        ApptField(label: model.mode.staffTitle) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.bookableStaff) { s in
                        ApptStaffPick(staff: s, selected: staffId == s.id, busy: isBusy(s.id)) {
                            pickStaff(s.id)
                        }
                    }
                    // 已經指定了人的預約，後台不能改回「不指定」（只送要改的欄位）
                    if isNew || request.existing?.staffId == nil {
                        ApptStaffPick(staff: nil, selected: staffId == nil, busy: false) {
                            pickStaff(nil)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func pickStaff(_ id: String?) {
        withAnimation(spring) { staffId = id }
        onDraft(staffId, start, totalMinutes)
    }

    /// 這個時段這個人有約了嗎（選人時看得到）
    private func isBusy(_ id: String) -> Bool {
        !model.appointmentConflicts(staffId: id, start: start, minutes: totalMinutes, ignoring: request.existing?.id).isEmpty
    }

    // MARK: 時間（大大的時間＋這個人接下來的空檔）

    private var timeSection: some View {
        let end = start.addingTimeInterval(Double(totalMinutes) * 60)
        let openings = freeSlots()
        return ApptField(label: "時間・\(start.dayTitle)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    HStack(spacing: 0) {
                        Button {
                            shift(-slot)
                        } label: {
                            HeroIcon("minus", size: 15)
                                .frame(width: 48, height: 56)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("早 \(slot) 分鐘")
                        Text(start.clockText)
                            .font(.brand(30, .medium))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .frame(minWidth: 96)
                        Button {
                            shift(slot)
                        } label: {
                            HeroIcon("plus", size: 15)
                                .frame(width: 48, height: 56)
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
                            .font(.brand(17, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink2)
                        Text(ApptText.duration(totalMinutes))
                            .textRole(.xs)
                            .foregroundStyle(Theme.muted)
                        if start < Date().addingTimeInterval(-5 * 60) {
                            Text("這個時間已經過了")
                                .textRole(.xs)
                                .foregroundStyle(Theme.warningFG)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !openings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(model.staffName(staffId)) 接下來的空檔")
                            .textRole(.xs)
                            .foregroundStyle(Theme.muted)
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            ForEach(openings, id: \.self) { t in
                                OptionChip(title: t.clockText, selected: t == start) {
                                    withAnimation(spring) { start = t }
                                    onDraft(staffId, start, totalMinutes)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 這個人這一天還空著、放得下這次服務的時間（最多 6 個，從現在或開門算起）
    private func freeSlots() -> [Date] {
        guard let id = staffId else { return [] }
        let dayStart = Calendar.taipei.startOfDay(for: start)
        let close = dayStart.addingTimeInterval(22 * 3600)
        var t = dayStart.addingTimeInterval(9 * 3600)
        let soon = Date().addingTimeInterval(Double(slot) * 60)
        if t < soon {
            let minutes = Int(soon.timeIntervalSince(dayStart) / 60)
            t = dayStart.addingTimeInterval(Double(((minutes + slot - 1) / slot) * slot) * 60)
        }
        let length = totalMinutes
        let step = Double(slot) * 60
        let jump = Double(max(slot, 30)) * 60
        var out: [Date] = []
        while t.addingTimeInterval(Double(length) * 60) <= close && out.count < 6 {
            if model.appointmentConflicts(staffId: id, start: t, minutes: length, ignoring: request.existing?.id).isEmpty {
                out.append(t)
                t = t.addingTimeInterval(jump)
            } else {
                t = t.addingTimeInterval(step)
            }
        }
        return out
    }

    private func shift(_ minutes: Int) {
        withAnimation(anim) { start = start.addingTimeInterval(Double(minutes) * 60) }
        onDraft(staffId, start, totalMinutes)
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

    // MARK: 下面：一句話總結＋建立

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // 名字、服務、時間不截斷：放不下就換行
                if let problem {
                    Text(problem)
                        .textRole(.small)
                        .foregroundStyle(Theme.dangerFG)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(summaryTitle)
                        .font(.brand(15, .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summaryDetail)
                        .textRole(.xs)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
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

    private var summaryTitle: String {
        let who = name.trimmingCharacters(in: .whitespaces)
        let display = who.isEmpty ? (member?.name ?? (phone.isEmpty ? "客人" : MemberRef(phone: phone).maskedPhone)) : who
        let what = picked.isEmpty ? "" : "・" + picked.map { $0.name }.joined(separator: "＋")
        return display + what
    }

    private var summaryDetail: String {
        "\(start.clockText)–\(start.addingTimeInterval(Double(totalMinutes) * 60).clockText)・\(model.staffName(staffId))"
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
        withAnimation(spring) {
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

/// 一項服務的格子（分類的粉彩色，和點餐畫面同一套）：名字、幾分鐘、價格；選了打勾
private struct ApptServiceTile: View {
    let item: MenuItem
    let swatch: Swatch
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(item.durationMinutes.map { "\($0) 分" } ?? "—")
                        .font(.brand(12, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tileInkMuted)
                    Spacer(minLength: 0)
                    ZStack {
                        Circle()
                            .fill(selected ? Theme.tileInk : Color.clear)
                            .overlay { Circle().strokeBorder(Theme.tileInk.opacity(0.35), lineWidth: selected ? 0 : 1.5) }
                        if selected {
                            HeroIcon("check", size: 12)
                                .foregroundStyle(Theme.swatch(swatch))
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                Spacer(minLength: 10)
                Text(item.name)
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.tileInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.openPrice ? "依現場報價" : item.price.formatted)
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tileInkMuted)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .background(Theme.swatch(swatch), in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: selected ? 2.5 : 0)
                    .padding(-4)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.96))
        .animation(Motion.fast, value: selected)
        .accessibilityLabel("\(item.name)，\(item.durationMinutes.map { "\($0) 分鐘" } ?? "")，\(item.price.formatted)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        VStack(alignment: .leading, spacing: 10) {
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

/// 查到的會員：頭像、名字、等級、儲值金、能用的卡、上次做了什麼（點「換人」重查）
private struct ApptMemberChip: View {
    let member: Member
    let account: MemberAccount?
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ApptInitial(name: member.name ?? "會", swatch: .sage, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(member.name ?? "會員")
                            .font(.brand(19, .semibold))
                            .foregroundStyle(Theme.ink)
                        if let tier = member.tierName {
                            StatusBadge(tier, tone: .gold)
                        }
                    }
                    Text("\(member.ref.maskedPhone)・來過 \(member.visits) 次")
                        .font(.brand(12.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                Button("換人", action: onSwitch)
                    .buttonStyle(.brand(.quiet, size: .sm))
            }
            if let account {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("儲值金")
                            .textRole(.xs)
                            .foregroundStyle(Theme.muted)
                        MoneyText(money: account.wallet, role: .h4)
                    }
                    let passes = account.usablePasses(at: Date())
                    if !passes.isEmpty {
                        Rule(vertical: true).frame(height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(passes.prefix(2)) { p in
                                Text("\(p.name)・\(p.statusText(at: Date()))")
                                    .font(.brand(12.5, .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.ink2)
                                    .lineLimit(1)
                            }
                        }
                    }
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
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.successFG.opacity(0.35), lineWidth: 1)
        }
    }
}
