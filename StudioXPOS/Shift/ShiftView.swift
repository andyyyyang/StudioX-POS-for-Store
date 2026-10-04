import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 交班：開班（零用金）→ 營業中的錢櫃（應有現金、存入取出、只開錢櫃、X 帳）→ 點錢交班（Z 帳）。
///
///   ┌ Cash drawer ─────────────────────────────────────┬ 右欄 ─────────────┐
///   │ ┌錢櫃裡應該有 NT$ 8,420─────┐ ┌錢櫃進出────────┐ │ [一個一個點][存入] │
///   │ │零用金／現金收款／存入／取出│ │存入 找零備用 +500│ │ [取出][只開錢櫃]   │
///   │ ┌Close the shift──────────────────────────────────┐│ [印 X 帳][重點]    │
///   │ │① 點錢 [1000 ×3][500 ×2]…[2000、200]  點到／應有  ││ 1  2  3 …          │
///   │ │② 備註                     ③ 交班單預覽           ││ [   交班並列印   ] │
///   │ ┌打卡（點一個人）┐  ┌今天交過的班（點一班）┐       │                    │
///   └─────────────────────────────────────────────────────┴────────────────────┘
///
/// 左邊選、右邊做：工作區只有資訊與選擇（面額格、打卡名單、交過的班）；動作都在右欄。
/// 沒選東西時右欄是這一頁的動作（大鍵「交班並列印」或「開班」）；選了一個人是「上班／下班」，選了一班是「補印」。
/// 存入、取出：右欄蓋上原因（不用打數字），選了原因再在鍵盤打金額（要授權的先問主管 PIN）。
///
/// 每個數字都在右側鍵盤打：點錢時點一個面額、鍵盤問張數，畫面上即時算差多少。
struct ShiftView: View {
    @Environment(POSModel.self) private var model

    /// 點到的錢（交班前一直留著，切到別頁再回來會重點）
    @State private var counted = CashCount()
    @State private var note = ""
    /// 2000、200 很少見：面額最後一格「2000、200」點了才出來
    @State private var showRare = false
    /// 存入／取出：右欄蓋上原因，選了原因再在鍵盤打金額
    @State private var moveKind: CashMoveKind?
    @State private var closing = false
    /// 打卡名單選起來的人、今天交過的班選起來的那一班（同時只選一個）
    @State private var selectedStaffId: String?
    @State private var selectedShiftId: String?

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
                ShiftAttendancePanel(selectedId: selectedStaffId) { id in
                    withAnimation(Motion.fast) {
                        selectedStaffId = selectedStaffId == id ? nil : id
                        selectedShiftId = nil
                    }
                    model.touch()
                }
                ShiftHistoryPanel(selectedId: selectedShiftId) { id in
                    withAnimation(Motion.fast) {
                        selectedShiftId = selectedShiftId == id ? nil : id
                        selectedStaffId = nil
                    }
                    model.touch()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .dockSelection(dock)
        .dockPanel(isPresented: Binding(get: { moveKind != nil }, set: { if !$0 { moveKind = nil } }),
                   title: moveTitle, subtitle: "選了原因，下一步在鍵盤打金額") {
            reasonChoices
        }
    }

    // MARK: - 右欄

    /// 選起來的人／那一班勝過這一頁的動作
    private var dock: DockSelection? {
        if let id = selectedStaffId, let member = model.staff.first(where: { $0.id == id }) {
            return staffDock(member)
        }
        if let id = selectedShiftId, let shift = model.state.shifts[id] {
            return shiftDock(shift)
        }
        return pageDock
    }

