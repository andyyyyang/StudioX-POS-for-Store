import AuthenticationServices
import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 用 StudioX 帳號配對的這一趟（docs/API.md「用 StudioX 帳號登入」）：登入 → 哪一家店 → 這台是誰的 → 配對。
///
///   - 手機：預設「我自己的」不用問；只有一家店就直接配對。「這是店裡共用的手機」走共用的那條（選崗位、取名字）
///   - iPad：登入後先問「這台是…」：店裡共用的（選崗位、取名字；之後大家用 PIN）或我自己的（和手機一樣）
///   - 配對完存起來的方式和配對碼一模一樣（POSModel.completePairing）
@Observable
final class AccountPairingFlow {
    enum Step: Equatable { case idle, signingIn, loadingSites, choosing, pairing }

    private enum FlowError: Error { case noSites }

    var step: Step = .idle
    var sites: [ConsoleSite] = []
    var siteId: String?
    var mode: DevicePairMode = .personal
    var role: DeviceRole = .register
    var name = ""
    var error: String?
    /// 手機（寬度 compact）：選店、共用的設定放在一張 sheet
    var sheetShown = false

    @ObservationIgnored private var session: ConsoleSession?
    @ObservationIgnored private var consoleURL: URL?
    /// 這台是手機（預設「我自己的」、崗位只有點餐、廚房、出餐口）
    private(set) var phone = false
    private var usesSheet = false

    var isActive: Bool { step != .idle }
    var isBusy: Bool { step == .signingIn || step == .loadingSites || step == .pairing }
    var site: ConsoleSite? { sites.first { $0.id == siteId } }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canPair: Bool { step == .choosing && site != nil && (mode == .personal || !trimmedName.isEmpty) }
    /// 手機只點一下店卡就配對（我自己的）；其他的選好再按大鍵
    var tapsToPair: Bool { phone && mode == .personal }

    /// 崗位（共用的）：手機一律是前場點餐，後廚、出餐口照舊（POSModel+Phone），所以手機只給這三個
    var roleChoices: [DeviceRole] {
        phone ? [.handheld, .kitchen, .expo] : [.register, .handheld, .reception, .kitchen, .expo]
    }

    /// 大鍵、按鈕上的字
    var signInTitle: String {
        switch step {
        case .signingIn: "登入中…"
        case .loadingSites: "找你的店…"
        case .pairing: "配對中…"
        case .idle, .choosing: "用 StudioX 帳號登入"
        }
    }

    // MARK: 選

    func choose(_ s: ConsoleSite) {
        siteId = s.id
        error = nil
    }

    func setMode(_ m: DevicePairMode) {
        mode = m
        error = nil
    }

    /// 換崗位：名稱還是預設的（或空的）就換成新崗位的預設
    func setRole(_ r: DeviceRole) {
        let wasDefault = trimmedName.isEmpty || name == Self.defaultName(role, phone: phone)
        role = r
        if wasDefault { name = Self.defaultName(r, phone: phone) }
    }

    static func defaultName(_ r: DeviceRole, phone: Bool) -> String {
        if phone {
            switch r {
            case .kitchen: return "廚房手機"
            case .expo: return "出餐口手機"
            default: return "店裡的點餐手機"
            }
        }
        switch r {
        case .register: return "櫃台 iPad"
        case .handheld: return "點餐 iPad"
        case .reception: return "接待 iPad"
        case .kitchen: return "廚房 iPad"
        case .expo: return "出餐口 iPad"
        }
    }

    // MARK: 登入 → 哪一家店

