import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 刷卡機那一筆的卡：金額送到刷卡機之後，「請客人在刷卡機上刷卡／感應」＋取消；
/// 沒成功時寫清楚有沒有扣款、能做什麼（再試一次、再查一次、手動記／只改 POS、關掉）。
/// 做到一半不能滑掉（錢可能正在扣），取消也要等刷卡機回答
struct CardTerminalSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: TerminalSession

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: session.title, subtitle: subtitle, closeLabel: "取消", close: closeAction)
            ScrollView {
                VStack(spacing: 22) {
                    reader
                    status
                    if !session.buttons.isEmpty { buttons }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.sheet)
        .posSheet([.large])
        .interactiveDismissDisabled(true)
    }

    private var subtitle: String {
        switch session.purpose {
        case .charge: "刷卡機・\(session.amount.formatted)"
        case .refund: "刷卡機退貨・\(session.amount.formatted)"
        case .void: "刷卡機取消・\(session.amount.formatted)"
        }
    }

    /// 等刷卡機時 × 是「取消」（要等刷卡機回）；問店員時 × 是「關掉」；查詢中、成功時沒有 ×
    private var closeAction: (() -> Void)? {
        switch session.phase {
        case .sending, .waiting: { session.cancel() }
        case .failed, .unknown: session.buttons.isEmpty ? nil : { session.choose(.close) }
        case .cancelling, .checking, .approved: nil
        }
    }

    // MARK: 中間：刷卡機、金額、要客人做什麼

    private var reader: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(circleColor)
                    .frame(width: 168, height: 168)
                    .scaleEffect(pulse && session.phase.isWorking && !reduceMotion ? 1.08 : 0.94)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                symbol
                    .foregroundStyle(symbolColor)
            }
            .onAppear { pulse = true }
            Text(session.amount.formatted)
                .font(.brand(40, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text(instruction)
                .textRole(.body)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var symbol: some View {
        switch session.phase {
        case .approved:
            Image(systemName: "checkmark").font(.system(size: 54, weight: .regular))
        case .failed:
            Image(systemName: "xmark").font(.system(size: 50, weight: .regular))
        case .unknown:
            Image(systemName: "questionmark").font(.system(size: 52, weight: .regular))
        case .checking, .cancelling:
            ProgressView().controlSize(.large)
        case .sending, .waiting:
            HeroIcon(walletLike ? "qr-code" : "credit-card", size: 56)
        }
    }

    private var walletLike: Bool {
        if case .charge(.wallet) = session.purpose { return true }
        return false
    }

    private var circleColor: Color {
        switch session.phase {
        case .approved: Tone.active.background
        case .failed: Tone.danger.background
        case .unknown: Tone.warning.background
        default: Theme.accentSoft
        }
    }

    private var symbolColor: Color {
        switch session.phase {
        case .approved: Theme.successFG
        case .failed: Theme.dangerFG
        case .unknown: Theme.warningFG
        default: Theme.accentText
        }
    }

    /// 要客人（或店員）做什麼
    private var instruction: String {
        switch session.phase {
        case .approved(let line): return line
        case .failed(let title, _), .unknown(let title, _): return title
        case .cancelling: return "請在刷卡機上按「取消」"
        case .checking: return "正在向刷卡機確認"
        case .sending, .waiting:
            switch session.purpose {
            case .charge(.eTicket): return "請客人把悠遊卡、一卡通、愛金卡靠近刷卡機"
            case .charge(.wallet): return "請客人打開付款碼，給刷卡機掃"
            case .charge: return "請客人在刷卡機上刷卡／感應"
            case .refund(.eTicket): return "請客人把原來那張票卡靠近刷卡機"
            case .refund(.wallet): return "照刷卡機的畫面操作（可能要掃客人的付款碼）"
            case .refund: return "請客人在刷卡機上刷原來那張卡"
            case .void: return "刷卡機取消中，客人不用再刷卡"
            }
        }
    }

    // MARK: 狀態那一行

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .sending:
            note("已送到刷卡機…", tone: .neutral)
        case .waiting:
            note("刷卡機收到了，等客人", tone: .active)
        case .cancelling:
            note("等刷卡機回覆；客人如果已經刷了，這筆照收", tone: .warning)
        case .checking:
            note("沒有收到結果：查刷卡機的上一筆，確認有沒有扣款", tone: .info)
        case .approved:
            EmptyView()
        case .failed(_, let detail):
            note(detail, tone: .danger)
        case .unknown(_, let detail):
            note(detail, tone: .warning)
        }
    }

    private func note(_ text: String, tone: Tone) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tone.dot).frame(width: 7, height: 7).padding(.top, 6)
            Text(text)
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: .rect(cornerRadius: Metric.radius, style: .continuous))
    }

    // MARK: 按鈕

    private var buttons: some View {
        VStack(spacing: 10) {
            ForEach(session.buttons) { b in
                Button {
                    session.choose(b.choice)
                } label: {
                    Text(b.title)
                        .font(.brand(16, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.brand(b.prominent ? .primary : (b.choice == .close ? .quiet : .ghost)))
            }
        }
    }
}

// MARK: - 放在收銀台最外層

/// iPad：model.cardTerminal.session → 刷卡機那一筆的卡（由流程自己關，不能滑掉）
private struct CardTerminalPresenter: ViewModifier {
    @Environment(POSModel.self) private var model

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { model.cardTerminal.session }, set: { _ in })) { s in
            CardTerminalSheet(session: s)
        }
    }
}

extension View {
    /// 收銀台：刷卡機那一筆的卡（Services/CardTerminal.swift 的 TerminalSession）
    func cardTerminalPresenter() -> some View { modifier(CardTerminalPresenter()) }
}
