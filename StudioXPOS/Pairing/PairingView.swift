import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 第一次打開：和店家的後台配對。
///
/// 右側鍵盤打後台「門市 POS → 裝置」產生的 8 位數配對碼（接 StudioX 的店家不用打網址：console 知道是哪一家），
/// 或用相機掃那裡的 QR Code；自己架後台的店家在「進階」填網址。也可以先看示範。
struct PairingView: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @State private var customURL = ""
    @State private var showAdvanced = false
    @State private var scanning = false
    @State private var working = false
    @State private var attempt = 0

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    HStack(spacing: 12) {
                        BrandMark()
                            .frame(width: 30, height: 30)
                            .foregroundStyle(Theme.ink)
                        Text("StudioX POS")
                            .textRole(.h4)
                            .foregroundStyle(Theme.ink2)
                    }
                    .reveal(0)

                    RisingHeadline(lines: ["Your store,", "*in sync*."], role: .hero)

                    Text("門市收銀和網站、StudioX Console 用同一份菜單、會員與報表。斷網照常營業，連上後自動補齊。")
                        .textRole(.lead)
                        .foregroundStyle(Theme.ink2)
                        .frame(maxWidth: 560, alignment: .leading)
                        .reveal(1)

                    VStack(alignment: .leading, spacing: 18) {
                        Eyebrow("開始使用")
                        step(1, "到網站後台", "「門市 POS → 裝置」按「新增裝置」，選這台的用途（收銀機、點餐機、廚房螢幕）")
                        step(2, "輸入配對碼", "在右邊的鍵盤打畫面上的 8 位數，或按下面掃 QR Code")
                        step(3, "輸入 PIN", "店員用自己的 PIN 登入，就可以開始點餐")
                    }
                    .reveal(2)

                    HStack(spacing: 12) {
                        Button {
                            scanning = true
                        } label: {
                            Label { Text("掃描 QR Code") } icon: { HeroIcon("qr-code", size: 18) }
                        }
                        .buttonStyle(.brand(.primary, size: .lg))
                        Button("先看看示範") {
                            keypad.cancel()
                            model.startDemo()
                        }
                        .buttonStyle(.brand(.ghost, size: .lg, arrow: true))
                    }
                    .reveal(3)

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(Motion.ease) { showAdvanced.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text("進階：自己架的後台")
                                HeroIcon(showAdvanced ? "chevron-down" : "chevron-right", size: 12)
                            }
                            .font(.brand(13.5, .medium))
                            .foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        if showAdvanced {
                            TextField("https://cms.example.tw", text: $customURL)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.brand(16, .regular))
                                .padding(12)
                                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                                .frame(maxWidth: 420)
                            Text("沒接 StudioX 的店家：填後台網址，再打配對碼")
                                .textRole(.xs)
                                .foregroundStyle(Theme.muted)
                        }
                    }

                    if working {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("配對中…").foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.horizontal, 56)
                .padding(.vertical, 64)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            KeypadDock()
                .frame(width: Metric.dock)
        }
        .background(Theme.page.ignoresSafeArea())
        .task(id: attempt) { await askCode() }
        .sheet(isPresented: $scanning) {
            CodeScannerSheet(title: "掃描後台的配對 QR Code", types: ScanKind.pairing) { text in
                if let url = URL(string: text) { model.handle(url) }
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("0\(n)")
                .font(.serif(22, italic: true))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).textRole(.h4).foregroundStyle(Theme.ink)
                Text(detail).textRole(.small).foregroundStyle(Theme.muted)
            }
        }
    }

    /// 右側鍵盤一直等配對碼；配對失敗就把錯誤寫在鍵盤上，再等一次
    private func askCode() async {
        var problem: String? = nil
        while model.phase == .pairing && !Task.isCancelled {
            guard let entry = await keypad.ask(.pairingCode, error: problem) else { return }
            working = true
            let url = customURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : URL(string: customURL.trimmingCharacters(in: .whitespaces))
            do {
                try await model.pair(code: entry.digits, cmsURL: url)
                working = false
                return
            } catch let e as APIError {
                working = false
                switch e {
                case .http(404, _, _): problem = "配對碼不對或過期了（10 分鐘內有效）"
                case .http(429, _, _): problem = "試太多次了，請等 10 分鐘"
                default: problem = e.userMessage
                }
            } catch {
                working = false
                problem = "配對失敗：\(error.localizedDescription)"
            }
        }
    }
}
