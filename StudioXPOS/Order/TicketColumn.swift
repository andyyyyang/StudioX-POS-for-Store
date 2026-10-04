import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 單子（工作區與右側鍵盤之間那一欄）：桌號、人數、點了什麼、金額。
///
/// 左邊選、右邊做（docs/DESIGN.md）：這一欄只有看與選——
///   - 沒點某一行：整張單的動作在右欄（大鍵：送單／結帳；動作鍵：找會員、折扣、備註、更多…、作廢）
///   - 點了某一行：右欄換成那一行（大鍵：數量；動作鍵：用卡抵、設計師、換規格、備註、折扣、刪除）；再點一下取消
///   - 不用打數字的選擇（設計師、課程卡、規格、折扣的種類、用餐方式…）蓋住右欄（.dockPanel）
/// 服飾多了整張單的銷售人員與換貨；美業、課程多了會員條（儲值金、課程卡）、每一行的設計師／教練與助理、用課程卡抵。
struct TicketColumn: View {
    @Environment(POSModel.self) private var model
    @State private var splitting: Ticket?
    @State private var noteFor: TicketLine?
    @State private var noteText = ""
    @State private var ticketNote = false
    @State private var voidReasonFor: [TicketLine] = []
    @State private var voidingTicket = false
    /// 會員條打開了（看課程卡、備註、上次做了什麼）
    @State private var memberOpen = false
    /// 點了哪一行（右欄換成那一行的動作；再點一下取消）
    @State private var selectedLineId: String? = nil
    /// 蓋住右欄的選擇
    @State private var panel: TicketPanel? = nil
    /// 自訂品項、掃商品條碼（以前在點餐頁的「⋯」）
    @State private var askingCustom = false
    @State private var customName = ""
    @State private var scanning = false

    /// 蓋住右欄的選擇：這一行的（設計師、助理、課程卡、規格、折扣、座位）、整張單的（折扣、更多、銷售人員）
    private enum TicketPanel: String, Identifiable {
        case performer, assistant, passes, variant, lineDiscount, lineCourse, ticketDiscount, ticketMore, salesperson
        var id: String { rawValue }
        var isLine: Bool { [.performer, .assistant, .passes, .variant, .lineDiscount, .lineCourse].contains(self) }
    }

