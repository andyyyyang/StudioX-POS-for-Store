import Foundation
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 報到（健身房、瑜珈、教室的櫃台首頁）。
///
///   ┌ Check in ─────────────────────────────────────── [報到] [課表] ┐
///   │ ┌──────────────────────────────────────────┐ │ 今天報到        │
///   │ │  ◜◝                                      │ │ 42 人次  ▁▃▇▅▂  │
///   │ │ ( 林 )  林小涵   金卡會員  本月壽星         │ │ (林) 林小涵 3 分前│
///   │ │  ◟◞ 剩 23 天   0912-***-678・來過 41 次    │ │ (王) 王大明 8 分前│
///   │ │ ┌ ✓ 可以入場 ─────────────────────────┐   │ │ …               │
///   │ │ │ 月卡・會籍到 11/3（還有 23 天）・不扣次數│   │ │                 │
///   │ └──────────────────────────────────────────┘ │                 │
///   └────────────────────────────────────────────────────────────────┘
///
/// 左邊選、右邊做：右側鍵盤等著「會員」（打手機號碼或掃會員卡）；查到的人放在左邊大大的，
/// 他的動作都在右欄：大鍵「入場」（不能進就是「續約／買卡」），其他（改用別張卡、破例入場）是動作鍵；
/// 續約／買卡、改用哪張卡是蓋住右欄的面板。入場或按 × 之後鍵盤再等下一位。
/// 今天報到的動態：點一筆選起來，右欄可以取消報到（要店長 PIN）。
/// 課表：今天的團體課（名額圈、教練、教室），名單是一顆顆頭像：點＝選起來，右欄大鍵「簽到」，沒卡的收單堂。
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
                    CheckInFeed(onVoided: { restartListening() })
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
        .dockSelection(desk.tab == .entry ? messageDock : nil)
        .task(id: listenKey) { await listen() }
        .onAppear {
            desk.forgetIfStale()
            if !model.mode.usesClasses { desk.tab = .entry }
            // 截圖：先帶出一位能入場的會員
            if LaunchArguments.preselect, desk.tab == .entry, desk.result == nil, let m = model.members.values.sorted(by: { $0.id < $1.id }).first(where: { model.checkInPlan(for: $0).pass != nil }) { desk.result = .member(id: m.id, offline: false) }
        }
        .onDisappear { stopListening() }
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.ease }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PageTitle(title: desk.tab == .entry ? "Check *in*" : "Today's *classes*", subtitle: "報到・\(Date().dayTitle)")
            Spacer(minLength: 12)
            if model.mode.usesClasses {
                HStack(spacing: 6) {
                    tabButton("報到", icon: "qr-code", .entry)
                    tabButton("課表", icon: "calendar-days", .classes)
                }
                .frame(width: 240)
            }
        }
    }

    private func tabButton(_ title: String, icon: String, _ tab: CheckInTab) -> some View {
        Button {
            guard desk.tab != tab else { return }
            stopListening()
            withAnimation(anim) { desk.tab = tab }
        } label: {
            Label {
                Text(title)
            } icon: {
                HeroIcon(icon, size: 15)
            }
            .labelStyle(BrandLabelStyle())
        }
        .buttonStyle(.choice(desk.tab == tab, height: 44))
    }

    // MARK: - 右側鍵盤一直等著會員號碼

    private var listenKey: String { "\(desk.tab.rawValue)-\(desk.listenToken)" }

    /// 報到頁開著就一直問「會員」：查完一位馬上問下一位（掃描器掃進來直接查）。
    /// 被別的題目插隊（主管 PIN）就等它問完再接著問；換頁、換到課表就停
    private func listen() async {
        guard desk.tab == .entry else { return }
        while !Task.isCancelled {
            // 右欄正在顯示某一位（或選了一筆報到）：先不問下一位，右欄才看得到他的動作；入場、按 × 之後再問
            if desk.result != nil || desk.searching || desk.feedId != nil {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
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
        withAnimation(reduceMotion ? nil : Motion.spring) {
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
            CheckInSearching(code: desk.code.map { CheckInText.masked($0) } ?? "")
        } else if let result = desk.result {
            ScrollView {
                resultView(result)
                    .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            CheckInPrompt(recent: recentNames)
                .transition(.opacity)
        }
    }

    /// 等人的畫面下面：剛剛進來的幾位（頭像）
    private var recentNames: [String] {
        let list = model.state.checkIns(businessDate: model.businessDate, cutoffHour: model.store.businessDayCutoffHour)
        return list.prefix(5).map { $0.member.name ?? $0.member.maskedPhone }
    }

    @ViewBuilder
    private func resultView(_ result: CheckInResult) -> some View {
        switch result {
        case .member(let id, let offline):
            if let m = model.members[id] {
                CheckInMemberPanel(member: m, offline: offline, onDone: { clear() })
                    .id(id)
            } else {
                CheckInMessage(icon: "exclamation-circle", title: "找不到這位會員的資料", detail: "請再查一次", tone: .warning)
            }
        case .notFound(let code):
            CheckInMessage(icon: "user", title: "查不到 \(CheckInText.masked(code))", detail: "還不是會員，或號碼打錯了", tone: .warning)
        case .offline(let code):
            CheckInMessage(icon: "wifi", title: "離線，查不到 \(CheckInText.masked(code))", detail: "這台沒查過這位會員。可以先記下號碼讓他進去，連上網路後到後台核對。", tone: .warning)
        case .failed(_, let message):
            CheckInMessage(icon: "exclamation-triangle", title: "查不到", detail: message, tone: .danger)
        }
    }

    /// 查不到、離線、出錯：動作在右欄（查到的會員由會員卡片自己交給右欄）
    private var messageDock: DockSelection? {
        guard let result = desk.result else { return nil }
        let again = POSAction("重新輸入", icon: "arrow-path") { clear() }
        switch result {
        case .member(let id, _):
            guard model.members[id] == nil else { return nil }
            return DockSelection(id: "checkin-missing-\(id)", kind: "查詢", title: "找不到這位會員的資料", detail: "請再查一次",
                                 badge: DockBadge("查不到", tone: .warning), primary: again, accent: false, clear: { clear() })
        case .notFound(let code):
            let canJoin = CheckInText.isPhone(code)
            return DockSelection(id: "checkin-notfound-\(code)", kind: "查詢", title: "查不到 \(CheckInText.masked(code))",
                                 detail: "還不是會員，或號碼打錯了", badge: DockBadge("不是會員", tone: .warning),
                                 primary: canJoin ? POSAction("用這支電話加入會員", icon: "user") { join(code) } : again,
                                 accent: false, actions: canJoin ? [again] : [], clear: { clear() })
        case .offline(let code):
            return DockSelection(id: "checkin-offline-\(code)", kind: "查詢", title: "離線，查不到 \(CheckInText.masked(code))",
                                 detail: "先記下號碼讓他進去，連上網路後到後台核對", badge: DockBadge("離線", tone: .warning),
                                 primary: POSAction("先讓他入場（記下號碼）", icon: "check") { offlineEntry(code) },
                                 actions: [again], clear: { clear() })
        case .failed(let code, let message):
            return DockSelection(id: "checkin-failed-\(code)", kind: "查詢", title: "查不到", detail: message,
                                 badge: DockBadge("出錯了", tone: .danger),
                                 primary: POSAction("再試一次", icon: "arrow-path") { Task { await lookUp(code) } },
                                 accent: false, actions: [again], clear: { clear() })
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
    /// 今天報到的動態裡選起來的那一筆（右欄可以取消報到）
    var feedId: String?
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
        feedId = nil
        touch()
    }

    /// 超過 3 分鐘沒動：上一位客人的資料不要留在畫面上
    func forgetIfStale() {
        if Date().timeIntervalSince(updatedAt) > 180 { clear() }
    }
}

/// 共用的文字、顏色
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

    /// 這張卡入場後的樣子：「剩 7 次 → 入場後剩 6 次」「會籍到 2026/11/3（還有 23 天）・不扣次數」
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

    /// 名字 → 固定的頭像顏色（同一個人每次都一樣）
    static func swatch(for key: String) -> Swatch {
        let all = Swatch.allCases
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return all[sum % all.count]
    }
}

// MARK: - 等人、查詢中

/// 等人：一圈一圈慢慢呼吸的圓、大字、剛剛進來的幾位
private struct CheckInPrompt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let recent: [String]

    @State private var breathe = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(Theme.accent.opacity(0.22 - Double(i) * 0.06), lineWidth: 1.5)
                        .frame(width: 120 + CGFloat(i) * 44, height: 120 + CGFloat(i) * 44)
                        .scaleEffect(breathe ? 1.04 : 0.96)
                        .animation(breathing(delay: Double(i) * 0.3), value: breathe)
                }
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 104, height: 104)
                HeroIcon("qr-code", size: 44)
                    .foregroundStyle(Theme.accent)
            }
            .frame(height: 220)
            Headline("Welcome *in*", role: .h1)
            Text("請客人報手機號碼，或掃會員卡")
                .textRole(.lead)
                .foregroundStyle(Theme.ink2)
            HStack(spacing: 8) {
                Text("右邊鍵盤輸入、按「查詢」；條碼掃描器直接掃")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                Text("→")
                    .font(.brand(20, .medium))
                    .foregroundStyle(Theme.accent)
            }
            if !recent.isEmpty {
                HStack(spacing: -8) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, n in
                        CheckInAvatar(name: n, size: 34)
                            .overlay { Circle().strokeBorder(Theme.page, lineWidth: 2.5) }
                    }
                    Text("剛剛進來")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                        .padding(.leading, 16)
                }
                .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .onAppear { breathe = true }
    }

    /// 慢慢呼吸（減少動態效果時不動）
    private func breathing(delay: Double) -> Animation? {
        guard !reduceMotion else { return nil }
        return Animation.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(delay)
    }
}

