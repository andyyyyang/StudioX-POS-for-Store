import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 交班：開班（零用金）→ 營業中的錢櫃（應有現金、存入取出、只開錢櫃、X 帳）→ 點錢交班（Z 帳）。
///
///   ┌ Cash drawer ──────────────────────────────────────────────┐
///   │ ┌錢櫃裡應該有 NT$ 8,420──────────────┐ ┌錢櫃進出────────┐  │
///   │ │零用金／現金收款／退款／存入／取出   │ │存入 找零備用 +500│  │
///   │ │[存入][取出][只開錢櫃]      [印 X 帳]│ │                  │  │
///   │ ┌Close the shift──────────────────────────────────────────┐│
///   │ │① 點錢 [1000 ×3][500 ×2][100 ×12]…  點到／應有／差額      ││
///   │ │② 備註                                ③ 交班單預覽［交班］ ││
///   │ ┌打卡┐  ┌今天交過的班┐                                     │
///   └──────────────────────────────────────────────────────────┘
///
/// 每個數字都在右側鍵盤打：點錢時點一個面額、鍵盤問張數，畫面上即時算差多少。
struct ShiftView: View {
    @Environment(POSModel.self) private var model

    /// 點到的錢（交班前一直留著，切到別頁再回來會重點）
    @State private var counted = CashCount()
    @State private var note = ""
    /// 2000、200 很少見：收在「更多」
    @State private var showRare = false
    /// 存入／取出：先選原因（下一步才在鍵盤打金額）
    @State private var moveKind: CashMoveKind?
    @State private var closing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let shift = model.openShift {
                    drawerRow(shift)
                    closePanel(shift)
                } else {
                    ShiftOpenHero()
                }
                ShiftAttendancePanel()
                ShiftHistoryPanel()
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            PageTitle(title: "Cash *drawer*", subtitle: subtitle)
            Spacer(minLength: 16)
            if let shift = model.openShift {
                StatusBadge("營業中・\(shift.openedAt.clockText) 開班", tone: .active)
            } else {
                StatusBadge("還沒開班", tone: .neutral)
            }
        }
    }

    private var subtitle: String {
        let name = model.device.name.isEmpty ? "這台" : model.device.name
        return "交班・\(name)"
    }

    // MARK: - 營業中的錢櫃

    private func drawerRow(_ shift: Shift) -> some View {
        let report = ShiftReport(shift: shift, state: model.state, now: Date())
        let expected = model.state.expectedCash(shiftId: shift.id)
        return HStack(alignment: .top, spacing: 20) {
            ShiftDrawerCard(shift: shift, report: report, expected: expected, moveKind: moveKind,
                            pick: { kind in withAnimation(Motion.fast) { moveKind = moveKind == kind ? nil : kind } },
                            choose: { reason in move(reason) },
                            cancel: { withAnimation(Motion.fast) { moveKind = nil } })
            ShiftMovesPanel(shift: shift)
                .frame(width: 320)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func move(_ reason: String) {
        guard let kind = moveKind else { return }
        moveKind = nil
        Task { await model.moveCash(kind, reason: reason) }
    }

    // MARK: - 交班

    private func closePanel(_ shift: Shift) -> some View {
        let expected = model.state.expectedCash(shiftId: shift.id)
        let preview = ShiftReport(shift: shift, state: model.state, now: Date(), counted: counted)
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Headline("Close the *shift*", role: .h3)
                Spacer(minLength: 8)
                Text("交班要店長以上授權")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 26) {
                    stepCount(expected: expected)
                    stepNote
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                ShiftReportPreview(report: preview, canClose: !counted.counts.isEmpty, closing: closing) {
                    close(shift)
                }
                .frame(width: 300)
            }
        }
        .panel(padding: 24)
    }

    private func stepCount(expected: Money) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShiftStepLabel(number: 1, title: "點錢", detail: "點一個面額，在右側鍵盤打張數；或按「一個一個點」照順序問")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                ForEach(denominations, id: \.self) { d in
                    ShiftDenominationCell(denomination: d, count: counted.count(d)) {
                        Task { await ask(d) }
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    Task { await countAll() }
                } label: {
                    Label {
                        Text("一個一個點")
                    } icon: {
                        HeroIcon("calculator", size: 16)
                    }
                }
                .buttonStyle(.brand(.primary, size: .md))

                Button(rareLabel) {
                    withAnimation(Motion.fast) { showRare.toggle() }
                }
                .buttonStyle(.brand(.quiet, size: .md))

                Spacer(minLength: 8)

                if !counted.counts.isEmpty {
                    Button("重點") {
                        counted = CashCount()
                    }
                    .buttonStyle(.brand(.quiet, size: .md))
                }
            }
            ShiftCountResult(counted: counted, expected: expected)
        }
    }

    private var rareLabel: String { showRare ? "收起 2000、200" : "更多（2000、200）" }

    /// 常用的面額；打開「更多」或 2000、200 已經點過的話全部顯示
    private var denominations: [Denomination] {
        let rare: [Denomination] = [.d2000, .d200]
        if showRare || rare.contains(where: { counted.count($0) > 0 }) { return Array(Denomination.allCases) }
        return Denomination.common
    }

    private var stepNote: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShiftStepLabel(number: 2, title: "備註", detail: "短少的原因、要交接的事（選填）")
            TextField("例如：找錯一張 100；明天要補零錢", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .font(.brand(15, .regular))
                .padding(12)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                }
        }
    }

    private func ask(_ d: Denomination) async {
        var spec = KeypadSpec.denomination(d, current: counted.count(d))
        // 單點一個面額：按完就好，不是「下一個」
        spec.confirmLabel = "確定"
        guard let n = await model.keypad.askNumber(spec) else { return }
        counted.set(d, n)
    }

    private func countAll() async {
        guard let c = await model.countCash(start: counted) else { return }
        counted = c
    }

    private func close(_ shift: Shift) {
        closing = true
        let id = shift.id
        let count = counted
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await model.closeShift(counted: count, note: text)
            closing = false
            // 真的交了班才清掉（取消授權、還有收了一半錢的單時留著）
            if model.state.shifts[id]?.isOpen == false {
                counted = CashCount()
                note = ""
                showRare = false
            }
        }
    }
}

