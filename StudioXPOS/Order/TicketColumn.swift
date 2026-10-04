import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 單子（工作區與右側鍵盤之間那一欄）：桌號、人數、點了什麼、金額；送單、結帳
struct TicketColumn: View {
    @Environment(POSModel.self) private var model
    @State private var splitting: Ticket?
    @State private var noteFor: TicketLine?
    @State private var noteText = ""
    @State private var ticketNote = false
    @State private var voidReasonFor: [TicketLine] = []
    @State private var voidingTicket = false

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
                Text(model.mode.usesTables && model.features.seating
                     ? "點左邊的品項就會開一張\(model.mode.defaultOrderType.label)單；要帶位到「桌位」點空桌。"
                     : "點左邊的品項就會開一張\(model.mode.defaultOrderType.label)單（\(model.mode.label)：\(model.mode.summary)）")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            HStack(spacing: 8) {
                ForEach(OrderType.allCases, id: \.self) { type in
                    Button(type.label) { model.openTicket(type: type) }
                        .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))
                }
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: 單子

    private func content(_ t: Ticket) -> some View {
        let x = t.totals
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
                                LineRow(line: line, ticket: t, editable: model.checkoutTicketId == nil,
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
                }
            }
            Rule()
            totals(t, x)
                .padding(18)
            actions(t, x)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
    }

    private func header(_ t: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title(floor: model.floor))
                        .font(.brand(22, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
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
                }
                Spacer()
                menu(t)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await model.setGuests(t) }
                } label: {
                    Label("\(t.guests) 位", systemImage: "person.2")
                }
                .buttonStyle(.brand(.ghost, size: .sm))
                .disabled(model.checkoutTicketId != nil)
                Menu {
                    ForEach(OrderType.allCases, id: \.self) { type in
                        Button(type.label) { model.setOrderType(type, for: t) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(t.orderType.label)
                        HeroIcon("chevron-down", size: 10)
                    }
                    .font(.brand(13, .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .overlay { RoundedRectangle(cornerRadius: Metric.radiusSm).strokeBorder(Theme.line) }
                }
                .foregroundStyle(Theme.ink)
                .disabled(model.checkoutTicketId != nil)
                if let m = t.member {
                    StatusBadge((m.name ?? m.maskedPhone) + (m.tierName.map { "・\($0)" } ?? ""), tone: .gold)
                }
                if t.billPrintedAt != nil { StatusBadge("已印結帳單", tone: .warning) }
            }
            if !t.note.isEmpty {
                Text("※ \(t.note)")
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.accentText)
            }
        }
    }

    private func menu(_ t: Ticket) -> some View {
        Menu {
            Button("會員…", systemImage: "person.crop.circle") { Task { await model.attachMember(to: t) } }
            if t.member != nil { Button("移除會員", systemImage: "person.crop.circle.badge.minus") { model.detachMember(from: t) } }
            Button("整張單的備註…", systemImage: "note.text") { noteText = t.note; ticketNote = true }
            Divider()
            Button("整單打折（%）…", systemImage: "percent") { Task { await model.discountTicket(t, kind: .percent) } }
            Button("整單折價（元）…", systemImage: "minus.circle") { Task { await model.discountTicket(t, kind: .amount) } }
            if t.discount != nil { Button("取消整單折扣", systemImage: "arrow.uturn.backward") { model.clearTicketDiscount(t) } }
            if t.serviceChargeBps > 0 { Button("免收服務費…", systemImage: "hand.raised") { Task { await model.waiveServiceCharge(t) } } }
            if model.store.tipsEnabled { Button("小費…", systemImage: "heart") { Task { await model.setTip(t) } } }
            Divider()
            Menu("用餐方式") {
                ForEach(OrderType.allCases, id: \.self) { type in
                    Button(type.label) { model.setOrderType(type, for: t) }
                }
            }
            Button("拆單…", systemImage: "scissors") { splitting = t }
            if model.features.seating { Button("換桌／併桌…", systemImage: "arrow.left.arrow.right") { model.go(.floor) } }
            ForEach(laterCourses(t), id: \.self) { c in
                Button("催菜：第 \(c) 道", systemImage: "flame") { model.fire(course: c, of: t) }
            }
            Button("印結帳單", systemImage: "printer") { model.printBill(t) }
            Divider()
            Button("作廢整張單…", systemImage: "trash", role: .destructive) { voidingTicket = true }
        } label: {
            HeroIcon("ellipsis-horizontal", size: 18)
        }
        .buttonStyle(SquareIconButtonStyle(size: 38))
        .disabled(model.checkoutTicketId != nil)
    }

    /// 還沒做的第 2、3 道
    private func laterCourses(_ t: Ticket) -> [Int] {
        Set(t.unsentLines.map(\.course)).filter { $0 >= 2 }.sorted()
    }

    private func totals(_ t: Ticket, _ x: TicketTotals) -> some View {
        VStack(spacing: 7) {
            ValueRow(label: "小計", value: x.subtotal.formatted)
            if x.orderDiscount.cents > 0 {
                ValueRow(label: "折扣 \(t.discount?.label ?? "")", value: "−" + x.orderDiscount.formatted, tone: Theme.accentText)
            }
            if x.serviceCharge.cents > 0 {
                ValueRow(label: "服務費 \(percentText(bps: t.serviceChargeBps))", value: x.serviceCharge.formatted)
            }
            if x.tip.cents > 0 { ValueRow(label: "小費", value: x.tip.formatted) }
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
            if x.paid.cents > 0 {
                ValueRow(label: "已收", value: x.paid.formatted, tone: Theme.successFG)
                ValueRow(label: x.balance.isNegative ? "多收" : "尚欠", value: Money(cents: abs(x.balance.cents)).formatted, strong: true,
                         tone: x.balance.isNegative ? Theme.dangerFG : Theme.ink)
            }
        }
    }

    @ViewBuilder
    private func actions(_ t: Ticket, _ x: TicketTotals) -> some View {
        if model.checkoutTicketId == t.id {
            Button("回到點餐") { model.cancelCheckout() }
                .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
        } else {
            let unsent = t.unsentLines.filter { $0.course <= 1 }
            HStack(spacing: 10) {
                // 餐廳：先送廚房、吃完再結帳；櫃台、咖啡：結帳時一起送（沒有「送單」鈕）
                if model.features.kitchen && model.mode.usesKitchen && !model.mode.payFirst && !unsent.isEmpty {
                    Button {
                        model.send(t)
                    } label: {
                        Text("送單 \(unsent.reduce(0) { $0 + $1.quantity })")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.brand(.primary, size: .lg, fullWidth: true))
                }
                Button {
                    model.beginCheckout(t)
                } label: {
                    Text("結帳").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.accent, size: .lg, fullWidth: true, arrow: true))
                .disabled(t.activeLines.isEmpty)
            }
        }
    }
}