private struct CheckInSearching: View {
    let code: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text("查詢 \(code)…")
                .textRole(.lead)
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 查不到、離線、出錯：一句話（動作在右欄）
private struct CheckInMessage: View {
    let icon: String
    let title: String
    let detail: String
    let tone: Tone

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tone.background)
                    .frame(width: 88, height: 88)
                HeroIcon(icon, size: 36)
                    .foregroundStyle(tone.foreground)
            }
            Text(title)
                .textRole(.h3)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .textRole(.body)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("動作在右邊")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

// MARK: - 查到的會員（主角卡）

private struct CheckInMemberPanel: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let member: Member
    let offline: Bool
    let onDone: () -> Void

    private var desk: CheckInDesk { CheckInDesk.shared }

    /// 改用哪張卡的面板（蓋住右欄）
    @State private var pickingPass = false

    var body: some View {
        let now = Date()
        let plan = model.checkInPlan(for: member, at: now)
        let pass = chosen(plan)
        VStack(alignment: .leading, spacing: 22) {
            if offline {
                Banner(text: "離線：用這台記得的資料（次數已經算上這台的報到）", tone: .warning)
            }
            identity(plan: plan, pass: pass, now: now)
            verdict(plan, pass: pass, now: now)
            passList(now: now)
        }
        // 入場（大鍵）、續約／買卡、改用別張卡、破例入場都在右欄
        .dockSelection(dock(plan, pass: pass))
        .dockPanel(isPresented: Binding(get: { desk.showShop }, set: { desk.showShop = $0 }),
                   title: "續約／買卡", subtitle: member.name ?? member.ref.maskedPhone) {
            CheckInShop(member: member)
        }
        .dockPanel(isPresented: $pickingPass, title: "改用哪張卡", subtitle: member.name ?? member.ref.maskedPhone) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.choices) { p in
                    DockChoice(title: p.name, detail: CheckInText.passEffect(p, at: now), trailing: p.statusText(at: now),
                               selected: pass?.id == p.id) {
                        withAnimation(anim) { desk.passId = p.id }
                        pickingPass = false
                    }
                }
            }
        }
        .padding(26)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .overlay {
            if let entered = desk.entered, entered.member.id == member.id {
                CheckInSuccess(name: member.name ?? member.ref.maskedPhone, checkIn: entered, visit: member.visits + 1)
                    .transition(.opacity)
            }
        }
        .sensoryFeedback(.success, trigger: desk.entered?.id)
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

    // MARK: 是誰：大頭照＋會籍的圈（剩幾天、剩幾次）

    private func identity(plan: CheckInPlan, pass: MemberPass?, now: Date) -> some View {
        let ring = CheckInRingInfo(pass: pass, problem: plan.problem, now: now)
        return HStack(alignment: .center, spacing: 26) {
            CheckInRingAvatar(member: member, ring: ring)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(member.name ?? "（沒有名字）")
                        .font(.brand(38, .semibold))
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
                    Text("來過 \(member.visits) 次")
                        .font(.brand(14, .regular))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    if CheckInText.birthdayThisMonth(member.birthday) {
                        HStack(spacing: 5) {
                            HeroIcon("cake", size: 14)
                            Text("本月壽星")
                        }
                        .font(.brand(13, .semibold))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.accentSoft, in: .capsule)
                    }
                }
                if let note = member.note, !note.isEmpty {
                    Text("※ \(note)")
                        .textRole(.small)
                        .foregroundStyle(Theme.warningFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 能不能進

    /// 這次用的卡（換過就用換的那張）
    private func chosen(_ plan: CheckInPlan) -> MemberPass? {
        if let id = desk.passId, let p = plan.choices.first(where: { $0.id == id }) { return p }
        return plan.pass
    }

    @ViewBuilder
    private func verdict(_ plan: CheckInPlan, pass: MemberPass?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pass {
                CheckInVerdict(ok: true, title: "可以入場", detail: "\(pass.name)・\(CheckInText.passEffect(pass, at: now))")
            } else {
                CheckInVerdict(ok: false, title: problemTitle(plan.problem), detail: problemDetail(plan.problem))
            }
            if plan.choices.count > 1 {
                Text("還有 \(plan.choices.count - 1) 張卡可以用：右邊「改用別張卡」")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            if let today = todayCheckIn {
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
        case .noAccount: return "查不到卡"
        }
    }

    private func problemDetail(_ problem: CheckInPlan.Problem?) -> String {
        guard let problem else { return "這位會員沒有能入場的會籍或次數卡" }
        switch problem {
        case .expired(_, let name): return "\(name) 過期了，請客人續約"
        case .usedUp(let name): return "\(name) 已經用完，請客人買新的卡"
        case .noPass: return "這位會員沒有能入場的會籍或次數卡"
        case .noAccount: return "後台沒有開「會員帳戶」，看不到會籍與次數"
        }
    }

    // MARK: 動作

    // MARK: 右欄

    /// 能進 → 大鍵「入場」（品牌橘）；不能進 → 大鍵「續約／買卡」，「破例入場」（要主管）是動作鍵。剛入場 → 「下一位」
    private func dock(_ plan: CheckInPlan, pass: MemberPass?) -> DockSelection {
        let name = member.name ?? member.ref.maskedPhone
        var detail = "\(member.ref.maskedPhone)・來過 \(member.visits) 次"
        if let pass { detail += "・用 \(pass.name)" }
        if let today = todayCheckIn { detail += "・\(alreadyText(today))" }
        let shop = POSAction(desk.showShop ? "收起續約／買卡" : "續約／買卡", icon: "credit-card") {
            withAnimation(reduceMotion ? nil : Motion.spring) { desk.showShop.toggle() }
        }
        if let entered = desk.entered, entered.member.id == member.id {
            return DockSelection(id: "checkin-\(member.id)-in", kind: "會員", title: name, detail: "\(entered.at.clockText) 入場",
                                 badge: DockBadge("已入場", tone: .active),
                                 primary: POSAction("下一位", icon: "arrow-path") { onDone() }, accent: false,
                                 clear: { onDone() })
        }
        var actions: [POSAction] = []
        let primary: POSAction
        if let pass {
            primary = POSAction("入場", icon: "check") { enter(pass) }
            actions.append(shop)
            if plan.choices.count > 1 {
                actions.append(POSAction("改用別張卡", icon: "arrows-right-left") { pickingPass = true })
            }
        } else {
            primary = shop
            actions.append(POSAction("破例入場（主管授權）", icon: "exclamation-triangle") { graceEntry() })
        }
        return DockSelection(
            id: "checkin-\(member.id)",
            kind: "會員",
            title: name,
            detail: detail,
            badge: pass != nil ? DockBadge("可以入場", tone: .active) : DockBadge(problemTitle(plan.problem), tone: .danger),
            primary: primary,
            accent: pass != nil,
            actions: actions,
            clear: { onDone() }
        )
    }

    private func enter(_ pass: MemberPass) {
        guard let ci = model.recordCheckIn(member.ref, pass: pass) else { return }
        let left = pass.spec.kind == .visits ? "・剩 \(max((pass.remaining ?? 1) - 1, 0)) 次" : ""
        model.show("\(member.name ?? member.ref.maskedPhone) 入場\(left)")
        withAnimation(reduceMotion ? nil : Motion.spring) {
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
            withAnimation(reduceMotion ? nil : Motion.spring) {
                desk.entered = ci
                desk.touch()
            }
        }
    }

    // MARK: 全部的卡

    @ViewBuilder
    private func passList(now: Date) -> some View {
        if let account = model.account(for: member.ref) {
            let usable = account.usablePasses(at: now)
            let others = account.passes.filter { p in !usable.contains(where: { $0.id == p.id }) }
                .sorted { ($0.expiresAt ?? $0.startsAt) > ($1.expiresAt ?? $1.startsAt) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow("會籍與課程卡")
                    Spacer()
                    Text("儲值金")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                    MoneyText(money: account.wallet, role: .h4)
                }
                if usable.isEmpty && others.isEmpty {
                    Text("還沒有任何卡")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(usable) { p in
                            CheckInPassCard(pass: p, usable: true, now: now)
                        }
                        ForEach(others.prefix(4)) { p in
                            CheckInPassCard(pass: p, usable: false, now: now)
                        }
                    }
                }
            }
        }
    }
}