// MARK: - 還沒開班

private struct ShiftOpenHero: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Eyebrow("還沒開班")
            Headline("Open the *drawer*", role: .h1)
            Text("開班時，在右側鍵盤打錢櫃裡的零用金。之後這台收的現金、退的現金、存入和取出都算在這一班；打烊或換人時點錢交班，印出交班單。")
                .textRole(.lead)
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: 600, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button {
                    Task { await model.startShift() }
                } label: {
                    Text("開班")
                }
                .buttonStyle(.brand(.accent, size: .lg, arrow: true))
                if let last = lastShift {
                    Text("上一班的零用金 \(last.openingCash.formatted)")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ShiftHeroStep(number: 1, title: "零用金", detail: "開班時錢櫃裡有多少")
                ShiftHeroStep(number: 2, title: "營業", detail: "現金收款、存入取出都記在這一班")
                ShiftHeroStep(number: 3, title: "交班", detail: "一個面額一個面額點，對帳、印交班單")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
        .panel(padding: 32)
    }

    private var lastShift: Shift? {
        model.state.shifts.values
            .filter { $0.deviceId == model.device.id && !$0.isOpen }
            .max { $0.openedAt < $1.openedAt }
    }
}

private struct ShiftHeroStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "%02d", number))
                .font(.brand(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.accentText)
            Text(title)
                .textRole(.h4)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { Rule() }
    }
}

// MARK: - 錢櫃

