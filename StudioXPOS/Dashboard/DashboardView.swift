import Charts
import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 報表：一天（或這一班）的營業。
///
///   ┌ Today's numbers ─────────────────── ‹ 10月4日 › [今天][這一班] ┐
///   │ ┌營業額（橘）┐ ┌單數┐ ┌客單價┐ ┌來客數┐                          │
///   │ 折扣｜退款｜服務費｜作廢                                         │
///   │ 實收｜儲值｜課程卡｜卡抵用｜報到（美業、課程、服飾才有）            │
///   │ ┌每小時營業額（長條）────────────┐ ┌付款方式（甜甜圈）┐          │
///   │ ┌設計師業績（每個人的長條、抽成、助理）──────────────────┐       │
///   │ ┌熱賣品項────────┐ ┌分類──────────┐                            │
///   │ ┌作廢・折扣・發票┐ ┌現在（開著的單）┐ ┌各營業模式┐               │
///   └────────────────────────────────────────────────────────────────┘
///
/// 今天、昨天用這台的事件算（自己記的＋已經同步進來的其他裝置）；更早的跟後台要（model.history），
/// 用同一套 SalesSummary 算，所以數字的意思一樣。
struct DashboardView: View {
    @Environment(POSModel.self) private var model
    @State private var range: DashRange = .today
    /// 看哪一天（nil＝今天：過了營業日的分界會自己換到新的一天）
    @State private var day: String?
    /// 跟後台要不到的日子（離線）：畫面上給「重試」
    @State private var offlineDays: Set<String> = []

    var body: some View {
        let date = day ?? model.businessDate
        let isToday = date == model.businessDate
        let shift = isToday ? model.openShift : nil
        let showingShift = range == .shift && shift != nil
        let summary = makeSummary(date: date, shift: showingShift ? shift : nil)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(date: date, shift: shift, showingShift: showingShift)
                if let summary {
                    DashReport(
                        summary: summary,
                        compare: isToday && !showingShift ? yesterdaySameTime() : nil,
                        bars: hourBars(summary, live: isToday && !showingShift),
                        liveHour: isToday && !showingShift ? currentHour : nil,
                        isToday: isToday
                    )
                } else if offlineDays.contains(date) {
                    DashRemoteState(loading: false, title: "連不到後台", message: "更早的報表存在後台；連上網路後再試一次",
                                    retry: { Task { await loadIfNeeded(date) } })
                } else {
                    DashRemoteState(loading: true, title: "向後台拿這天的報表…", message: "這台 iPad 只留最近兩天；更早的在後台", retry: nil)
                }
                footnote(date: date)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .task(id: date) { await loadIfNeeded(date) }
    }

    // MARK: - 上面