    /// 營業中：大鍵「交班並列印」；動作鍵「一個一個點」「存入」「取出」「只開錢櫃」「印 X 帳」「重點」。還沒開班：大鍵「開班」
    private var pageDock: DockSelection {
        guard let shift = model.openShift else {
            return DockSelection.page("shift", primary: POSAction("開班", icon: "banknotes") {
                Task { await model.startShift() }
            }, accent: true)
        }
        var actions: [POSAction] = [
            POSAction("一個一個點", icon: "calculator") { Task { await countAll() } },
            POSAction("存入", icon: "arrow-down-tray") { moveKind = .payIn },
            POSAction("取出", icon: "arrow-up") { moveKind = .payOut },
            POSAction("只開錢櫃", icon: "banknotes") { Task { await model.moveCash(.noSale, reason: "換零錢") } },
            POSAction("印 X 帳", icon: "printer") {
                model.printXReport()
                model.show("已送出 X 帳（不關班）", tone: .neutral)
            },
        ]
        if !counted.counts.isEmpty {
            actions.append(POSAction("重點", icon: "arrow-path", destructive: true) { counted = CashCount() })
        }
        let primary = POSAction(closing ? "交班中…" : "交班並列印", icon: "check", enabled: !counted.counts.isEmpty && !closing) {
            close(shift)
        }
        return DockSelection.page("shift", primary: primary, accent: true, actions: actions)
    }

    /// 打卡：選起來的人，大鍵「上班」或「下班」
    private func staffDock(_ member: StaffMember) -> DockSelection {
        let on = model.isClockedIn(member)
        let action = POSAction(on ? "下班" : "上班", icon: on ? "arrow-right-start-on-rectangle" : "clock") {
            model.toggleClock(member)
            withAnimation(Motion.fast) { selectedStaffId = nil }
        }
        return DockSelection(
            id: "shift-staff-\(member.id)",
            kind: "打卡",
            title: member.name,
            detail: "\(member.role.label)・今天 \(model.hoursToday(member))",
            badge: DockBadge(on ? "上班中" : "沒上班", tone: on ? .active : .neutral),
            primary: action,
            accent: false,
            clear: { selectedStaffId = nil }
        )
    }

    /// 今天交過的班：選起來的那一班，大鍵「補印」
    private func shiftDock(_ shift: Shift) -> DockSelection {
        let expected = shift.expectedAtClose ?? model.state.expectedCash(shiftId: shift.id)
        let result = ShiftDifference.describe(counted: shift.counted?.total, expected: expected)
        return DockSelection(
            id: "shift-closed-\(shift.id)",
            kind: "交過的班",
            title: "\(shift.openedAt.clockText)–\(shift.closedAt?.clockText ?? "")",
            detail: "\(model.staffName(shift.openedBy)) 開・\(model.staffName(shift.closedBy)) 交・應有 \(expected.formatted)",
            badge: DockBadge(result.text, tone: result.tone),
            primary: POSAction("補印交班單", icon: "printer") { model.reprintShiftReport(shift) },
            accent: false,
            clear: { selectedShiftId = nil }
        )
    }

    // MARK: 存入、取出的原因（右欄的面板）

    private var moveTitle: String {
        switch moveKind {
        case .some(.payIn): "存入的原因"
        case .some(.payOut): "取出的原因"
        case .some(.noSale), .none: "開錢櫃的原因"
        }
    }

    private var moveReasons: [String] {
        switch moveKind {
        case .some(.payIn): ["找零備用", "其他"]
        case .some(.payOut): ["買菜", "付廠商", "其他"]
        case .some(.noSale), .none: ["換零錢"]
        }
    }