private struct ShiftDrawerCard: View {
    @Environment(POSModel.self) private var model
    let shift: Shift
    let report: ShiftReport
    let expected: Money
    let moveKind: CashMoveKind?
    let pick: (CashMoveKind) -> Void
    let choose: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                LiveDot()
                Text("\(shift.openedAt.clockText) 開班・\(model.staffName(shift.openedBy))")
                    .font(.brand(13.5, .medium))
                    .foregroundStyle(Theme.ink2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("錢櫃裡應該有")
                    .font(.brand(13.5, .medium))
                    .foregroundStyle(Theme.muted)
                MoneyText(money: expected, role: .stat)
            }
            breakdown
            Rule(color: Theme.hair)
            actions
            if let kind = moveKind {
                ShiftReasonPicker(kind: kind, choose: choose, cancel: cancel)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: 24)
    }

    private var breakdown: some View {
        VStack(spacing: 8) {
            ValueRow(label: "零用金", value: report.openingCash.formatted)
            ValueRow(label: "現金收款", value: "+\(report.cashSales.formatted)")
            if report.cashRefunds.cents > 0 {
                ValueRow(label: "現金退款", value: "−\(report.cashRefunds.formatted)", tone: Theme.dangerFG)
            }
            // 換貨退回的比新買的多：差額從錢櫃退現金（應有現金已經扣掉了）
            if report.cashBack.cents > 0 {
                ValueRow(label: "換貨退差額", value: "−\(report.cashBack.formatted)", tone: Theme.dangerFG)
            }
            if report.payIns.cents > 0 {
                ValueRow(label: "存入", value: "+\(report.payIns.formatted)")
            }
            if report.payOuts.cents > 0 {
                ValueRow(label: "取出", value: "−\(report.payOuts.formatted)", tone: Theme.dangerFG)
            }
        }
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 8)], alignment: .leading, spacing: 8) {
            Button {
                pick(.payIn)
            } label: {
                actionLabel("存入", icon: "arrow-down-tray")
            }
            .buttonStyle(.brand(moveKind == .payIn ? .primary : .ghost, size: .md, fullWidth: true))

            Button {
                pick(.payOut)
            } label: {
                actionLabel("取出", icon: "arrow-up")
            }
            .buttonStyle(.brand(moveKind == .payOut ? .primary : .ghost, size: .md, fullWidth: true))

            Button {
                Task { await model.moveCash(.noSale, reason: "換零錢") }
            } label: {
                actionLabel("只開錢櫃", icon: "banknotes")
            }
            .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))

            Button {
                model.printXReport()
                model.show("已送出 X 帳（不關班）", tone: .neutral)
            } label: {
                actionLabel("印 X 帳", icon: "printer")
            }
            .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))
        }
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            HeroIcon(icon, size: 16)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 存入、取出：先點原因，再到右側鍵盤打金額
private struct ShiftReasonPicker: View {
    let kind: CashMoveKind
    let choose: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt)
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
            FlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(reasons, id: \.self) { r in
                    OptionChip(title: r, selected: false) { choose(r) }
                }
                Button("取消", action: cancel)
                    .buttonStyle(.brand(.quiet, size: .md))
            }
        }
        .padding(16)
        .background(Theme.press, in: .rect(cornerRadius: Metric.radius, style: .continuous))
    }

    private var prompt: String {
        switch kind {
        case .payIn: "存入的原因（下一步在右側鍵盤打金額）"
        case .payOut: "取出的原因（下一步在右側鍵盤打金額）"
        case .noSale: "開錢櫃的原因"
        }
    }

    private var reasons: [String] {
        switch kind {
        case .payIn: ["找零備用", "其他"]
        case .payOut: ["買菜", "付廠商", "其他"]
        case .noSale: ["換零錢"]
        }
    }
}

private struct ShiftMovesPanel: View {
    @Environment(POSModel.self) private var model
    let shift: Shift

