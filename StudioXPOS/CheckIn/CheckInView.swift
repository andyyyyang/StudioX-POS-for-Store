import Foundation
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 報到（健身房、瑜珈、教室的櫃台首頁）。
///
///   ┌ Check in ──────────────────────────────── [報到] [課表] ┐
///   │ ┌ ⓛ 林小涵  金卡會員  0912-***-678  本月壽星 ┐ │ 今天報到 │
///   │ │ ✓ 可以入場                                  │ │   42     │
///   │ │   10 次卡・剩 7 次 → 入場後剩 6 次          │ │ ▁▃▇▅▂▁▃  │
///   │ │ ⚠ 今天 14:02 已經報到過                     │ │ 14:05 …  │
///   │ │ [            入場 →            ] [續約／買卡] │ │ 13:58 …  │
///   │ └─────────────────────────────────────────────┘ │          │
///   └──────────────────────────────────────────────────────────┘
///
/// 右側鍵盤一直等著「會員」：打手機號碼或掃會員卡（掃描器打進鍵盤、按 Enter）就查，查到馬上換下一位。
/// 課表：今天的團體課、名單、報名、簽到（扣能抵這堂課的卡）、沒卡的收單堂。
struct CheckInView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 換頁（去結帳、會員頁）再回來，剛剛查到的人還在
    private var desk: CheckInDesk { CheckInDesk.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch desk.tab {
            case .entry:
                HStack(alignment: .top, spacing: 24) {
                    entry
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    Rule(vertical: true)
                    CheckInToday(onVoided: { restartListening() })
                        .frame(width: 300)
                }
            case .classes:
                CheckInClasses()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: listenKey) { await listen() }
        .onAppear {
            desk.forgetIfStale()
            if !model.mode.usesClasses { desk.tab = .entry }
        }
        .onDisappear { stopListening() }
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.ease }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PageTitle(title: desk.tab == .entry ? "Check *in*" : "Class *list*", subtitle: "報到・\(Date().dayTitle)")
            Spacer(minLength: 12)
            if model.mode.usesClasses {
                HStack(spacing: 6) {
                    tabButton("報到", .entry)
                    tabButton("課表", .classes)
                }
                .frame(width: 220)
            }
        }
    }

    private func tabButton(_ title: String, _ tab: CheckInTab) -> some View {
        Button(title) {
            guard desk.tab != tab else { return }
            stopListening()
            withAnimation(anim) { desk.tab = tab }
        }
        .buttonStyle(.choice(desk.tab == tab, height: 42))
    }

    // MARK: - 右側鍵盤一直等著會員號碼

    private var listenKey: String { "\(desk.tab.rawValue)-\(desk.listenToken)" }

    /// 報到頁開著就一直問「會員」：查完一位馬上問下一位（掃描器掃進來直接查）。
    /// 被別的題目插隊（主管 PIN）就等它問完再接著問；換頁、換到課表就停
    private func listen() async {
        guard desk.tab == .entry else { return }
        while !Task.isCancelled {
            if let entry = await model.keypad.ask(KeypadSpec.memberCode) {
                await lookUp(entry.digits)
                continue
            }
            // 取消（按了 ×、別的題目插隊、換頁）：等一下、鍵盤空了再問
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled && model.keypad.isAsking {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func stopListening() {
        if model.keypad.request?.spec == KeypadSpec.memberCode { model.keypad.cancel() }
    }

    private func restartListening() {
        desk.listenToken += 1
    }

    private func lookUp(_ code: String) async {
        withAnimation(anim) {
            desk.code = code
            desk.searching = true
            desk.entered = nil
            desk.passId = nil
            desk.showShop = false
        }
        let result = await model.findMember(code: code)
        // 查的時候又掃了下一位：以最新的為準
        guard desk.code == code else { return }
        withAnimation(anim) {
            desk.searching = false
            switch result {
            case .found(let m): desk.result = .member(id: m.id, offline: false)
            case .cached(let m): desk.result = .member(id: m.id, offline: true)
            case .notFound: desk.result = .notFound(code)
            case .offline: desk.result = .offline(code)
            case .failed(let message): desk.result = .failed(code, message)
            }
            desk.touch()
        }
    }

    // MARK: - 報到

    @ViewBuilder
    private var entry: some View {
        if desk.searching {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("查詢 \(desk.code.map { CheckInText.masked($0) } ?? "")…")
                    .textRole(.lead)
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = desk.result {
            ScrollView {
                resultView(result)
                    .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        } else {
            CheckInPrompt()
        }
    }

    @ViewBuilder
    private func resultView(_ result: CheckInResult) -> some View {
        switch result {
        case .member(let id, let offline):
            if let m = model.members[id] {
                CheckInMemberPanel(member: m, offline: offline, onDone: { clear() })
                    .id(id)
            } else {
                CheckInMessage(icon: "exclamation-circle", title: "找不到這位會員的資料", detail: "請再查一次", tone: .warning) {
                    Button("重新輸入") { clear() }
                        .buttonStyle(.brand(.ghost, size: .lg))
                }
            }
        case .notFound(let code):
            CheckInMessage(icon: "user", title: "查不到 \(CheckInText.masked(code))", detail: "還不是會員，或號碼打錯了", tone: .warning) {
                if CheckInText.isPhone(code) {
                    Button {
                        join(code)
                    } label: {
                        Text("用這支電話加入會員")
                    }
                    .buttonStyle(.brand(.primary, size: .lg, arrow: true))
                }
                Button("重新輸入") { clear() }
                    .buttonStyle(.brand(.ghost, size: .lg))
            }
        case .offline(let code):
            CheckInMessage(icon: "wifi", title: "離線，查不到 \(CheckInText.masked(code))", detail: "這台沒查過這位會員。可以先記下號碼讓他進去，連上網路後到後台核對。", tone: .warning) {
                Button {
                    offlineEntry(code)
                } label: {
                    Text("先讓他入場（記下號碼）")
                }
                .buttonStyle(.brand(.primary, size: .lg))
                Button("重新輸入") { clear() }
                    .buttonStyle(.brand(.ghost, size: .lg))
            }
        case .failed(let code, let message):
            CheckInMessage(icon: "exclamation-triangle", title: "查不到", detail: message, tone: .danger) {
                Button("再試一次") {
                    Task { await lookUp(code) }
                }
                .buttonStyle(.brand(.primary, size: .lg))
                Button("重新輸入") { clear() }
                    .buttonStyle(.brand(.ghost, size: .lg))
            }
        }
    }

    private func clear() {
        withAnimation(anim) { desk.clear() }
    }

    private func join(_ phone: String) {
        Task {
            guard let m = await model.createMember(phone: phone, name: nil) else { return }
            model.show("新會員 \(m.ref.maskedPhone) 加入了")
            withAnimation(anim) {
                desk.result = .member(id: m.id, offline: false)
                desk.showShop = true
                desk.touch()
            }
        }
    }

    private func offlineEntry(_ code: String) {
        let ref = MemberRef(phone: code)
        guard model.recordCheckIn(ref, pass: nil, note: "離線報到，待核對") != nil else { return }
        model.show("\(ref.maskedPhone) 入場（離線，待核對）", tone: .warning)
        clear()
    }
}

// MARK: - 跨畫面的狀態

private enum CheckInTab: String {
    case entry, classes
}

private enum CheckInResult: Equatable {
    case member(id: String, offline: Bool)
    case notFound(String)
    case offline(String)
    case failed(String, String)
}

/// 報到櫃台現在在看誰（換到結帳、會員頁再回來還在；放太久就清掉，不留給下一位客人看）
@Observable
private final class CheckInDesk {
    static let shared = CheckInDesk()

    var tab: CheckInTab = .entry
    var code: String?
    var result: CheckInResult?
    var searching = false
    /// 換一張卡用（nil＝建議的那張）
    var passId: String?
    /// 剛入場的（顯示 3 秒歡迎）
    var entered: CheckIn?
    /// 打開「續約／買卡」
    var showShop = false
    /// 課表選到的那一堂
    var sessionId: String?
    /// 改了就重新開始問會員號碼
    var listenToken = 0
    private var updatedAt = Date()

    func touch() { updatedAt = Date() }

    func clear() {
        code = nil
        result = nil
        searching = false
        passId = nil
        entered = nil
        showShop = false
        touch()
    }

    /// 超過 3 分鐘沒動：上一位客人的資料不要留在畫面上
    func forgetIfStale() {
        if Date().timeIntervalSince(updatedAt) > 180 { clear() }
    }
}

/// 共用的文字
private enum CheckInText {
    static func masked(_ code: String) -> String {
        isPhone(code) ? MemberRef(phone: code).maskedPhone : code
    }

    static func isPhone(_ code: String) -> Bool {
        code.count == 10 && code.hasPrefix("09")
    }

    /// 生日是這個月（MM-DD）
    static func birthdayThisMonth(_ birthday: String?) -> Bool {
        guard let b = birthday, let month = Int(b.prefix(2)) else { return false }
        return month == TaipeiTime.components(Date()).month
    }

    /// 2026/11/3
    static func day(_ d: Date) -> String {
        let c = TaipeiTime.components(d)
        return "\(c.year ?? 0)/\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// 這張卡入場後的樣子：「剩 7 次 → 入場後剩 6 次」「會籍到 2026/11/3・不扣次數」
    static func passEffect(_ p: MemberPass, at date: Date) -> String {
        switch p.spec.kind {
        case .visits:
            let left = p.remaining ?? 0
            var s = "剩 \(left) 次 → 入場後剩 \(max(left - 1, 0)) 次"
            if let e = p.expiresAt { s += "・到 \(day(e.addingTimeInterval(-1)))" }
            return s
        case .period:
            guard let e = p.expiresAt else { return "不限次數・不扣次數" }
            let days = p.daysLeft(at: date) ?? 0
            return "會籍到 \(day(e.addingTimeInterval(-1)))（還有 \(days) 天）・不扣次數"
        }
    }
}

// MARK: - 等人的畫面

private struct CheckInPrompt: View {
    var body: some View {
        VStack(spacing: 18) {
            HeroIcon("qr-code", size: 44)
                .foregroundStyle(Theme.faint)
            Headline("Welcome *in*", role: .h2)
            Text("請客人報手機號碼，或掃會員卡")
                .textRole(.lead)
                .foregroundStyle(Theme.ink2)
            HStack(spacing: 8) {
                Text("右邊鍵盤輸入、按「查詢」；條碼掃描器直接掃")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                Text("→")
                    .font(.brand(18, .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 查不到、離線、出錯：一句話＋動作
private struct CheckInMessage<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    let tone: Tone
    let actions: Actions

    init(icon: String, title: String, detail: String, tone: Tone, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.tone = tone
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            HeroIcon(icon, size: 36)
                .foregroundStyle(tone.foreground)
            Text(title)
                .textRole(.h3)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .textRole(.body)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                actions
            }
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - 查到的會員

private struct CheckInMemberPanel: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let member: Member
    let offline: Bool
    let onDone: () -> Void

    private var desk: CheckInDesk { CheckInDesk.shared }

    var body: some View {
        let now = Date()
        let plan = model.checkInPlan(for: member, at: now)
        VStack(alignment: .leading, spacing: 18) {
            if offline {
                Banner(text: "離線：用這台記得的資料（次數已經算上這台的報到）", tone: .warning)
            }
            identity
            if let entered = desk.entered, entered.member.id == member.id {
                welcome(entered)
            } else {
                verdict(plan, now: now)
                actions(plan)
                if desk.showShop {
                    CheckInShop(member: member)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                passList(now: now)
            }
        }
        .padding(22)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .task(id: desk.entered?.id) {
            // 入場後 3 秒換下一位
            guard let id = desk.entered?.id else { return }
            try? await Task.sleep(for: .seconds(3))
            if desk.entered?.id == id {
                withAnimation(reduceMotion ? nil : Motion.ease) { onDone() }
            }
        }
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.fast }

    // MARK: 是誰

    private var identity: some View {
        HStack(alignment: .center, spacing: 18) {
            CheckInPhoto(urlString: member.photoURL, name: member.name ?? "會")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(member.name ?? "（沒有名字）")
                        .font(.brand(30, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let tier = member.tierName {
                        StatusBadge(tier, tone: .gold)
                    }
                }
                HStack(spacing: 12) {
                    Text(member.ref.maskedPhone)
                        .font(.brand(15, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                    if CheckInText.birthdayThisMonth(member.birthday) {
                        HStack(spacing: 5) {
                            HeroIcon("cake", size: 14)
                            Text("本月壽星")
                        }
                        .font(.brand(13, .semibold))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accentSoft, in: .capsule)
                    }
                    Text("來過 \(member.visits) 次")
                        .font(.brand(13, .regular))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                if let note = member.note, !note.isEmpty {
                    Text("※ \(note)")
                        .textRole(.small)
                        .foregroundStyle(Theme.warningFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDone) {
                HeroIcon("x-mark", size: 16)
            }
            .buttonStyle(SquareIconButtonStyle(size: 40))
            .accessibilityLabel("清除，換下一位")
        }
    }

    // MARK: 能不能進

    /// 這次用的卡（換過就用換的那張）
    private func chosen(_ plan: CheckInPlan) -> MemberPass? {
        if let id = desk.passId, let p = plan.choices.first(where: { $0.id == id }) { return p }
        return plan.pass
    }

    @ViewBuilder
    private func verdict(_ plan: CheckInPlan, now: Date) -> some View {
        let today = todayCheckIn
        VStack(alignment: .leading, spacing: 10) {
            if let pass = chosen(plan) {
                CheckInVerdict(ok: true, title: "可以入場", detail: "\(pass.name)・\(CheckInText.passEffect(pass, at: now))")
            } else {
                CheckInVerdict(ok: false, title: problemTitle(plan.problem), detail: problemDetail(plan.problem))
            }
            if plan.choices.count > 1 {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(plan.choices) { p in
                        OptionChip(title: p.name, detail: p.statusText(at: now), selected: chosen(plan)?.id == p.id) {
                            desk.passId = p.id
                        }
                    }
                }
            }
            if let today {
                HStack(spacing: 8) {
                    HeroIcon("exclamation-triangle", size: 15)
                    Text(alreadyText(today))
                }
                .font(.brand(14.5, .medium))
                .foregroundStyle(Theme.warningFG)
            }
        }
    }

    private func alreadyText(_ c: CheckIn) -> String {
        let pass = c.passName.map { "（\($0)）" } ?? ""
        return "今天 \(c.at.clockText) 已經報到過\(pass)"
    }

    /// 今天報到過了沒（一天第二次要提醒，不擋）
    private var todayCheckIn: CheckIn? {
        guard let last = model.state.lastCheckIn(memberId: member.id) else { return nil }
        let today = model.businessDate
        return TaipeiTime.businessDate(last.at, cutoffHour: model.store.businessDayCutoffHour) == today ? last : nil
    }

    private func problemTitle(_ problem: CheckInPlan.Problem?) -> String {
        guard let problem else { return "沒有可用的卡" }
        switch problem {
        case .expired(let days, _): return "會籍已到期 \(days) 天"
        case .usedUp: return "次數用完了"
        case .noPass: return "沒有可用的卡"
        case .noAccount: return "查不到卡（後台沒有會員帳戶）"
        }
    }

    private func problemDetail(_ problem: CheckInPlan.Problem?) -> String {
        guard let problem else { return "這位會員沒有能入場的會籍或次數卡" }
        switch problem {
        case .expired(_, let name): return "\(name) 過期了，請客人續約"
        case .usedUp(let name): return "\(name) 已經用完，請客人買新的卡"
        case .noPass: return "這位會員沒有能入場的會籍或次數卡"
        case .noAccount: return "請到後台開啟「會員帳戶」，才看得到會籍與次數"
        }
    }

    // MARK: 動作

    @ViewBuilder
    private func actions(_ plan: CheckInPlan) -> some View {
        HStack(spacing: 10) {
            if let pass = chosen(plan) {
                Button {
                    enter(pass)
                } label: {
                    Text("入場")
                        .font(.brand(18, .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.accent, size: .lg, fullWidth: true, arrow: true))
            } else {
                Button {
                    graceEntry()
                } label: {
                    Text("破例入場")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
            }
            Button {
                withAnimation(anim) { desk.showShop.toggle() }
            } label: {
                Text(desk.showShop ? "收起" : (plan.canEnter ? "續約／買卡" : "續約／買卡 →"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(plan.canEnter ? .ghost : .primary, size: .lg, fullWidth: true))
        }
    }

    private func enter(_ pass: MemberPass) {
        guard let ci = model.recordCheckIn(member.ref, pass: pass) else { return }
        let left = pass.spec.kind == .visits ? "・剩 \(max((pass.remaining ?? 1) - 1, 0)) 次" : ""
        model.show("\(member.name ?? member.ref.maskedPhone) 入場\(left)")
        withAnimation(anim) {
            desk.entered = ci
            desk.touch()
        }
    }

    /// 沒有卡也讓他進（主管同意；不扣次數，記一筆備註）
    private func graceEntry() {
        Task {
            guard await model.authorize(.discount, detail: "\(member.name ?? member.ref.maskedPhone) 沒有可用的卡，破例入場") != nil else { return }
            guard let ci = model.recordCheckIn(member.ref, pass: nil, note: "破例入場") else { return }
            model.show("\(member.name ?? member.ref.maskedPhone) 破例入場", tone: .warning)
            withAnimation(anim) {
                desk.entered = ci
                desk.touch()
            }
        }
    }

    private func welcome(_ ci: CheckIn) -> some View {
        HStack(spacing: 16) {
            HeroIcon("check-circle", size: 44)
                .foregroundStyle(Theme.successFG)
            VStack(alignment: .leading, spacing: 4) {
                Text("歡迎，\(member.name ?? "")")
                    .font(.brand(26, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(welcomeDetail(ci))
                    .textRole(.body)
                    .foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.successFG.opacity(0.1), in: .rect(cornerRadius: Metric.radius))
    }

    private func welcomeDetail(_ ci: CheckIn) -> String {
        guard let name = ci.passName else { return ci.note.isEmpty ? "入場" : ci.note }
        return ci.uses > 0 ? "\(name)・扣 \(ci.uses) 次" : name
    }

    // MARK: 全部的卡

    @ViewBuilder
    private func passList(now: Date) -> some View {
        if let account = model.account(for: member.ref) {
            let usable = account.usablePasses(at: now)
            let others = account.passes.filter { p in !usable.contains(where: { $0.id == p.id }) }
                .sorted { ($0.expiresAt ?? $0.startsAt) > ($1.expiresAt ?? $1.startsAt) }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Eyebrow("會籍與課程卡")
                    Spacer()
                    Text("儲值金")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                    MoneyText(money: account.wallet, role: .small)
                }
                if usable.isEmpty && others.isEmpty {
                    Text("還沒有任何卡")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                }
                VStack(spacing: 0) {
                    ForEach(usable) { p in
                        CheckInPassRow(pass: p, usable: true, now: now)
                        Rule(color: Theme.hair)
                    }
                    ForEach(others.prefix(4)) { p in
                        CheckInPassRow(pass: p, usable: false, now: now)
                        Rule(color: Theme.hair)
                    }
                }
            }
        }
    }
}

/// 會員照片（核對是不是本人）；沒有照片用名字第一個字
private struct CheckInPhoto: View {
    let urlString: String?
    let name: String

    var body: some View {
        ZStack {
            Circle().fill(Theme.swatch(.sand))
            Text(String(name.prefix(1)))
                .font(.brand(36, .semibold))
                .foregroundStyle(Theme.tileInk)
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(.circle)
        .overlay { Circle().strokeBorder(Theme.line, lineWidth: 1) }
        .accessibilityLabel("\(name) 的照片")
    }
}

/// 大大的「可以入場」（綠）／「會籍已到期」（紅）
private struct CheckInVerdict: View {
    let ok: Bool
    let title: String
    let detail: String

    var body: some View {
        let color = ok ? Theme.successFG : Theme.dangerFG
        HStack(alignment: .center, spacing: 14) {
            HeroIcon(ok ? "check-circle" : "x-circle", size: 36)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.brand(28, .semibold))
                    .foregroundStyle(color)
                Text(detail)
                    .textRole(.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: .rect(cornerRadius: Metric.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一張卡：名字、規則、狀態（能用的綠點）
private struct CheckInPassRow: View {
    let pass: MemberPass
    let usable: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(usable ? Theme.live : Theme.faint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.name)
                    .font(.brand(15, .medium))
                    .foregroundStyle(usable ? Theme.ink : Theme.muted)
                Text(pass.spec.summary + (pass.spec.checkIn ? "・可入場" : ""))
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Text(pass.statusText(at: now))
                .font(.brand(13.5, .medium))
                .monospacedDigit()
                .foregroundStyle(usable ? Theme.ink2 : Theme.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .opacity(usable ? 1 : 0.7)
    }
}

/// 續約、買卡、儲值：點一下加進這位會員的單、去結帳（報到接待交給結帳櫃台）
private struct CheckInShop: View {
    @Environment(POSModel.self) private var model
    let member: Member

    var body: some View {
        let items = model.catalog.items.filter { ($0.itemKind == .pass || $0.itemKind == .storedValue) && model.isAvailable($0) }
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("續約／買卡")
            if items.isEmpty {
                Text("菜單上還沒有會籍、課程卡或儲值（到後台菜單把品項種類設成「課程卡／會籍」）")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            Task { await model.sell(item, to: member.ref) }
                        } label: {
                            shopTile(item)
                        }
                        .buttonStyle(PressScale(scale: 0.97))
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.pageAlt.opacity(0.6), in: .rect(cornerRadius: Metric.radius))
    }

    private func shopTile(_ item: MenuItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.brand(16, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(item.pass?.summary ?? item.itemKind.label)
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.openPrice {
                Text("自訂金額")
                    .font(.brand(14, .medium))
                    .foregroundStyle(Theme.ink2)
            } else {
                MoneyText(money: item.price, role: .h4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
        .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
        .contentShape(.rect)
    }
}

// MARK: - 今天的報到（右欄）

private struct CheckInToday: View {
    @Environment(POSModel.self) private var model
    /// 取消報到要主管 PIN（會用到右側鍵盤）：好了以後重新開始問會員號碼
    let onVoided: () -> Void

    @State private var confirming: CheckIn?

    var body: some View {
        let list = model.state.checkIns(businessDate: model.businessDate, cutoffHour: model.store.businessDayCutoffHour)
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("今天報到")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(list.count)")
                    .font(.brand(48, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(value: Double(list.count)))
                Text("人次")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            CheckInHourBars(times: list.map(\.at))
            Rule()
            if list.isEmpty {
                Text("還沒有人報到")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { c in
                            row(c)
                            Rule(color: Theme.hair)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert("取消這筆報到？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { c in
            Button("取消報到", role: .destructive) {
                Task {
                    _ = await model.voidCheckIn(c, reason: "櫃台取消")
                    onVoided()
                }
            }
            Button("返回", role: .cancel) {}
        } message: { c in
            Text("\(c.member.name ?? c.member.maskedPhone) \(c.at.clockText)" + (c.uses > 0 ? "・扣掉的 \(c.uses) 次會還回去" : "") + "。要店長輸入 PIN。")
        }
    }

    private func row(_ c: CheckIn) -> some View {
        HStack(spacing: 10) {
            Text(c.at.clockText)
                .font(.brand(13.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.member.name ?? c.member.maskedPhone)
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(detail(c))
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if c.uses > 0 {
                Text("−\(c.uses)")
                    .font(.brand(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
            }
            Menu {
                Button("取消報到", role: .destructive) { confirming = c }
            } label: {
                HeroIcon("ellipsis-horizontal", size: 14)
            }
            .buttonStyle(SquareIconButtonStyle(size: 30))
            .accessibilityLabel("更多")
        }
        .padding(.vertical, 9)
    }

    private func detail(_ c: CheckIn) -> String {
        var parts: [String] = []
        if let sid = c.sessionId, let s = model.classes.first(where: { $0.id == sid }) { parts.append(s.name) }
        parts.append(c.passName ?? (c.note.isEmpty ? "沒有用卡" : c.note))
        return parts.joined(separator: "・")
    }
}

/// 每個小時幾個人（6 點到 23 點；現在這個小時是橘色）
private struct CheckInHourBars: View {
    let times: [Date]

    var body: some View {
        let counts = hourCounts
        let top = max(counts.max() ?? 0, 1)
        let current = TaipeiTime.components(Date()).hour ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(counts.enumerated()), id: \.offset) { i, n in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Self.firstHour + i == current ? Theme.accent : Theme.ink2.opacity(n > 0 ? 0.55 : 0.15))
                        .frame(height: max(CGFloat(n) / CGFloat(top) * 44, 2))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44, alignment: .bottom)
            HStack {
                Text("6")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("23")
            }
            .font(.brand(10.5, .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("每小時報到人數")
    }

    private static let firstHour = 6

    private var hourCounts: [Int] {
        var out = Array(repeating: 0, count: 18)
        for t in times {
            let h = TaipeiTime.components(t).hour ?? 0
            let i = h - Self.firstHour
            if i >= 0 && i < out.count { out[i] += 1 }
        }
        return out
    }
}

// MARK: - 課表

private struct CheckInClasses: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var desk: CheckInDesk { CheckInDesk.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
        .task {
            // 課表與報名名單：進來抓一次、之後每分鐘
            while !Task.isCancelled {
                await model.loadClasses()
                await model.loadReservations()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func content(now: Date) -> some View {
        let sessions = model.classes
        let picked = sessions.first(where: { $0.id == desk.sessionId })
        let upcoming = sessions.first(where: { $0.endsAt > now })
        let selected = picked ?? upcoming ?? sessions.first
        return HStack(alignment: .top, spacing: 20) {
            if sessions.isEmpty {
                EmptyState(icon: "calendar-days", title: "今天沒有團體課", message: "課表在後台「門市 POS → 課表」排。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sessions) { s in
                            Button {
                                withAnimation(reduceMotion ? nil : Motion.fast) { desk.sessionId = s.id }
                            } label: {
                                CheckInSessionRow(session: s, coach: model.staffName(s.staffId), now: now, selected: selected?.id == s.id)
                            }
                            .buttonStyle(PressScale(scale: 0.98))
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .frame(width: 320)
                Rule(vertical: true)
                if let s = selected {
                    CheckInRoster(session: s, now: now)
                        .id(s.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }
}

/// 課表的一堂：時間、課名、教練、教室、報名人數
private struct CheckInSessionRow: View {
    let session: ClassSession
    let coach: String
    let now: Date
    let selected: Bool

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(s.startsAt.clockText)–\(s.endsAt.clockText)")
                    .font(.brand(13.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                Spacer(minLength: 4)
                if let tag = timing {
                    StatusBadge(tag.text, tone: tag.tone)
                }
            }
            Text(s.name)
                .font(.brand(18, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(who)
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            CheckInCapacity(booked: s.booked, capacity: s.capacity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: Metric.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1)
        }
        .opacity(now >= s.endsAt ? 0.6 : 1)
        .contentShape(.rect)
    }

    /// 「Amy・A 教室」
    private var who: String {
        var parts: [String] = []
        if coach != "—" { parts.append(coach) }
        if let room = session.room { parts.append(room) }
        return parts.joined(separator: "・")
    }

    private var timing: (text: String, tone: Tone)? {
        let s = session
        if now >= s.endsAt { return ("已結束", .neutral) }
        if now >= s.startsAt { return ("上課中", .active) }
        let m = Int(s.startsAt.timeIntervalSince(now) / 60)
        if m <= 60 { return ("\(m) 分鐘後", .gold) }
        if s.isFull { return ("額滿", .warning) }
        return nil
    }
}

/// 報名人數：12 / 20（額滿是橘色）
private struct CheckInCapacity: View {
    let booked: Int
    let capacity: Int

    var body: some View {
        HStack(spacing: 8) {
            if capacity > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.press)
                        Capsule()
                            .fill(booked >= capacity ? Theme.accent : Theme.ink2)
                            .frame(width: geo.size.width * min(CGFloat(booked) / CGFloat(capacity), 1))
                    }
                }
                .frame(height: 5)
                Text("\(booked)/\(capacity)")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(booked >= capacity ? Theme.accentText : Theme.muted)
            } else {
                Text("\(booked) 人報名・不限名額")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(capacity > 0 ? "報名 \(booked) 人，名額 \(capacity)" : "報名 \(booked) 人")
    }
}

/// 一堂課的名單：報名、簽到（扣卡）、沒卡的收單堂
private struct CheckInRoster: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ClassSession
    let now: Date

    /// 報名時查不到會員：補名字再報名
    @State private var pendingPhone: String?
    @State private var pendingName = ""
    /// 沒有能抵這堂課的卡的那一位
    @State private var noPassId: String?
    @State private var busyId: String?
    @State private var confirming: ResvCancel?

    private struct ResvCancel: Identifiable {
        let reservation: Reservation
        let status: ReservationStatus
        var id: String { reservation.id + status.rawValue }
    }

    var body: some View {
        let roster = model.roster(of: session)
        VStack(alignment: .leading, spacing: 16) {
            header(roster)
            if let phone = pendingPhone {
                pendingRow(phone)
            }
            if roster.isEmpty {
                EmptyState(icon: "user-group", title: "還沒有人報名", message: "按「報名」用電話幫客人報名；沒報名的按「現場單堂」。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(roster) { r in
                            row(r)
                            Rule(color: Theme.hair)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { c in
            Button(c.status == .cancelled ? "取消報名" : "標示未到", role: .destructive) {
                Task {
                    if c.status == .cancelled {
                        await model.cancelClassBooking(c.reservation)
                    } else {
                        await model.setStatus(.noShow, for: c.reservation)
                    }
                }
            }
            Button("返回", role: .cancel) {}
        } message: { c in
            Text("\(c.reservation.name)・\(session.name) \(session.startsAt.clockText)")
        }
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.fast }

    private var confirmTitle: String {
        guard let c = confirming else { return "" }
        return c.status == .cancelled ? "取消 \(c.reservation.name) 的報名？" : "\(c.reservation.name) 沒有來？"
    }

    // MARK: 上面

    private func header(_ roster: [Reservation]) -> some View {
        let s = session
        let arrived = roster.filter { $0.status == .seated || $0.status == .arrived }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Headline(s.name, role: .h3)
                        .lineLimit(1)
                    Text(headerDetail)
                        .textRole(.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await walkInDropIn() }
                } label: {
                    Text("現場單堂")
                }
                .buttonStyle(.brand(.ghost, size: .md))
                Button {
                    Task { await book() }
                } label: {
                    Label {
                        Text("報名")
                    } icon: {
                        HeroIcon("plus", size: 15)
                    }
                }
                .buttonStyle(.brand(.primary, size: .md))
            }
            HStack(spacing: 16) {
                CheckInCapacity(booked: s.booked, capacity: s.capacity)
                    .frame(maxWidth: 260)
                Text("已簽到 \(arrived)")
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.successFG)
                if let note = s.note, !note.isEmpty {
                    Text("※ \(note)")
                        .textRole(.xs)
                        .foregroundStyle(Theme.warningFG)
                        .lineLimit(1)
                }
            }
        }
    }

    private var headerDetail: String {
        let s = session
        var parts = ["\(s.startsAt.clockText)–\(s.endsAt.clockText)"]
        let coach = model.staffName(s.staffId)
        if coach != "—" { parts.append("\(model.mode.staffTitle) \(coach)") }
        if let room = s.room { parts.append(room) }
        if let price = s.dropInPrice { parts.append("單堂 \(price.formatted)") }
        return parts.joined(separator: "・")
    }

    // MARK: 一位

    private func row(_ r: Reservation) -> some View {
        let member = r.memberId.flatMap { model.members[$0] }
        let account = member.flatMap { model.account(for: $0.ref) }
        let pass = account.flatMap { model.classPass(for: $0, session: session, at: now) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.name)
                        .font(.brand(17, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(rowDetail(r, member: member, account: account, pass: pass))
                        .textRole(.xs)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusBadge(r.status.label(for: .classBooking), tone: tone(r.status))
                if r.status.isActive {
                    Button {
                        Task { await signIn(r) }
                    } label: {
                        Text(busyId == r.id ? "…" : "簽到")
                            .frame(minWidth: 52)
                    }
                    .buttonStyle(.brand(.accent, size: .sm))
                    .disabled(busyId != nil)
                }
                Menu {
                    if r.status.isActive {
                        Button("未到") { confirming = ResvCancel(reservation: r, status: .noShow) }
                        Button("取消報名", role: .destructive) { confirming = ResvCancel(reservation: r, status: .cancelled) }
                    }
                    if r.status == .noShow {
                        Button("改回已報名") { Task { await model.setStatus(.booked, for: r) } }
                    }
                } label: {
                    HeroIcon("ellipsis-horizontal", size: 14)
                }
                .buttonStyle(SquareIconButtonStyle(size: 32))
                .accessibilityLabel("更多")
            }
            if noPassId == r.id {
                noPassRow(r, member: member)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 12)
    }

    private func rowDetail(_ r: Reservation, member: Member?, account: MemberAccount?, pass: MemberPass?) -> String {
        var parts = [r.phone.isEmpty ? "沒留電話" : MemberRef(phone: r.phone).maskedPhone]
        if r.status == .seated, let c = signedIn(r) {
            parts.append("\(c.at.clockText) 簽到" + (c.passName.map { "・\($0)" } ?? "・單堂"))
        } else if let pass {
            parts.append("\(pass.name) \(pass.statusText(at: now))")
        } else if account != nil {
            parts.append("沒有能抵這堂的卡")
        } else if member == nil && r.memberId == nil {
            parts.append("非會員")
        }
        return parts.joined(separator: "・")
    }

    /// 這筆報名的簽到（這台最近兩天記得的）
    private func signedIn(_ r: Reservation) -> CheckIn? {
        model.state.checkIns.values.first { $0.reservationId == r.id && !$0.isVoided }
    }

    private func tone(_ s: ReservationStatus) -> Tone {
        switch s {
        case .booked, .notified: .info
        case .arrived, .seated: .active
        case .cancelled: .neutral
        case .noShow: .danger
        }
    }

    private func noPassRow(_ r: Reservation, member: Member?) -> some View {
        HStack(spacing: 10) {
            HeroIcon("exclamation-circle", size: 15)
                .foregroundStyle(Theme.warningFG)
            Text("沒有能抵這堂課的卡")
                .font(.brand(14, .medium))
                .foregroundStyle(Theme.warningFG)
            Spacer(minLength: 6)
            Button {
                noPassId = nil
                Task { await model.dropIn(r, session: session, member: member) }
            } label: {
                Text(session.dropInPrice.map { "單堂 \($0.formatted)" } ?? "單堂收費")
            }
            .buttonStyle(.brand(.primary, size: .sm))
            if let member {
                Button("買卡") { openShop(member) }
                    .buttonStyle(.brand(.ghost, size: .sm))
            }
        }
        .padding(10)
        .background(Tone.warning.background, in: .rect(cornerRadius: Metric.radiusSm))
    }

    // MARK: 報名中、查不到會員

    private func pendingRow(_ phone: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(MemberRef(phone: phone).maskedPhone) 還不是會員：填名字，加入會員並報名")
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
            HStack(spacing: 10) {
                TextField("名字", text: $pendingName)
                    .font(.brand(17, .medium))
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                    .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                Button("加入並報名") {
                    Task { await joinAndBook(phone) }
                }
                .buttonStyle(.brand(.primary, size: .md))
                Button("取消") {
                    withAnimation(anim) {
                        pendingPhone = nil
                        pendingName = ""
                    }
                }
                .buttonStyle(.brand(.ghost, size: .md))
            }
        }
        .padding(14)
        .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
    }

    // MARK: 動作

    /// 報名：右側鍵盤打電話 → 查會員 → 報名（查不到就補名字、加入會員）
    private func book() async {
        if session.isFull { model.show("\(session.name) 已經額滿，照樣報名", tone: .warning) }
        var spec = KeypadSpec.phone
        spec.title = "報名電話"
        spec.subtitle = "\(session.name) \(session.startsAt.clockText)"
        spec.confirmLabel = "報名"
        guard let entry = await model.keypad.ask(spec) else { return }
        switch await model.findMember(code: entry.digits) {
        case .found(let m), .cached(let m):
            _ = await model.bookClass(session, member: m, name: m.name ?? m.ref.maskedPhone, phone: m.phone)
        case .notFound:
            withAnimation(anim) {
                pendingPhone = entry.digits
                pendingName = ""
            }
        case .offline:
            model.show("離線，報名要連上網路", tone: .warning)
        case .failed(let message):
            model.show(message, tone: .danger)
        }
    }

    private func joinAndBook(_ phone: String) async {
        let name = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = await model.createMember(phone: phone, name: name.isEmpty ? nil : name) else { return }
        _ = await model.bookClass(session, member: m, name: m.name ?? m.ref.maskedPhone, phone: phone)
        withAnimation(anim) {
            pendingPhone = nil
            pendingName = ""
        }
    }

    /// 簽到：先找會員（這台沒查過就查一次），有能抵這堂課的卡就扣；沒有就問要不要收單堂
    private func signIn(_ r: Reservation) async {
        busyId = r.id
        defer { busyId = nil }
        var member = r.memberId.flatMap { model.members[$0] }
        if member == nil, !r.phone.isEmpty {
            switch await model.findMember(code: r.phone) {
            case .found(let m), .cached(let m): member = m
            case .notFound, .offline, .failed: break
            }
        }
        let pass = member.flatMap { model.account(for: $0.ref) }.flatMap { model.classPass(for: $0, session: session) }
        guard let pass else {
            withAnimation(anim) { noPassId = r.id }
            return
        }
        withAnimation(anim) { noPassId = nil }
        await model.signIn(r, session: session, member: member, pass: pass)
    }

    /// 沒報名、沒卡的現場客：電話 → 會員 → 開單收單堂
    private func walkInDropIn() async {
        var spec = KeypadSpec.phone
        spec.title = "現場單堂"
        spec.subtitle = "客人電話（可以按 × 跳過）"
        spec.confirmLabel = "開單"
        var member: Member? = nil
        if let entry = await model.keypad.ask(spec) {
            switch await model.findMember(code: entry.digits) {
            case .found(let m), .cached(let m): member = m
            case .notFound: member = await model.createMember(phone: entry.digits, name: nil)
            case .offline, .failed: break
            }
        }
        await model.dropIn(nil, session: session, member: member)
    }

    /// 沒卡的人想買卡：回到報到頁、帶出這位、打開「續約／買卡」
    private func openShop(_ m: Member) {
        let desk = CheckInDesk.shared
        withAnimation(anim) {
            desk.clear()
            desk.code = m.phone
            desk.result = .member(id: m.id, offline: false)
            desk.showShop = true
            desk.tab = .entry
        }
    }
}