    private func header(date: String, shift: Shift?, showingShift: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            PageTitle(title: showingShift ? "This *shift*" : (date == model.businessDate ? "Today's *numbers*" : "Past *numbers*"),
                      subtitle: subtitle(date: date, shift: shift, showingShift: showingShift))
            Spacer(minLength: 12)
            DashDayBar(title: DashDays.short(date, today: model.businessDate), isToday: date == model.businessDate,
                       step: { stepDay(from: date, by: $0) }, today: { goToday() })
            if date == model.businessDate {
                DashRangePicker(selected: showingShift ? .shift : .today, shiftAvailable: shift != nil) { r in
                    withAnimation(Motion.fast) { range = r }
                }
            }
        }
    }

    private func subtitle(date: String, shift: Shift?, showingShift: Bool) -> String {
        if showingShift, let shift {
            return "報表・這一班 \(shift.openedAt.clockText) 開班・\(model.staffName(shift.openedBy))"
        }
        let title = DashDays.noon(date)?.dayTitle ?? date
        return model.isLocal(date: date) ? "報表・\(title)" : "報表・\(title)・後台的資料"
    }

    private func stepDay(from date: String, by delta: Int) {
        guard let next = DashDays.shift(date, by: delta) else { return }
        // 不往未來走；回到今天就交給 nil（跟著營業日換日）
        day = next >= model.businessDate ? nil : next
        if day != nil { range = .today }
        model.touch()
    }

    private func goToday() {
        day = nil
    }

    // MARK: - 資料

    /// 這一班、這台還有的日子（今天、昨天）在這台算；更早的用後台那天的資料（還沒拿到是 nil）
    private func makeSummary(date: String, shift: Shift?) -> SalesSummary? {
        if let shift {
            return ShiftReport(shift: shift, state: model.state, now: Date()).summary
        }
        if model.isLocal(date: date) {
            return model.state.dailySummary(businessDate: date)
        }
        return model.historyCache[date]?.summary
    }

    /// 更早的日子：跟後台要一次（model 會快取）；拿不到記下來，畫面上給「重試」
    private func loadIfNeeded(_ date: String) async {
        guard !model.isLocal(date: date), model.historyCache[date] == nil else { return }
        offlineDays.remove(date)
        let h = await model.history(date: date)
        if h == nil { offlineDays.insert(date) }
    }

    private var currentHour: Int { TaipeiTime.components(Date()).hour ?? 0 }

    private func hourBars(_ s: SalesSummary, live: Bool) -> [DashHourBar] {
        // 今天：一路畫到現在這個小時（還沒有生意的時段補 0，看得出空檔）
        let through: Int? = live && !s.byHour.isEmpty ? currentHour : nil
        return s.dashHours(cutoffHour: model.store.businessDayCutoffHour, through: through)
    }

    /// 昨天到「現在這個時間」為止：今天還沒打烊，跟昨天全天比不公平（昨天一定還在這台）
    private func yesterdaySameTime() -> DashComparison? {
        guard let y = DashDays.shift(model.businessDate, by: -1) else { return nil }
        let all = model.state.closedSales(businessDate: y)
        guard !all.isEmpty else { return nil }
        let cutoff = Date().addingTimeInterval(-86_400)
        let sofar = all.filter { $0.closedAt <= cutoff }
        let s = SalesSummary(sales: sofar, refunds: [], voidedTickets: [], invoices: [], voidedInvoices: [])
        return DashComparison(sameTime: s, fullDayTotal: Money.sum(all.map(\.total)), until: Date())
    }

    // MARK: - 頁尾

    private func footnote(date: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HeroIcon("information-circle", size: 15)
            Text(footnoteText(date: date))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.brand(12.5, .regular))
        .foregroundStyle(Theme.muted)
    }

    private func footnoteText(date: String) -> String {
        let source = model.isLocal(date: date)
            ? "這台 iPad 看得到的所有裝置：自己記的，加上已經同步進來的其他 iPad；離線的裝置補送後數字會再變。"
            : "後台存的那一天：所有門市裝置的結帳、退款與作廢。"
        return "\(source)營業日 \(date)，凌晨 \(model.store.businessDayCutoffHour) 點前算前一天。"
    }
}

/// 一天的報表內容（今天、昨天、後台的日子都用這一份）
private struct DashReport: View {
    @Environment(POSModel.self) private var model
    let summary: SalesSummary
    let compare: DashComparison?
    let bars: [DashHourBar]
    let liveHour: Int?
    let isToday: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DashHeadline(summary: summary, compare: compare)
            if let compare {
                DashCompareNote(compare: compare)
            }
            DashMinorRow(summary: summary)
            DashAccountsRow(summary: summary)
            if summary.prepaidSold.cents > 0 {
                DashPrepaidNote(summary: summary)
            }
            HStack(alignment: .top, spacing: 20) {
                DashHourlyPanel(bars: bars, liveHour: liveHour)
                DashTenderPanel(summary: summary)
                    .frame(width: 300)
            }
            .fixedSize(horizontal: false, vertical: true)
            if showsStaff {
                DashStaffPanel(staff: summary.byStaff, title: "\(model.mode.staffTitle)業績")
            }
            HStack(alignment: .top, spacing: 20) {
                DashTopItemsPanel(items: summary.topItems)
                DashCategoryPanel(categories: summary.byCategory)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 20) {
                DashControlsPanel(summary: summary)
                if isToday {
                    DashFloorNowPanel()
                }
                if showsModes {
                    DashModePanel(byMode: summary.byMode)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 有開業績抽成，或今天真的有抽成、卡抵、助理（美業、課程）
    private var showsStaff: Bool {
        if summary.byStaff.isEmpty { return false }
        if model.features.commission { return true }
        return summary.byStaff.contains(where: { $0.commission.cents > 0 || $0.redeemed.cents > 0 || $0.assists > 0 })
    }

    /// 一家店同一天有兩種以上的營業模式在賣（健身房的櫃台賣飲料）
    private var showsModes: Bool {
        summary.byMode.values.filter { $0.cents > 0 }.count >= 2
    }
}

/// 營業日（YYYY-MM-DD）的換算
private enum DashDays {
    /// 那天中午（台北）：避開凌晨的營業日分界
    static func noon(_ date: String) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        c.hour = 12
        return TaipeiTime.calendar.date(from: c)
    }

    static func shift(_ date: String, by days: Int) -> String? {
        guard let d = noon(date), let moved = TaipeiTime.calendar.date(byAdding: .day, value: days, to: d) else { return nil }
        return TaipeiTime.dayString(moved)
    }

    /// 「今天」「昨天」「10/1 週四」
    static func short(_ date: String, today: String) -> String {
        if date == today { return "今天" }
        if shift(date, by: 1) == today { return "昨天" }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return date }
        return "\(parts[1])/\(parts[2])"
    }
}