    var body: some View {
        let moves = Array(shift.moves.reversed())
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("錢櫃進出・\(moves.count) 筆")
            if moves.isEmpty {
                Text("還沒有存入、取出或開錢櫃")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(spacing: 0) {
                    ForEach(moves) { m in
                        ShiftMoveRow(move: m, by: model.staffName(m.by))
                        if m.id != moves.last?.id {
                            Rule(color: Theme.hair)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: 22)
    }
}

private struct ShiftMoveRow: View {
    let move: CashMove
    let by: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(move.kind.label)・\(move.reason)")
                    .font(.brand(14.5, .medium))
                    .foregroundStyle(Theme.ink)
                Text("\(move.at.clockText)・\(by)")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Text(amountText)
                .font(.brand(14.5, .medium))
                .monospacedDigit()
                .foregroundStyle(amountColor)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var amountText: String {
        switch move.kind {
        case .payIn: "+\(move.amount.formatted)"
        case .payOut: "−\(move.amount.formatted)"
        case .noSale: "—"
        }
    }

    private var amountColor: Color {
        switch move.kind {
        case .payIn: Theme.ink
        case .payOut: Theme.dangerFG
        case .noSale: Theme.muted
        }
    }
}

// MARK: - 點錢

private struct ShiftStepLabel: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(number))
                .font(.brand(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.onAccent)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一格面額：點了右側鍵盤問張數；點過的淡橘底
private struct ShiftDenominationCell: View {
    let denomination: Denomination
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(denomination.rawValue))
                        .font(.brand(22, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text(denomination.isCoin ? "元硬幣" : "元")
                        .font(.brand(12, .medium))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("× \(count)")
                        .font(.brand(15, .medium))
                        .monospacedDigit()
                        .foregroundStyle(count > 0 ? Theme.ink : Theme.faint)
                    Spacer(minLength: 4)
                    Text(subtotal.short)
                        .font(.brand(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(count > 0 ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(count > 0 ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityLabel(accessibilityText)
    }

    private var subtotal: Money { denomination.value * count }

    private var accessibilityText: String {
        "\(denomination.label)，\(count) \(denomination.isCoin ? "個" : "張")"
    }
}

/// 差額的說法與顏色：相符（綠）／短少（紅）／溢收（黃）
private enum ShiftDifference {
    static func describe(counted: Money?, expected: Money) -> (text: String, tone: Tone) {
        guard let counted else { return ("還沒點", .neutral) }
        let diff = counted - expected
        if diff.isZero { return ("相符", .active) }
        if diff.isNegative { return ("短少 \(Money(cents: -diff.cents).formatted)", .danger) }
        return ("溢收 \(diff.formatted)", .warning)
    }
}

private struct ShiftCountResult: View {
    let counted: CashCount
    let expected: Money

    var body: some View {
        let result = ShiftDifference.describe(counted: counted.counts.isEmpty ? nil : counted.total, expected: expected)
        HStack(alignment: .center, spacing: 0) {
            column("點到", money: counted.total, color: Theme.ink)
            divider
            column("應有", money: expected, color: Theme.ink2)
            divider
            VStack(alignment: .leading, spacing: 6) {
                Text("差額")
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.muted)
                Text(result.text)
                    .font(.brand(20, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(result.tone.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
        }
        .padding(16)
        .background(result.tone.background, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .animation(Motion.fast, value: counted.total)
        .accessibilityElement(children: .combine)
    }

    private func column(_ title: String, money: Money, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.brand(12.5, .medium))
                .foregroundStyle(Theme.muted)
            Text(money.formatted)
                .font(.brand(20, .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
    }

    private var divider: some View {
        Rule(vertical: true)
            .frame(height: 40)
    }
}

/// 交班單預覽（這一班的營業重點）＋交班的按鈕
private struct ShiftReportPreview: View {
    let report: ShiftReport
    let canClose: Bool
    let closing: Bool
    let close: () -> Void

    /// 「12 張・18 位」；沒有人數（服飾、美業）就只寫張數
    private func guestLine(_ s: SalesSummary) -> String {
        s.guests > 0 ? "\(s.tickets) 張・\(s.guests) 位" : "\(s.tickets) 張"
    }

    var body: some View {
        let s = report.summary
        VStack(alignment: .leading, spacing: 14) {
            ShiftStepLabel(number: 3, title: "交班", detail: "存交班單、印 Z 帳、通知負責人")
            VStack(spacing: 8) {
                ValueRow(label: "營業額", value: s.total.formatted, strong: true)
                ValueRow(label: "單數", value: guestLine(s))
                if s.received != s.total {
                    ValueRow(label: "實收", value: s.received.formatted)
                }
                ForEach(s.byTender, id: \.tender) { t in
                    ValueRow(label: "\(t.tender.label) \(t.count) 筆", value: t.amount.formatted)
                }
                if s.discounts.cents > 0 {
                    ValueRow(label: "折扣", value: "−\(s.discounts.formatted)", tone: Theme.accentText)
                }
                if s.refunds.cents > 0 {
                    ValueRow(label: "退款", value: "−\(s.refunds.formatted)", tone: Theme.dangerFG)
                }
                if report.cashBack.cents > 0 {
                    ValueRow(label: "換貨退差額（現金）", value: "−\(report.cashBack.formatted)", tone: Theme.dangerFG)
                }
                if s.prepaidSold.cents > 0 {
                    ValueRow(label: "儲值（預收）", value: s.prepaidSold.formatted)
                }
                if s.passesSold.cents > 0 {
                    ValueRow(label: "課程卡", value: s.passesSold.formatted)
                }
                if s.redeemedValue.cents > 0 {
                    ValueRow(label: "卡抵用", value: s.redeemedValue.formatted, tone: Theme.accentText)
                }
                if s.checkIns > 0 {
                    ValueRow(label: "報到", value: "\(s.checkIns) 人次")
                }
                ValueRow(label: "作廢", value: "\(s.voidedItems) 項・整張 \(s.voidedTickets)")
                ValueRow(label: "發票", value: "開 \(s.invoicesIssued)・作廢 \(s.invoicesVoided)")
                if report.noSaleCount > 0 {
                    ValueRow(label: "只開錢櫃", value: "\(report.noSaleCount) 次")
                }
            }
            Button(action: close) {
                Text(closing ? "交班中…" : "交班並列印")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.accent, size: .lg, fullWidth: true, arrow: true))
            .disabled(!canClose || closing)
            if !canClose {
                Text("先點錢：至少打一個面額（錢櫃是空的就打 0）")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(Theme.press, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
    }
}

// MARK: - 打卡

private struct ShiftAttendancePanel: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let onDuty = model.staff.filter { model.isClockedIn($0) }.count
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("打卡・\(onDuty) 人上班中")
            if model.staff.isEmpty {
                Text("後台還沒有設定人員")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.staff) { s in
                        ShiftStaffRow(member: s)
                        if s.id != model.staff.last?.id {
                            Rule(color: Theme.hair)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: 22)
    }
}

private struct ShiftStaffRow: View {
    @Environment(POSModel.self) private var model
    let member: StaffMember

    var body: some View {
        let on = model.isClockedIn(member)
        HStack(spacing: 12) {
            StaffAvatar(name: member.name, swatch: member.swatch, size: 34, active: member.id == model.currentStaff?.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(.brand(15, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(detail(on: on))
                    .font(.brand(12.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if on {
                StatusBadge("上班中", tone: .active)
            }
            Button(on ? "下班" : "上班") {
                model.toggleClock(member)
            }
            .buttonStyle(.brand(on ? .ghost : .primary, size: .sm))
        }
        .padding(.vertical, 10)
    }

    /// 「店長・09:02 上班・今天 6 小時 12 分」
    private func detail(on: Bool) -> String {
        var parts = [member.role.label]
        if on, let since = clockInTime { parts.append("\(since.clockText) 上班") }
        parts.append("今天 \(model.hoursToday(member))")
        return parts.joined(separator: "・")
    }

    private var clockInTime: Date? {
        model.state.attendance.last(where: { $0.staffId == member.id && $0.outAt == nil })?.inAt
    }
}

// MARK: - 今天交過的班

private struct ShiftHistoryPanel: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let list = closedToday
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("今天交過的班・\(list.count)")
            if list.isEmpty {
                Text("這台今天還沒交過班")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        ShiftHistoryRow(shift: s)
                        if s.id != list.last?.id {
                            Rule(color: Theme.hair)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: 22)
    }

    private var closedToday: [Shift] {
        model.state.shifts.values
            .filter { $0.deviceId == model.device.id && !$0.isOpen && $0.businessDate == model.businessDate }
            .sorted { $0.openedAt > $1.openedAt }
    }
}

private struct ShiftHistoryRow: View {
    @Environment(POSModel.self) private var model
    let shift: Shift

    var body: some View {
        let expected = shift.expectedAtClose ?? model.state.expectedCash(shiftId: shift.id)
        let result = ShiftDifference.describe(counted: shift.counted?.total, expected: expected)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(timeRange)
                    .font(.brand(15, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text("\(model.staffName(shift.openedBy)) 開・\(model.staffName(shift.closedBy)) 交")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                Text("應有 \(expected.formatted)・點到 \(shift.counted?.total.formatted ?? "—")")
                    .font(.brand(12.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                if !shift.note.isEmpty {
                    Text(shift.note)
                        .textRole(.xs)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            StatusBadge(result.text, tone: result.tone)
            Button {
                model.reprintShiftReport(shift)
            } label: {
                HeroIcon("printer", size: 16)
            }
            .buttonStyle(SquareIconButtonStyle(size: 34))
            .accessibilityLabel("補印交班單")
        }
        .padding(.vertical, 10)
    }

    private var timeRange: String {
        "\(shift.openedAt.clockText)–\(shift.closedAt?.clockText ?? "")"
    }
}

// MARK: - 補印交班單

extension POSModel {
    /// 補印已經交班的那一班（數字用交班時存下來的應有現金與點到的錢）
    fileprivate func reprintShiftReport(_ shift: Shift) {
        let report = ShiftReport(shift: shift, state: state, now: Date())
        printers.print(Templates.shiftReport(report, store: store, deviceName: device.name, staffName: { [weak self] in self?.staffName($0) ?? "—" }), role: .receipt)
        show("已送出交班單補印", tone: .neutral)
    }
}
