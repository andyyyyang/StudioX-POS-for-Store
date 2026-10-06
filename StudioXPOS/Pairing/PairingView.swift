import AuthenticationServices
import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 第一次打開：用 StudioX 帳號登入（和 StudioX App 同一個帳號），這是唯一的開始方式。
///
///   登入 → 哪一家店（只有一家就不用選）→ 這台做什麼（iPad：收銀台、點餐、接待、廚房、出餐口；手機一律是前場點餐）→ 開始
///
/// 每台都綁著登入的那個人：打開就是他，不用配對碼、不用 PIN（離開一陣子回來用 Face ID 解鎖）；換人＝登出再登入。
/// 下面一行小字「先看看示範」：五家示範的店（一張 sheet），資料只在這次開著的時候
struct PairingView: View {
    @Environment(POSModel.self) private var model
    /// 用 StudioX 帳號登入的這一趟
    @State private var account = AccountPairingFlow()
    @State private var showDemos = false
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        ScrollView {
            Group {
                // iPad：登入後在同一頁選店、選崗位；手機（寬度 compact）放在 sheet
                if !compact && (account.step == .choosing || account.step == .pairing) {
                    AccountSetupPanel(flow: account, model: model)
                } else {
                    intro
                }
            }
            .padding(.horizontal, compact ? 24 : 64)
            .padding(.vertical, compact ? 32 : 72)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(Theme.page.ignoresSafeArea())
        .sheet(isPresented: $account.sheetShown, onDismiss: { account.sheetDismissed() }) {
            AccountSetupSheet(flow: account, model: model)
        }
        .sheet(isPresented: $showDemos) { demos }
    }

    /// 標誌、一句話、登入的大鍵、「先看看示範」
    private var intro: some View {
        VStack(alignment: .leading, spacing: compact ? 28 : 40) {
            HStack(spacing: 12) {
                BrandMark()
                    .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
                    .foregroundStyle(Theme.ink)
                Text("StudioX POS")
                    .textRole(.h4)
                    .foregroundStyle(Theme.ink2)
            }
            .reveal(0)

            RisingHeadline(lines: ["Your store,", "*in sync*."], role: compact ? .h1 : .hero)

            Text("用你的 StudioX 帳號登入（和 StudioX App 同一個）。這台會綁著你：打開就是你，不用配對碼、不用 PIN；換人時登出再登入。")
                .textRole(.lead)
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: 560, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .reveal(1)

            VStack(alignment: .leading, spacing: 14) {
                AccountSignInButton(flow: account) { startAccount() }
                AccountFlowError(text: account.error)
                Button("先看看示範") { showDemos = true }
                    .buttonStyle(.brand(.quiet, size: .sm))
                    .disabled(account.isBusy)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .reveal(2)
        }
    }

    /// 打開登入視窗
    private func startAccount() {
        let auth = webAuthenticationSession
        let usesSheet = compact
        Task { await account.start(model: model, auth: auth, usesSheet: usesSheet) }
    }

    /// 五家示範的店：點一家就打開
    private var demos: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "先看看示範", subtitle: "\(DemoKind.allCases.count) 家示範的店（黃毛丫頭是店裡真的菜單），資料只在這次開著的時候。點一家就打開",
                        close: { showDemos = false })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(DemoKind.allCases) { kind in
                        DemoStoreCard(kind: kind) {
                            showDemos = false
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
