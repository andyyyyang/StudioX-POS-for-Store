import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 單子（工作區與右側鍵盤之間那一欄）：桌號、人數、點了什麼、金額；送單、結帳。
///
/// 服飾多了整張單的銷售人員與換貨；美業、課程多了會員條（儲值金、課程卡）、每一行的設計師／教練與助理、用課程卡抵。
/// 要選的東西（人、卡、規格）都在單子裡展開，不跳視窗：右側鍵盤一直看得到、用得到。
///
/// 按鈕照 docs/DESIGN.md：頁首只有標題、一排小標籤、會員條；每一行不放按鈕，點一下選起來、動作出現在那一行下面；
/// 最下面一個主要動作（結帳；餐廳有還沒送的是送單），其他整張單的動作收進「⋯」
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
    /// 正在選銷售人員（服飾）
    @State private var pickingSalesperson = false
    /// 點了哪一行（那一行下面出現它的動作；一次只有一行）
    @State private var selectedLineId: String? = nil

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
        .onChange(of: model.selectedTicketId) { _, _ in
            memberOpen = false
            pickingSalesperson = false
            selectedLineId = nil
        }
        .onChange(of: model.checkoutTicketId) { _, _ in
            pickingSalesperson = false
            selectedLineId = nil
        }
        .sheet(item: $splitting) { t in
            SplitSheet(ticket: t)
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
            }
            // 一個主要動作（照模式：開預設的單、或先找會員）；其他用餐方式收進「⋯」
            ActionBar(primary: emptyPrimary, secondary: emptySecondary, more: emptyMore, size: .md)
            Spacer()
        }
        .padding(20)
    }

    private var emptyPrimary: POSAction {
        if model.mode.wantsCustomer {
            return POSAction("找會員開單", icon: "user-circle") { Task { await startWithMember() } }
        }
        let type = model.mode.defaultOrderType
        return POSAction(model.mode.showsOrderType ? "開\(type.label)單" : "開一張新單", icon: "plus-circle") {
            model.openTicket(type: type)
        }
    }

    private var emptySecondary: [POSAction] {
        guard model.mode.wantsCustomer else { return [] }
        return [POSAction("不找會員") { model.openTicket(type: model.mode.defaultOrderType) }]
    }

    private var emptyMore: [POSAction] {
        guard model.mode.showsOrderType else { return [] }
        return OrderType.allCases.filter { $0 != model.mode.defaultOrderType }.map { type in
            POSAction("開\(type.label)單") { model.openTicket(type: type) }
        }
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
                                        onSelect: { select(line) },
                                        onNote: { noteText = line.note; noteFor = line },
                                        onVoid: { voidReasonFor = [line] })
                                    .id(line.id)
                                Rule(color: Theme.hair)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: t.lines.count) { _, _ in
                        if let last = t.lines.last { withAnimation(Motion.ease) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    // 選起來的那一行連同它的動作要看得到
                    .onChange(of: selectedLineId) { _, id in
                        guard let id else { return }
                        Task {
                            try? await Task.sleep(for: .milliseconds(120))
                            withAnimation(Motion.ease) { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            Rule()
            totals(t, x)
                .padding(18)
            actions(t, x)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .animation(Motion.spring, value: selectedLineId)
    }

    /// 點一行：選起來（動作出現在那一行下面）；再點一次收起來
    private func select(_ line: TicketLine) {
        guard model.checkoutTicketId == nil, line.isActive else { return }
        selectedLineId = selectedLineId == line.id ? nil : line.id
        model.touch()
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
            // 一排小標籤：用餐方式與人數（點了改）、銷售人員（服飾）、已印結帳單
            if showsChipRow(t) {
                HStack(spacing: 8) {
                    if showsOrderChip(t) { orderChip(t, editable: editable) }
                    if model.mode.staffPerTicket { salespersonChip(t, editable: editable) }
                    if t.billPrintedAt != nil { StatusBadge("已印結帳單", tone: .warning) }
                }
                if pickingSalesperson && editable && model.mode.staffPerTicket {
                    TicketStaffPicker(staff: salespeople, selected: t.salespersonId, noneLabel: "不指定") { id in
                        model.setSalesperson(id, for: t)
                        withAnimation(Motion.fast) { pickingSalesperson = false }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            if let x = t.exchange {
                exchangeBanner(x)
            }
            if t.member != nil {
                TicketMemberStrip(ticket: t, open: $memberOpen)
            } else if model.mode.wantsCustomer && editable {
                findMember(t)
            }
            if !t.note.isEmpty {
                Text("※ \(t.note)")
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .animation(Motion.fast, value: pickingSalesperson)
        .animation(Motion.fast, value: memberOpen)
    }

    /// 用餐方式＋人數的標籤：有內用的模式，或這張單本來就有桌子、人數
    private func showsOrderChip(_ t: Ticket) -> Bool {
        model.mode.showsOrderType || !t.tableIds.isEmpty || t.guests > 0
    }

    private func showsChipRow(_ t: Ticket) -> Bool {
        showsOrderChip(t) || model.mode.staffPerTicket || t.billPrintedAt != nil
    }

    /// 「內用・4 位 ⌄」：點了選用餐方式、改人數（一個標籤，不是一排按鈕）
    private func orderChip(_ t: Ticket, editable: Bool) -> some View {
        let text = orderChipText(t)
        return Menu {
            if model.mode.showsOrderType {
                ForEach(OrderType.allCases, id: \.self) { type in
                    Button {
                        model.setOrderType(type, for: t)
                    } label: {
                        if t.orderType == type { Label(type.label, systemImage: "checkmark") } else { Text(type.label) }
                    }
                }
                Divider()
            }
            Button("人數…", systemImage: "person.2") { Task { await model.setGuests(t) } }
        } label: {
            HStack(spacing: 5) {
                Text(text)
                    .lineLimit(1)
                HeroIcon("chevron-down", size: 10)
            }
            .font(.brand(13, .medium))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .overlay { RoundedRectangle(cornerRadius: Metric.radiusSm).strokeBorder(Theme.line) }
            .contentShape(.rect)
        }
        .foregroundStyle(Theme.ink)
        .disabled(!editable)
        .accessibilityLabel("\(text)，點一下改用餐方式或人數")
    }

    private func orderChipText(_ t: Ticket) -> String {
        var parts: [String] = []
        if model.mode.showsOrderType { parts.append(t.orderType.label) }
        if t.guests > 0 { parts.append("\(t.guests) 位") }
        return parts.isEmpty ? "人數" : parts.joined(separator: "・")
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

    // MARK: 銷售人員（服飾）

    /// 「銷售：Cameron ⌄」：點了在下面展開選人
    private func salespersonChip(_ t: Ticket, editable: Bool) -> some View {
        let s = model.staffMember(t.salespersonId)
        let title: String = s.map { "銷售：\($0.name)" } ?? "指定\(model.mode.staffTitle)"
        let tint: Color = s == nil ? Theme.accentText : Theme.ink
        return Button {
            withAnimation(Motion.fast) { pickingSalesperson.toggle() }
            model.touch()
        } label: {
            HStack(spacing: 7) {
                if let s {
                    StaffAvatar(name: s.name, swatch: s.swatch, size: 22)
                } else {
                    HeroIcon("user", size: 15)
                }
                Text(title)
                    .lineLimit(1)
                HeroIcon("chevron-down", size: 10)
                    .rotationEffect(.degrees(pickingSalesperson ? 180 : 0))
            }
            .font(.brand(13, .medium))
            .padding(.leading, s == nil ? 10 : 5)
            .padding(.trailing, 10)
            .frame(height: 32)
            .foregroundStyle(tint)
            .background(pickingSalesperson ? Theme.press : Color.clear, in: .rect(cornerRadius: Metric.radiusSm))
            .overlay { RoundedRectangle(cornerRadius: Metric.radiusSm).strokeBorder(Theme.line) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .accessibilityLabel(s == nil ? "指定銷售人員" : "\(title)，點一下換人")
    }

    /// 銷售人員的候選：上班中的排前面
    private var salespeople: [StaffMember] {
        let active = model.staff.filter(\.isActive)
        return active.filter { model.isClockedIn($0) } + active.filter { !model.isClockedIn($0) }
    }

    // MARK: 找會員（美業、課程一定要有客人）

    private func findMember(_ t: Ticket) -> some View {
        Button {
            Task { await model.attachMember(to: t) }
        } label: {
            HStack(spacing: 12) {
                HeroIcon("user-circle", size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("找會員")
                        .font(.brand(15.5, .semibold))
                    Text(memberHint)
                        .font(.brand(12, .regular))
                        .opacity(0.72)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("→")
                    .font(.brand(18, .regular))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.choice(true, height: 58))
        .accessibilityLabel("找會員，在右邊的鍵盤打電話")
    }

    private var memberHint: String {
        model.mode == .fitness ? "右邊打電話・堂數要記在會員身上" : "右邊打電話・做完記在客人的紀錄上"
    }

    // MARK: 整張單的其他動作（「⋯」）

    /// 不常用的整張單動作：會員、備註、整單折扣、服務費、小費、催菜、拆單、換桌、印結帳單、作廢
    private func moreActions(_ t: Ticket) -> [POSAction] {
        var out: [POSAction] = []
        if t.member != nil {
            out.append(POSAction("換會員…", icon: "user-circle") { Task { await model.attachMember(to: t) } })
            out.append(POSAction("移除會員", icon: "x-circle") { model.detachMember(from: t) })
        } else if !model.mode.wantsCustomer {
            // 美業、課程的「找會員」在頁首
            out.append(POSAction("會員…", icon: "user-circle") { Task { await model.attachMember(to: t) } })
        }
        out.append(POSAction("整張單的備註…", icon: "pencil-square") {
            noteText = t.note
            ticketNote = true
        })
        out.append(POSAction("整單打折（%）…", icon: "tag") { Task { await model.discountTicket(t, kind: .percent) } })
        out.append(POSAction("整單折價（元）…", icon: "minus-circle") { Task { await model.discountTicket(t, kind: .amount) } })
        if t.discount != nil {
            out.append(POSAction("取消整單折扣", icon: "arrow-uturn-left") { model.clearTicketDiscount(t) })
        }
        if t.serviceChargeBps > 0 {
            out.append(POSAction("免收服務費…", icon: "hand-raised") { Task { await model.waiveServiceCharge(t) } })
        }
        if model.store.tipsEnabled {
            out.append(POSAction("小費…", icon: "banknotes") { Task { await model.setTip(t) } })
        }
        for c in laterCourses(t) {
            out.append(POSAction("催菜：第 \(c) 道", icon: "fire") { model.fire(course: c, of: t) })
        }
        out.append(POSAction("拆單…", icon: "scissors", enabled: t.itemCount > 1) { splitting = t })
        if model.visibleSections.contains(.floor) {
            out.append(POSAction("換桌／併桌…", icon: "arrows-right-left") { model.go(.floor) })
        }
        out.append(POSAction("印結帳單", icon: "printer") { model.printBill(t) })
        out.append(POSAction("作廢整張單…", icon: "trash", destructive: true) { voidingTicket = true })
        return out
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

    // MARK: 送單、結帳

    /// 最下面：一個主要動作（結帳；餐廳有還沒送的就是送單、結帳退成次要），其他收進「⋯」
    @ViewBuilder
    private func actions(_ t: Ticket, _ x: TicketTotals) -> some View {
        if model.checkoutTicketId == t.id {
            // 結帳中：付款、回到點餐都在左邊的結帳畫面
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                Text("結帳中・在左邊選付款方式")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
        } else {
            let unsent = t.unsentLines.filter { $0.course <= 1 }
            // 餐廳：先送廚房、吃完再結帳；櫃台、咖啡：結帳時一起送（沒有「送單」）；美業沒有廚房，只有結帳
            let canSend = model.features.kitchen && model.mode.usesKitchen && !model.mode.payFirst && !unsent.isEmpty
            let checkout = checkoutAction(t)
            if canSend {
                ActionBar(primary: POSAction("送單 \(unsent.reduce(0) { $0 + $1.quantity })", icon: "fire") { model.send(t) },
                          secondary: [checkout], more: moreActions(t), size: .lg)
            } else {
                // 品牌橘一個畫面只有一個：左邊開著規格、加料的卡（「加入」是橘的）時，結帳用墨色
                let panelOpen = model.modifierItem != nil || model.variantItem != nil
                ActionBar(primary: checkout, more: moreActions(t), size: .lg, accent: model.role.takesPayment && !panelOpen)
            }
        }
    }

    /// 結帳；不收錢的崗位（報到接待）：單子已經同步到結帳櫃台，請客人過去結
    private func checkoutAction(_ t: Ticket) -> POSAction {
        let hasLines = !t.activeLines.isEmpty
        if model.role.takesPayment {
            return POSAction("結帳", enabled: hasLines) { model.beginCheckout(t) }
        }
        return POSAction("送到結帳櫃台", icon: "paper-airplane", enabled: hasLines) {
            model.show("\(t.number) 已經同步到結帳櫃台，請客人到櫃台結帳", tone: .info)
        }
    }
}

// MARK: - 一行

/// 單子上的一行：只顯示（數量、名字、規格、時間、設計師、卡抵、狀態），不放按鈕。
/// 點一下選起來：下面出現這一行的動作——主要是數量（右側鍵盤），常用的兩個（照這一行：用卡抵、設計師、換規格、備註、打折），其他在「⋯」
struct LineRow: View {
    @Environment(POSModel.self) private var model
    let line: TicketLine
    let ticket: Ticket
    let editable: Bool
    var selected = false
    var onSelect: () -> Void = {}
    let onNote: () -> Void
    let onVoid: () -> Void

    /// 選起來之後展開的選擇：設計師／教練、助理、用哪張卡抵、換規格
    private enum Drawer: Hashable { case performer, assistant, passes, variant }
    @State private var drawer: Drawer? = nil

    private var item: MenuItem? { line.itemId.flatMap { model.catalog.item($0) } }

    /// 美業、課程的服務：每一行可以指定設計師／教練（已經指定了的，換到其他模式也看得到）
    private var showsStaff: Bool {
        line.isActive && ((model.mode.staffPerLine && line.itemKind == .service) || line.staffId != nil)
    }

    private var canEditStaff: Bool { editable && model.mode.staffPerLine && line.itemKind == .service }

    /// 還沒送出、品項有規格：可以換顏色尺寸
    private var canChangeVariant: Bool {
        editable && line.isActive && !line.isSent && line.skuId != nil && (item?.hasVariants ?? false)
    }

    /// 餐飲、零售（座位、第幾道、「還沒送出」的點只有這幾個模式用）
    private var isClassic: Bool { !model.mode.staffPerLine && !model.mode.staffPerTicket }

    var body: some View {
        let passes = editable && line.isActive && line.redeem == nil ? model.redeemablePasses(for: line, in: ticket) : []
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelect) {
                summary(passes)
            }
            .buttonStyle(.row)
            .accessibilityHint(editable && line.isActive ? (selected ? "收起這一行的動作" : "點一下改這一行") : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if selected {
                editor(passes)
                    .padding(.leading, 18)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background { rowBackground }
        .animation(Motion.fast, value: drawer)
        .animation(Motion.spring, value: line.redeem)
        .onChange(of: selected) { _, now in
            if !now { drawer = nil }
        }
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
            // 選起來的：亮一階的底、左邊一條墨色線
            (line.redeem != nil ? Theme.accentSoft : Theme.surface)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.ink).frame(width: 3) }
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

    // MARK: 選起來之後：這一行的動作

    private struct Plan {
        var primary: POSAction
        var secondary: [POSAction]
        var more: [POSAction]
    }

    private func editor(_ passes: [MemberPass]) -> some View {
        let plan = actions(passes)
        return VStack(alignment: .leading, spacing: 10) {
            // 一排放得下就一排；窄的單子欄（直的 iPad）主要動作自己一排，字不會被切掉
            ViewThatFits(in: .horizontal) {
                ActionBar(primary: plan.primary, secondary: plan.secondary, more: plan.more, size: .sm)
                VStack(alignment: .leading, spacing: 8) {
                    ActionBar(primary: plan.primary, size: .sm)
                    HStack(spacing: 0) {
                        ActionBar(primary: nil, secondary: plan.secondary, more: plan.more, size: .sm)
                        Spacer(minLength: 0)
                    }
                }
            }
            if drawer != nil {
                drawerView(passes)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Theme.page, in: .rect(cornerRadius: Metric.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
    }

    /// 主要：數量（右側鍵盤）。常用的兩個照這一行挑：課程卡 → 設計師／教練 → 換規格 → 備註 → 打折；其他收進「⋯」
    private func actions(_ passes: [MemberPass]) -> Plan {
        let primary = POSAction("數量 \(line.quantity)", icon: "calculator") {
            Task { await model.changeQuantity(line, in: ticket) }
        }
        var featured: [POSAction] = []
        if line.redeem != nil {
            featured.append(POSAction("取消抵用", icon: "arrow-uturn-left") { model.unredeem(line, in: ticket) })
        } else if !passes.isEmpty {
            featured.append(POSAction("用卡抵", icon: "ticket") {
                if passes.count == 1, let p = passes.first {
                    model.redeem(line, with: p, in: ticket)
                } else {
                    toggle(.passes)
                }
            })
        }
        if canEditStaff {
            let title = line.staffId == nil ? "指定\(model.mode.staffTitle)" : "換\(model.mode.staffTitle)"
            featured.append(POSAction(title, icon: "user") { toggle(.performer) })
        }
        if canChangeVariant {
            featured.append(POSAction("換規格", icon: "swatch") { toggle(.variant) })
        }
        featured.append(POSAction("備註…", icon: "pencil-square") { onNote() })
        featured.append(POSAction("打折（%）…", icon: "tag") { Task { await model.discount(line, in: ticket, kind: .percent) } })

        var more = Array(featured.dropFirst(2))
        more.append(POSAction("折價（元）…", icon: "minus-circle") { Task { await model.discount(line, in: ticket, kind: .amount) } })
        if line.discount != nil {
            more.append(POSAction("取消折扣", icon: "arrow-uturn-left") { model.clearDiscount(line, in: ticket) })
        }
        more.append(POSAction("改價…", icon: "currency-dollar") { Task { await model.changePrice(line, in: ticket) } })
        if canEditStaff {
            more.append(POSAction(line.assistantId == nil ? "加助理…" : "換助理…", icon: "users") { toggle(.assistant) })
        }
        if isClassic {
            more.append(POSAction("座位…", icon: "user") { Task { await model.setSeat(line, in: ticket) } })
            if !line.isSent {
                if line.course != 0 { more.append(POSAction("馬上做", icon: "fire") { model.setCourse(0, for: line, in: ticket) }) }
                if line.course != 2 { more.append(POSAction("第 2 道（等催菜）", icon: "clock") { model.setCourse(2, for: line, in: ticket) }) }
                if line.course != 3 { more.append(POSAction("第 3 道（等催菜）", icon: "clock") { model.setCourse(3, for: line, in: ticket) }) }
            }
        }
        if line.isSent {
            more.append(POSAction("作廢…", icon: "x-circle", destructive: true) { onVoid() })
        } else {
            more.append(POSAction("刪除", icon: "trash", destructive: true) {
                Task { await model.void([line], in: ticket, reason: "點錯") }
            })
        }
        return Plan(primary: primary, secondary: Array(featured.prefix(2)), more: more)
    }

    private func passList(_ passes: [MemberPass]) -> some View {
        VStack(spacing: 6) {
            ForEach(passes) { p in
                let note = passNote(p)
                Button {
                    model.redeem(line, with: p, in: ticket)
                    close()
                } label: {
                    HStack(spacing: 10) {
                        HeroIcon("ticket", size: 15)
                            .foregroundStyle(Theme.accentText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                                .font(.brand(13.5, .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text(p.statusText(at: Date()))
                                .font(.brand(11.5, .regular))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 6)
                        Text(note)
                            .font(.brand(12, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                    .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                    .contentShape(.rect)
                }
                .buttonStyle(PressScale(scale: 0.98))
                .accessibilityLabel("\(p.name)，\(p.statusText(at: Date()))，\(note)")
            }
        }
    }

    /// 「可抵 7 次」「次數不夠（剩 1）」「不限次數」
    private func passNote(_ p: MemberPass) -> String {
        guard let left = model.visitsLeft(on: p, excluding: line.id) else { return "不限次數" }
        return left >= line.quantity ? "可抵 \(left) 次" : "次數不夠（剩 \(max(left, 0))）"
    }

    @ViewBuilder
    private func drawerView(_ passes: [MemberPass]) -> some View {
        switch drawer {
        case .performer?:
            TicketStaffPicker(staff: model.bookableStaff, selected: line.staffId, noneLabel: "不指定") { id in
                model.setPerformer(line, staffId: id, in: ticket)
                close()
            }
        case .assistant?:
            TicketStaffPicker(staff: model.staff.filter { $0.isActive && $0.id != line.staffId }, selected: line.assistantId, noneLabel: "不用助理") { id in
                model.setAssistant(line, staffId: id, in: ticket)
                close()
            }
        case .passes?:
            passList(passes)
        case .variant?:
            if let item {
                VariantMatrix(item: item, selectedId: line.skuId, compact: true) { v in
                    model.changeVariant(line, to: v, in: ticket)
                    close()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
            }
        case nil:
            EmptyView()
        }
    }

    private func toggle(_ d: Drawer) {
        withAnimation(Motion.fast) { drawer = drawer == d ? nil : d }
        model.touch()
    }

    private func close() {
        withAnimation(Motion.fast) { drawer = nil }
    }
}

// MARK: - 選人

/// 選人（銷售人員、設計師、教練、助理）：在單子裡展開的一排頭像，不是跳出來的視窗（右側鍵盤不會被蓋住）
struct TicketStaffPicker: View {
    @Environment(POSModel.self) private var model
    let staff: [StaffMember]
    let selected: String?
    var noneLabel = "不指定"
    let pick: (String?) -> Void

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            chip(nil)
            ForEach(staff) { s in
                chip(s)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
        .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
    }

    private func chip(_ s: StaffMember?) -> some View {
        let on = s?.id == selected
        let title = s?.name ?? noneLabel
        let role = s?.title ?? ""
        let working = s.map { model.isClockedIn($0) } ?? false
        return Button {
            pick(s?.id)
        } label: {
            HStack(spacing: 6) {
                if let s {
                    StaffAvatar(name: s.name, swatch: s.swatch, size: 20)
                }
                Text(title)
                    .lineLimit(1)
                if !role.isEmpty {
                    Text(role)
                        .foregroundStyle(on ? Theme.page.opacity(0.65) : Theme.muted)
                }
                if working {
                    Circle()
                        .fill(Theme.live)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("上班中")
                }
            }
            .font(.brand(13, .medium))
            .padding(.leading, s == nil ? 11 : 4)
            .padding(.trailing, 11)
            .frame(minHeight: 32)
            .foregroundStyle(on ? Theme.page : Theme.ink)
            .background(on ? Theme.ink : Theme.page, in: .capsule)
            .overlay { Capsule().strokeBorder(on ? Color.clear : Theme.line) }
            .contentShape(.capsule)
        }
        .buttonStyle(PressScale(scale: 0.96))
        .accessibilityAddTraits(on ? .isSelected : [])
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
