import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import VisionKit

// 掃碼的相機放在哪裡、怎麼打開（model.scanRequest）：
//
//   - 收銀台（iPad）：MainShell 最外層一張 sheet（置中的表單大小）
//   - 手機：PhoneShell 最外層一張 sheet。同一層不能同時兩張：單子的 sheet、鍵盤、面板開著時先收起來，等它收好再打開相機；
//     從單子裡打開的，相機關掉後回到單子（看得到剛掛上的會員、折價券）
//   - 相機關掉後：要選甜度、規格的品項（掃到時相機擋著）現在才打開那張卡（model.afterScan）
//
// 要店員確認的事（model.confirmRequest：套折價券會換掉原本的折扣）：右欄（手機是下面）蓋上來的面板；相機開著時由相機自己問。

/// 照用途打開的相機：一般的「掃碼」連續掃，其他的（載具、會員、折價券）掃到一個就關
struct ScanRequestSheet: View {
    @Environment(POSModel.self) private var model
    let request: ScanRequest

    var body: some View {
        let m = model
        let purpose = request.purpose
        CodeScannerSheet(title: title, subtitle: subtitle, types: types, continuous: purpose == .any) { code in
            await m.handleScan(code, context: purpose)
        }
    }

    private var title: String {
        switch request.purpose {
        case .any: "掃碼"
        case .carrier: "掃手機條碼載具"
        case .member, .memberProfile: "掃會員條碼"
        case .coupon: "掃折價券"
        }
    }

    private var subtitle: String {
        let ticket = model.scanTicket.map { "掛到 \($0.number)" }
        switch request.purpose {
        case .any:
            return "商品、會員卡、發票載具、折價券都可以，一個接一個掃・" + (ticket ?? "還沒有單：掃商品就開一張")
        case .carrier:
            return "對準客人手機上的條碼（/ 開頭 8 碼）" + (ticket.map { "・\($0)" } ?? "")
        case .member:
            return "會員卡、App 上的條碼或 QR Code（就是手機號碼）" + (ticket.map { "・\($0)" } ?? "")
        case .memberProfile:
            return "會員卡、App 上的條碼或 QR Code（就是手機號碼）"
        case .coupon:
            return "折價券上的 QR Code 或條碼" + (ticket.map { "・\($0)" } ?? "")
        }
    }

    private var types: [DataScannerViewController.RecognizedDataType] {
        switch request.purpose {
        case .any: ScanKind.all
        case .carrier: ScanKind.carrier
        case .member, .memberProfile: ScanKind.member
        case .coupon: ScanKind.coupon
        }
    }
}

// MARK: - 收銀台

/// iPad：model.scanRequest → 相機（關掉後做 afterScan）
private struct ScanPresenter: ViewModifier {
    @Environment(POSModel.self) private var model

    func body(content: Content) -> some View {
        content.sheet(item: request, onDismiss: { finished() }) { r in
            ScanRequestSheet(request: r)
        }
    }

    private var request: Binding<ScanRequest?> {
        Binding(get: { model.scanRequest }, set: { value in
            if value == nil { model.scanRequest = nil }
        })
    }

    private func finished() {
        model.scanRequest = nil
        model.takeAfterScan()?()
    }
}

// MARK: - 手機

/// 手機：先收起同一層的 sheet（單子、鍵盤、面板），等它收好再打開相機；從單子裡打開的，關掉後回到單子
private struct PhoneScanPresenter: ViewModifier {
    @Environment(POSModel.self) private var model
    let ui: PhoneUI
    @State private var shown: ScanRequest?
    @State private var reopenTicket = false

    func body(content: Content) -> some View {
        content
            .task(id: model.scanRequest?.id) { await present() }
            .sheet(item: $shown, onDismiss: { finished() }) { r in
                ScanRequestSheet(request: r)
            }
    }

    private func present() async {
        guard let r = model.scanRequest, shown?.id != r.id else { return }
        if ui.ticketOpen {
            reopenTicket = true
            ui.ticketOpen = false
        }
        // 單子的 sheet、面板收起來要一點時間：收好之前打開會被 SwiftUI 擋掉
        try? await Task.sleep(for: .milliseconds(reopenTicket ? 550 : 400))
        guard !Task.isCancelled, model.scanRequest?.id == r.id else { return }
        shown = r
    }

    private func finished() {
        model.scanRequest = nil
        let after = model.takeAfterScan()
        let reopen = reopenTicket && after == nil
        reopenTicket = false
        after?()
        // 要選甜度、規格的卡優先（它自己是一張 sheet）；不然回到單子
        if reopen, model.selectedTicket != nil, model.section == .order {
            ui.ticketOpen = true
        }
    }
}

// MARK: - 確認

/// model.confirmRequest：右欄（手機是下面）蓋上來的面板，兩個選擇；× ＝不要。相機開著時由相機問（這裡讓開）
private struct ConfirmDockPanel: ViewModifier {
    @Environment(POSModel.self) private var model

    func body(content: Content) -> some View {
        content.dockPanel(item: request, title: { $0.title }, subtitle: nil) { r in
            ConfirmChoices(request: r)
        }
    }

    private var request: Binding<ConfirmRequest?> {
        Binding(get: { model.scannersOpen == 0 ? model.confirmRequest : nil }, set: { value in
            if value == nil { model.answerConfirm(false) }
        })
    }
}

private struct ConfirmChoices: View {
    @Environment(POSModel.self) private var model
    let request: ConfirmRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.message)
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            DockChoice(title: request.confirmLabel, detail: request.confirmDetail) {
                model.answerConfirm(true)
            }
            DockChoice(title: request.keepLabel) {
                model.answerConfirm(false)
            }
        }
    }
}

extension View {
    /// 收銀台最外層：掃碼的相機
    func scanPresenter() -> some View { modifier(ScanPresenter()) }

    /// 手機最外層：掃碼的相機（會先收起單子的 sheet）
    func phoneScanPresenter(_ ui: PhoneUI) -> some View { modifier(PhoneScanPresenter(ui: ui)) }

    /// 要確認的事（套折價券換掉原本的折扣）：右欄的面板
    func confirmDockPanel() -> some View { modifier(ConfirmDockPanel()) }
}

// MARK: - 鍵盤在問會員的電話

/// 找會員、會員頁、報到時鍵盤在問電話：「用相機掃會員條碼」。掃到＝把電話打進鍵盤、按「查詢」（後面照打電話的流程走）
struct MemberScanButton: View {
    @Environment(KeypadController.self) private var keypad
    @State private var scanning = false

    var body: some View {
        Button {
            scanning = true
        } label: {
            HStack(spacing: 10) {
                HeroIcon("qr-code", size: 18)
                Text("用相機掃會員條碼")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))
        .accessibilityHint("會員卡的條碼或 QR Code 就是手機號碼")
        .sheet(isPresented: $scanning) {
            CodeScannerSheet(title: "掃會員條碼", subtitle: "會員卡、App 上的條碼或 QR Code（就是手機號碼）", types: ScanKind.member) { code in
                useScanned(code)
            }
        }
    }

    private func useScanned(_ code: String) -> ScanOutcome {
        guard let phone = ScanCode.memberPhone(in: code) else {
            return .failed(.member, "這不是會員條碼：會員卡的條碼是手機號碼（掃到 \(POSModel.excerpt(code))）")
        }
        guard keypad.isAskingMemberPhone else {
            return .failed(.member, "鍵盤已經沒有在問電話了")
        }
        keypad.fill(phone)
        return .done(.member, "會員 \(MemberRef(phone: phone).maskedPhone)", tally: nil)
    }
}
