import Foundation
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
    /// 已經跟後台查過儲值金的會員（查不到＝離線）
    @State private var walletLookup: String? = nil
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
        // 左邊選付款方式、右邊打金額；完成結帳、回到點餐、平分、小費、會員、退回付款都在右欄
        .dockSelection(dock(t, x))
        // 會員還沒查過（從預約、報到帶進來的）：先查一次儲值金，付款方式才知道要不要出現「儲值金」
        .task(id: t.member?.id) { await lookUpWallet(t) }
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

    /// 現金以外、可以手動選的付款方式（儲值金看會員；換貨抵用是自動的，不列）
    private static let otherTenders: [Tender] = Tender.selectable.filter { $0 != .cash }

    private func tenders(_ t: Ticket, _ x: TicketTotals) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 付款方式是「選一個」（格子），不是一排動作；平分、小費這些在下面的「⋯」
            Eyebrow("付款方式")
            // 現金最大（台灣最常用）；沒有錢櫃的崗位（前場）不收現金
            if model.role.hasDrawer {
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
            } else {
                HStack(spacing: 12) {
                    HeroIcon("banknotes", size: 20)
                        .foregroundStyle(Theme.faint)
                    Text("這台是「\(model.role.label)」，沒有錢櫃：現金請到結帳櫃台收；這裡可以刷卡、電子支付")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.press, in: .rect(cornerRadius: Metric.radius))
            }

            prepaidTile(t, x)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                ForEach(Self.otherTenders, id: \.self) { tender in
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

    /// 會員的儲值金（美業、健身常用）：有會員、開了帳戶功能、餘額大於 0 才出現；還沒查過餘額先出現、一邊查。
    /// 做成一張「錢包」：餘額大大的，下面寫這次最多可以扣多少
    @ViewBuilder
    private func prepaidTile(_ t: Ticket, _ x: TicketTotals) -> some View {
        if model.features.accounts, let ref = t.member, ref.id != nil {
            let known = model.member(for: ref) != nil
            let wallet = model.account(for: ref)?.wallet ?? .zero
            if !known || wallet.cents > 0 {
                let note = prepaidNote(known: known, wallet: wallet, due: x.balance, memberId: ref.id)
                let shape = RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                Button {
                    Task { await model.payWithPrepaid(t) }
                } label: {
                    HStack(alignment: .center, spacing: 16) {
                        HeroIcon("gift", size: 22)
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 46, height: 46)
                            .background(Theme.accent, in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("儲值金")
                                .font(.brand(18, .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(note)
                                .font(.brand(12.5, .regular))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 10)
                        if known {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("餘額")
                                    .font(.brand(11.5, .medium))
                                    .foregroundStyle(Theme.muted)
                                MoneyText(money: wallet, role: .number, color: Theme.accentText)
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .opacity(walletLookup == ref.id ? 0 : 1)
                        }
                        Text("→")
                            .font(.brand(20, .regular))
                            .foregroundStyle(Theme.ink2)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                    .background {
                        shape.fill(LinearGradient(colors: [Theme.accentSoft, Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .overlay { shape.strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1) }
                    .contentShape(shape)
                }
                .buttonStyle(PressScale(scale: 0.98))
                .disabled(x.isPaidInFull)
                .opacity(x.isPaidInFull ? 0.45 : 1)
                .accessibilityLabel("儲值金，\(note)")
            }
        }
    }

    /// 「餘額 NT$8,500・這次最多扣 NT$1,200」「查餘額中…」
    private func prepaidNote(known: Bool, wallet: Money, due: Money, memberId: String?) -> String {
        guard known else { return walletLookup == memberId ? "離線查不到餘額，點一下再試" : "查餘額中…" }
        let most = min(wallet, max(due, .zero))
        return "\(ticketMemberName)餘額 \(wallet.formatted)・這次最多扣 \(most.formatted)"
    }

    private var ticketMemberName: String {
        guard let m = ticket?.member, let name = m.name, !name.isEmpty else { return "" }
        return "\(name)・"
    }

    /// 會員還沒查過就跟後台查一次（儲值金餘額）
    private func lookUpWallet(_ t: Ticket) async {
        guard model.features.accounts, let ref = t.member, let id = ref.id, model.member(for: ref) == nil else { return }
        await model.refreshMember(ref)
        walletLookup = id
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
            Eyebrow("平分 \(shares.count) 份")
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
                ForEach(t.approvedPayments.filter { $0.tender == .exchange }) { p in
                    exchangeCard(p)
                        .padding(.bottom, 10)
                }
                ForEach(t.approvedPayments.filter { $0.tender != .exchange }) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(paymentTitle(p))
                                .font(.brand(15.5, .medium))
                            if let detail = paymentDetail(p) {
                                Text(detail)
                                    .font(.brand(12.5, .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(p.tender == .exchange && p.change.cents > 0 ? Theme.dangerFG : Theme.muted)
                            }
                        }
                        Spacer()
                        Text(p.amount.formatted)
                            .font(.brand(15.5, .medium))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.vertical, 10)
                    Rule(color: Theme.hair)
                }
            }
        }
    }

    /// 換貨抵用：做成一張卡（深色、品牌橘的光），原單號、抵多少；新的比較便宜時寫退差額。
    /// 是自動記的（回到點餐就拿掉），沒有退回的按鈕
    private func exchangeCard(_ p: Payment) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    HeroIcon("arrows-right-left", size: 14)
                    Text("換貨抵用")
                        .tracking(0.6)
                }
                .font(.brand(12, .semibold))
                .foregroundStyle(Theme.inverseMuted)
                Text(p.reference.map { "原單 \($0)" } ?? "退回的商品")
                    .font(.brand(19, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.onInverse)
                if p.change.cents > 0 {
                    Text("退差額 \(p.change.formatted)（現金）")
                        .font(.brand(12.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 10)
            MoneyText(money: p.amount, role: .number, color: Theme.onInverse)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                shape.fill(LinearGradient(colors: [Theme.inverse, Theme.inverse.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle()
                    .fill(Theme.accent.opacity(0.28))
                    .frame(width: 150, height: 150)
                    .blur(radius: 30)
                    .offset(x: 40, y: -60)
            }
            .clipShape(shape)
        }
        .overlay { shape.strokeBorder(Theme.inverseLine, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(paymentTitle(p) + "，" + p.amount.formatted + (paymentDetail(p).map { "，\($0)" } ?? ""))
    }

    /// 「信用卡 ****1234」「換貨抵用（原單 A012）」
    private func paymentTitle(_ p: Payment) -> String {
        switch p.tender {
        case .exchange:
            return p.reference.map { "換貨抵用（原單 \($0)）" } ?? "換貨抵用"
        default:
            return p.tender.label + (p.cardLast4.map { " ****\($0)" } ?? "")
        }
    }

    /// 「收 NT$1,000・找 NT$120」「退差額 NT$300（現金）」「會員 0912-***-678」
    private func paymentDetail(_ p: Payment) -> String? {
        if p.tender == .exchange {
            return p.change.cents > 0 ? "退差額 \(p.change.formatted)（現金）" : nil
        }
        if let tendered = p.tendered, p.change.cents > 0 {
            return "收 \(tendered.formatted)・找 \(p.change.formatted)"
        }
        if p.tender == .prepaid, let ref = p.reference, !ref.isEmpty {
            return "會員 \(ref)"
        }
        return nil
    }

    // MARK: 發票

    private enum BuyerKind: String, CaseIterable {
        case paper, carrier, business, donation

        var label: String {
            switch self {
            case .paper: "紙本"
            case .carrier: "手機條碼"
            case .business: "統編"
            case .donation: "捐贈"
            }
        }
    }

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
            buyerSegments(t, k)
            detail(t, k)
            if let note = invoiceNote(t) {
                HStack(alignment: .top, spacing: 8) {
                    HeroIcon("information-circle", size: 16)
                        .padding(.top, 1)
                    Text(note)
                        .font(.brand(13, .medium))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.infoFG)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tone.info.background, in: .rect(cornerRadius: Metric.radius))
            }
        }
        .padding(18)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay { RoundedRectangle(cornerRadius: Metric.radiusLg).strokeBorder(Theme.line) }
    }

    /// 發票怎麼開：一個分段控制（紙本｜手機條碼｜統編｜捐贈）；統編、捐贈點了在右側鍵盤打
    private func buyerSegments(_ t: Ticket, _ k: BuyerKind) -> some View {
        HStack(spacing: 4) {
            ForEach(BuyerKind.allCases, id: \.self) { kind in
                Button {
                    choose(kind, for: t)
                } label: {
                    Text(kind.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(InvoiceSegmentStyle(selected: k == kind))
                .accessibilityAddTraits(k == kind ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.page, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
    }

    private func choose(_ kind: BuyerKind, for t: Ticket) {
        model.touch()
        switch kind {
        case .paper:
            carrierFocused = false
            model.setBuyer(.paper, for: t)
        case .carrier:
            carrierFocused = true
        case .business:
            carrierFocused = false
            Task { await model.askTaxId(for: t) }
        case .donation:
            carrierFocused = false
            Task { await model.askLoveCode(for: t) }
        }
    }

    /// 發票金額和總計不一樣的時候說一聲：
    /// 「發票開 NT$1,000（儲值金扣抵 2,000 已在儲值時開立）」「課程卡抵用不開發票」「這張不用開發票」
    private func invoiceNote(_ t: Ticket) -> String? {
        let total = t.totals.total
        let cover = InvoiceBuilder.coverage(for: t, prepaid: model.store.prepaidInvoicing)
        let redeemed = t.activeLines.contains { $0.redeem != nil }
        var reasons: [String] = []
        if cover.prepaidDeduction.cents > 0 { reasons.append("儲值金扣抵 \(cover.prepaidDeduction.plain) 已在儲值時開立") }
        if cover.excludedNet.cents > 0 { reasons.append("儲值 \(cover.excludedNet.plain) 等消費時才開") }
        if cover.amount.cents == 0 {
            if redeemed { reasons.append("課程卡抵用") }
            return reasons.isEmpty ? "這張不用開發票" : "這張不用開發票（\(reasons.joined(separator: "；"))）"
        }
        if redeemed { reasons.append("課程卡抵用不開發票") }
        if cover.amount != total {
            return "發票開 \(cover.amount.formatted)" + (reasons.isEmpty ? "" : "（\(reasons.joined(separator: "；"))）")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "；")
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
                }
                if let account = model.account(for: m) {
                    let passes = account.usablePasses(at: Date())
                    HStack(spacing: 8) {
                        StatusBadge("儲值金 \(account.wallet.formatted)", tone: account.wallet.cents > 0 ? .gold : .neutral)
                        if !passes.isEmpty {
                            StatusBadge("可用課程卡 \(passes.count) 張", tone: .info)
                        }
                    }
                }
                Text("結帳後這筆會算進他的累積消費（和網路商店同一份）")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            } else {
                HStack(spacing: 8) {
                    HeroIcon("user-circle", size: 18)
                    Text("還沒有會員・在右邊「找會員」打電話")
                        .textRole(.small)
                }
                .foregroundStyle(Theme.muted)
            }
        }
        .padding(18)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay { RoundedRectangle(cornerRadius: Metric.radiusLg).strokeBorder(Theme.line) }
    }

    // MARK: 下面：還差多少

    /// 最下面只留金額（還差多少／收齊了）；動作都在右欄
    private func footer(_ t: Ticket, _ x: TicketTotals) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(x.isPaidInFull ? "收齊了" : "尚欠")
                .font(.brand(13, .medium))
                .foregroundStyle(x.isPaidInFull ? Theme.successFG : Theme.muted)
            Text(x.isPaidInFull ? x.paid.formatted : x.balance.formatted)
                .font(.brand(22, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText(value: Double(x.isPaidInFull ? x.paid.cents : x.balance.cents)))
            Spacer(minLength: 8)
            Text(x.isPaidInFull ? "右邊「完成結帳」" : "選付款方式，在右邊打金額")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.page.opacity(0.96))
        .overlay(alignment: .top) { Rule() }
        .animation(Motion.fast, value: x.isPaidInFull)
    }

    // MARK: 右欄

    /// 結帳的右欄：大鍵＝完成結帳（收齊了才有）；動作鍵＝回到點餐、平分、小費、會員、退回付款
    private func dock(_ t: Ticket, _ x: TicketTotals) -> DockSelection {
        let done: POSAction? = x.isPaidInFull ? POSAction("完成結帳", icon: "check-circle") { Task { await model.complete(t) } } : nil
        var actions: [POSAction] = [POSAction("回到點餐", icon: "arrow-left") { model.cancelCheckout() }]
        if shares.isEmpty {
            actions.append(POSAction("平分…", icon: "users", enabled: !x.isPaidInFull) {
                Task { shares = await model.splitEvenly(t) ?? [] }
            })
        } else {
            actions.append(POSAction("取消平分", icon: "arrow-uturn-left") { shares = [] })
        }
        if model.store.tipsEnabled {
            actions.append(POSAction(x.tip.cents > 0 ? "小費 \(x.tip.formatted)" : "小費…", icon: "banknotes") { Task { await model.setTip(t) } })
        }
        if model.features.members {
            if t.member == nil {
                actions.append(POSAction("找會員", icon: "user-circle") { Task { await model.attachMember(to: t) } })
            } else {
                actions.append(POSAction("換會員…", icon: "user-circle") { Task { await model.attachMember(to: t) } })
                actions.append(POSAction("移除會員", icon: "x-circle") { model.detachMember(from: t) })
            }
        }
        // 換貨抵用是自動記的（回到點餐就拿掉），不能手動退
        let refundable = t.approvedPayments.filter { $0.tender != .exchange }
        for (i, p) in refundable.enumerated() {
            actions.append(POSAction("退回第 \(i + 1) 筆：\(paymentTitle(p)) \(p.amount.formatted)", icon: "receipt-refund", destructive: true) {
                Task { await model.voidPayment(p, in: t) }
            })
        }
        return .page("checkout-\(t.id)", primary: done, accent: true, actions: actions)
    }
}

/// 發票分段控制的一段：選到的墨色實心
private struct InvoiceSegmentStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(14, .medium))
            .foregroundStyle(selected ? Theme.page : Theme.ink2)
            .background(selected ? Theme.ink : (configuration.isPressed ? Theme.press : Color.clear),
                        in: .rect(cornerRadius: Metric.radius, style: .continuous))
            .contentShape(.rect)
            .animation(Motion.fast, value: selected)
    }
}