/// 「‹ 今天 ›」：一次看一天
private struct DashDayBar: View {
    let title: String
    let isToday: Bool
    let step: (Int) -> Void
    let today: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                step(-1)
            } label: {
                HeroIcon("chevron-right", size: 14)
                    .rotationEffect(.degrees(180))
            }
            .buttonStyle(SquareIconButtonStyle(size: 38))
            .accessibilityLabel("前一天")

            Text(title)
                .font(.brand(14.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 54)

            Button {
                step(1)
            } label: {
                HeroIcon("chevron-right", size: 14)
            }
            .buttonStyle(SquareIconButtonStyle(size: 38))
            .disabled(isToday)
            .opacity(isToday ? 0.35 : 1)
            .accessibilityLabel("後一天")

            if !isToday {
                Button("回今天", action: today)
                    .buttonStyle(.brand(.quiet, size: .sm))
            }
        }
    }
}

/// 向後台拿資料時的安靜狀態：小轉圈或「連不到」＋重試
private struct DashRemoteState: View {
    let loading: Bool
    let title: String
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if loading {
                ProgressView()
                    .controlSize(.regular)
            } else {
                HeroIcon("cloud", size: 28)
                    .foregroundStyle(Theme.faint)
            }
            Text(title)
                .textRole(.h4)
                .foregroundStyle(Theme.ink2)
            Text(message)
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if let retry {
                Button("重試", action: retry)
                    .buttonStyle(.brand(.ghost, size: .sm))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .panel(padding: 24)
    }
}

// MARK: - 範圍

private enum DashRange: String, CaseIterable, Identifiable {
    case today, shift

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "今天"
        case .shift: "這一班"
        }
    }
}

private struct DashRangePicker: View {
    let selected: DashRange
    let shiftAvailable: Bool
    let select: (DashRange) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DashRange.allCases) { r in
                Button {
                    select(r)
                } label: {
                    Text(r.label)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                }
                .buttonStyle(DashSegmentStyle(selected: selected == r))
                .disabled(r == .shift && !shiftAvailable)
                .accessibilityAddTraits(selected == r ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
    }
}

private struct DashSegmentStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(14.5, .medium))
            .foregroundStyle(selected ? Theme.page : Theme.ink2)
            .background(selected ? Theme.ink : (configuration.isPressed ? Theme.press : Color.clear),
                        in: .rect(cornerRadius: Metric.radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect)
            .animation(Motion.fast, value: selected)
    }
}

// MARK: - 比較

/// 昨天同一時間的數字
private struct DashComparison {
    let sameTime: SalesSummary
    let fullDayTotal: Money
    let until: Date
}

/// 比昨天多幾 %（昨天是 0 就不比）
private func dashChange(_ now: Int, _ before: Int) -> Double? {
    guard before > 0 else { return nil }
    return Double(now - before) / Double(before)
}

private struct DashCompareNote: View {
    let compare: DashComparison

    var body: some View {
        Text("比較的是昨天到 \(compare.until.clockText) 為止：\(compare.sameTime.total.formatted)・\(compare.sameTime.tickets) 單（昨天全天 \(compare.fullDayTotal.formatted)）")
            .font(.brand(12.5, .regular))
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
    }
}

// MARK: - 上面四格大數字

private struct DashHeadline: View {
    let summary: SalesSummary
    let compare: DashComparison?

