import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 第一次打開：和店家的後台配對。
///
/// 右側鍵盤打後台「門市 POS → 裝置」產生的 8 位數配對碼（接 StudioX 的店家不用打網址：console 知道是哪一家），
/// 或用相機掃那裡的 QR Code；自己架後台的店家在「進階」填網址。
/// 也可以先看示範：五家示範的店（餐廳咖啡、服飾、美髮、健身，和夜市外帶＋叫號的黃毛丫頭），在這頁直接展開卡片選一家（不用 sheet，右邊的鍵盤一直在）。
/// 手機（寬度 compact）：上面是說明（可以捲），下面是整個寬度的鍵盤；示範的店放在一張 sheet（選店不用打數字）
struct PairingView: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @State private var customURL = ""
    @State private var showAdvanced = false
    @State private var scanning = false
    @State private var working = false
    @State private var attempt = 0
    /// 手機：示範的店
    @State private var showDemos = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 鍵盤在哪一邊（iPad 右邊、手機下面）
    private var keypadSide: String { sizeClass == .compact ? "下面" : "右邊" }

    var body: some View {
        Group {
            if sizeClass == .compact {
                compact
            } else {
                regular
            }
        }
        .background(Theme.page.ignoresSafeArea())
        .task(id: attempt) { await askCode() }
        .sheet(isPresented: $scanning) {
            CodeScannerSheet(title: "掃描後台的配對 QR Code", types: ScanKind.pairing) { text in
                if let url = URL(string: text) { model.handle(url) }
            }
        }
    }

    // MARK: 手機：上面說明、下面鍵盤

    /// 手機：鍵盤要的高度（題目、大字、四排鍵、確認鍵）
    private static let compactKeypadHeight: CGFloat = 580

    private var compact: some View {
        GeometryReader { geo in
            if geo.size.height >= 240 + Self.compactKeypadHeight {
                VStack(spacing: 0) {
                    ScrollView {
                        compactIntro
                    }
                    .scrollIndicators(.hidden)
                    KeypadDock(showsCancel: false)
                        .frame(height: Self.compactKeypadHeight)
                        .overlay(alignment: .top) { Rule() }
                }
            } else {
                // 矮的手機（SE、mini）：說明和鍵盤一起捲
                ScrollView {
                    VStack(spacing: 0) {
                        compactIntro
                        KeypadDock(showsCancel: false)
                            .frame(height: Self.compactKeypadHeight)
                            .overlay(alignment: .top) { Rule() }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .sheet(isPresented: $showDemos) {
            VStack(spacing: 0) {
                SheetHeader(title: "先看看示範", subtitle: "\(DemoKind.allCases.count) 家示範的店，資料只在這次開著的時候。點一家就打開",
                            close: { showDemos = false })
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(DemoKind.allCases) { kind in
                            DemoStoreCard(kind: kind) {
                                showDemos = false
                                keypad.cancel()
                                model.startDemo(kind: kind)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }
            .posSheet()
        }
    }

    /// 手機：說明（配對的三步、掃 QR Code、進階、先看看示範）
    private var compactIntro: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                BrandMark()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Theme.ink)
                Text("StudioX POS")
                    .textRole(.h4)
                    .foregroundStyle(Theme.ink2)
            }
            RisingHeadline(lines: ["Your store,", "*in sync*."], role: .h1)
            VStack(alignment: .leading, spacing: 14) {
                step(1, "到網站後台", "「門市 POS → 裝置」按「新增裝置」，崗位選「前場點餐」（手機點餐、送到結帳櫃台一起結）")
                step(2, "輸入配對碼", "在下面的鍵盤打畫面上的 8 位數，按「配對」")
                step(3, "輸入 PIN", "店員用自己的 PIN 登入，就可以開始點餐")
            }
            otherWays
            Button {
                showDemos = true
            } label: {
                HStack(spacing: 8) {
                    HeroIcon("sparkles", size: 16)
                    Text("先看看示範（五家店）")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.ghost, size: .md, fullWidth: true))
            if working {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("配對中…").foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: iPad：左邊說明、右邊鍵盤

    private var regular: some View {
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
                        step(1, "到網站後台", "「門市 POS → 裝置」按「新增裝置」，選這台的崗位（結帳櫃台、前場點餐、報到接待、後廚、出餐口）")
                        step(2, "輸入配對碼", "在右邊的鍵盤打畫面上的 8 位數，按「配對」")
                        step(3, "輸入 PIN", "店員用自己的 PIN 登入，就可以開始點餐")
                        otherWays
                            .padding(.leading, 38)
                    }
                    .reveal(2)

                    demoPicker
                        .reveal(3)

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

            KeypadDock(showsCancel: false)
                .frame(width: Metric.dock)
        }
    }

    // MARK: 配對的其他方式（次要：細框的掃描、安靜的進階）

    /// 主要的動作是右邊鍵盤的「配對」；這裡只放另外兩種配對方式
    private var otherWays: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    scanning = true
                } label: {
                    Label { Text("掃描 QR Code") } icon: { HeroIcon("qr-code", size: 16) }
                }
                .buttonStyle(.brand(.ghost, size: .sm))
                Button {
                    withAnimation(reduceMotion ? nil : Motion.ease) { showAdvanced.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("進階：自己架的後台")
                        HeroIcon(showAdvanced ? "chevron-down" : "chevron-right", size: 12)
                    }
                }
                .buttonStyle(.brand(.quiet, size: .sm))
            }
            if showAdvanced {
                VStack(alignment: .leading, spacing: 8) {
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
                    Text("沒接 StudioX 的店家：填後台網址，再在\(keypadSide)的鍵盤打配對碼")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: 示範

    /// 示範的店：一家一張卡（整張可以點；行業的圖示與色塊、店名、看得到什麼、適合哪些店）
    private var demoPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("或先看看示範")
                Text("五家示範的店（黃毛丫頭是店裡真的菜單），資料只在這次開著的時候。點一家就打開")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(Array(DemoKind.allCases.enumerated()), id: \.element) { i, kind in
                    DemoStoreCard(kind: kind) {
                        keypad.cancel()
                        model.startDemo(kind: kind)
                    }
                    .reveal(i + 4, .rise)
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
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

/// 一家示範的店：行業的色塊與圖示、店名、一句話、三個重點、適合哪些店
private struct DemoStoreCard: View {
    let kind: DemoKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                            .fill(Theme.swatch(kind.swatch))
                        HeroIcon(kind.icon, size: 24)
                            .foregroundStyle(Theme.tileInk)
                    }
                    .frame(width: 52, height: 52)
                    Spacer(minLength: 8)
                    Text(kind.industry)
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(kind.storeName)
                            .textRole(.h3)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("→")
                            .font(.brand(18, .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(kind.summary)
                        .textRole(.small)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    ForEach(kind.highlights, id: \.self) { h in
                        Text(h)
                            .font(.brand(12, .medium))
                            .foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.press, in: .rect(cornerRadius: Metric.chip))
                    }
                }
                Text("適合：\(kind.mode.examples)")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Theme.surface
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(Theme.swatch(kind.swatch).opacity(0.55))
                            .frame(width: 200, height: 200)
                            .blur(radius: 60)
                            .offset(x: 70, y: -90)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Theme.swatch(kind.swatch))
                    .frame(width: 3)
                    .padding(.vertical, 22)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.97))
        .accessibilityLabel("示範：\(kind.industry)「\(kind.storeName)」")
    }
}