    var body: some View {
        Group {
            if let t = model.checkoutTicket ?? model.selectedTicket {
                content(t)
            } else {
                empty
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.dock.opacity(0.55))
        .overlay(alignment: .leading) { Rule(vertical: true) }
        .dockSelection(dock)
        .dockPanel(item: $panel, title: { panelTitle($0) }, subtitle: { panelSubtitle($0) }) { p in
            panelContent(p)
        }
        .onChange(of: model.selectedTicketId) { _, _ in
            memberOpen = false
            selectedLineId = nil
            panel = nil
        }
        .onChange(of: model.checkoutTicketId) { _, _ in
            selectedLineId = nil
            panel = nil
        }
        .onChange(of: selectedLineId) { _, _ in
            if panel?.isLine == true { panel = nil }
        }
        // 規格、加料的卡打開了：右欄換成那張卡，這一行就不選了
        .onChange(of: model.variantItem?.id) { _, id in
            if id != nil { selectedLineId = nil }
        }
        .onChange(of: model.modifierItem?.id) { _, id in
            if id != nil { selectedLineId = nil }
        }
        // 截圖：先選起第一行（只在 Debug、帶 -preselect）
        .task(id: model.selectedTicketId) {
            if LaunchArguments.preselect { preselectForScreenshot() }
        }
        .sheet(item: $splitting) { t in
            SplitSheet(ticket: t)
        }
        .sheet(isPresented: $scanning) {
            CodeScannerSheet(title: "掃商品條碼", types: ScanKind.product) { code in
                model.lookup(code: code)
            }
        }
        .alert("自訂品項", isPresented: $askingCustom) {
            TextField("品名（例如：開瓶費）", text: $customName)
            Button("下一步：輸入金額") {
                let name = customName.trimmingCharacters(in: .whitespaces)
                customName = ""
                guard !name.isEmpty else { return }
                Task { await model.addCustom(name: name) }
            }
            Button("取消", role: .cancel) { customName = "" }
        }
        .alert("備註", isPresented: Binding(get: { noteFor != nil }, set: { if !$0 { noteFor = nil } })) {
            TextField("例如：不要香菜", text: $noteText)
            Button("好") {
                if let l = noteFor, let t = model.selectedTicket { model.setNote(noteText, for: l, in: t) }
                noteFor = nil
            }
            Button("取消", role: .cancel) { noteFor = nil }
        }
        .alert("整張單的備註", isPresented: $ticketNote) {
            TextField("例如：有過敏、先上飲料", text: $noteText)
            Button("好") {
                if let t = model.selectedTicket { model.setTicketNote(noteText, for: t) }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("為什麼不要了？", isPresented: Binding(get: { !voidReasonFor.isEmpty }, set: { if !$0 { voidReasonFor = [] } })) {
            ForEach(["客人取消", "點錯", "出餐太慢", "餐點問題", "招待"], id: \.self) { reason in
                Button(reason) {
                    let lines = voidReasonFor
                    voidReasonFor = []
                    if let t = model.selectedTicket { Task { await model.void(lines, in: t, reason: reason) } }
                }
            }
            Button("取消", role: .cancel) { voidReasonFor = [] }
        }
        .confirmationDialog("作廢整張單？", isPresented: $voidingTicket) {
            ForEach(["客人離開", "開錯單", "測試"], id: \.self) { reason in
                Button(reason, role: .destructive) {
                    if let t = model.selectedTicket { Task { await model.voidTicket(t, reason: reason) } }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 截圖用：單子有東西就先選起第一行（右欄是那一行的動作）
    private func preselectForScreenshot() {
        guard selectedLineId == nil, model.checkoutTicketId == nil, let t = model.selectedTicket,
              let first = t.activeLines.first else { return }
        selectedLineId = first.id
    }

    // MARK: 沒有單

    private var empty: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("單子")
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Headline("Nothing *yet*", role: .h3)
                Text(emptyHint)
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                Text("開單、自訂品項、掃條碼在右邊")
                    .textRole(.xs)
                    .foregroundStyle(Theme.faint)
            }
            Spacer()
        }
        .padding(20)
    }

    private var emptyHint: String {
        if model.mode.usesTables && model.features.seating {
            return "點左邊的品項就會開一張\(model.mode.defaultOrderType.label)單；要帶位到「桌位」點空桌。"
        }
        if model.mode.showsOrderType {
            return "點左邊的品項就會開一張\(model.mode.defaultOrderType.label)單（\(model.mode.label)：\(model.mode.summary)）"
        }
        return "點左邊的品項就會開一張新單（\(model.mode.label)：\(model.mode.summary)）"
    }


    /// 美業、課程：先找會員再點服務
    private func startWithMember() async {
        guard let t = model.ensureTicket() else { return }
        await model.attachMember(to: t)
    }


    // MARK: 單子

    private func content(_ t: Ticket) -> some View {
        let x = t.totals
        let editable = model.checkoutTicketId == nil
        return VStack(spacing: 0) {
            header(t)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Rule()
            if t.activeLines.isEmpty && t.lines.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("還沒點東西")
                        .textRole(.h4)
                        .foregroundStyle(Theme.ink2)
                    Text("點左邊的品項加進來；先在右側鍵盤打數字＝一次加幾份")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(t.lines) { line in
                                LineRow(line: line, ticket: t, editable: editable,
                                        selected: editable && line.isActive && selectedLineId == line.id,
                                        onSelect: { select(line) })
                                    .id(line.id)
                                Rule(color: Theme.hair)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: t.lines.count) { _, _ in
                        if let last = t.lines.last { withAnimation(Motion.ease) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onChange(of: selectedLineId) { _, id in
                        guard let id else { return }
                        withAnimation(Motion.ease) { proxy.scrollTo(id) }
                    }
                }
            }
            Rule()
            totals(t, x)
                .padding(18)
        }
        .animation(Motion.spring, value: selectedLineId)
    }

    /// 點一行：選起來（右欄換成那一行的動作）；再點一次取消
    private func select(_ line: TicketLine) {
        guard model.checkoutTicketId == nil, line.isActive else { return }
        if selectedLineId == line.id {
            selectedLineId = nil
        } else {
            selectedLineId = line.id
            // 左邊開著規格、加料的卡就收起來：右欄只對應一樣東西
            model.variantItem = nil
            model.modifierItem = nil
        }
        model.touch()
    }

    private func selectedLine(in t: Ticket) -> TicketLine? {
        guard let id = selectedLineId else { return nil }
        return t.lines.first { $0.id == id && $0.isActive }
    }

    private func header(_ t: Ticket) -> some View {
        let editable = model.checkoutTicketId == nil
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title(floor: model.floor))
                    .font(.brand(22, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 6) {
                    Text(t.number)
                    Text("・")
                    Text(model.staffName(t.openedBy))
                    Text("・")
                    Text(TaipeiTime.clock(t.openedAt))
                }
                .font(.brand(12.5, .regular))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            }
            // 一排狀態（不是按鈕）：用餐方式與人數、銷售人員、已印結帳單；要改在右欄
            if showsChipRow(t) {
                HStack(spacing: 8) {
                    if showsOrderChip(t) { StatusBadge(orderChipText(t), tone: .neutral) }
                    if model.mode.staffPerTicket { salespersonTag(t) }
                    if t.billPrintedAt != nil { StatusBadge("已印結帳單", tone: .warning) }
                }
            }
            if let x = t.exchange {
                exchangeBanner(x)
            }
            if t.member != nil {
                TicketMemberStrip(ticket: t, open: $memberOpen)
            } else if model.mode.wantsCustomer && editable {
                // 美業、課程一定要有客人：提醒一下，「找會員」在右欄
                HStack(spacing: 10) {
                    HeroIcon("user-circle", size: 18)
                    Text("還沒有會員・\(memberHint)")
                        .font(.brand(13, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
            }
            if !t.note.isEmpty {
                Text("※ \(t.note)")
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .animation(Motion.fast, value: memberOpen)
    }

    /// 用餐方式＋人數的標籤：有內用的模式，或這張單本來就有桌子、人數
    private func showsOrderChip(_ t: Ticket) -> Bool {
        model.mode.showsOrderType || !t.tableIds.isEmpty || t.guests > 0
    }

    private func showsChipRow(_ t: Ticket) -> Bool {
        showsOrderChip(t) || model.mode.staffPerTicket || t.billPrintedAt != nil
    }

    private func orderChipText(_ t: Ticket) -> String {
        var parts: [String] = []
        if model.mode.showsOrderType { parts.append(t.orderType.label) }
        if t.guests > 0 { parts.append("\(t.guests) 位") }
        return parts.isEmpty ? "人數" : parts.joined(separator: "・")
    }


    /// 「銷售 Cameron」（只顯示；改在右欄「銷售…」）
    private func salespersonTag(_ t: Ticket) -> some View {
        let s = model.staffMember(t.salespersonId)
        return HStack(spacing: 6) {
            if let s {
                StaffAvatar(name: s.name, swatch: s.swatch, size: 20)
                Text("銷售 \(s.name)")
            } else {
                HeroIcon("user", size: 13)
                Text("還沒指定\(model.mode.staffTitle)")
            }
        }
        .font(.brand(12.5, .medium))
        .foregroundStyle(s == nil ? Theme.accentText : Theme.ink2)
        .lineLimit(1)
    }

    // MARK: 換貨

    /// 「換貨單・原單 A012 退回 2 件，抵 NT$1,280」
    private func exchangeBanner(_ x: ExchangeCredit) -> some View {
        let count = x.lines.reduce(0) { $0 + $1.quantity }
        let detail = "原單 \(x.number) 退回 \(count) 件，抵 \(x.amount.formatted)"
        return HStack(alignment: .top, spacing: 10) {
            HeroIcon("arrows-right-left", size: 16)
                .foregroundStyle(Theme.infoFG)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("換貨單")
                    .font(.brand(13.5, .semibold))
                    .foregroundStyle(Theme.infoFG)
                Text(detail)
                    .font(.brand(12.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Tone.info.background, in: .rect(cornerRadius: Metric.radius))
        .accessibilityElement(children: .combine)
    }


    /// 銷售人員的候選：上班中的排前面
    private var salespeople: [StaffMember] {
        let active = model.staff.filter(\.isActive)
        return active.filter { model.isClockedIn($0) } + active.filter { !model.isClockedIn($0) }
    }


    private var memberHint: String {
        model.mode == .fitness ? "在右邊「找會員」：堂數要記在會員身上" : "在右邊「找會員」：做完記在客人的紀錄上"
    }

    /// 還沒做的第 2、3 道
    private func laterCourses(_ t: Ticket) -> [Int] {
        Set(t.unsentLines.map(\.course)).filter { $0 >= 2 }.sorted()
    }


    // MARK: 金額

    private func totals(_ t: Ticket, _ x: TicketTotals) -> some View {
        let minutes = serviceMinutes(t)
        let redeemedCount = t.activeLines.filter { $0.redeem != nil }.reduce(0) { $0 + $1.quantity }
        let showsMinutes = minutes > 0 && (model.mode.staffPerLine || t.appointmentId != nil)
        return VStack(spacing: 7) {
            ValueRow(label: "小計", value: x.subtotal.formatted)
            if redeemedCount > 0 {
                ValueRow(label: "課程卡抵用 \(redeemedCount) 項", value: "不收費", tone: Theme.accentText)
            }
            if x.orderDiscount.cents > 0 {
                ValueRow(label: "折扣 \(t.discount?.label ?? "")", value: "−" + x.orderDiscount.formatted, tone: Theme.accentText)
            }
            if x.serviceCharge.cents > 0 {
                ValueRow(label: "服務費 \(percentText(bps: t.serviceChargeBps))", value: x.serviceCharge.formatted)
            }
            if x.tip.cents > 0 { ValueRow(label: "小費", value: x.tip.formatted) }
            if showsMinutes {
                ServiceDurationBar(segments: durationSegments(t), total: minutes)
                    .padding(.vertical, 2)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("總計")
                        .font(.brand(17, .semibold))
                    Text("含稅 \(x.tax.plain)・\(t.itemCount) 項")
                        .font(.brand(12, .regular))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                MoneyText(money: x.amountDue, role: .number)
            }
            .padding(.top, 4)
            // 換貨單（還沒進結帳）：退回的抵多少、要補還是要退
            if let ex = t.exchange, t.exchangeApplied.cents == 0 {
                exchangePreview(ex, x)
            }
            if x.paid.cents > 0 {
                ValueRow(label: "已收", value: x.paid.formatted, tone: Theme.successFG)
                ValueRow(label: x.balance.isNegative ? "多收" : "尚欠", value: Money(cents: abs(x.balance.cents)).formatted, strong: true,
                         tone: x.balance.isNegative ? Theme.dangerFG : Theme.ink)
            }
        }
    }

    @ViewBuilder
    private func exchangePreview(_ ex: ExchangeCredit, _ x: TicketTotals) -> some View {
        let used = min(ex.amount, x.amountDue)
        ValueRow(label: "換貨抵用（原單 \(ex.number)）", value: "−" + used.formatted, tone: Theme.infoFG)
        if ex.amount > x.amountDue {
            ValueRow(label: "退差額（現金）", value: (ex.amount - x.amountDue).formatted, strong: true, tone: Theme.dangerFG)
        } else {
            ValueRow(label: "補差額", value: (x.amountDue - ex.amount).formatted, strong: true)
        }
    }

    /// 時間條的每一段：一個服務、多久、誰做（設計師的顏色）
    private func durationSegments(_ t: Ticket) -> [ServiceDurationBar.Segment] {
        t.activeLines.filter { $0.itemKind == .service && ($0.durationMinutes ?? 0) > 0 }.map { l in
            let who = model.staffMember(l.staffId)
            return ServiceDurationBar.Segment(id: l.id, name: l.name, minutes: (l.durationMinutes ?? 0) * l.quantity,
                                              color: who.map { Theme.swatch($0.swatch) } ?? Theme.faint, staffName: who?.name)
        }
    }

    /// 這張單的服務一共要多久（分鐘）
    private func serviceMinutes(_ t: Ticket) -> Int {
        t.activeLines.filter { $0.itemKind == .service }.reduce(0) { $0 + ($1.durationMinutes ?? 0) * $1.quantity }
    }

    /// 「45 分」「1 小時 30 分」「2 小時」
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) 分" }
        return m == 0 ? "\(h) 小時" : "\(h) 小時 \(m) 分"
    }


    // MARK: - 右欄：整張單

    /// 右欄要放什麼：結帳中不放（付款畫面自己放）；選了某一行放那一行；不然放整張單（沒有單就是開單）
    private var dock: DockSelection? {
        guard model.checkoutTicketId == nil else { return nil }
        guard let t = model.selectedTicket else { return emptyPage }
        if let line = selectedLine(in: t) { return lineSelection(line, in: t) }
        return ticketPage(t)
    }

    /// 還沒有單：開單（照模式）、其他用餐方式、自訂品項、掃條碼
    private var emptyPage: DockSelection {
        let type = model.mode.defaultOrderType
        var actions: [POSAction] = []
        let primary: POSAction
        if model.mode.wantsCustomer {
            primary = POSAction("找會員開單", icon: "user-circle") { Task { await startWithMember() } }
            actions.append(POSAction("開新單（不找會員）", icon: "plus-circle") { model.openTicket(type: type) })
        } else {
            primary = POSAction(model.mode.showsOrderType ? "開\(type.label)單" : "開一張新單", icon: "plus-circle") {
                model.openTicket(type: type)
            }
        }
        if model.mode.showsOrderType {
            for other in OrderType.allCases where other != type {
                actions.append(POSAction("開\(other.label)單", icon: "plus-circle") { model.openTicket(type: other) })
            }
        }
        actions.append(POSAction("自訂品項…", icon: "pencil-square") { askingCustom = true })
        actions.append(POSAction("掃商品條碼…", icon: "qr-code") { scanning = true })
        // 剛結帳的那一筆（點餐頁下面那條）：補印交易明細
        if let sale = model.lastSale, Date().timeIntervalSince(sale.closedAt) < 120 {
            actions.append(POSAction("印上一筆明細", icon: "printer") { model.printReceipt(sale) })
        }
        return .page("ticket-empty", primary: primary, accent: false, actions: actions)
    }

    /// 整張單：大鍵＝送單（餐廳有還沒送的）或結帳；動作鍵只放常用的，其他在「更多…」「折扣…」的面板
    private func ticketPage(_ t: Ticket) -> DockSelection {
        let unsent = t.unsentLines.filter { $0.course <= 1 }
        // 餐廳：先送廚房、吃完再結帳；櫃台、咖啡：結帳時一起送（沒有「送單」）；美業沒有廚房，只有結帳
        let canSend = model.features.kitchen && model.mode.usesKitchen && !model.mode.payFirst && !unsent.isEmpty
        let checkout = checkoutAction(t)
        var actions: [POSAction] = []
        if canSend { actions.append(checkout) }
        actions += ticketActions(t)
        if canSend {
            let count = unsent.reduce(0) { $0 + $1.quantity }
            return .page("ticket-\(t.id)", primary: POSAction("送單 \(count)", icon: "fire") { model.send(t) }, accent: true, actions: actions)
        }
        return .page("ticket-\(t.id)", primary: checkout, accent: model.role.takesPayment, actions: actions)
    }

    /// 結帳；不收錢的崗位（報到接待）：單子已經同步到結帳櫃台，請客人過去結
    private func checkoutAction(_ t: Ticket) -> POSAction {
        let hasLines = !t.activeLines.isEmpty
        if model.role.takesPayment {
            return POSAction("結帳", icon: "banknotes", enabled: hasLines) { model.beginCheckout(t) }
        }
        return POSAction("送到結帳櫃台", icon: "paper-airplane", enabled: hasLines) {
            model.show("\(t.number) 已經同步到結帳櫃台，請客人到櫃台結帳", tone: .info)
        }
    }

    /// 整張單的動作鍵（右欄上面的空間有限：最多六個；不常用的在「更多…」）
    private func ticketActions(_ t: Ticket) -> [POSAction] {
        var out: [POSAction] = []
        if t.member == nil {
            out.append(POSAction("找會員", icon: "user-circle") { Task { await model.attachMember(to: t) } })
        }
        if model.mode.staffPerTicket {
            let s = model.staffMember(t.salespersonId)
            out.append(POSAction(s.map { "銷售：\($0.name)" } ?? "指定\(model.mode.staffTitle)", icon: "user") { panel = .salesperson })
        }
        out.append(POSAction(t.discount == nil ? "折扣…" : "折扣（\(t.discount?.label ?? "")）…", icon: "tag") { panel = .ticketDiscount })
        out.append(POSAction("整張單的備註…", icon: "pencil-square") {
            noteText = t.note
            ticketNote = true
        })
        out.append(POSAction("更多…", icon: "ellipsis-horizontal") { panel = .ticketMore })
        out.append(POSAction("作廢整張單…", icon: "trash", destructive: true) { voidingTicket = true })
        return out
    }

    // MARK: - 右欄：選起來的一行

    /// 這一行：大鍵＝數量（右側鍵盤）；動作鍵照這一行挑（課程卡、設計師、助理、換規格、備註、折扣、座位、刪除）
    private func lineSelection(_ line: TicketLine, in t: Ticket) -> DockSelection {
        let passes = line.redeem == nil ? model.redeemablePasses(for: line, in: t) : []
        let title = model.mode.staffTitle
        var actions: [POSAction] = []
        if line.redeem != nil {
            actions.append(POSAction("取消抵用", icon: "arrow-uturn-left") { model.unredeem(line, in: t) })
        } else if let only = passes.first, passes.count == 1 {
            actions.append(POSAction("用\(only.name)抵", icon: "ticket") { model.redeem(line, with: only, in: t) })
        } else if !passes.isEmpty {
            actions.append(POSAction("用卡抵…", icon: "ticket") { panel = .passes })
        }
        if canEditStaff(line) {
            actions.append(POSAction(line.staffId == nil ? "指定\(title)" : "換\(title)", icon: "user") { panel = .performer })
            actions.append(POSAction(line.assistantId == nil ? "加助理" : "換助理", icon: "users") { panel = .assistant })
        }
        if canChangeVariant(line) {
            actions.append(POSAction("換規格", icon: "swatch") { panel = .variant })
        }
        actions.append(POSAction("備註…", icon: "pencil-square") {
            noteText = line.note
            noteFor = line
        })
        actions.append(POSAction(line.discount == nil ? "折扣・改價…" : "折扣（\(line.discount?.label ?? "")）…", icon: "tag") { panel = .lineDiscount })
        if isClassic {
            actions.append(POSAction(line.isSent ? "座位…" : "座位・第幾道…", icon: "clock") { panel = .lineCourse })
        }
        if line.isSent {
            actions.append(POSAction("作廢…", icon: "x-circle", destructive: true) { voidReasonFor = [line] })
        } else {
            actions.append(POSAction("刪除", icon: "trash", destructive: true) {
                selectedLineId = nil
                Task { await model.void([line], in: t, reason: "點錯") }
            })
        }
        let quantity = POSAction("數量 \(line.quantity)", icon: "calculator") { Task { await model.changeQuantity(line, in: t) } }
        return DockSelection(id: "line-\(line.id)", kind: "這一行", title: line.displayName, detail: lineDetail(line),
                             badge: lineBadge(line), primary: quantity, accent: false, actions: actions,
                             clear: { selectedLineId = nil })
    }

    /// 「×2・NT$240・半糖・少冰・Cameron」
    private func lineDetail(_ line: TicketLine) -> String {
        var parts = ["×\(line.quantity)"]
        parts.append(line.redeem != nil ? "卡抵" : (line.gross - line.lineDiscount).formatted)
        if !line.modifiers.isEmpty { parts.append(line.modifierText) }
        if line.itemKind == .service, let m = line.durationMinutes { parts.append(TicketColumn.duration(m * line.quantity)) }
        if let s = model.staffMember(line.staffId) { parts.append(s.name) }
        return parts.joined(separator: "・")
    }

    private func lineBadge(_ line: TicketLine) -> DockBadge? {
        if line.redeem != nil { return DockBadge("卡抵", tone: .gold) }
        if line.isSent { return DockBadge(line.kitchen.label, tone: .info) }
        if isClassic { return DockBadge("未送出", tone: .gold) }
        return nil
    }

    private func canEditStaff(_ line: TicketLine) -> Bool {
        model.mode.staffPerLine && line.itemKind == .service && line.isActive
    }

    private func canChangeVariant(_ line: TicketLine) -> Bool {
        guard line.isActive, !line.isSent, line.skuId != nil, let id = line.itemId else { return false }
        return model.catalog.item(id)?.hasVariants ?? false
    }

    /// 餐飲、零售（座位、第幾道只有這幾個模式用）
    private var isClassic: Bool { !model.mode.staffPerLine && !model.mode.staffPerTicket }

    // MARK: - 蓋住右欄的選擇

    private func panelTitle(_ p: TicketPanel) -> String {
        switch p {
        case .performer: "指定\(model.mode.staffTitle)"
        case .assistant: "助理"
        case .passes: "用課程卡抵"
        case .variant: "換規格"
        case .lineDiscount: "折扣・改價"
        case .lineCourse: "座位・第幾道"
        case .ticketDiscount: "整張單的折扣"
        case .ticketMore: "這張單"
        case .salesperson: "銷售人員"
        }
    }

    private func panelSubtitle(_ p: TicketPanel) -> String? {
        if p.isLine { return model.selectedTicket.flatMap { selectedLine(in: $0) }?.displayName }
        guard let t = model.selectedTicket else { return nil }
        switch p {
        case .salesperson: return "整張單的業績算給誰"
        default: return "\(t.number)・\(t.title(floor: model.floor))"
        }
    }

    @ViewBuilder
    private func panelContent(_ p: TicketPanel) -> some View {
        if let t = model.selectedTicket {
            VStack(alignment: .leading, spacing: 8) {
                if p.isLine {
                    if let line = selectedLine(in: t) {
                        linePanel(p, line: line, in: t)
                    }
                } else {
                    ticketPanel(p, in: t)
                }
            }
        }
    }

    /// 這一行的選擇
    @ViewBuilder
    private func linePanel(_ p: TicketPanel, line: TicketLine, in t: Ticket) -> some View {
        switch p {
        case .performer:
            staffChoices(model.bookableStaff, selected: line.staffId, none: "不指定") { id in
                model.setPerformer(line, staffId: id, in: t)
            }
        case .assistant:
            staffChoices(model.staff.filter { $0.isActive && $0.id != line.staffId }, selected: line.assistantId, none: "不用助理") { id in
                model.setAssistant(line, staffId: id, in: t)
            }
        case .passes:
            ForEach(model.redeemablePasses(for: line, in: t)) { pass in
                let left = model.visitsLeft(on: pass, excluding: line.id)
                DockChoice(title: pass.name, detail: pass.statusText(at: Date()),
                           trailing: left.map { $0 >= line.quantity ? "可抵 \($0) 次" : "剩 \(max($0, 0)) 次" } ?? "不限次數",
                           enabled: left.map { $0 >= line.quantity } ?? true) {
                    panel = nil
                    model.redeem(line, with: pass, in: t)
                }
            }
        case .variant:
            if let id = line.itemId, let item = model.catalog.item(id) {
                VariantMatrix(item: item, selectedId: line.skuId, compact: true) { v in
                    panel = nil
                    model.changeVariant(line, to: v, in: t)
                }
                Text("小字是這家店的庫存；價格不一樣的會照新規格的價格")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)
            }
        case .lineDiscount:
            DockChoice(title: "打折（%）", detail: "在右邊打要折掉的 %") {
                panel = nil
                Task { await model.discount(line, in: t, kind: .percent) }
            }
            DockChoice(title: "折價（元）", detail: "在右邊打折掉多少錢") {
                panel = nil
                Task { await model.discount(line, in: t, kind: .amount) }
            }
            if line.discount != nil {
                DockChoice(title: "取消折扣", trailing: line.discount?.label) {
                    panel = nil
                    model.clearDiscount(line, in: t)
                }
            }
            DockChoice(title: "改價", detail: "改單價（要領班以上）", trailing: line.unitPrice.formatted) {
                panel = nil
                Task { await model.changePrice(line, in: t) }
            }
        case .lineCourse:
            DockChoice(title: "座位", detail: "第幾位客人（分開結帳用）", trailing: line.seat.map { "座 \($0)" }) {
                panel = nil
                Task { await model.setSeat(line, in: t) }
            }
            if !line.isSent {
                DockChoice(title: "馬上做", selected: line.course <= 1) {
                    panel = nil
                    model.setCourse(0, for: line, in: t)
                }
                DockChoice(title: "第 2 道", detail: "等「催菜」再做", selected: line.course == 2) {
                    panel = nil
                    model.setCourse(2, for: line, in: t)
                }
                DockChoice(title: "第 3 道", detail: "等「催菜」再做", selected: line.course == 3) {
                    panel = nil
                    model.setCourse(3, for: line, in: t)
                }
            }
        case .ticketDiscount, .ticketMore, .salesperson:
            EmptyView()
        }
    }

    /// 整張單的選擇
    @ViewBuilder
    private func ticketPanel(_ p: TicketPanel, in t: Ticket) -> some View {
        switch p {
        case .ticketDiscount:
            DockChoice(title: "整單打折（%）", detail: "在右邊打要折掉的 %") {
                panel = nil
                Task { await model.discountTicket(t, kind: .percent) }
            }
            DockChoice(title: "整單折價（元）", detail: "在右邊打折掉多少錢") {
                panel = nil
                Task { await model.discountTicket(t, kind: .amount) }
            }
            if t.discount != nil {
                DockChoice(title: "取消整單折扣", trailing: t.discount?.label) {
                    panel = nil
                    model.clearTicketDiscount(t)
                }
            }
            if t.serviceChargeBps > 0 {
                DockChoice(title: "免收服務費", detail: "要領班以上", trailing: percentText(bps: t.serviceChargeBps)) {
                    panel = nil
                    Task { await model.waiveServiceCharge(t) }
                }
            }
            if model.store.tipsEnabled {
                DockChoice(title: "小費", detail: "不開發票", trailing: t.tip.cents > 0 ? t.tip.formatted : nil) {
                    panel = nil
                    Task { await model.setTip(t) }
                }
            }
        case .ticketMore:
            if model.mode.showsOrderType {
                Eyebrow("用餐方式")
                ForEach(OrderType.allCases, id: \.self) { type in
                    DockChoice(title: type.label, selected: t.orderType == type) {
                        panel = nil
                        model.setOrderType(type, for: t)
                    }
                }
            }
            if showsOrderChip(t) {
                DockChoice(title: "人數", detail: "在右邊打幾位", trailing: t.guests > 0 ? "\(t.guests) 位" : nil) {
                    panel = nil
                    Task { await model.setGuests(t) }
                }
            }
            Eyebrow("單子").padding(.top, 8)
            if t.member != nil {
                DockChoice(title: "換會員", detail: "在右邊打電話") {
                    panel = nil
                    Task { await model.attachMember(to: t) }
                }
                DockChoice(title: "移除會員", detail: "用他的課程卡抵的會一起取消") {
                    panel = nil
                    model.detachMember(from: t)
                }
            }
            DockChoice(title: "自訂品項", detail: "菜單上沒有的（開瓶費、運費）") {
                panel = nil
                askingCustom = true
            }
            DockChoice(title: "掃商品條碼", detail: "用相機掃") {
                panel = nil
                scanning = true
            }
            ForEach(laterCourses(t), id: \.self) { c in
                DockChoice(title: "催菜：第 \(c) 道", detail: "開始做第 \(c) 道") {
                    panel = nil
                    model.fire(course: c, of: t)
                }
            }
            DockChoice(title: "拆單", detail: "選品項搬到新的一張", enabled: t.itemCount > 1) {
                panel = nil
                splitting = t
            }
            if model.visibleSections.contains(.floor) {
                DockChoice(title: "換桌／併桌", detail: "到桌位圖") {
                    panel = nil
                    model.go(.floor)
                }
            }
            DockChoice(title: "印結帳單", detail: t.billPrintedAt.map { "已印過 \(TaipeiTime.clock($0))" }) {
                panel = nil
                model.printBill(t)
            }
        case .salesperson:
            staffChoices(salespeople, selected: t.salespersonId, none: "不指定（算給開單的人）") { id in
                model.setSalesperson(id, for: t)
            }
        case .performer, .assistant, .passes, .variant, .lineDiscount, .lineCourse:
            EmptyView()
        }
    }

    /// 選人：「不指定」＋每一位（職稱、上班中）
    @ViewBuilder
    private func staffChoices(_ list: [StaffMember], selected: String?, none: String, pick: @escaping (String?) -> Void) -> some View {
        DockChoice(title: none, selected: selected == nil) {
            panel = nil
            pick(nil)
        }
        ForEach(list) { s in
            let working = model.isClockedIn(s)
            let info = [s.title, working ? "上班中" : nil].compactMap { $0 }.joined(separator: "・")
            DockChoice(title: s.name, detail: info.isEmpty ? nil : info,
                       selected: s.id == selected) {
                panel = nil
                pick(s.id)
            }
        }
    }
}

// MARK: - 一行

/// 單子上的一行：只顯示（數量、名字、規格、時間、設計師、卡抵、狀態），不放按鈕。
/// 點一下選起來（品牌橘的框），右欄換成這一行的動作；再點一下取消
struct LineRow: View {
    @Environment(POSModel.self) private var model
    let line: TicketLine
    let ticket: Ticket
    let editable: Bool
    var selected = false
    var onSelect: () -> Void = {}

    private var item: MenuItem? { line.itemId.flatMap { model.catalog.item($0) } }

    /// 美業、課程的服務：每一行有設計師／教練（已經指定了的，換到其他模式也看得到）
    private var showsStaff: Bool {
        line.isActive && ((model.mode.staffPerLine && line.itemKind == .service) || line.staffId != nil)
    }

    /// 餐飲、零售（「還沒送出」的點只有這幾個模式用）
    private var isClassic: Bool { !model.mode.staffPerLine && !model.mode.staffPerTicket }

    var body: some View {
        let passes = editable && line.isActive && line.redeem == nil ? model.redeemablePasses(for: line, in: ticket) : []
        Button(action: onSelect) {
            summary(passes)
        }
        .buttonStyle(.row)
        .background { rowBackground }
        .overlay {
            if selected {
                Rectangle()
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHint(editable && line.isActive ? (selected ? "再點一下取消選取" : "點一下，右邊出現這一行的動作") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(Motion.spring, value: line.redeem)
        .animation(Motion.fast, value: selected)
    }

    // MARK: 這一行（只顯示）

    private func summary(_ passes: [MemberPass]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            quantityBox

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(line.name)
                        .font(.brand(15.5, .medium))
                        .strikethrough(!line.isActive)
                        .multilineTextAlignment(.leading)
                    if !line.isSent && line.isActive && isClassic {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .accessibilityLabel("還沒送出")
                    }
                }
                .foregroundStyle(line.isActive ? Theme.ink : Theme.faint)
                metaRow
                if !line.modifiers.isEmpty {
                    Text(line.modifierText)
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                }
                if !line.note.isEmpty {
                    Text("※ \(line.note)")
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.accentText)
                        .multilineTextAlignment(.leading)
                }
                kindRow
                if showsStaff {
                    staffRow
                        .padding(.top, 3)
                }
                redeemStatus(passes)
                HStack(spacing: 6) {
                    if let d = line.discount, line.isActive { StatusBadge(d.label, tone: .gold) }
                    if line.course >= 2 { StatusBadge("第 \(line.course) 道", tone: .info) }
                    if let s = line.seat { StatusBadge("座 \(s)", tone: .neutral) }
                    if line.isSent && line.isActive { StatusBadge(line.kitchen.label, tone: kitchenTone) }
                    if let v = line.voided { StatusBadge("作廢・\(v.reason)", tone: .danger) }
                }
            }
            Spacer(minLength: 6)
            priceColumn
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if selected {
            // 選起來的：亮一階的底、左邊一條品牌橘、外框（右欄對應的就是這一行）
            (line.redeem != nil ? Theme.accentSoft : Theme.surface)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 4) }
        } else if line.redeem != nil && line.isActive {
            // 用課程卡抵的行：淡淡的品牌橘底、左邊一條橘線，一眼看得出不收錢
            Theme.accentSoft.opacity(0.7)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
    }

    private var quantityBox: some View {
        Text("\(line.quantity)")
            .font(.brand(17, .semibold))
            .monospacedDigit()
            .foregroundStyle(line.isActive ? Theme.ink : Theme.faint)
            .frame(width: 34, height: 34)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusSm)
                    .strokeBorder(selected ? Theme.ink : Theme.line, lineWidth: selected ? 1.5 : 1)
            }
            .accessibilityLabel("數量 \(line.quantity)")
    }

    private var priceColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if line.redeem != nil && line.isActive {
                // 用課程卡抵：不收錢，原價劃掉給客人看
                Text("卡抵")
                    .font(.brand(14.5, .semibold))
                    .foregroundStyle(Theme.accentText)
                Text(listValue.short)
                    .font(.brand(12, .regular))
                    .monospacedDigit()
                    .strikethrough()
                    .foregroundStyle(Theme.faint)
            } else {
                Text((line.gross - line.lineDiscount).short)
                    .font(.brand(15.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(line.isActive ? Theme.ink : Theme.faint)
                    .strikethrough(!line.isActive)
            }
        }
    }

    /// 原價（用卡抵之前）
    private var listValue: Money {
        (line.unitPrice + Money.sum(line.modifiers.map(\.priceDelta))) * line.quantity
    }

    private var kitchenTone: Tone {
        switch line.kitchen {
        case .new: .neutral
        case .sent: .info
        case .preparing: .warning
        case .ready: .active
        case .served: .neutral
        }
    }

    // MARK: 規格、時間

    @ViewBuilder
    private var metaRow: some View {
        let minutes: Int? = line.itemKind == .service ? line.durationMinutes : nil
        if line.variantName != nil || minutes != nil {
            HStack(spacing: 8) {
                if let v = line.variantName {
                    HStack(spacing: 5) {
                        if let item, let first = item.variant(line.skuId).flatMap({ VariantPanel.colorValue(of: $0, in: item) }) {
                            ColorSwatchDot(color: VariantPanel.swatchFill(for: first), size: 10)
                        }
                        Text(v)
                    }
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(line.isActive ? Theme.ink2 : Theme.faint)
                }
                if let m = minutes {
                    HStack(spacing: 4) {
                        HeroIcon("clock", size: 11)
                        Text(TicketColumn.duration(m * line.quantity))
                            .monospacedDigit()
                    }
                    .font(.brand(12, .medium))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Theme.press, in: .capsule)
                    .overlay { Capsule().strokeBorder(Theme.hair) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("服務時間 \(TicketColumn.duration(m * line.quantity))")
                }
            }
        }
    }

    // MARK: 課程卡、儲值

    @ViewBuilder
    private var kindRow: some View {
        if line.itemKind == .pass || line.itemKind == .storedValue {
            let isPass = line.itemKind == .pass
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusBadge(isPass ? "課程卡" : "儲值", tone: isPass ? .info : .gold)
                if let detail = kindDetail {
                    Text(detail)
                        .font(.brand(12, .regular))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
        }
    }

    /// 課程卡：「10 次・180 天內・續約：接在 11/3 後」；儲值：「儲值金 +11,000」
    private var kindDetail: String? {
        switch line.itemKind {
        case .pass:
            var parts: [String] = []
            if let spec = line.pass { parts.append(spec.summary) }
            if let start = line.passStartsAt { parts.append("續約：接在 \(Self.monthDay(start.addingTimeInterval(-1))) 後") }
            return parts.isEmpty ? nil : parts.joined(separator: "・")
        case .storedValue:
            guard let credit = line.credit else { return nil }
            return "儲值金 +\((credit * line.quantity).plain)"
        case .goods, .service:
            return nil
        }
    }

    private static func monthDay(_ d: Date) -> String {
        let c = TaipeiTime.components(d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    // MARK: 設計師／教練、助理（只顯示；選起來才改）

    private var staffRow: some View {
        HStack(spacing: 6) {
            staffTag(line.staffId, placeholder: "未指定\(model.mode.staffTitle)", prefix: nil, prominent: true)
            if let a = line.assistantId {
                staffTag(a, placeholder: "", prefix: "助理", prominent: false)
            }
        }
    }

    private func staffTag(_ id: String?, placeholder: String, prefix: String?, prominent: Bool) -> some View {
        let s = model.staffMember(id)
        let title: String = s.map { member in (prefix.map { "\($0) " } ?? "") + member.name } ?? placeholder
        let tint: Color = s == nil ? (prominent ? Theme.accentText : Theme.muted) : Theme.ink
        let border: Color = s == nil && prominent ? Theme.accent.opacity(0.45) : Theme.line
        let dash: [CGFloat] = s == nil ? [3, 2] : []
        return HStack(spacing: 5) {
            if let s {
                StaffAvatar(name: s.name, swatch: s.swatch, size: 18)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.brand(12.5, .medium))
        .padding(.leading, s == nil ? 9 : 3)
        .padding(.trailing, 9)
        .frame(height: 26)
        .foregroundStyle(tint)
        .overlay { Capsule().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: dash)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    // MARK: 課程卡抵用（狀態）

    @ViewBuilder
    private func redeemStatus(_ passes: [MemberPass]) -> some View {
        if let r = line.redeem, line.isActive {
            HStack(alignment: .center, spacing: 6) {
                HeroIcon("ticket", size: 14)
                Text("卡抵・\(r.name)")
                    .font(.brand(12.5, .semibold))
                    .lineLimit(1)
                if let left = redeemLeft(r) {
                    Text(left)
                        .font(.brand(11, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 7)
                        .frame(height: 19)
                        .background(Theme.accent, in: .capsule)
                }
            }
            .foregroundStyle(Theme.accentText)
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(redeemText(r))
        } else if !passes.isEmpty && !selected {
            // 提示：這一行可以用客人的卡抵（點一下這一行就有「用卡抵」）
            HStack(spacing: 5) {
                HeroIcon("ticket", size: 12)
                Text(passes.count == 1 ? "可用\(passes[0].name)抵" : "可用課程卡抵（\(passes.count) 張）")
                    .lineLimit(1)
            }
            .font(.brand(12, .medium))
            .foregroundStyle(Theme.accentText)
            .padding(.top, 2)
        }
    }

    /// 「卡抵・剪髮 10 次卡（剩 7 次）」：剩的次數已經扣掉還沒結帳的單（包括這一行）
    private func redeemText(_ r: PassRedemption) -> String {
        guard let left = redeemLeft(r) else { return "卡抵・\(r.name)" }
        return "卡抵・\(r.name)（\(left)）"
    }

    /// 「剩 7 次」（次數卡）、「到 2026/11/3」（期間會籍）；查不到帳戶是 nil
    private func redeemLeft(_ r: PassRedemption) -> String? {
        guard let pass = model.account(for: ticket.member)?.passes.first(where: { $0.id == r.passId }) else { return nil }
        if let left = model.visitsLeft(on: pass) { return "剩 \(max(left, 0)) 次" }
        return pass.statusText(at: Date())
    }
}

// MARK: - 會員條

/// 單子上的會員：名字、電話、等級；查得到帳戶就有儲值金與課程卡。點一下展開看每一張卡、備註、上次做了什麼
struct TicketMemberStrip: View {
    @Environment(POSModel.self) private var model
    let ticket: Ticket
    @Binding var open: Bool
    @State private var looking = false

    var body: some View {
        if let ref = ticket.member {
            let info = model.member(for: ref)
            let account = model.account(for: ref)
            let usableCount = account?.usablePasses(at: Date()).count ?? 0
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(Motion.fast) { open.toggle() }
                    model.touch()
                } label: {
                    summary(ref, account: account, passCount: usableCount)
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "收起來" : "看課程卡與備註")
                if open {
                    Rule(color: Theme.accent.opacity(0.2))
                    detail(ref, info: info, account: account)
                        .transition(.opacity)
                }
            }
            .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
            .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.accent.opacity(0.22)) }
            .task(id: ref.id) { await lookUp(ref, force: false) }
        }
    }

    private func summary(_ ref: MemberRef, account: MemberAccount?, passCount: Int) -> some View {
        let name = ref.name ?? ref.maskedPhone
        let sub = [ref.name != nil ? ref.maskedPhone : nil, ref.id == nil ? "離線先記電話" : nil].compactMap { $0 }.joined(separator: "・")
        return HStack(alignment: .center, spacing: 10) {
            Text(String(name.prefix(1)))
                .font(.brand(15, .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(Theme.accent, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.brand(15, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let tier = ref.tierName, !tier.isEmpty {
                        Text(tier)
                            .font(.brand(10.5, .semibold))
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay { RoundedRectangle(cornerRadius: Metric.chip).strokeBorder(Theme.accent.opacity(0.5)) }
                    }
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.brand(12, .regular))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                if let account {
                    HStack(spacing: 6) {
                        pill(icon: "banknotes", text: "儲值 \(account.wallet.formatted)", strong: account.wallet.cents > 0)
                        pill(icon: "ticket", text: passCount > 0 ? "\(passCount) 張卡" : "沒有卡", strong: passCount > 0)
                    }
                } else if looking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("查儲值金、課程卡…")
                            .font(.brand(11.5, .medium))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            Spacer(minLength: 6)
            HeroIcon("chevron-down", size: 11)
                .foregroundStyle(Theme.muted)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    /// 會員條上的小膠囊（儲值金、幾張卡）
    private func pill(icon: String, text: String, strong: Bool) -> some View {
        HStack(spacing: 4) {
            HeroIcon(icon, size: 11)
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.brand(11.5, .semibold))
        .foregroundStyle(strong ? Theme.ink : Theme.muted)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.surface, in: .capsule)
        .overlay { Capsule().strokeBorder(strong ? Theme.accent.opacity(0.35) : Theme.line) }
    }

    private func detail(_ ref: MemberRef, info: Member?, account: MemberAccount?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let account {
                let passes = sortedPasses(account)
                if passes.isEmpty {
                    Text("沒有課程卡、會籍")
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(Theme.muted)
                } else {
                    ForEach(passes) { p in
                        let usable = p.isUsable(at: Date())
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            HeroIcon("ticket", size: 12)
                            Text(p.name)
                                .font(.brand(13, .medium))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(p.statusText(at: Date()))
                                .font(.brand(12, .regular))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .foregroundStyle(usable ? Theme.ink : Theme.faint)
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if model.features.accounts && ref.id != nil {
                HStack(spacing: 8) {
                    Text(looking ? "查儲值金與課程卡…" : "查不到儲值金與課程卡（離線？）")
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 6)
                    if !looking {
                        Button("再查一次") { Task { await lookUp(ref, force: true) } }
                            .buttonStyle(.brand(.quiet, size: .sm))
                    }
                }
            }
            if let note = info?.note, !note.isEmpty {
                Text("※ \(note)")
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let visit = info?.recentVisits?.first {
                Text(lastVisit(visit))
                    .font(.brand(12, .regular))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            if account == nil && info?.note == nil && info?.recentVisits?.first == nil && !(model.features.accounts && ref.id != nil) {
                Text(ref.maskedPhone)
                    .font(.brand(12.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 能用的排前面、快到期的排前面（最多 8 張）
    private func sortedPasses(_ account: MemberAccount) -> [MemberPass] {
        let now = Date()
        let sorted = account.passes.sorted { a, b in
            let ua = a.isUsable(at: now) ? 0 : 1
            let ub = b.isUsable(at: now) ? 0 : 1
            if ua != ub { return ua < ub }
            return (a.expiresAt ?? .distantFuture) < (b.expiresAt ?? .distantFuture)
        }
        return Array(sorted.prefix(8))
    }

    /// 「上次 2026/10/2・剪髮、染髮・Cameron」
    private func lastVisit(_ v: MemberVisit) -> String {
        var parts = ["上次 \(v.at.dayText)"]
        if !v.items.isEmpty { parts.append(v.items.joined(separator: "、")) }
        if !v.staffNames.isEmpty { parts.append(v.staffNames.joined(separator: "、")) }
        return parts.joined(separator: "・")
    }

    /// 還沒查過這位會員（例如從預約、報到帶進來的）就跟後台查一次：儲值金、課程卡、備註
    private func lookUp(_ ref: MemberRef, force: Bool) async {
        guard ref.id != nil, model.features.members || model.features.accounts, !looking else { return }
        guard force || model.member(for: ref) == nil else { return }
        looking = true
        await model.refreshMember(ref)
        looking = false
    }
}

// MARK: - 服務時間條

/// 美業、課程：這張單的服務一共多久——一條分段的時間條（每一段是一個服務，顏色是做的人），旁邊是總時間與大約幾點做完
struct ServiceDurationBar: View {
    struct Segment: Identifiable {
        var id: String
        var name: String
        var minutes: Int
        var color: Color
        var staffName: String?
    }

    let segments: [Segment]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    HeroIcon("clock", size: 13)
                    Text("服務時間")
                }
                .font(.brand(14, .medium))
                .foregroundStyle(Theme.ink2)
                Spacer(minLength: 8)
                Text(TicketColumn.duration(total))
                    .font(.brand(15, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            GeometryReader { geo in
                let gap: CGFloat = 3
                let usable = max(geo.size.width - gap * CGFloat(max(segments.count - 1, 0)), 0)
                HStack(spacing: gap) {
                    ForEach(segments) { s in
                        Capsule()
                            .fill(s.color)
                            .frame(width: max(usable * CGFloat(s.minutes) / CGFloat(max(total, 1)), 6))
                    }
                }
            }
            .frame(height: 8)
            .background(Theme.press, in: .capsule)
            Text("現在開始，大約 \(TaipeiTime.clock(Date().addingTimeInterval(TimeInterval(total * 60)))) 做完")
                .font(.brand(11.5, .regular))
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let parts: [String] = segments.map { s in
            let who = s.staffName.map { "（\($0)）" } ?? ""
            return "\(s.name) \(s.minutes) 分\(who)"
        }
        return "服務時間 \(TicketColumn.duration(total))：\(parts.joined(separator: "、"))"
    }
}

// MARK: - 拆單

/// 拆單：選要搬到新單的品項與數量
struct SplitSheet: View {
    @Environment(POSModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket
    @State private var moving: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("拆單・\(ticket.number)")
                    Headline("Split the *check*", role: .h3)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.brand(.ghost, size: .sm))
            }
            .padding(24)
            Rule()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ticket.activeLines) { line in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.displayName).font(.brand(16, .medium))
                                if !line.modifiers.isEmpty {
                                    Text(line.modifierText).font(.brand(12.5, .regular)).foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer()
                            Text("共 \(line.quantity)")
                                .font(.brand(13, .regular))
                                .foregroundStyle(Theme.muted)
                            Stepper(value: Binding(get: { moving[line.id] ?? 0 }, set: { moving[line.id] = min(max($0, 0), line.quantity) }), in: 0...line.quantity) {
                                Text("搬 \(moving[line.id] ?? 0)")
                                    .font(.brand(16, .semibold))
                                    .monospacedDigit()
                            }
                            .fixedSize()
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        Rule(color: Theme.hair)
                    }
                }
            }
            Rule()
            HStack {
                Button("全部選") { for l in ticket.activeLines { moving[l.id] = l.quantity } }
                    .buttonStyle(.brand(.quiet, size: .md))
                Spacer()
                Button("拆出新的一張") {
                    model.split(ticket, moving: moving)
                    dismiss()
                }
                .buttonStyle(.brand(.accent, size: .lg, arrow: true))
                .disabled(!canSplit)
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(Theme.sheet)
    }

    /// 至少搬一項，而且不能全部搬走（全部搬走就不是拆單了）
    private var canSplit: Bool {
        let total = moving.values.reduce(0, +)
        let all = ticket.activeLines.reduce(0) { $0 + $1.quantity }
        return total > 0 && total < all
    }
}
