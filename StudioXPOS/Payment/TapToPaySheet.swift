import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 卡緊收（iPhone 感應收款，Apple 的 Tap to Pay on iPhone）：只有手機有（iPad 不支援；手機也接不了刷卡機）。
///
/// **暫時的**：金流（TapPay／收單銀行）的 SDK 與 Apple 的權限還沒拿到——
///   - 示範模式：模擬客人感應，兩秒後收款完成
///   - 正式的店：先用銀行的卡緊收 App 收這一筆，收好了回來按「已收款」記帳（交易序號、卡號末四碼選填，對帳用）
/// 接上 SDK 之後，這張卡的「請感應」就是真的讀卡，記帳那一步不用人按。記成「感應支付」（`Tender.tapToPay`）
struct TapToPaySheet: View {
    @Environment(POSModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ticketId: String

    @State private var reference = ""
    @State private var last4 = ""
    @State private var demoDone = false
    @State private var pulse = false
    @State private var saving = false

    private var ticket: Ticket? { model.state.tickets[ticketId] }
    private var due: Money { ticket?.totals.balance ?? .zero }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "卡緊收", subtitle: ticket.map { "\($0.number)・\(due.formatted)" }, closeLabel: "取消", close: { dismiss() })
            ScrollView {
                VStack(spacing: 22) {
                    reader
                    if model.isDemo {
                        Text(demoDone ? "收款完成" : "示範：模擬客人感應，兩秒後完成")
                            .textRole(.small)
                            .foregroundStyle(demoDone ? Theme.ink : Theme.muted)
                    } else {
                        manual
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.sheet)
        .posSheet([.large])
        .task { await runDemo() }
    }

    /// 感應的地方：iPhone 上方、客人把卡或手機靠過來
    private var reader: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 168, height: 168)
                    .scaleEffect(pulse && !reduceMotion ? 1.08 : 0.94)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                Image(systemName: demoDone ? "checkmark" : "wave.3.right")
                    .font(.system(size: 54, weight: .regular))
                    .foregroundStyle(Theme.accentText)
                    .contentTransition(.symbolEffect(.replace))
            }
            .onAppear { pulse = true }
            Text(due.formatted)
                .font(.brand(40, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text("請客人把信用卡、Apple Pay 靠近 iPhone 上方")
                .textRole(.body)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    /// 正式的店（SDK 還沒接）：先用銀行的卡緊收 App 收，回來記一筆
    private var manual: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                HeroIcon("information-circle", size: 18)
                    .foregroundStyle(Theme.infoFG)
                Text("卡緊收還沒接上金流（TapPay／收單銀行）。先用銀行的卡緊收 App 收這一筆，收好了按「已收款」記到這張單。")
                    .textRole(.small)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.infoFG.opacity(0.11), in: .rect(cornerRadius: Metric.radius, style: .continuous))
            field("交易序號（選填，對帳用）", text: $reference)
            field("卡號末四碼（選填）", text: $last4)
            Button {
                Task { await save() }
            } label: {
                Text(saving ? "記帳中…" : "已收款 \(due.formatted)")
                    .font(.brand(17, .semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.brand(.primary))
            .disabled(saving || due.cents <= 0)
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .font(.brand(16, .regular))
            .keyboardType(.numberPad)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
            .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
    }

    private func save() async {
        guard let t = ticket else { return }
        saving = true
        let digits = last4.filter(\.isNumber)
        await model.recordTapToPay(t, amount: due, last4: digits.count == 4 ? digits : nil,
                                   reference: reference.trimmingCharacters(in: .whitespaces))
        saving = false
        dismiss()
    }

    /// 示範模式：兩秒後「感應成功」、記一筆、關掉
    private func runDemo() async {
        guard model.isDemo, let t = ticket else { return }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        withAnimation(Motion.spring) { demoDone = true }
        let fake = String(format: "%04d", Int.random(in: 0...9999))
        await model.recordTapToPay(t, amount: due, last4: fake, reference: "DEMO-\(fake)")
        try? await Task.sleep(for: .milliseconds(700))
        dismiss()
    }
}

extension POSModel {
    /// 卡緊收：只有會收款的手機（iPad 沒有 Tap to Pay on iPhone）
    var offersTapToPay: Bool { isPhone && takesPayment }

    /// 記一筆感應支付；付清了就結帳（和其他付款方式一樣）
    func recordTapToPay(_ t: Ticket, amount: Money, last4: String?, reference: String?) async {
        guard amount.cents > 0, let me = currentStaff, let fresh = state.tickets[t.id], fresh.isOpen else { return }
        let ref = reference.flatMap { $0.isEmpty ? nil : "卡緊收 \($0)" } ?? "卡緊收"
        let p = Payment(id: newID(), tender: .tapToPay, amount: min(amount, fresh.totals.balance), reference: ref, cardLast4: last4,
                        at: Date(), by: me.id, shiftId: openShift?.id)
        guard record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: p))) else { return }
        lastChange = .zero
        if let after = state.tickets[t.id], after.totals.isPaidInFull { await complete(after) }
    }
}