    var body: some View {
        // 夠寬一排四格；不夠（直的 iPad）排成兩排，數字才不會被截成「NT$8,6…」
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                revenueTile
                ticketsTile
                averageTile
                guestsTile
            }
            .frame(minWidth: 4 * 196 + 3 * 16)
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    revenueTile
                    ticketsTile
                }
                HStack(alignment: .top, spacing: 16) {
                    averageTile
                    guestsTile
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var revenueTile: some View {
        DashTile(title: "營業額", icon: "currency-dollar", accent: true, note: "扣退款後 \(summary.net.formatted)", delta: delta(\.total.cents)) {
            MoneyText(money: summary.total, role: .stat, color: Theme.onAccent)
        }
    }

    private var ticketsTile: some View {
        DashTile(title: "單數", icon: "queue-list", note: ticketsNote, delta: delta(\.tickets)) {
            Text(String(summary.tickets))
                .textRole(.stat)
                .foregroundStyle(Theme.ink)
        }
    }

    private var averageTile: some View {
        DashTile(title: "客單價", icon: "tag", note: "每位 \(summary.averagePerGuest.formatted)", delta: delta(\.averageTicket.cents)) {
            MoneyText(money: summary.averageTicket, role: .stat)
        }
    }

    private var guestsTile: some View {
        DashTile(title: "來客數", icon: "users", note: guestsNote, delta: delta(\.guests)) {
            Text(String(summary.guests))
                .textRole(.stat)
                .foregroundStyle(Theme.ink)
        }
    }

    private func delta(_ key: KeyPath<SalesSummary, Int>) -> Double? {
        guard let compare else { return nil }
        return dashChange(summary[keyPath: key], compare.sameTime[keyPath: key])
    }

    private var ticketsNote: String {
        summary.voidedTickets > 0 ? "作廢 \(summary.voidedTickets) 張" : "每單平均 \(summary.averageTicket.formatted)"
    }

    private var guestsNote: String {
        if let compare { return "昨天同時段 \(compare.sameTime.guests) 位" }
        return "內用、外帶都算"
    }
}

/// 一格大數字：左上標題、右上比昨天、中間數字、下面一行小字。營業額那格是品牌橘
private struct DashTile<Value: View>: View {
    let title: String
    let icon: String
    let accent: Bool
    let note: String?
    let delta: Double?
    let value: Value