    /// shared：手機的「這是店裡共用的手機」；usesSheet：選店與設定放在 sheet（寬度 compact）
    func start(model: POSModel, auth: WebAuthenticationSession, shared: Bool, usesSheet: Bool) async {
        guard !isActive else { return }
        phone = model.isPhone
        self.usesSheet = usesSheet
        consoleURL = model.settings.consoleURL
        error = nil
        sites = []
        siteId = nil
        mode = shared ? .shared : .personal
        role = phone ? .handheld : .register
        name = Self.defaultName(role, phone: phone)
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
            // iPad 多半是店裡共用的：預設選「店裡共用的」（只有一家、而且不是店長時預設「我自己的」）
            if !phone && !shared {
                let onlyNotManager = found.count == 1 && found[0].level != nil && !found[0].canAddSharedDevices
                mode = onlyNotManager ? .personal : .shared
            }
            // 手機、我自己的、只有一家：直接配對
            if tapsToPair && found.count == 1 {
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

    // MARK: 配對

    func pair(model: POSModel) async {
        guard let site, let session, step != .pairing else { return }
        guard mode == .personal || !trimmedName.isEmpty else {
            error = "幫這台取個名字（後台「裝置」頁看到的）"
            return
        }
        let request: PersonalPairRequest = mode == .shared
            ? .shared(siteId: site.id, device: model.deviceInfo, role: role, name: trimmedName)
            : .personal(siteId: site.id, device: model.deviceInfo)
        step = .pairing
        error = nil
        do {
            let client = ConsoleClient(consoleURL: model.settings.consoleURL)
            let r = try await session.authorized { token in try await client.personalPair(request, accessToken: token) }
            // 店裡共用的：StudioX 帳號只拿來配對，不留在這台（之後大家用自己的 PIN）
            if !r.personal { ConsoleAccount.forget(consoleURL: model.settings.consoleURL) }
            try await model.completeAccountPairing(r)
            reset()
        } catch {
            fail(Self.message(for: error))
        }
    }

    // MARK: 取消、失敗

    /// 不用了（改用配對碼、關掉 sheet）：StudioX 帳號的 token 也清掉
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

    /// 還沒選到店（登入、找店失敗，或手機只有一家直接配對失敗）：回到按鈕、寫原因；選店之後失敗：留在選的地方
    private func fail(_ message: String) {
        let backToStart = sites.isEmpty || (tapsToPair && sites.count == 1)
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
        case .http(403, "forbidden", _): return "要店長才能新增店裡的裝置"
        // 其他 403、429：網站（或 console）的那一句原樣顯示
        case .http(403, _, let m): return m ?? "沒有權限配對這台，請找店長"
        case .http(429, _, let m): return m ?? "試太多次了，請稍後再試"
        // console 連不到那家店的後台（或那邊不接受）
        case .http(502, "upstream", _): return "店的後台連不上，請稍後再試"
        case .http(404, _, let m): return m ?? "StudioX 還不支援用帳號登入門市 POS，請先用配對碼"
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

// MARK: - 這台是…

/// 「我自己的」／「店裡共用的」：一張卡一個選擇（左邊選、右邊的大鍵配對）
struct AccountKindCard: View {
    let mode: DevicePairMode
    let selected: Bool
    var note: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HeroIcon(mode == .personal ? "user" : "building-storefront", size: 22)
                        .foregroundStyle(selected ? Theme.accentText : Theme.ink2)
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(mode == .personal ? "我自己的" : "店裡共用的")
                    .textRole(.h4)
                    .foregroundStyle(Theme.ink)
                Text(summary)
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.brand(12, .medium))
                        .foregroundStyle(Theme.warningFG)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(selected ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var summary: String {
        mode == .personal
            ? "綁著你：打開就是你，不用 PIN、不能換人；離開一陣子回來用 Face ID 解鎖"
            : "收銀台、點餐機、廚房螢幕：選崗位、取名字，大家用自己的 PIN 登入"
    }
}

/// 店裡共用的：崗位（沿用崗位的名稱與說明）
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
    }
}

/// 店裡共用的：名稱（後台「裝置」頁看到的）
struct AccountNameField: View {
    @Bindable var flow: AccountPairingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(AccountPairingFlow.defaultName(flow.role, phone: flow.phone), text: $flow.name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .font(.brand(16, .regular))
                .padding(12)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
            Text("後台「門市 POS → 裝置」看到的名字；之後可以在後台改")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - iPad：左邊選（店、這台是…、崗位與名稱），右邊的大鍵配對

struct AccountSetupPanel: View {
    let flow: AccountPairingFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            header
            if flow.sites.count > 1 { sitesSection }
            kindSection
            if flow.mode == .shared { sharedSection }
            AccountFlowError(text: flow.error)
            Button("← 改用配對碼") { flow.cancel() }
                .buttonStyle(.brand(.quiet, size: .sm))
                .disabled(flow.step == .pairing)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.fast, value: flow.mode)
        .animation(reduceMotion ? nil : Motion.fast, value: flow.error)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("用 StudioX 帳號登入")
            Text(flow.sites.count > 1 && flow.site == nil ? "選一家店" : "這台是…")
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
            Text("選好之後按右邊的「配對這台」")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
        }
    }

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("哪一家店")
            ForEach(flow.sites) { s in
                ConsoleSiteCard(site: s, selected: flow.siteId == s.id) { flow.choose(s) }
            }
        }
    }

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("這台是…")
            HStack(alignment: .top, spacing: 12) {
                AccountKindCard(mode: .shared, selected: flow.mode == .shared, note: sharedNote) { flow.setMode(.shared) }
                AccountKindCard(mode: .personal, selected: flow.mode == .personal) { flow.setMode(.personal) }
            }
        }
    }

    /// 不是負責人、管理者：後台會擋（403 forbidden），先講
    private var sharedNote: String? {
        guard let site = flow.site, site.level != nil, !site.canAddSharedDevices else { return nil }
        return "要店長（負責人、管理者）才能新增"
    }

    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("崗位")
            AccountRolePicker(flow: flow, columns: 2)
            Eyebrow("名稱")
                .padding(.top, 8)
            AccountNameField(flow: flow)
                .frame(maxWidth: 420)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

