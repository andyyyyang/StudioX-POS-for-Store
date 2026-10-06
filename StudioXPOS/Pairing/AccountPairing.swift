import AuthenticationServices
import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 用 StudioX 帳號登入的這一趟（docs/API.md「用 StudioX 帳號登入」）：登入 → 哪一家店 → 這台做什麼 → 開始。
///
///   - 每台都綁著登入的那個人（沒有店裡共用的裝置、沒有配對碼）：打開就是他，換人＝登出再登入
///   - 手機：一律是前場點餐；只有一家店就直接開始
///   - iPad：選這台的崗位（收銀台、點餐、接待、廚房、出餐口；上次選的先選好）
///   - 存起來的方式在 POSModel.completeAccountPairing
@Observable
final class AccountPairingFlow {
    enum Step: Equatable { case idle, signingIn, loadingSites, choosing, pairing }

    private enum FlowError: Error { case noSites }

    var step: Step = .idle
    var sites: [ConsoleSite] = []
    var siteId: String?
    var role: DeviceRole = .register
    var error: String?
    /// 手機（寬度 compact）：選店（與崗位）放在一張 sheet
    var sheetShown = false

    @ObservationIgnored private var session: ConsoleSession?
    @ObservationIgnored private var consoleURL: URL?
    /// 這台是手機（一律前場點餐，不問崗位）
    private(set) var phone = false
    private var usesSheet = false

    /// 上次在這台選的崗位（重新登入、換人時先選好）
    private static let lastRoleKey = "pos.account.lastRole"

    var isActive: Bool { step != .idle }
    var isBusy: Bool { step == .signingIn || step == .loadingSites || step == .pairing }
    var site: ConsoleSite? { sites.first { $0.id == siteId } }
    var canPair: Bool { step == .choosing && site != nil }
    /// iPad 要選崗位；手機不用（點一家店就開始）
    var asksRole: Bool { !phone }
    let roleChoices: [DeviceRole] = [.register, .handheld, .reception, .kitchen, .expo]

    /// 大鍵、按鈕上的字
    var signInTitle: String {
        switch step {
        case .signingIn: "登入中…"
        case .loadingSites: "找你的店…"
        case .pairing: "準備這台…"
        case .idle, .choosing: "用 StudioX 帳號登入"
        }
    }

    // MARK: 選

    func choose(_ s: ConsoleSite) {
        siteId = s.id
        error = nil
    }

    func setRole(_ r: DeviceRole) {
        role = r
        error = nil
    }

    // MARK: 登入 → 哪一家店

    /// usesSheet：選店與崗位放在 sheet（寬度 compact）
    func start(model: POSModel, auth: WebAuthenticationSession, usesSheet: Bool) async {
        guard !isActive else { return }
        phone = model.isPhone
        self.usesSheet = usesSheet
        consoleURL = model.settings.consoleURL
        error = nil
        sites = []
        siteId = nil
        role = phone ? .handheld : (UserDefaults.standard.string(forKey: Self.lastRoleKey).flatMap(DeviceRole.init(rawValue:)) ?? .register)
        step = .signingIn
        let consoleURL = model.settings.consoleURL
        do {
            let tokens = try await ConsoleAccount.signIn(using: auth, consoleURL: consoleURL)
            let session = ConsoleAccount.session(tokens: tokens, consoleURL: consoleURL)
            self.session = session
            step = .loadingSites
            let client = ConsoleClient(consoleURL: consoleURL)
            let found = try await session.authorized { token in try await client.sites(accessToken: token) }
            guard !found.isEmpty else { throw FlowError.noSites }
            sites = found
            siteId = found.count == 1 ? found[0].id : nil
            // 手機、只有一家：直接開始
            if !asksRole && found.count == 1 {
                await pair(model: model)
                return
            }
            step = .choosing
            sheetShown = usesSheet
        } catch ConsoleAuthError.cancelled {
            cancel()
        } catch {
            fail(Self.message(for: error))
        }
    }

    // MARK: 開始

    func pair(model: POSModel) async {
        guard let site, let session, step != .pairing else { return }
        step = .pairing
        error = nil
        let siteId = site.id
        let device = model.deviceInfo
        let chosen: DeviceRole = asksRole ? self.role : .handheld
        do {
            let client = ConsoleClient(consoleURL: model.settings.consoleURL)
            let r = try await session.authorized { token in
                try await client.personalPair(siteId: siteId, device: device, role: chosen, accessToken: token)
            }
            if asksRole { UserDefaults.standard.set(chosen.rawValue, forKey: Self.lastRoleKey) }
            try await model.completeAccountPairing(r)
            reset()
        } catch {
            fail(Self.message(for: error))
        }
    }