/// 會籍圈的資料：剩幾成、顏色、底下那行字
private struct CheckInRingInfo {
    var progress: Double
    var color: Color
    var caption: String

    init(pass: MemberPass?, problem: CheckInPlan.Problem?, now: Date) {
        guard let pass else {
            progress = 0
            color = Theme.dangerFG
            var text = "沒有卡"
            if let problem {
                switch problem {
                case .expired(let days, _): text = "過期 \(days) 天"
                case .usedUp: text = "次數用完"
                case .noPass, .noAccount: text = "沒有卡"
                }
            }
            caption = text
            return
        }
        switch pass.spec.kind {
        case .visits:
            let left = pass.remaining ?? 0
            let total = max(pass.spec.visits ?? left, 1)
            progress = min(Double(left) / Double(total), 1)
            color = left <= 2 ? Theme.warningFG : Theme.successFG
            caption = "剩 \(left) 次"
        case .period:
            if let days = pass.daysLeft(at: now) {
                let total = max(pass.spec.validDays ?? max(days, 30), 1)
                progress = min(Double(days) / Double(total), 1)
                color = days <= 7 ? Theme.warningFG : Theme.successFG
                caption = "剩 \(days) 天"
            } else {
                progress = 1
                color = Theme.successFG
                caption = "不限期"
            }
        }
    }
}

