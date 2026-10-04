import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 結帳（工作區）：應收多少、怎麼付（可以分好幾種）、發票怎麼開、會員。
/// 金額一律在右側鍵盤打：現金有「剛好」與湊整的快速鍵，刷卡、電子支付預設剩下的全部
struct PaymentView: View {
    @Environment(POSModel.self) private var model
    let ticketId: String

    @State private var carrierText = ""
    @State private var scanning = false
    @State private var shares: [Money] = []
    @FocusState private var carrierFocused: Bool

    private var ticket: Ticket? { model.state.tickets[ticketId] }

    var body: some View {
        if let t = ticket {
            content(t)
        } else {
            EmptyState(icon: "check-circle", title: "這張單已經結帳了")
        }
    }

    private func content(_ t: Ticket) -> some View {
        let x = t.totals
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(t, x)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 24) {
                        tenders(t, x)
                        if !shares.isEmpty { sharesView }
                        if !t.approvedPayments.isEmpty { payments(t) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 24) {
                        if model.features.invoice && model.invoiceSettings.enabled { invoice(t) }
                        if model.features.members { member(t) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { footer(t, x) }
        .sheet(isPresented: $scanning) {
            CodeScannerSheet(title: "掃客人的手機條碼", types: ScanKind.carrier) { code in
                carrierText = code
                if !model.setCarrier(code, for: t) { model.show("載具格式不對：\(code)", tone: .warning) }
            }
        }
    }

    // MARK: 上面：應收

    private func header(_ t: Ticket, _ x: TicketTotals) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("結帳・\(t.number)・\(t.title(floor: model.floor))")
                Headline(x.isPaidInFull ? "All *paid*" : "Collect *payment*", role: .h2)
            }
            Spacer()
            stat("應收", x.amountDue, role: .number, color: Theme.ink2)
            if x.paid.cents > 0 { stat("已收", x.paid, role: .number, color: Theme.successFG) }
            stat(x.balance.isNegative ? "多收" : "尚欠", Money(cents: abs(x.balance.cents)), role: .stat, color: x.balance.isNegative ? Theme.dangerFG : Theme.ink)
        }
    }

    private func stat(_ label: String, _ m: Money, role: TextRole, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.brand(12.5, .medium))
                .foregroundStyle(Theme.muted)
            MoneyText(money: m, role: role, color: color)
        }
    }

    // MARK: 付款方式

    private static let tenderOrder: [Tender] = [.cash, .card, .tapToPay, .linePay, .jkoPay, .pxPay, .easyWallet, .stored, .voucher, .transfer, .other]

    private func tenders(_ t: Ticket, _ x: TicketTotals) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("付款方式")
                Spacer()
                Button("平分") {
                    Task { shares = await model.splitEvenly(t) ?? [] }
                }
                .buttonStyle(.brand(.quiet, size: .sm))
                .disabled(x.isPaidInFull)
            }
            // 現金最大（台灣最常用）
            Button {
                Task { await model.takeCash(t) }
            } label: {
                HStack(spacing: 14) {
                    HeroIcon("banknotes", size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("現金").font(.brand(20, .semibold))
                        Text("在右邊打收了多少，找零自動算").font(.brand(12.5, .regular)).opacity(0.7)
                    }
                    Spacer()
                    Text("→").font(.brand(22, .regular))
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 84)
            }
            .buttonStyle(.choice(true, height: 84))
            .disabled(x.isPaidInFull)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                ForEach(Self.tenderOrder.dropFirst(), id: \.self) { tender in
                    Button {
                        Task { await model.take(tender, for: t) }
                    } label: {
                        VStack(spacing: 6) {
                            tenderIcon(tender)
                            Text(tender.label).font(.brand(14, .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 74)
                    }
                    .buttonStyle(.choice(false, height: 74))
                    .disabled(x.isPaidInFull)
                }
            }
        }
    }

    @ViewBuilder
    private func tenderIcon(_ tender: Tender) -> some View {
        switch tender {
        case .card: HeroIcon("credit-card", size: 22)
        case .tapToPay: Image(systemName: "wave.3.right").font(.system(size: 19, weight: .regular))
        case .linePay, .jkoPay, .pxPay, .easyWallet: HeroIcon("device-phone-mobile", size: 22)
        case .stored: HeroIcon("identification", size: 22)
        case .voucher: HeroIcon("ticket", size: 22)
        case .transfer: HeroIcon("arrows-right-left", size: 22)
        case .cash: HeroIcon("banknotes", size: 22)
        case .other: HeroIcon("ellipsis-horizontal", size: 22)
        case .prepaid: HeroIcon("gift", size: 22)
        case .exchange: HeroIcon("arrows-right-left", size: 22)
        }
    }

    private var sharesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("平分 \(shares.count) 份")
                Spacer()
                Button("收起來") { shares = [] }
                    .buttonStyle(.brand(.quiet, size: .sm))
            }
            FlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(Array(shares.enumerated()), id: \.offset) { i, m in
                    Text("第 \(i + 1) 位 \(m.formatted)")
                        .font(.brand(14, .medium))
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                        .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                }
            }
            Text("每一位選付款方式時，在右邊打他那一份的金額")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
        }
    }

    private func payments(_ t: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("已收")
            VStack(spacing: 0) {
                ForEach(t.approvedPayments) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.tender.label + (p.cardLast4.map { " ****\($0)" } ?? ""))
                                .font(.brand(15.5, .medium))
                            if let tendered = p.tendered, p.change.cents > 0 {
                                Text("收 \(tendered.formatted)・找 \(p.change.formatted)")
                                    .font(.brand(12.5, .regular))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        Text(p.amount.formatted)
                            .font(.brand(15.5, .medium))
                            .monospacedDigit()
                        Button {
                            Task { await model.voidPayment(p, in: t) }
                        } label: {
                            HeroIcon("x-mark", size: 14)
                        }
                        .buttonStyle(SquareIconButtonStyle(size: 30))
                        .accessibilityLabel("退回這筆")
                    }
                    .padding(.vertical, 10)
                    Rule(color: Theme.hair)
                }
            }
        }
    }

    // MARK: 發票

    private enum BuyerKind: String, CaseIterable { case paper, carrier, business, donation }

    private func kind(of b: InvoiceBuyer) -> BuyerKind {
        switch b {
        case .consumer(nil): .paper
        case .consumer: .carrier
        case .business: .business
        case .donation: .donation
        }
    }

    private func invoice(_ t: Ticket) -> some View {
        let k = kind(of: t.invoiceBuyer)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("電子發票")
                Spacer()
                Text("剩 \(model.invoiceNumbersLeft) 張號碼")
                    .font(.brand(12, .medium))
                    .foregroundStyle(model.invoiceNumbersLeft < 10 ? Theme.warningFG : Theme.muted)
            }
            HStack(spacing: 8) {
                choice("紙本", selected: k == .paper) { model.setBuyer(.paper, for: t) }
                choice("手機條碼", selected: k == .carrier) { carrierFocused = true }
                choice("統編", selected: k == .business) { Task { await model.askTaxId(for: t) } }
                choice("捐贈", selected: k == .donation) { Task { await model.askLoveCode(for: t) } }
            }
            detail(t, k)
        }
        .padding(18)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay { RoundedRectangle(cornerRadius: Metric.radiusLg).strokeBorder(Theme.line) }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.choice(selected, height: 46))
    }

    @ViewBuilder
    private func detail(_ t: Ticket, _ k: BuyerKind) -> some View {
        switch k {
        case .paper:
            Text("印電子發票證明聯給客人")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
        case .carrier, .business, .donation:
            HStack(spacing: 8) {
                if let p = t.invoiceBuyer.problem {
                    Label(p, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.dangerFG)
                } else {
                    Label(t.invoiceBuyer.summary, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.successFG)
                }
            }
            .font(.brand(14, .medium))
        }
        if k == .carrier || carrierFocused {
            HStack(spacing: 8) {
                TextField("/ABC+123（掃描器掃或手打）", text: $carrierText)
                    .focused($carrierFocused)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.brand(16, .regular).monospaced())
                    .padding(12)
                    .background(Theme.page, in: .rect(cornerRadius: Metric.radius))
                    .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                    .onSubmit {
                        if !model.setCarrier(carrierText, for: t) { model.show("手機條碼是 / 開頭 8 碼", tone: .warning) }
                    }
                Button {
                    scanning = true
                } label: {
                    HeroIcon("qr-code", size: 18)
                }
                .buttonStyle(SquareIconButtonStyle(size: 46))
                .accessibilityLabel("用相機掃")
            }
        }
        if case .business = t.invoiceBuyer {
            Text("打統編的發票會印證明聯（格式 25），金額分開列銷售額與稅額")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: 會員

    private func member(_ t: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("會員")
            if let m = t.member {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name ?? m.maskedPhone).font(.brand(17, .medium))
                        Text([m.maskedPhone, m.tierName].compactMap { $0 }.joined(separator: "・"))
                            .font(.brand(12.5, .regular))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("移除") { model.detachMember(from: t) }
                        .buttonStyle(.brand(.quiet, size: .sm))
                }
                Text("結帳後這筆會算進他的累積消費（和網路商店同一份）")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            } else {
                Button {
                    Task { await model.attachMember(to: t) }
                } label: {
                    Label { Text("輸入電話找會員") } icon: { HeroIcon("user-circle", size: 18) }
                }
                .buttonStyle(.brand(.ghost, size: .md))
            }
        }
        .padding(18)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay { RoundedRectangle(cornerRadius: Metric.radiusLg).strokeBorder(Theme.line) }
    }

    // MARK: 下面

    private func footer(_ t: Ticket, _ x: TicketTotals) -> some View {
        HStack(spacing: 12) {
            Button("回到點餐") { model.cancelCheckout() }
                .buttonStyle(.brand(.ghost, size: .lg))
            Spacer()
            if x.isPaidInFull {
                Button {
                    Task { await model.complete(t) }
                } label: {
                    Text("完成結帳")
                }
                .buttonStyle(.brand(.accent, size: .lg, arrow: true))
            } else {
                Text("尚欠 \(x.balance.formatted)")
                    .font(.brand(17, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.page.opacity(0.96))
        .overlay(alignment: .top) { Rule() }
    }
}