    init(title: String, icon: String, accent: Bool = false, note: String? = nil, delta: Double? = nil, @ViewBuilder value: () -> Value) {
        self.title = title
        self.icon = icon
        self.accent = accent
        self.note = note
        self.delta = delta
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HeroIcon(icon, size: 16)
                Text(title)
                    .font(.brand(13.5, .medium))
                Spacer(minLength: 4)
                if let delta {
                    DashDelta(value: delta, onAccent: accent)
                }
            }
            .foregroundStyle(accent ? Theme.onAccent.opacity(0.85) : Theme.muted)
            Spacer(minLength: 22)
            value
                .lineLimit(1)
                .minimumScaleFactor(0.45)
            if let note {
                Text(note)
                    .font(.brand(12.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(accent ? Theme.onAccent.opacity(0.8) : Theme.muted)
                    .lineLimit(1)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 172)
        .background(accent ? Theme.accent : Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .overlay {
            if !accent {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「↗ +12%」：比昨天同時段（顏色＋箭頭＋數字，不只靠顏色）
private struct DashDelta: View {
    let value: Double
    var onAccent = false

    var body: some View {
        HStack(spacing: 3) {
            HeroIcon(up ? "arrow-trending-up" : "arrow-trending-down", size: 13)
            Text(String(format: "%+.0f%%", value * 100))
                .monospacedDigit()
        }
        .font(.brand(12, .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(background, in: .rect(cornerRadius: Metric.chip))
        .accessibilityLabel("比昨天同時段 \(String(format: "%+.0f%%", value * 100))")
    }

    private var up: Bool { value >= 0 }

    private var foreground: Color {
        if onAccent { return Theme.onAccent }
        return up ? Theme.successFG : Theme.dangerFG
    }

    private var background: Color {
        if onAccent { return Color.white.opacity(0.2) }
        return up ? Tone.active.background : Tone.danger.background
    }
}

// MARK: - 小一點的四格

private struct DashMinorRow: View {
    let summary: SalesSummary

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DashSmallTile(title: "折扣", value: summary.discounts.formatted, tone: summary.discounts.cents > 0 ? Theme.accentText : Theme.ink)
            DashSmallTile(title: "退款", value: summary.refunds.formatted, tone: summary.refunds.cents > 0 ? Theme.dangerFG : Theme.ink)
            DashSmallTile(title: "服務費", value: summary.serviceCharge.formatted, tone: Theme.ink)
            DashSmallTile(title: "作廢", value: summary.voidedAmount.formatted, tone: Theme.ink,
                          note: "\(summary.voidedItems) 項・整張 \(summary.voidedTickets)")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DashSmallTile: View {
    let title: String
    let value: String
    let tone: Color
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.brand(13, .medium))
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.brand(24, .medium))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let note {
                Text(note)
                    .font(.brand(12, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 實收、儲值、課程卡、卡抵用、報到

/// 一格小數字（只在這一格有意義時出現）
private struct DashFigure: Identifiable {
    let id: String
    let title: String
    let value: String
    let tone: Color
    let note: String?
}

/// 美業、課程、服飾關心的數字：真的收到多少錢、預收了多少儲值、賣了多少課程卡、卡抵了多少、報到幾人次。
/// 有數字、或這個營業模式本來就會有的才顯示（餐廳通常一格都不出現）
private struct DashAccountsRow: View {
    @Environment(POSModel.self) private var model
    let summary: SalesSummary

    var body: some View {
        let figures = self.figures
        if !figures.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                ForEach(figures) { f in
                    DashSmallTile(title: f.title, value: f.value, tone: f.tone, note: f.note)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var figures: [DashFigure] {
        let mode = model.mode
        // 美業、課程開了會員帳戶：儲值、課程卡、卡抵用一定會用到
        let accounts = model.features.accounts && mode.wantsCustomer
        var out: [DashFigure] = []
        let internalUse = summary.prepaidUsed.cents > 0 || summary.exchangeCredit.cents > 0
        if internalUse || summary.prepaidSold.cents > 0 || accounts || mode.usesExchanges {
            out.append(DashFigure(id: "received", title: "實收", value: summary.received.formatted, tone: Theme.ink, note: receivedNote))
        }
        if summary.prepaidSold.cents > 0 || accounts {
            let used = summary.prepaidUsed.cents > 0 ? "用掉 \(summary.prepaidUsed.formatted)" : "預收款"
            out.append(DashFigure(id: "prepaid", title: "儲值", value: summary.prepaidSold.formatted, tone: Theme.ink, note: used))
        }
        if summary.passesSold.cents > 0 || accounts {
            out.append(DashFigure(id: "passes", title: "課程卡", value: summary.passesSold.formatted, tone: Theme.ink, note: "課程卡、會籍"))
        }
        if summary.redeemedValue.cents > 0 || accounts {
            out.append(DashFigure(id: "redeemed", title: "卡抵用", value: summary.redeemedValue.formatted, tone: Theme.accentText,
                                  note: "課程卡抵的服務價值（沒收錢、算業績）"))
        }
        if summary.checkIns > 0 || mode.usesCheckIn {
            out.append(DashFigure(id: "checkins", title: "報到", value: "\(summary.checkIns) 人次", tone: Theme.ink, note: "入場報到"))
        }
        return out
    }

    /// 「不含儲值金 NT$1,200、換貨抵 NT$890」
    private var receivedNote: String {
        var parts: [String] = []
        if summary.prepaidUsed.cents > 0 { parts.append("儲值金 \(summary.prepaidUsed.formatted)") }
        if summary.exchangeCredit.cents > 0 { parts.append("換貨抵 \(summary.exchangeCredit.formatted)") }
        if parts.isEmpty { return "真的收到的錢（扣退款、含小費）" }
        return "不含 " + parts.joined(separator: "、")
    }
}

/// 有賣儲值時：營業額裡有一部分是預收款
private struct DashPrepaidNote: View {
    let summary: SalesSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HeroIcon("information-circle", size: 14)
            Text("儲值是預收款：營業額含儲值 \(summary.prepaidSold.formatted)，扣掉後的營收是 \(summary.revenue.formatted)。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.brand(12.5, .regular))
        .monospacedDigit()
        .foregroundStyle(Theme.muted)
    }
}

// MARK: - 業績

/// 每位服務人員的業績：服務／商品／卡抵、抽成、當助理的次數（照業績排）
private struct DashStaffPanel: View {
    let staff: [StaffTotal]
    let title: String

    var body: some View {
        let rows = staff.filter { $0.performance.cents > 0 || $0.assists > 0 }
        let top = rows.map(\.performance.cents).max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow(title)
                Spacer(minLength: 8)
                Text("業績＝實收＋課程卡抵的價值")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            if rows.isEmpty {
                Text("還沒有業績")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
                        DashStaffRow(total: s, ratio: top > 0 ? Double(s.performance.cents) / Double(top) : 0,
                                     color: i == 0 ? Theme.accent : Theme.chart[i % Theme.chart.count])
                        if i < rows.count - 1 {
                            Rule(color: Theme.hair)
                        }
                    }
                }
            }
        }
        .dashPanel()
    }
}

private struct DashStaffRow: View {
    @Environment(POSModel.self) private var model
    let total: StaffTotal
    let ratio: Double
    let color: Color

    var body: some View {
        let member = model.staffMember(total.staffId)
        HStack(alignment: .center, spacing: 14) {
            StaffAvatar(name: member?.name ?? "?", swatch: member?.swatch ?? .sand, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(member?.name ?? "不在名單上的人")
                    .font(.brand(15, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(member?.title ?? member?.role.label ?? "")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                DashShareBar(ratio: ratio, color: color)
                Text(split)
                    .font(.brand(12, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 2) {
                Text(total.performance.formatted)
                    .font(.brand(16, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text(extra)
                    .font(.brand(12, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// 「服務 $3,200・商品 $480・卡抵 $1,500」
    private var split: String {
        var parts: [String] = []
        if total.services.cents > 0 { parts.append("服務 \(total.services.short)") }
        if total.goods.cents > 0 { parts.append("商品 \(total.goods.short)") }
        if total.redeemed.cents > 0 { parts.append("卡抵 \(total.redeemed.short)") }
        return parts.isEmpty ? "只當助理" : parts.joined(separator: "・")
    }

    /// 「抽成 $640・助理 3 次」
    private var extra: String {
        var parts: [String] = []
        if total.commission.cents > 0 { parts.append("抽成 \(total.commission.short)") }
        if total.assists > 0 { parts.append("助理 \(total.assists) 次") }
        if parts.isEmpty { parts.append("\(total.items) 項") }
        return parts.joined(separator: "・")
    }
}

// MARK: - 各營業模式

private struct DashModeRow: Identifiable {
    let mode: ServiceMode
    let amount: Money
    var id: String { mode.rawValue }
}

/// 同一天有兩種以上的營業模式（健身房的課程＋櫃台飲料）：各賣了多少
private struct DashModePanel: View {
    let byMode: [String: Money]

    var body: some View {
        let rows = self.rows
        let total = rows.reduce(0) { $0 + $1.amount.cents }
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("各營業模式")
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HeroIcon(r.mode.icon, size: 15)
                            .foregroundStyle(Theme.ink2)
                        Text(r.mode.label)
                            .font(.brand(14.5, .medium))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Text(dashPercent(r.amount.cents, of: total))
                            .font(.brand(12.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                        Text(r.amount.formatted)
                            .font(.brand(14.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                    }
                    DashShareBar(ratio: total > 0 ? Double(r.amount.cents) / Double(total) : 0, color: Theme.accent)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .dashPanel()
    }

    /// 認得的模式、有營業額的，照金額排
    private var rows: [DashModeRow] {
        var out: [DashModeRow] = []
        for (key, amount) in byMode where amount.cents > 0 {
            if let m = ServiceMode(rawValue: key) { out.append(DashModeRow(mode: m, amount: amount)) }
        }
        return out.sorted { $0.amount > $1.amount }
    }
}

// MARK: - 每小時

private struct DashHourBar: Identifiable {
    let hour: Int
    let amount: Int
    let count: Int

    var id: Int { hour }
    var label: String { String(hour) }
}

private struct DashHourlyPanel: View {
    let bars: [DashHourBar]
    /// 現在這個小時（還在進行中，畫淡一點）
    let liveHour: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow("每小時營業額")
                Spacer(minLength: 8)
                if let peak {
                    Text("尖峰 \(peak.hour) 點・\(Money(dollars: peak.amount).formatted)・\(peak.count) 單")
                        .font(.brand(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            if peak == nil {
                Text("還沒有結帳的單")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                chart
                    .frame(height: 220)
            }
        }
        .dashPanel()
    }

    private var peak: DashHourBar? {
        bars.filter { $0.amount > 0 }.max { $0.amount < $1.amount }
    }

    /// 時段多的時候隔一個標一次
    private var axisLabels: [String] {
        let step = bars.count > 12 ? 2 : 1
        return bars.enumerated().filter { $0.offset % step == 0 }.map { $0.element.label }
    }

    private var chart: some View {
        let peakHour = peak?.hour
        return Chart(bars) { b in
            BarMark(
                x: .value("時段", b.label),
                y: .value("營業額", b.amount),
                width: .ratio(0.62)
            )
            .cornerRadius(3)
            .foregroundStyle(b.hour == liveHour ? Theme.accent.opacity(0.45) : Theme.accent)
            .annotation(position: .top, alignment: .center, spacing: 4) {
                if b.hour == peakHour {
                    Text(Money(dollars: b.amount).short)
                        .font(.brand(11, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accentText)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisLabels) { value in
                AxisValueLabel {
                    if let s = value.as(String.self) {
                        Text(s)
                            .font(.brand(11, .medium))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                    .foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(Money.group(v))
                            .font(.brand(11, .regular))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .accessibilityLabel("每小時營業額")
    }
}

// MARK: - 付款方式

private struct DashSlice: Identifiable {
    let id: String
    let label: String
    let count: Int
    let amount: Money
    let color: Color
    /// 儲值金、換貨抵用：不是真的收到錢，「實收」不算
    let isInternal: Bool
}

private struct DashTenderPanel: View {
    let summary: SalesSummary

    var body: some View {
        let slices = summary.dashSlices()
        let total = slices.reduce(0) { $0 + $1.amount.cents }
        let count = slices.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("付款方式")
            if slices.isEmpty {
                Text("還沒有收款")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                donut(slices, count: count)
                    .frame(width: 164, height: 164)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    ForEach(slices) { s in
                        legendRow(s, total: total)
                    }
                }
                Rule(color: Theme.hair)
                HStack(alignment: .firstTextBaseline) {
                    Text("實收")
                        .font(.brand(13.5, .medium))
                        .foregroundStyle(Theme.ink2)
                    Spacer(minLength: 8)
                    Text(summary.received.formatted)
                        .font(.brand(15, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
                Text(tenderNote(slices))
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dashPanel()
    }

    private func donut(_ slices: [DashSlice], count: Int) -> some View {
        Chart(slices) { s in
            SectorMark(angle: .value("金額", s.amount.dollars), innerRadius: .ratio(0.68), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(s.color)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 2) {
                Text(String(count))
                    .textRole(.number)
                    .foregroundStyle(Theme.ink)
                Text("筆付款")
                    .font(.brand(12, .regular))
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityLabel("付款方式比例")
    }

    private func legendRow(_ s: DashSlice, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(s.color)
                    .frame(width: 8, height: 8)
                Text(s.label)
                    .font(.brand(14, .medium))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                Text(s.amount.formatted)
                    .font(.brand(14, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            Text("\(s.count) 筆・\(dashPercent(s.amount.cents, of: total))\(s.isInternal ? "・不算實收" : "")")
                .font(.brand(12, .regular))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .padding(.leading, 16)
        }
        .accessibilityElement(children: .combine)
    }
}

extension DashTenderPanel {
    /// 實收的說明：扣了退款、不含儲值金與換貨抵用
    fileprivate func tenderNote(_ slices: [DashSlice]) -> String {
        var parts: [String] = []
        if summary.refunds.cents > 0 { parts.append("已扣退款") }
        if slices.contains(where: \.isInternal) { parts.append("不含儲值金、換貨抵用") }
        parts.append("含小費")
        return parts.joined(separator: "・")
    }
}

/// 「38%」
private func dashPercent(_ part: Int, of total: Int) -> String {
    guard total > 0 else { return "0%" }
    return "\(Int((Double(part) / Double(total) * 100).rounded()))%"
}

// MARK: - 熱賣品項、分類

private struct DashTopItemsPanel: View {
    let items: [NamedTotal]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("熱賣品項")
            if items.isEmpty {
                Text("還沒有賣出的品項")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        row(i, item)
                        if i < items.count - 1 {
                            Rule(color: Theme.hair)
                        }
                    }
                }
            }
        }
        .dashPanel()
    }

    private func row(_ i: Int, _ item: NamedTotal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(format: "%02d", i + 1))
                .font(.brand(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(i == 0 ? Theme.accentText : Theme.faint)
                .frame(width: 24, alignment: .leading)
            Text(item.name)
                .font(.brand(15, i == 0 ? .semibold : .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("×\(item.quantity)")
                .font(.brand(13.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            Text(item.amount.formatted)
                .font(.brand(14.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct DashCategoryPanel: View {
    let categories: [NamedTotal]

    var body: some View {
        let top = categories.map(\.amount.cents).max() ?? 0
        let total = categories.reduce(0) { $0 + $1.amount.cents }
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("分類")
            if categories.isEmpty {
                Text("還沒有資料")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(categories.enumerated()), id: \.offset) { i, c in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(c.name)
                                .font(.brand(14.5, .medium))
                                .foregroundStyle(Theme.ink)
                            Text("\(c.quantity) 項")
                                .font(.brand(12.5, .regular))
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                            Spacer(minLength: 8)
                            Text(dashPercent(c.amount.cents, of: total))
                                .font(.brand(12.5, .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                            Text(c.amount.formatted)
                                .font(.brand(14.5, .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                        }
                        DashShareBar(ratio: top > 0 ? Double(c.amount.cents) / Double(top) : 0,
                                     color: Theme.chart[i % Theme.chart.count])
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .dashPanel()
    }
}

/// 一條細的比例長條（最大的那一項＝滿格）
private struct DashShareBar: View {
    let ratio: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.press)
                Capsule()
                    .fill(color)
                    .frame(width: max(geo.size.width * min(max(ratio, 0), 1), 4))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - 作廢、折扣、發票

private struct DashControlsPanel: View {
    let summary: SalesSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("作廢・折扣・發票")
            ValueRow(label: "作廢品項", value: "\(summary.voidedItems) 項・\(summary.voidedAmount.formatted)")
            ValueRow(label: "作廢整張單", value: "\(summary.voidedTickets) 張")
            ValueRow(label: "折扣", value: summary.discounts.formatted)
            ValueRow(label: "退款", value: summary.refunds.formatted)
            if summary.tips.cents > 0 {
                ValueRow(label: "小費", value: summary.tips.formatted)
            }
            Rule(color: Theme.hair)
                .padding(.vertical, 2)
            ValueRow(label: "電子發票", value: "開 \(summary.invoicesIssued)・作廢 \(summary.invoicesVoided)")
            if !summary.invoiceRanges.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.invoiceRanges, id: \.self) { r in
                        Text(r)
                            .font(.brand(12.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .dashPanel()
    }
}

// MARK: - 現在

/// 現在開著的單（不分今天、這一班：就是此刻的桌況）
private struct DashFloorNowPanel: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let tickets = model.state.openTickets
        let value = Money.sum(tickets.map { $0.totals.total })
        let guests = tickets.reduce(0) { $0 + $1.guests }
        let billing = tickets.filter { $0.billPrintedAt != nil }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Eyebrow("現在")
                Spacer(minLength: 8)
                if !tickets.isEmpty {
                    LiveDot()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(tickets.count))
                    .textRole(.number)
                    .foregroundStyle(Theme.ink)
                Text("張單進行中")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            ValueRow(label: "還沒結的金額", value: value.formatted, strong: true)
            ValueRow(label: "在座客人", value: "\(guests) 位")
            ValueRow(label: "待結帳（印了結帳單）", value: "\(billing) 張")
            if let oldest = tickets.map(\.openedAt).min() {
                ValueRow(label: "坐最久", value: "\(max(Int(Date().timeIntervalSince(oldest) / 60), 0)) 分")
            }
            Button {
                model.go(.orders)
            } label: {
                Text("看進行中的單")
            }
            .buttonStyle(.brand(.ghost, size: .sm, arrow: true))
            .padding(.top, 4)
        }
        .dashPanel()
    }
}

// MARK: - 小工具

extension View {
    /// 報表的卡片：同一列的卡片一樣高（外層 HStack 配 fixedSize）
    fileprivate func dashPanel() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .panel(padding: 22)
    }
}

extension SalesSummary {
    /// 每小時，照營業日的順序（凌晨 cutoff 點前算前一天的尾巴），中間沒生意的時段補 0
    fileprivate func dashHours(cutoffHour: Int, through extraHour: Int?) -> [DashHourBar] {
        let table = Dictionary(byHour.map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        var hours = Array(table.keys)
        if let extraHour { hours.append(extraHour) }
        let order: (Int) -> Int = { h in ((h - cutoffHour) % 24 + 24) % 24 }
        let ordered = hours.map(order)
        guard let lo = ordered.min(), let hi = ordered.max() else { return [] }
        return (lo...hi).map { o in
            let h = (o + cutoffHour) % 24
            let t = table[h]
            return DashHourBar(hour: h, amount: t?.amount.dollars ?? 0, count: t?.count ?? 0)
        }
    }

    /// 付款方式（扣掉退款後還是正的才畫；顏色照 Theme.chart 的順序）
    fileprivate func dashSlices() -> [DashSlice] {
        let positive = byTender.filter { $0.amount.cents > 0 }
        return positive.enumerated().map { i, t in
            DashSlice(id: t.tender.rawValue, label: t.tender.label, count: t.count, amount: t.amount,
                      color: t.tender.isInternal ? Theme.ink.opacity(0.3) : Theme.chart[i % Theme.chart.count], isInternal: t.tender.isInternal)
        }
    }
}