/// 大頭照（沒有照片用名字第一個字）外面一圈會籍：綠＝還很多、黃＝快到了、紅＝不能進
private struct CheckInRingAvatar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let member: Member
    let ring: CheckInRingInfo

    @State private var shown = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Theme.press, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: shown || reduceMotion ? max(ring.progress, 0.001) : 0)
                    .stroke(ring.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                CheckInPhoto(urlString: member.photoURL, name: member.name ?? "會", size: 128)
            }
            .frame(width: 152, height: 152)
            Text(ring.caption)
                .font(.brand(15, .semibold))
                .monospacedDigit()
                .foregroundStyle(ring.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(ring.color.opacity(0.12), in: .capsule)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : Motion.slow) { shown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(member.name ?? "會員")，\(ring.caption)")
    }
}

/// 會員照片（核對是不是本人）；沒有照片用名字第一個字
private struct CheckInPhoto: View {
    let urlString: String?
    let name: String
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle().fill(Theme.swatch(CheckInText.swatch(for: name)))
            Text(String(name.prefix(1)))
                .font(.brand(size * 0.4, .semibold))
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
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// 名字第一個字的小頭像（動態、名單用）
private struct CheckInAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.brand(size * 0.42, .semibold))
            .foregroundStyle(Theme.tileInk)
            .frame(width: size, height: size)
            .background(Theme.swatch(CheckInText.swatch(for: name)), in: .circle)
            .accessibilityHidden(true)
    }
}

/// 大大的「可以入場」（綠）／「會籍已到期」（紅）
private struct CheckInVerdict: View {
    let ok: Bool
    let title: String
    let detail: String