    private var reasonChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(moveReasons, id: \.self) { r in
                DockChoice(title: r) { move(r) }
            }
        }
    }

    private func move(_ reason: String) {
        guard let kind = moveKind else { return }
        moveKind = nil
        Task { await model.moveCash(kind, reason: reason) }
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
            ShiftDrawerCard(shift: shift, report: report, expected: expected)
            ShiftMovesPanel(shift: shift)
                .frame(width: 320)
        }
        .fixedSize(horizontal: false, vertical: true)
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
                ShiftReportPreview(report: preview, canClose: !counted.counts.isEmpty)
                    .frame(width: 300)
            }
        }
        .panel(padding: 24)
    }

    private func stepCount(expected: Money) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShiftStepLabel(number: 1, title: "點錢", detail: "點一個面額，在右側鍵盤打張數；或按右邊的「一個一個點」照順序問")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                ForEach(denominations, id: \.self) { d in
                    ShiftDenominationCell(denomination: d, count: counted.count(d)) {
                        Task { await ask(d) }
                    }
                }
                // 少見的面額：最後一格點了才展開（點過了就一直顯示，不用這格）
                if !rareCounted {
                    ShiftRareToggleCell(expanded: showRare) {
                        withAnimation(Motion.fast) { showRare.toggle() }
                    }
                }
            }
            ShiftCountResult(counted: counted, expected: expected)
        }
    }

    private var rareCounted: Bool { [Denomination.d2000, .d200].contains(where: { counted.count($0) > 0 }) }

    /// 常用的面額；打開「2000、200」或已經點過的話全部顯示
    private var denominations: [Denomination] {
        if showRare || rareCounted { return Array(Denomination.allCases) }
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
            // 「開班」是右欄最下面的大鍵（左邊選、右邊做）
            HStack(spacing: 10) {
                HeroIcon("chevron-right", size: 16)
                    .foregroundStyle(Theme.accentText)
                Text(lastShift.map { "按右邊的「開班」・上一班的零用金 \($0.openingCash.formatted)" } ?? "按右邊的「開班」")
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.ink2)
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
            Text("存入、取出、只開錢櫃、印 X 帳在右邊")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
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

/// 面額最後一格：「2000、200」點了展開、再點收起（虛線框，看得出不是面額）
private struct ShiftRareToggleCell: View {
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text("2000、200")
                    .font(.brand(17, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Text(expanded ? "收起" : "少見的面額")
                        .font(.brand(13, .medium))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    HeroIcon("chevron-down", size: 13)
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityLabel(expanded ? "收起 2000、200 元" : "顯示 2000、200 元")
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

/// 交班單預覽（這一班的營業重點）。「交班並列印」是右欄最下面的大鍵
private struct ShiftReportPreview: View {
    let report: ShiftReport
    let canClose: Bool

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
            Text(canClose ? "對好了就按右邊的「交班並列印」" : "先點錢：至少打一個面額（錢櫃是空的就打 0），再按右邊的「交班並列印」")
                .textRole(.xs)
                .foregroundStyle(canClose ? Theme.ink2 : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Theme.press, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
    }
}

// MARK: - 打卡

/// 打卡：名單只顯示狀態；點一個人選起來（橘框），右欄的大鍵是「上班」或「下班」；再點一下取消
private struct ShiftAttendancePanel: View {
    @Environment(POSModel.self) private var model
    let selectedId: String?
    let select: (String) -> Void

    var body: some View {
        let onDuty = model.staff.filter { model.isClockedIn($0) }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow("打卡・\(onDuty) 人上班中")
                Spacer(minLength: 8)
                if !model.staff.isEmpty {
                    Text("點一個人打卡")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
            }
            if model.staff.isEmpty {
                Text("後台還沒有設定人員")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.staff) { s in
                        Button {
                            select(s.id)
                        } label: {
                            ShiftStaffRow(member: s, selected: selectedId == s.id)
                        }
                        .buttonStyle(.row)
                        .accessibilityAddTraits(selectedId == s.id ? .isSelected : [])
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
    let selected: Bool

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
            StatusBadge(on ? "上班中" : "沒上班", tone: on ? .active : .neutral)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(selected ? Theme.press : Color.clear, in: .rect(cornerRadius: Metric.radius, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
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

/// 今天交過的班：點一班選起來（橘框），右欄的大鍵是「補印交班單」；再點一下取消
private struct ShiftHistoryPanel: View {
    @Environment(POSModel.self) private var model
    let selectedId: String?
    let select: (String) -> Void

    var body: some View {
        let list = closedToday
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow("今天交過的班・\(list.count)")
                Spacer(minLength: 8)
                if !list.isEmpty {
                    Text("點一班可以補印")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
            }
            if list.isEmpty {
                Text("這台今天還沒交過班")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        Button {
                            select(s.id)
                        } label: {
                            ShiftHistoryRow(shift: s, selected: selectedId == s.id)
                        }
                        .buttonStyle(.row)
                        .accessibilityAddTraits(selectedId == s.id ? .isSelected : [])
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
    let selected: Bool

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
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(selected ? Theme.press : Color.clear, in: .rect(cornerRadius: Metric.radius, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
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