    // MARK: 取消、失敗

    /// 不用了（按「取消」、關掉 sheet）：StudioX 帳號的 token 也清掉
    func cancel() {
        if let consoleURL { ConsoleAccount.forget(consoleURL: consoleURL) }
        reset()
    }

    /// 手機的 sheet 往下滑掉了
    func sheetDismissed() {
        if step == .choosing { cancel() }
    }

    private func reset() {
        step = .idle
        sites = []
        siteId = nil
        session = nil
        sheetShown = false
    }

    /// 還沒選到店（登入、找店失敗，或手機只有一家直接開始卻失敗）：回到按鈕、寫原因；選店之後失敗：留在選的地方
    private func fail(_ message: String) {
        let backToStart = sites.isEmpty || (!asksRole && sites.count == 1)
        if backToStart {
            cancel()
        } else {
            step = .choosing
            sheetShown = usesSheet
        }
        error = message
    }

    /// 給人看的一句話（docs/API.md 的錯誤碼）
    static func message(for error: Error) -> String {
        if error is FlowError { return "這個帳號沒有開通門市 POS 的店" }
        if let e = error as? ConsoleAuthError { return e.userMessage }
        guard let e = error as? APIError else { return "登入沒有完成，請再試一次" }
        switch e {
        case .http(403, "staff_inactive", _): return "你在這家店的門市人員被停用了，請找店長"
        // 其他 403、409（收銀機台數滿了）、429：網站（或 console）的那一句原樣顯示
        case .http(403, _, let m): return m ?? "沒有權限用這家店的門市 POS，請找店長"
        case .http(409, "register_limit", let m): return m ?? "方案的收銀機台數滿了：選別的崗位，或請店長在後台移除用不到的收銀台"
        case .http(429, _, let m): return m ?? "試太多次了，請稍後再試"
        // console 連不到那家店的後台（或那邊不接受）
        case .http(502, "upstream", _): return "店的後台連不上，請稍後再試"
        case .http(404, _, let m): return m ?? "這家店的後台還不支援用 StudioX 帳號登入，請找 StudioX"
        case .serviceOff: return "這家店還沒開通門市 POS，或暫停中，請找店長"
        case .unauthorized, .revoked: return "登入已經過期，請重新登入"
        case .offline: return "連不上網路，請稍後再試"
        default: return e.userMessage
        }
    }
}

// MARK: - 用 StudioX 帳號登入的大鍵

struct AccountSignInButton: View {
    let flow: AccountPairingFlow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if flow.isBusy {
                    ProgressView()
                        .tint(Theme.onAccent)
                } else {
                    HeroIcon("user-circle", size: 19)
                }
                Text(flow.signInTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.brand(.accent, size: .lg, fullWidth: true))
        .disabled(flow.isBusy || flow.step == .choosing)
    }
}

/// 失敗的原因（紅字）
struct AccountFlowError: View {
    let text: String?

    var body: some View {
        if let text {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.brand(13.5, .medium))
            .foregroundStyle(Theme.dangerFG)
            .transition(.opacity)
        }
    }
}

// MARK: - 一家店（和示範的店同一種卡）

struct ConsoleSiteCard: View {
    let site: ConsoleSite
    var selected = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                ConsoleSiteIconView(site: site, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(site.name)
                            .textRole(.h3)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("→")
                            .font(.brand(18, .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(detail)
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay { border }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityLabel(site.name)
        .accessibilityValue(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
            .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1)
    }

    @ViewBuilder
    private var trailing: some View {
        if busy {
            ProgressView()
        } else if selected {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentText)
        }
    }

    /// 「負責人・cms.example.tw」
    private var detail: String {
        let host = URL(string: site.cmsUrl)?.host() ?? site.cmsUrl
        guard let level = Self.levelLabel(site.level) else { return host }
        return "\(level)・\(host)"
    }

    static func levelLabel(_ level: String?) -> String? {
        switch level {
        case "owner": "負責人"
        case "manager": "管理者"
        case "fulfillment": "訂單處理人員"
        case "staff": "員工"
        case let other?: other.isEmpty ? nil : other
        case nil: nil
        }
    }
}

/// 店的圖示：console 抓的圖（data: 或 https），沒有就是店名的第一個字
struct ConsoleSiteIconView: View {
    let site: ConsoleSite
    var size: CGFloat = 52

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            Theme.surface
            image
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.line, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var image: some View {
        if let data = site.icon?.imageData, let ui = UIImage(data: data) {
            iconImage(Image(uiImage: ui))
        } else if let url = site.icon?.url {
            AsyncImage(url: url) { phase in
                if let img = phase.image { iconImage(img) } else { initial }
            }
        } else {
            initial
        }
    }