    var body: some View {
        let color = ok ? Theme.successFG : Theme.dangerFG
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 52, height: 52)
                HeroIcon(ok ? "check" : "x-mark", size: 26)
                    .foregroundStyle(Theme.page)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.brand(32, .semibold))
                    .foregroundStyle(color)
                Text(detail)
                    .textRole(.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 入場了：整張卡蓋上綠色，圓圈畫一圈、勾彈出來、「歡迎回來」
private struct CheckInSuccess: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String
    let checkIn: CheckIn
    /// 這是第幾次來
    let visit: Int

    @State private var drawn = false
    @State private var popped = false

    var body: some View {
        let on = drawn || reduceMotion
        let pop = popped || reduceMotion
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Theme.successFG.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: on ? 1 : 0)
                    .stroke(Theme.successFG, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HeroIcon("check", size: 64)
                    .foregroundStyle(Theme.successFG)
                    .scaleEffect(pop ? 1 : 0.4)
                    .opacity(pop ? 1 : 0)
            }
            .frame(width: 150, height: 150)
            Text("歡迎回來，\(name)")
                .font(.brand(34, .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(detail)
                .textRole(.lead)
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .fill(Theme.surface)
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .fill(Theme.successFG.opacity(0.08))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.successFG.opacity(0.4), lineWidth: 1.5)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Motion.ease) { drawn = true }
            withAnimation(Motion.snap.delay(0.25)) { popped = true }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = ["第 \(visit) 次來"]
        if let p = checkIn.passName {
            parts.append(checkIn.uses > 0 ? "\(p) 扣 \(checkIn.uses) 次" : p)
        } else if !checkIn.note.isEmpty {
            parts.append(checkIn.note)
        }
        return parts.joined(separator: "・")
    }
}

/// 一張卡：名字、規則、狀態（能用的有綠點、一條剩下多少）
private struct CheckInPassCard: View {
    let pass: MemberPass
    let usable: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(usable ? Theme.live : Theme.faint)
                    .frame(width: 7, height: 7)
                Text(pass.name)
                    .font(.brand(15, .semibold))
                    .foregroundStyle(usable ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if pass.spec.checkIn {
                    Text("可入場")
                        .font(.brand(11, .semibold))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
                }
            }
            Text(pass.statusText(at: now))
                .font(.brand(14, .medium))
                .monospacedDigit()
                .foregroundStyle(usable ? Theme.ink2 : Theme.muted)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.press)
                    Capsule()
                        .fill(usable ? Theme.successFG : Theme.faint)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            Text(pass.spec.summary)
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(14)
        .background(Theme.page.opacity(usable ? 0.6 : 0.3), in: .rect(cornerRadius: Metric.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .opacity(usable ? 1 : 0.7)
    }

    /// 還剩幾成（次數卡看次數、有期限的看天數）
    private var fraction: CGFloat {
        guard usable else { return 0 }
        switch pass.spec.kind {
        case .visits:
            let total = max(pass.spec.visits ?? 1, 1)
            return CGFloat(min(Double(pass.remaining ?? 0) / Double(total), 1))
        case .period:
            guard let days = pass.daysLeft(at: now), let total = pass.spec.validDays, total > 0 else { return 1 }
            return CGFloat(min(Double(days) / Double(total), 1))
        }
    }
}

/// 續約、買卡、儲值：點一下加進這位會員的單、去結帳（報到接待交給結帳櫃台）
private struct CheckInShop: View {
    @Environment(POSModel.self) private var model
    let member: Member

    var body: some View {
        let items = model.catalog.items.filter { ($0.itemKind == .pass || $0.itemKind == .storedValue) && model.isAvailable($0) }
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text("菜單上還沒有會籍、課程卡或儲值（到後台菜單把品項種類設成「課程卡／會籍」）")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(items) { item in
                    DockChoice(title: item.name,
                               detail: item.pass?.summary ?? item.itemKind.label,
                               trailing: item.openPrice ? "自訂金額" : item.price.formatted) {
                        Task { await model.sell(item, to: member.ref) }
                    }
                }
            }
        }
    }
}

// MARK: - 今天的報到（右欄：即時動態）

