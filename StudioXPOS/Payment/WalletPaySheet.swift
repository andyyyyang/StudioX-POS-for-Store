import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import VisionKit

/// 掃碼付那一筆的卡（流程在 POSModel+WalletPay；和刷卡機的卡 CardTerminalSheet 同一個樣子）：
///
///   ┌ LINE Pay                          × ┐
///   │ 掃客人的付款碼・A012・NT$1,280        │
///   │ ┌──────── 相機 ─────────┐           │   掃碼：相機，或條碼機打進下面的框
///   │ └───────────────────────┘           │
///   │ [ 條碼機掃這裡，或手打付款碼 ] [收款]   │
///   └─────────────────────────────────────┘
///
/// 送出之後：等錢包（客人在手機上確認）→ 每 3 秒查一次，最多 20 分鐘；可以取消（錢包正在處理的取消不了，等結果）。
/// 不知道有沒有扣款時只能「再查一次」或「先關掉，之後再查」（不會再送一次付款碼）。做到一半不能滑掉
struct WalletPaySheet: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: WalletPaySession

    @State private var typed = ""
    @State private var pulse = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: session.tender.label, subtitle: subtitle, closeLabel: closeLabel, close: closeAction)
            ScrollView {
                VStack(spacing: 22) {
                    if session.phase == .scanning {
                        scanner
                    } else {
                        status
                    }
                    if let line = noteLine { note(line.text, tone: line.tone) }
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
        .sensoryFeedback(.success, trigger: session.phase.isApproved)
        // 卡被關掉（鎖定、這張單在別台結帳了）：流程停下來，還不知道結果的背景查
        .onDisappear { model.walletSheetClosed(session) }
    }

    private var subtitle: String {
        session.phase == .scanning ? "掃客人的付款碼・\(session.ticketNumber)・\(session.amount.formatted)" : "\(session.ticketNumber)・\(session.amount.formatted)"
    }

    /// 掃碼時 × 是「取消」（還沒送出，不會扣款）；等錢包時 × 是「取消」（送取消）；問店員時 × 是「關掉」；送出、查詢中、成功時沒有 ×
    private var closeAction: (() -> Void)? {
        let s = session
        switch s.phase {
        case .scanning:
            return { s.abort() }
        case .waiting:
            // 錢包正在處理、取消不了：用下面的「先關掉，之後再查」
            if s.cancelRefused { return nil }
            return { s.press(.cancel) }
        case .failed, .unknown:
            if s.buttons.isEmpty { return nil }
            return { s.press(.close) }
        case .charging, .checking, .cancelling, .approved:
            return nil
        }
    }

    private var closeLabel: String {
        switch session.phase {
        case .scanning, .waiting: "取消"
        default: "關掉"
        }
    }

    // MARK: 掃碼

    private var scanner: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottom) {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ScannerRepresentable(symbologies: ScanKind.walletCode) { code in session.submit(code) }
                } else {
                    Theme.surface
                    EmptyState(icon: "qr-code", title: "這台裝置不能用相機掃", message: "請用條碼機掃進下面的框，或手打付款碼")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: model.isPhone ? 300 : 260)
            .clipShape(.rect(cornerRadius: Metric.radiusLg))
            Text("請客人打開\(session.tender.label)的付款碼，對準相機")
                .textRole(.body)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(model.isPhone ? "手打付款碼" : "條碼機掃這裡，或手打付款碼", text: $typed)
                    .focused($fieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .font(.brand(16, .regular).monospaced())
                    .padding(12)
                    .background(Theme.page, in: .rect(cornerRadius: Metric.radius))
                    .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                    // 條碼機掃完會按 Enter：直接送出
                    .onSubmit { submitTyped() }
                Button {
                    submitTyped()
                } label: {
                    Text("收款").padding(.horizontal, 6)
                }
                .buttonStyle(.brand(.primary, size: .md))
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.isDemo {
                // 示範：模擬器沒有相機，按一下當作掃到客人的付款碼
                Button {
                    session.submit(Self.demoCode)
                } label: {
                    HStack(spacing: 8) {
                        HeroIcon("qr-code", size: 18)
                        Text("示範：模擬掃到付款碼")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))
            }
        }
        .padding(.top, 4)
        // iPad 接條碼機：框先選起來，掃了就進來（手機用相機，不跳鍵盤擋住）
        .onAppear { if !model.isPhone { fieldFocused = true } }
    }

    static let demoCode = "381234567890123456"

    private func submitTyped() {
        let text = typed
        typed = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.submit(text)
        if !model.isPhone { fieldFocused = true }
    }

    // MARK: 送出之後

    private var status: some View {
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
        case .charging, .checking, .cancelling:
            ProgressView().controlSize(.large)
        case .waiting, .scanning:
            HeroIcon("device-phone-mobile", size: 56)
        }
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

    private var instruction: String {
        switch session.phase {
        case .approved(let line): line
        case .failed(let title, _), .unknown(let title, _): title
        case .waiting(let text): text
        case .charging: "送出去了，等\(session.tender.label)回覆"
        case .checking: "查這一筆的結果"
        case .cancelling: "取消中…"
        case .scanning: ""
        }
    }

    // MARK: 小字

    private var noteLine: (text: String, tone: Tone)? {
        if let n = session.note { return (n, .warning) }
        switch session.phase {
        case .scanning:
            return session.scanHint.map { ($0, Tone.warning) }
        case .charging:
            return ("客人的付款碼送出去了；結果回來之前不要讓客人再付一次", .neutral)
        case .waiting:
            let every = max((model.walletScanConfig?.pollMs ?? 3000) / 1000, 1)
            let minutes = model.walletScanConfig?.windowMinutes ?? 20
            return ("每 \(every) 秒查一次，最多等 \(minutes) 分鐘；錢包扣款了這筆會自動記上", .active)
        case .checking:
            return ("只查結果，不會再扣一次款", .info)
        case .cancelling:
            return ("錢包如果已經扣款了，這筆照收（要退照退款）", .warning)
        case .failed(_, let detail):
            return (detail, .danger)
        case .unknown(_, let detail):
            return (detail, .warning)
        case .approved:
            return nil
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
                    session.press(b.choice)
                } label: {
                    Text(b.title)
                        .font(.brand(16, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.brand(b.prominent ? .primary : (b.choice == .close || b.choice == .later ? .quiet : .ghost)))
            }
        }
    }
}

extension WalletPaySession.Phase {
    var isApproved: Bool {
        if case .approved = self { return true }
        return false
    }
}