    @ViewBuilder
    private func iconImage(_ img: Image) -> some View {
        if site.icon?.fill == true {
            img.resizable().scaledToFill()
        } else {
            img.resizable().scaledToFit().padding(size * 0.18)
        }
    }

    private var initial: some View {
        Text(String(site.name.prefix(1)))
            .font(.brand(size * 0.42, .medium))
            .foregroundStyle(Theme.ink)
    }
}

// MARK: - 這台做什麼（崗位）

/// 崗位：沿用崗位的名稱與說明（收銀台、點餐、接待、廚房、出餐口）
struct AccountRolePicker: View {
    let flow: AccountPairingFlow
    var columns = 2

    var body: some View {
        let choices = flow.roleChoices
        let rows = stride(from: 0, to: choices.count, by: columns).map { Array(choices[$0 ..< min($0 + columns, choices.count)]) }
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r], id: \.self) { role in
                        DockChoice(title: role.label, detail: role.summary, selected: flow.role == role) {
                            flow.setRole(role)
                        }
                    }
                    if rows[r].count < columns {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
        .disabled(flow.step == .pairing)
    }
}

/// 「開始使用」的大鍵（iPad 的那一頁、sheet 的下面）
private struct AccountStartButton: View {
    let flow: AccountPairingFlow
    let model: POSModel

    var body: some View {
        Button {
            Task { await flow.pair(model: model) }
        } label: {
            HStack(spacing: 8) {
                if flow.step == .pairing { ProgressView().tint(Theme.onAccent) }
                Text(flow.step == .pairing ? "準備這台…" : "開始使用")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.brand(.accent, size: .lg, fullWidth: true, arrow: true))
        .disabled(!flow.canPair)
    }
}

// MARK: - iPad：登入後選店、選崗位（同一頁）

struct AccountSetupPanel: View {
    let flow: AccountPairingFlow
    let model: POSModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            header
            if flow.sites.count > 1 { sitesSection }
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("這台的崗位")
                AccountRolePicker(flow: flow, columns: 2)
            }
            AccountFlowError(text: flow.error)
            HStack(spacing: 16) {
                AccountStartButton(flow: flow, model: model)
                    .frame(maxWidth: 360)
                Button("取消") { flow.cancel() }
                    .buttonStyle(.brand(.quiet, size: .md))
                    .disabled(flow.step == .pairing)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.fast, value: flow.error)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("用 StudioX 帳號登入")
            Text(flow.sites.count > 1 && flow.site == nil ? "選一家店" : "這台做什麼")
                .textRole(.h1)
                .foregroundStyle(Theme.ink)
            if let site = flow.site, flow.sites.count == 1 {
                HStack(spacing: 10) {
                    ConsoleSiteIconView(site: site, size: 28)
                    Text(site.name)
                        .textRole(.h4)
                        .foregroundStyle(Theme.ink2)
                }
            }
            Text("這台會綁著你：打開就是你，回來用 Face ID 解鎖；換人時登出再登入")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
        }
    }

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("哪一家店")
            ForEach(flow.sites) { s in
                ConsoleSiteCard(site: s, selected: flow.siteId == s.id) { flow.choose(s) }
                    .disabled(flow.step == .pairing)
            }
        }
    }
}

// MARK: - 手機：選店（sheet）

struct AccountSetupSheet: View {
    let flow: AccountPairingFlow
    let model: POSModel

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: flow.asksRole && flow.sites.count <= 1 ? "這台做什麼" : "選一家店", subtitle: subtitle, close: { flow.cancel() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if flow.sites.count > 1 { sites }
                    if flow.asksRole {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow("這台的崗位")
                            AccountRolePicker(flow: flow, columns: 1)
                        }
                    }
                    AccountFlowError(text: flow.error)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            // 要選崗位（寬度窄的 iPad）：選好按下面的大鍵；手機點一家就開始
            if flow.asksRole {
                AccountStartButton(flow: flow, model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .overlay(alignment: .top) { Rule() }
            }
        }
        .posSheet()
        .interactiveDismissDisabled(flow.step == .pairing)
    }

    private var subtitle: String {
        flow.asksRole
            ? "這台會綁著你：打開就是你；換人時登出再登入"
            : "點一家就開始；這支手機會綁著你，是你在那家店的點餐機"
    }

    private var sites: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("哪一家店")
            ForEach(flow.sites) { s in
                ConsoleSiteCard(site: s, selected: flow.siteId == s.id, busy: flow.step == .pairing && flow.siteId == s.id) {
                    flow.choose(s)
                    if !flow.asksRole { Task { await flow.pair(model: model) } }
                }
                .disabled(flow.step == .pairing)
            }
        }
    }
}