private struct CheckInFeed: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 取消報到要主管 PIN（會用到右側鍵盤）：好了以後重新開始問會員號碼
    let onVoided: () -> Void

    @State private var confirming: CheckIn?

    private var desk: CheckInDesk { CheckInDesk.shared }

    var body: some View {
        let list = model.state.checkIns(businessDate: model.businessDate, cutoffHour: model.store.businessDayCutoffHour)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                LiveDot()
                Eyebrow("今天報到")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(list.count)")
                    .font(.brand(56, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(value: Double(list.count)))
                Text("人次")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            CheckInHourBars(times: list.map { $0.at })
            Rule()
            if list.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: -8) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Theme.press)
                                .frame(width: 32, height: 32)
                                .overlay { Circle().strokeBorder(Theme.page, lineWidth: 2) }
                                .opacity(1 - Double(i) * 0.25)
                        }
                    }
                    Text("今天還沒有人報到")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                Spacer(minLength: 0)
            } else {
                // 每 30 秒更新「幾分鐘前」
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(list) { c in
                                row(c)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .animation(reduceMotion ? nil : Motion.spring, value: list.first?.id)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface.opacity(0.6), in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        // 選起來的那一筆：右欄可以取消報到（要確認、要店長 PIN）
        .dockSelection(feedDock(list))
        .alert("取消這筆報到？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { c in
            Button("取消報到", role: .destructive) {
                desk.feedId = nil
                Task {
                    _ = await model.voidCheckIn(c, reason: "櫃台取消")
                    onVoided()
                }
            }
            Button("返回", role: .cancel) {}
        } message: { c in
            Text(voidMessage(c))
        }
    }

    private func voidMessage(_ c: CheckIn) -> String {
        let who = c.member.name ?? c.member.maskedPhone
        let back = c.uses > 0 ? "・扣掉的 \(c.uses) 次會還回去" : ""
        return "\(who) \(c.at.clockText)\(back)。要店長輸入 PIN。"
    }

    private func feedDock(_ list: [CheckIn]) -> DockSelection? {
        guard let id = desk.feedId, let c = list.first(where: { $0.id == id }) else { return nil }
        var info = "\(c.at.clockText) 入場・\(detail(c))"
        if c.uses > 0 { info += "・扣了 \(c.uses) 次" }
        return DockSelection(
            id: "checkin-feed-\(c.id)",
            kind: "報到紀錄",
            title: c.member.name ?? c.member.maskedPhone,
            detail: info,
            badge: DockBadge("已入場", tone: .active),
            actions: [POSAction("取消報到", icon: "arrow-uturn-left", destructive: true) { confirming = c }],
            clear: { select(nil) }
        )
    }

    /// 選一筆：鍵盤先不等下一位（右欄才看得到它的動作）；再點一次取消
    private func select(_ c: CheckIn?) {
        let next = c?.id == desk.feedId ? nil : c?.id
        if next != nil, model.keypad.request?.spec == KeypadSpec.memberCode { model.keypad.cancel() }
        withAnimation(reduceMotion ? nil : Motion.fast) { desk.feedId = next }
    }

    private func row(_ c: CheckIn) -> some View {
        let selected = desk.feedId == c.id
        return Button {
            select(c)
        } label: {
            rowBody(c, selected: selected)
        }
        .buttonStyle(.press)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("點一下選起來，右邊可以取消報到")
    }

    private func rowBody(_ c: CheckIn, selected: Bool) -> some View {
        let name = c.member.name ?? c.member.maskedPhone
        return HStack(spacing: 12) {
            CheckInAvatar(name: name, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.brand(15, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(detail(c))
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(c.at.relativeText)
                    .font(.brand(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                if c.uses > 0 {
                    Text("−\(c.uses) 次")
                        .font(.brand(11.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(selected ? Theme.accentSoft : Color.clear, in: .rect(cornerRadius: Metric.radius))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
        .contentShape(.rect)
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
                        .frame(height: max(CGFloat(n) / CGFloat(top) * 48, 2))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 48, alignment: .bottom)
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
        return VStack(alignment: .leading, spacing: 20) {
            if sessions.isEmpty {
                CheckInNoClasses()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(sessions) { s in
                                Button {
                                    withAnimation(reduceMotion ? nil : Motion.spring) { desk.sessionId = s.id }
                                } label: {
                                    CheckInClassCard(session: s, coach: model.staffMember(s.staffId), now: now, selected: selected?.id == s.id)
                                }
                                .buttonStyle(PressScale(scale: 0.97))
                                .id(s.id)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear {
                        if let id = selected?.id { proxy.scrollTo(id, anchor: .leading) }
                    }
                }
                if let s = selected {
                    CheckInRoster(session: s, now: now)
                        .id(s.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// 今天沒有課
private struct CheckInNoClasses: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                        .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: 92, height: 120)
                        .opacity(1 - Double(i) * 0.25)
                }
            }
            Headline("No classes *today*", role: .h3)
            Text("課表在後台「門市 POS → 課表」排；排好這裡會一堂一張卡。")
                .textRole(.body)
                .foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 一堂課：時間大字、課名、教練頭像、教室、名額圈
private struct CheckInClassCard: View {
    let session: ClassSession
    let coach: StaffMember?
    let now: Date
    let selected: Bool

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.startsAt.clockText)
                        .font(.brand(30, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text("到 \(s.endsAt.clockText)")
                        .font(.brand(12.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                CheckInCapacityRing(booked: s.booked, capacity: s.capacity, size: 58)
            }
            Text(s.name)
                .font(.brand(19, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            HStack(spacing: 8) {
                if let c = coach {
                    StaffAvatar(name: c.name, swatch: c.swatch, size: 24)
                    Text(c.name)
                        .font(.brand(13, .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                if let room = s.room {
                    Text(room)
                        .font(.brand(12, .medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let tag = timing {
                StatusBadge(tag.text, tone: tag.tone)
            }
        }
        .padding(16)
        .frame(width: 236, height: 196, alignment: .topLeading)
        .background(selected ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1)
        }
        .opacity(now >= s.endsAt ? 0.55 : 1)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var timing: (text: String, tone: Tone)? {
        let s = session
        if now >= s.endsAt { return ("已結束", .neutral) }
        if now >= s.startsAt { return ("上課中", .active) }
        let m = Int(s.startsAt.timeIntervalSince(now) / 60)
        if m <= 60 { return ("\(m) 分鐘後開始", .gold) }
        if s.isFull { return ("額滿", .warning) }
        return nil
    }
}

/// 名額圈：12 / 20（額滿是橘色、不限名額只寫人數）
private struct CheckInCapacityRing: View {
    let booked: Int
    let capacity: Int
    var size: CGFloat = 58

    var body: some View {
        let full = capacity > 0 && booked >= capacity
        let fraction = capacity > 0 ? min(Double(booked) / Double(capacity), 1) : 0
        ZStack {
            Circle()
                .stroke(Theme.press, lineWidth: 6)
            if capacity > 0 {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.001))
                    .stroke(full ? Theme.accent : Theme.successFG, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text("\(booked)")
                    .font(.brand(size * 0.3, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(full ? Theme.accentText : Theme.ink)
                Text(capacity > 0 ? "/\(capacity)" : "人")
                    .font(.brand(size * 0.17, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(capacity > 0 ? "報名 \(booked) 人，名額 \(capacity)" : "報名 \(booked) 人，不限名額")
    }
}

/// 一堂課的名單：一顆一顆頭像（點＝簽到；長按＝未到、取消）、報名、沒卡的收單堂
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
    @State private var confirming: CheckInRosterAction?
    /// 選起來的那一位（動作在右欄：大鍵「簽到」）
    @State private var selectedId: String?

    var body: some View {
        let roster = model.roster(of: session)
        VStack(alignment: .leading, spacing: 18) {
            header(roster)
            if let phone = pendingPhone {
                pendingRow(phone)
            }
            if roster.isEmpty {
                VStack(spacing: 12) {
                    HStack(spacing: -10) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle()
                                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .frame(width: 52, height: 52)
                                .background(Theme.page, in: .circle)
                                .opacity(1 - Double(i) * 0.2)
                        }
                    }
                    Text("還沒有人報名")
                        .textRole(.h4)
                        .foregroundStyle(Theme.ink2)
                    Text("右邊「報名」用電話幫客人報名；沒報名的按「現場單堂」。")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    FlowLayout(spacing: 12, rowSpacing: 14) {
                        ForEach(roster) { r in
                            chip(r)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(20)
        .background(Theme.surface.opacity(0.6), in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .dockSelection(dock(roster))
        .onAppear {
            // 截圖：先選名單上的第一位
            if LaunchArguments.preselect, selectedId == nil { selectedId = roster.first(where: { $0.status.isActive })?.id ?? roster.first?.id }
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

    private var anim: Animation? { reduceMotion ? nil : Motion.spring }

    private var confirmTitle: String {
        guard let c = confirming else { return "" }
        return c.status == .cancelled ? "取消 \(c.reservation.name) 的報名？" : "\(c.reservation.name) 沒有來？"
    }

    // MARK: 上面

    private func header(_ roster: [Reservation]) -> some View {
        let s = session
        let arrived = roster.filter { $0.status == .seated || $0.status == .arrived }.count
        return HStack(alignment: .center, spacing: 16) {
            CheckInCapacityRing(booked: s.booked, capacity: s.capacity, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Headline(s.name, role: .h3)
                    .lineLimit(1)
                Text(headerDetail)
                    .textRole(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                HStack(spacing: 12) {
                    Text("已簽到 \(arrived)／\(roster.count)")
                        .font(.brand(13.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.successFG)
                    if let note = s.note, !note.isEmpty {
                        Text("※ \(note)")
                            .textRole(.xs)
                            .foregroundStyle(Theme.warningFG)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
        }
    }

    // MARK: 右欄

    /// 選了一位：大鍵「簽到」（沒卡＝收單堂）；沒選：這一堂的動作（報名、現場單堂）
    private func dock(_ roster: [Reservation]) -> DockSelection? {
        if let phone = pendingPhone {
            return DockSelection(
                id: "roster-join-\(phone)", kind: "報名", title: MemberRef(phone: phone).maskedPhone,
                detail: "還不是會員：左邊填名字，加入會員並報名 \(session.name)",
                primary: POSAction("加入並報名", icon: "user") { Task { await joinAndBook(phone) } },
                actions: [POSAction("不報了", icon: "x-mark", destructive: true) { cancelPending() }],
                clear: { cancelPending() }
            )
        }
        guard let id = selectedId, let r = roster.first(where: { $0.id == id }) else {
            return DockSelection.page("roster-\(session.id)",
                         primary: POSAction("報名", icon: "plus") { Task { await book() } },
                         actions: [POSAction("現場單堂", icon: "user") { Task { await walkInDropIn() } }])
        }
        let member = r.memberId.flatMap { model.members[$0] }
        let account = member.flatMap { model.account(for: $0.ref) }
        let pass = account.flatMap { model.classPass(for: $0, session: session, at: now) }
        let busy = busyId == r.id
        var detail = "\(session.name) \(session.startsAt.clockText)・\(chipDetail(r, account: account, pass: pass))"
        var primary: POSAction?
        var actions: [POSAction] = []
        if r.status.isActive {
            if noPassId == r.id {
                // 沒有能抵這堂課的卡：收單堂、或請客人買卡
                detail = "\(session.name) \(session.startsAt.clockText)・沒有能抵這堂課的卡"
                primary = POSAction(session.dropInPrice.map { "收單堂 \($0.formatted)" } ?? "收單堂", icon: "credit-card") {
                    withAnimation(anim) { noPassId = nil }
                    Task { await model.dropIn(r, session: session, member: member) }
                }
                if let member {
                    actions.append(POSAction("買卡", icon: "credit-card") { openShop(member) })
                }
                actions.append(POSAction("再查一次卡", icon: "arrow-path", enabled: !busy) { Task { await signIn(r) } })
            } else {
                primary = POSAction(busy ? "簽到中…" : "簽到", icon: "check", enabled: !busy) { Task { await signIn(r) } }
            }
            actions.append(POSAction("未到", icon: "no-symbol", destructive: true) {
                confirming = CheckInRosterAction(reservation: r, status: .noShow)
            })
            actions.append(POSAction("取消報名", icon: "x-circle", destructive: true) {
                confirming = CheckInRosterAction(reservation: r, status: .cancelled)
            })
        } else if r.status == .noShow {
            actions.append(POSAction("改回已報名", icon: "arrow-uturn-left") { Task { await model.setStatus(.booked, for: r) } })
        }
        let tone: Tone
        switch r.status {
        case .booked, .notified: tone = .info
        case .arrived, .seated: tone = .active
        case .noShow: tone = .danger
        case .cancelled: tone = .neutral
        }
        return DockSelection(
            id: "roster-\(r.id)", kind: "上課", title: r.name, detail: detail,
            badge: DockBadge(r.status.label(for: .classBooking), tone: tone),
            primary: primary, actions: actions,
            clear: { select(nil) }
        )
    }

    private func select(_ r: Reservation?) {
        withAnimation(anim) {
            selectedId = r?.id == selectedId ? nil : r?.id
            noPassId = nil
        }
    }

    private func cancelPending() {
        withAnimation(anim) {
            pendingPhone = nil
            pendingName = ""
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

    // MARK: 一位（頭像）

    private func chip(_ r: Reservation) -> some View {
        let member = r.memberId.flatMap { model.members[$0] }
        let account = member.flatMap { model.account(for: $0.ref) }
        let pass = account.flatMap { model.classPass(for: $0, session: session, at: now) }
        let selected = selectedId == r.id
        return Button {
            select(r)
        } label: {
            CheckInRosterChip(reservation: r, passText: chipDetail(r, account: account, pass: pass), busy: busyId == r.id, selected: selected)
        }
        .buttonStyle(PressScale(scale: 0.95))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("點一下選起來，右邊簽到")
    }

    private func chipDetail(_ r: Reservation, account: MemberAccount?, pass: MemberPass?) -> String {
        if r.status == .seated, let c = signedIn(r) {
            return "\(c.at.clockText) 簽到"
        }
        if r.status == .noShow { return "未到" }
        if let pass {
            if pass.spec.kind == .visits { return "剩 \(pass.remaining ?? 0) 堂" }
            return "會籍"
        }
        if account != nil { return "沒有卡" }
        return r.memberId == nil ? "非會員" : "點一下選起來"
    }

    /// 這筆報名的簽到（這台最近兩天記得的）
    private func signedIn(_ r: Reservation) -> CheckIn? {
        model.state.checkIns.values.first { $0.reservationId == r.id && !$0.isVoided }
    }

    // MARK: 報名中、查不到會員

    private func pendingRow(_ phone: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(MemberRef(phone: phone).maskedPhone) 還不是會員：填名字，加入會員並報名")
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
            // 名字在這裡打；「加入並報名」是右欄的大鍵
            TextField("名字", text: $pendingName)
                .font(.brand(17, .medium))
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
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
            // 右欄換成「收單堂／買卡」
            withAnimation(anim) {
                selectedId = r.id
                noPassId = r.id
            }
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

private struct CheckInRosterAction: Identifiable {
    let reservation: Reservation
    let status: ReservationStatus
    var id: String { reservation.id + status.rawValue }
}

/// 名單上的一位：頭像（狀態色的圈、簽到了有勾）、名字、一行小字
private struct CheckInRosterChip: View {
    let reservation: Reservation
    let passText: String
    let busy: Bool
    var selected = false

    var body: some View {
        let r = reservation
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CheckInAvatar(name: r.name, size: 56)
                    .overlay {
                        Circle()
                            .strokeBorder(ringColor, lineWidth: r.status == .booked || r.status == .notified ? 1.5 : 3)
                            .padding(-4)
                    }
                    .opacity(r.status == .noShow ? 0.45 : 1)
                if r.status == .seated || r.status == .arrived {
                    ZStack {
                        Circle().fill(Theme.successFG)
                        HeroIcon("check", size: 11)
                            .foregroundStyle(Theme.page)
                    }
                    .frame(width: 20, height: 20)
                    .overlay { Circle().strokeBorder(Theme.surface, lineWidth: 2) }
                    .offset(x: 4, y: 4)
                }
                if busy {
                    ProgressView()
                        .frame(width: 56, height: 56)
                }
            }
            .frame(width: 64, height: 64)
            Text(r.name)
                .font(.brand(13.5, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(passText)
                .font(.brand(11, .medium))
                .monospacedDigit()
                .foregroundStyle(detailColor)
                .lineLimit(1)
        }
        .frame(width: 88)
        .padding(.vertical, 6)
        .background(selected ? Theme.accentSoft : Color.clear, in: .rect(cornerRadius: Metric.radius))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.name)，\(r.status.label(for: .classBooking))，\(passText)")
    }

    private var ringColor: Color {
        switch reservation.status {
        case .booked, .notified: Theme.line
        case .arrived, .seated: Theme.successFG
        case .noShow: Theme.dangerFG
        case .cancelled: Theme.faint
        }
    }

    private var detailColor: Color {
        switch reservation.status {
        case .seated, .arrived: Theme.successFG
        case .noShow: Theme.dangerFG
        case .booked, .notified, .cancelled: passText == "沒有卡" ? Theme.warningFG : Theme.muted
        }
    }
}