/// 單子上的一行
struct LineRow: View {
    @Environment(POSModel.self) private var model
    let line: TicketLine
    let ticket: Ticket
    let editable: Bool
    let onNote: () -> Void
    let onVoid: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                guard editable, line.isActive else { return }
                Task { await model.changeQuantity(line, in: ticket) }
            } label: {
                Text("\(line.quantity)")
                    .font(.brand(17, .semibold))
                    .monospacedDigit()
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm))
                    .overlay { RoundedRectangle(cornerRadius: Metric.radiusSm).strokeBorder(Theme.line) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .accessibilityLabel("數量 \(line.quantity)，點一下用右邊鍵盤改")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(line.name)
                        .font(.brand(15.5, .medium))
                        .strikethrough(!line.isActive)
                    if !line.isSent && line.isActive {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .accessibilityLabel("還沒送出")
                    }
                }
                .foregroundStyle(line.isActive ? Theme.ink : Theme.faint)
                if !line.modifiers.isEmpty {
                    Text(line.modifierText)
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(Theme.muted)
                }
                if !line.note.isEmpty {
                    Text("※ \(line.note)")
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.accentText)
                }
                HStack(spacing: 6) {
                    if let d = line.discount, line.isActive { StatusBadge(d.label, tone: .gold) }
                    if line.course >= 2 { StatusBadge("第 \(line.course) 道", tone: .info) }
                    if let s = line.seat { StatusBadge("座 \(s)", tone: .neutral) }
                    if line.isSent && line.isActive { StatusBadge(line.kitchen.label, tone: kitchenTone) }
                    if let v = line.voided { StatusBadge("作廢・\(v.reason)", tone: .danger) }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 6) {
                Text((line.gross - line.lineDiscount).short)
                    .font(.brand(15.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(line.isActive ? Theme.ink : Theme.faint)
                    .strikethrough(!line.isActive)
                if editable && line.isActive {
                    HStack(spacing: 4) {
                        stepButton("minus", -1)
                        stepButton("plus", 1)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .contextMenu { if editable && line.isActive { menu } }
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

    private func stepButton(_ icon: String, _ delta: Int) -> some View {
        Button {
            model.stepQuantity(line, in: ticket, by: delta)
        } label: {
            HeroIcon(icon, size: 14)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(SquareIconButtonStyle(size: 30))
    }

    @ViewBuilder
    private var menu: some View {
        Button("改數量…", systemImage: "number") { Task { await model.changeQuantity(line, in: ticket) } }
        Button("改價…", systemImage: "dollarsign") { Task { await model.changePrice(line, in: ticket) } }
        Button("打折（%）…", systemImage: "percent") { Task { await model.discount(line, in: ticket, kind: .percent) } }
        Button("折價（元）…", systemImage: "minus.circle") { Task { await model.discount(line, in: ticket, kind: .amount) } }
        if line.discount != nil { Button("取消折扣", systemImage: "arrow.uturn.backward") { model.clearDiscount(line, in: ticket) } }
        Button("備註…", systemImage: "note.text") { onNote() }
        Button("座位…", systemImage: "person") { Task { await model.setSeat(line, in: ticket) } }
        if !line.isSent {
            Menu("第幾道") {
                Button("馬上做") { model.setCourse(0, for: line, in: ticket) }
                Button("第 2 道（等催菜）") { model.setCourse(2, for: line, in: ticket) }
                Button("第 3 道（等催菜）") { model.setCourse(3, for: line, in: ticket) }
            }
        }
        Divider()
        if line.isSent {
            Button("作廢…", systemImage: "xmark.circle", role: .destructive) { onVoid() }
        } else {
            Button("刪除", systemImage: "trash", role: .destructive) { Task { await model.void([line], in: ticket, reason: "點錯") } }
        }
    }
}

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
                                Text(line.name).font(.brand(16, .medium))
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