extension AccountPairingFlow {
    /// iPad 右欄：選好的店與「這台是…」、大鍵「配對這台」（左邊選、右邊做）
    func dockSelection(model: POSModel) -> DockSelection? {
        guard step == .choosing || step == .pairing else { return nil }
        let detail = mode == .personal
            ? "我自己的・不用 PIN，回來用 Face ID 解鎖"
            : "店裡共用的・\(role.label)・\(trimmedName.isEmpty ? "還沒取名字" : trimmedName)"
        return DockSelection(
            id: "account-pair",
            kind: "用 StudioX 帳號",
            title: site?.name ?? "選一家店",
            detail: detail,
            badge: step == .pairing ? DockBadge("配對中", tone: .info) : nil,
            primary: POSAction(step == .pairing ? "配對中…" : "配對這台", icon: "check", enabled: canPair) {
                Task { await self.pair(model: model) }
            },
            accent: true,
            actions: [POSAction("改用配對碼", icon: "key", enabled: step != .pairing) { self.cancel() }],
            clear: { self.cancel() }
        )
    }
}

// MARK: - 手機：選店、店裡共用的手機（sheet）

struct AccountSetupSheet: View {
    let flow: AccountPairingFlow
    let model: POSModel

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: subtitle, close: { flow.cancel() })
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            if !flow.tapsToPair {
                confirmBar
            }
        }
        .posSheet()
        .interactiveDismissDisabled(flow.step == .pairing)
    }

    private var title: String {
        if flow.mode == .shared { return flow.phone ? "店裡共用的手機" : "這台是…" }
        return "選一家店"
    }

    private var subtitle: String {
        if flow.tapsToPair { return "點一家就開始；這支手機會是你在那家店的點餐機，不用 PIN" }
        if flow.mode == .shared { return "選崗位、取名字；之後大家用自己的 PIN 登入" }
        return "這台綁著你：打開就是你，回來用 Face ID 解鎖"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if flow.sites.count > 1 { sites }
            if !flow.phone { kinds }
            if flow.mode == .shared { shared }
            AccountFlowError(text: flow.error)
        }
    }

    private var sites: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("哪一家店")
            ForEach(flow.sites) { s in
                ConsoleSiteCard(site: s, selected: flow.siteId == s.id, busy: flow.step == .pairing && flow.siteId == s.id) {
                    pick(s)
                }
                .disabled(flow.step == .pairing)
            }
        }
    }

    private var kinds: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("這台是…")
            AccountKindCard(mode: .shared, selected: flow.mode == .shared) { flow.setMode(.shared) }
            AccountKindCard(mode: .personal, selected: flow.mode == .personal) { flow.setMode(.personal) }
        }
    }

    private var shared: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("崗位")
            AccountRolePicker(flow: flow, columns: 1)
            Eyebrow("名稱")
                .padding(.top, 6)
            AccountNameField(flow: flow)
        }
    }

    private var confirmBar: some View {
        Button {
            Task { await flow.pair(model: model) }
        } label: {
            HStack(spacing: 8) {
                if flow.step == .pairing { ProgressView().tint(Theme.onAccent) }
                Text(flow.step == .pairing ? "配對中…" : (flow.phone ? "配對這支手機" : "配對這台"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.brand(.accent, size: .lg, fullWidth: true, arrow: true))
        .disabled(!flow.canPair)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) { Rule() }
    }

    /// 手機的「我自己的」：點一家就配對；其他：選起來，按下面的大鍵
    private func pick(_ s: ConsoleSite) {
        flow.choose(s)
        if flow.tapsToPair { Task { await flow.pair(model: model) } }
    }
}
