import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 一位會員的資料卡：大頭像與名字、等級與壽星、累積消費；今天的預約與開著的單；
/// 儲值金（大數字）、課程卡與會籍（圓環卡片）；備註卡（美業的配方、健身的身體狀況）；來店時間軸。
///
/// 左邊選、右邊做（docs/DESIGN.md）：這裡只有看的與要打字的（名字、備註），動作都在右欄——
/// 最下面的大鍵「開單」（已經有單就「繼續 A0xx」），上面的動作鍵：儲值、預約或報到、買卡／續約（面板）、改名字、改生日、重新查。
/// 儲值、生日在右側鍵盤打（儲值方案是鍵盤上的快速鍵）；右欄的 × 取消選取。
///
/// 後台是真的資料：打開時先顯示這台記得的，同時向後台重查一次。儲值、買卡都是開一張這位會員的單、直接結帳。
struct MembersProfile: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let focus: MembersFocus
    /// 窄的工作區（直的 iPad）：資料卡佔滿（右欄的 × 回到名單）
    var compact = false
    var onClose: () -> Void

    enum Phase: Equatable {
        case loading
        case fresh(Date)
        case offline(String)
        case notFound
        case failed(String)
    }

    enum Field: Hashable { case name, note, enroll }

    @State private var phase: Phase = .loading
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var noteDraft = ""
    @State private var loadedName: String? = nil
    @State private var loadedNote: String? = nil
    @State private var savingName = false
    @State private var savingNote = false
    /// 頭上的提醒（名字、生日存不進後台）
    @State private var headerProblem: String? = nil
    @State private var noteProblem: String? = nil
    @State private var noteSavedAt: Date? = nil
    @State private var enrollName = ""
    @State private var enrolling = false
    @State private var enrollProblem: String? = nil
    /// 右欄的「買卡／續約」面板
    @State private var choosingPass = false
    @FocusState private var editing: Field?

    private var vocab: MembersVocabulary { MembersVocabulary(mode: model.mode) }
    private var anim: Animation? { reduceMotion ? nil : Motion.ease }

    /// 這台記得的這位會員（後台查到就換成新的）
    private var member: Member? {
        if let id = focus.ref?.id, let m = model.members[id] { return m }
        return model.rememberedMember(phone: focus.phone)
    }

    var body: some View {
        Group {
            if let m = member {
                card(m)
            } else {
                switch phase {
                case .notFound: notFound
                case .failed(let why): failed(why)
                case .loading, .fresh, .offline: loading
                }
            }
        }
        .dockSelection(dock)
        .dockPanel(isPresented: $choosingPass, title: vocab.buyPass, subtitle: member.map { $0.name ?? $0.ref.maskedPhone }) {
            passChoices
        }
        .task(id: focus.token) { await refresh() }
        .onChange(of: member) { _, m in sync(m) }
    }

    // MARK: - 資料卡

    private func card(_ m: Member) -> some View {
        let now = Date()
        let account = model.account(for: m.ref)
        let problem = entryProblem(account, now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero(m, now: now)
                    .reveal(0)
                if let problem {
                    Banner(text: problem, tone: .warning)
                }
                today(m)
                if let account {
                    accountSection(m, account: account, now: now)
                        .reveal(1)
                }
                noteCard(m)
                    .reveal(2)
                history(m)
                    .reveal(3)
            }
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: 頭

    private func hero(_ m: Member, now: Date) -> some View {
        let open = model.openTickets(for: m)
        // 在店裡：單子開著，或預約已到店
        let inStore = !open.isEmpty || model.memberBookings(for: m).contains { $0.status == .arrived }
        return VStack(alignment: .leading, spacing: 20) {
            heroIdentity(m, now: now, inStore: inStore)
            stats(m, now: now)
        }
        .padding(compact ? 20 : 24)
        .background { heroBackground(seed: m.id) }
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
        }
        .animation(anim, value: editingName)
    }

    /// 大頭像、等級、壽星、名字、電話與同步狀態（沒有按鈕；改名字在「⋯」）
    private func heroIdentity(_ m: Member, now: Date, inStore: Bool) -> some View {
        let display = (m.name?.isEmpty ?? true) ? m.ref.maskedPhone : (m.name ?? "")
        return HStack(alignment: .top, spacing: compact ? 16 : 20) {
            MembersAvatar(name: display, seed: m.id, photoURL: m.photoURL, size: compact ? 72 : 96, inStore: inStore)
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8, rowSpacing: 6) {
                    if let tier = m.tierName { MembersTierTag(tier: tier) }
                    if POSModel.isBirthdayMonth(m.birthday, now: now), let b = POSModel.birthdayText(m.birthday) {
                        MembersBirthdayBadge(text: "本月壽星 \(b)")
                    }
                    if inStore { StatusBadge("在店裡", tone: .gold) }
                }
                if editingName {
                    nameEditor(m)
                } else {
                    Text(display)
                        .font(.brand(compact ? 26 : 32, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(m.ref.maskedPhone)
                    .font(.brand(14, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                syncStatus
                if let headerProblem {
                    Text(headerProblem)
                        .textRole(.xs)
                        .foregroundStyle(Theme.warningFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 改名字（右欄「改名字」打開）：一格字；存、取消在右欄（鍵盤上的「完成」也會存）
    private func nameEditor(_ m: Member) -> some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("輸入名字", text: $nameDraft)
                .font(.brand(compact ? 24 : 28, .medium))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .submitLabel(.done)
                .focused($editing, equals: .name)
                .onSubmit { Task { await saveName(m) } }
                .accessibilityLabel("會員名字")
            if savingName { ProgressView().controlSize(.small) }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.accent).frame(height: 1.5)
        }
    }

    /// 頭的底：紙色卡片，角落暈開這位會員的顏色（放在 overlay：不會把底撐得比卡片大）
    private func heroBackground(seed: String) -> some View {
        Theme.surface
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Theme.swatch(MembersStyle.swatch(for: seed)).opacity(0.55))
                    .frame(width: 340, height: 340)
                    .blur(radius: 90)
                    .offset(x: -110, y: -160)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Theme.accent.opacity(0.06))
                    .frame(width: 260, height: 260)
                    .blur(radius: 70)
                    .offset(x: 80, y: 90)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous))
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch phase {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("向後台更新中…")
            }
            .font(.brand(12.5, .medium))
            .foregroundStyle(Theme.muted)
        case .fresh(let at):
            HStack(spacing: 6) {
                Circle().fill(Theme.live).frame(width: 6, height: 6)
                Text("後台的資料・\(at.clockText) 更新")
            }
            .font(.brand(12.5, .medium))
            .foregroundStyle(Theme.muted)
        case .offline(let why):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Theme.warningFG).frame(width: 6, height: 6)
                Text("這台記得的資料：\(why)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.brand(12.5, .medium))
            .foregroundStyle(Theme.warningFG)
        case .notFound, .failed:
            EmptyView()
        }
    }

    // MARK: - 右欄（選起來的這一位：所有動作都在這裡）

    /// 右欄的卡片與動作：看是資料卡、查不到、查詢中、出錯
    private var dock: DockSelection {
        let masked = MemberRef(phone: focus.phone).maskedPhone
        if let m = member { return memberDock(m) }
        switch phase {
        case .notFound:
            return DockSelection(id: "member-new-\(focus.phone)", kind: "新會員", title: Self.groupedPhone(focus.phone), detail: "還不是會員：稱呼可以在左邊先填",
                                 primary: POSAction(enrolling ? "加入中…" : "加入會員", icon: "plus", enabled: !enrolling) { Task { await enroll() } },
                                 accent: true, clear: { onClose() })
        case .failed(let why):
            return DockSelection(id: "member-failed-\(focus.phone)", kind: "會員", title: masked, detail: why,
                                 badge: DockBadge("查不到", tone: .danger),
                                 primary: POSAction("再試一次", icon: "arrow-path") { Task { await refresh() } }, accent: false,
                                 clear: { onClose() })
        case .loading, .fresh, .offline:
            return DockSelection(id: "member-loading-\(focus.phone)", kind: "會員", title: focus.ref?.name ?? masked,
                                 detail: "向後台查 \(masked)…", clear: { onClose() })
        }
    }

    private func memberDock(_ m: Member) -> DockSelection {
        let now = Date()
        let account = model.account(for: m.ref)
        let open = model.openTickets(for: m)
        let name = (m.name?.isEmpty ?? true) ? m.ref.maskedPhone : (m.name ?? "")

        var detail = [m.ref.maskedPhone]
        if let tier = m.tierName { detail.append(tier) }
        if let account, m.wallet != nil || account.wallet.cents != 0 { detail.append("儲值金 \(account.wallet.formatted)") }
        let usable = account?.usablePasses(at: now).count ?? 0
        if usable > 0 { detail.append("\(usable) 張卡能用") }

        var badge: DockBadge? = nil
        if !open.isEmpty || model.memberBookings(for: m).contains(where: { $0.status == .arrived }) {
            badge = DockBadge("在店裡", tone: .gold)
        } else if POSModel.isBirthdayMonth(m.birthday, now: now) {
            badge = DockBadge("本月壽星", tone: .gold)
        }

        // 改名字的時候：大鍵是「存名字」，動作只有「取消」
        if editingName {
            return DockSelection(id: "member-\(m.id)-name", kind: "改名字", title: name, detail: "在左邊改，按「存名字」（或鍵盤上的完成）",
                                 primary: POSAction(savingName ? "存名字中…" : "存名字", icon: "check", enabled: !savingName) { Task { await saveName(m) } },
                                 actions: [POSAction("取消改名字", icon: "x-mark") { cancelNameEdit() }],
                                 clear: { cancelNameEdit() })
        }

        var actions: [POSAction] = []
        if account != nil, !model.memberProducts(.storedValue).isEmpty {
            actions.append(POSAction("儲值", icon: "banknotes") { topUp(m) })
        }
        if model.mode.usesCheckIn && model.visibleSections.contains(.checkIn) {
            actions.append(POSAction("報到", icon: "qr-code") { model.go(.checkIn) })
        }
        if model.visibleSections.contains(.appointments) {
            actions.append(POSAction(vocab.book, icon: "calendar") { model.go(.appointments) })
        }
        let passItems = account == nil ? [] : model.memberProducts(.pass)
        if passItems.count == 1, let item = passItems.first {
            let renew = account.map { renewableNames(m, account: $0, now: now).contains(item.name) } ?? false
            actions.append(POSAction(renew ? "續約\(item.name)" : "買\(item.name)", icon: "ticket") { sell(item, to: m) })
        } else if passItems.count > 1 {
            actions.append(POSAction(vocab.buyPass, icon: "ticket") { choosingPass = true })
        }
        actions.append(POSAction("改名字", icon: "pencil-square") { startNameEdit() })
        actions.append(POSAction("改生日", icon: "cake") { editBirthday(m) })
        actions.append(POSAction("重新查", icon: "arrow-path") { Task { await refresh() } })
        for t in open.dropLast() {
            actions.append(POSAction("打開 \(t.number)", icon: "queue-list") { model.openExistingTicket(t) })
        }

        let primary = POSAction(open.last.map { "繼續 \($0.number)" } ?? "開單", icon: open.isEmpty ? "plus" : "queue-list") {
            model.openMemberTicket(m)
        }
        return DockSelection(id: "member-\(m.id)", kind: "會員", title: name, detail: detail.joined(separator: "・"), badge: badge,
                             primary: primary, accent: true, actions: actions, clear: { onClose() })
    }

    /// 右欄的「買卡／續約」面板：快到期、過期、用完的那幾種排前面（續約、再買一張），其他照菜單
    @ViewBuilder
    private var passChoices: some View {
        if let m = member, let account = model.account(for: m.ref) {
            let now = Date()
            let renewable = renewableNames(m, account: account, now: now)
            let items = model.memberProducts(.pass)
            let ordered = items.filter { renewable.contains($0.name) } + items.filter { !renewable.contains($0.name) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ordered) { item in
                    DockChoice(title: item.name, detail: choiceDetail(item, m: m, renewable: renewable), trailing: item.price.short) {
                        choosingPass = false
                        sell(item, to: m)
                    }
                }
            }
        }
    }

    private func choiceDetail(_ item: MenuItem, m: Member, renewable: Set<String>) -> String {
        if let start = model.renewalStart(of: item, for: m) {
            return "續約・接在 \(MembersStyle.monthDay(start)) 後"
        }
        if renewable.contains(item.name) {
            return item.pass?.kind == .period ? "續約・今天開始" : "再買一張・上一張快用完或過期了"
        }
        return item.pass?.summary ?? item.itemKind.label
    }

    /// 該續約、再買的卡（快到期、過期、用完；同一種還有沒快到期的或還沒開始的就不算）
    private func renewableNames(_ m: Member, account: MemberAccount, now: Date) -> Set<String> {
        let byName = Dictionary(grouping: account.passes.filter { $0.status != .cancelled }, by: \.name)
        var out = Set<String>()
        for (name, group) in byName {
            let covered = group.contains { p in
                let s = MembersStyle.state(of: p, at: now)
                return s == .active || s == .upcoming
            }
            if !covered { out.insert(name) }
        }
        return out
    }

    /// 0912 345 678
    static func groupedPhone(_ phone: String) -> String {
        let d = phone.filter(\.isNumber)
        guard d.count == 10 else { return phone }
        return "\(d.prefix(4)) \(d.dropFirst(4).prefix(3)) \(d.suffix(3))"
    }

    // MARK: 數字

    private func stats(_ m: Member, now: Date) -> some View {
        // 夠寬一排四格；不夠就兩排（數字不縮到看不清楚）
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                spendStat(m)
                statDivider
                visitsStat(m)
                statDivider
                lastSeenStat(m, now: now)
                statDivider
                birthdayStat(m, now: now)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 0) {
                    spendStat(m)
                    statDivider
                    visitsStat(m)
                }
                HStack(alignment: .top, spacing: 0) {
                    lastSeenStat(m, now: now)
                    statDivider
                    birthdayStat(m, now: now)
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rule() }
        .overlay(alignment: .bottom) { Rule() }
    }

    private func spendStat(_ m: Member) -> some View {
        stat("累積消費") {
            MoneyText(money: m.lifetimeSpend, role: .number)
                .fixedSize()
        }
    }

    private func visitsStat(_ m: Member) -> some View {
        stat("來店") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(m.visits)").textRole(.number)
                Text("次").font(.brand(13, .medium)).foregroundStyle(Theme.muted)
            }
            .fixedSize()
        }
    }

    private func lastSeenStat(_ m: Member, now: Date) -> some View {
        stat("上次來") {
            Text(lastSeenText(m, now: now))
                .font(.brand(22, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func birthdayStat(_ m: Member, now: Date) -> some View {
        stat("生日") {
            Text(POSModel.birthdayText(m.birthday) ?? "—")
                .font(.brand(22, .medium))
                .monospacedDigit()
                .foregroundStyle(POSModel.isBirthdayMonth(m.birthday, now: now) ? Theme.accentText : Theme.ink)
                .fixedSize()
        }
    }

    private func stat<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.brand(12, .medium))
                .foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statDivider: some View {
        Rule(vertical: true)
            .frame(height: 44)
            .padding(.horizontal, 14)
    }

    /// 上次來店：後台的、這台今天的、最近幾次裡最新的
    private func lastSeenText(_ m: Member, now: Date) -> String {
        var latest = m.lastVisitAt
        if let local = model.memberHistory(for: m).first?.at, local > (latest ?? .distantPast) { latest = local }
        if let c = model.state.lastCheckIn(memberId: m.id)?.at, c > (latest ?? .distantPast) { latest = c }
        guard let d = latest else { return "—" }
        if Calendar.taipei.isDateInToday(d) { return "今天" }
        if Calendar.taipei.isDateInYesterday(d) { return "昨天" }
        let days = Int(now.timeIntervalSince(d) / 86_400)
        return days < 60 ? "\(max(days, 1)) 天前" : MembersStyle.monthDay(d)
    }

    // MARK: 今天（只是狀態：開單、報到在動作列）

    @ViewBuilder
    private func today(_ m: Member) -> some View {
        let bookings = model.memberBookings(for: m)
        let open = model.openTickets(for: m)
        let checkIn = todaysCheckIn(m)
        if !bookings.isEmpty || !open.isEmpty || checkIn != nil {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("今天")
                FlowLayout(spacing: 8, rowSpacing: 8) {
                    ForEach(bookings) { r in
                        let paid = r.ticketId.flatMap { model.state.tickets[$0] }?.status == .closed
                        todayChip(icon: r.kind == .classBooking ? "user-group" : "calendar", text: model.bookingSummary(r),
                                  badge: paid ? "已結帳" : r.status.label(for: r.kind), tone: paid ? .neutral : bookingTone(r.status))
                    }
                    ForEach(open) { t in
                        todayChip(icon: "queue-list", text: "單子 \(t.number)・\(t.totals.total.formatted)", badge: "開著", tone: .gold)
                    }
                    if let c = checkIn {
                        todayChip(icon: "qr-code", text: "\(c.at.clockText) 報到・\(c.passName ?? "單次入場")", badge: nil, tone: .active)
                    }
                }
            }
        }
    }

    private func todayChip(icon: String, text: String, badge: String?, tone: Tone) -> some View {
        HStack(spacing: 10) {
            HeroIcon(icon, size: 16)
                .foregroundStyle(tone.foreground)
            Text(text)
                .font(.brand(14, .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let badge { StatusBadge(badge, tone: tone) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
        .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
        .accessibilityElement(children: .combine)
    }

    private func bookingTone(_ s: ReservationStatus) -> Tone {
        switch s {
        case .booked, .notified: .info
        case .arrived: .gold
        case .seated: .active
        case .cancelled: .neutral
        case .noShow: .danger
        }
    }

    private func todaysCheckIn(_ m: Member) -> CheckIn? {
        guard let c = model.state.lastCheckIn(memberId: m.id) else { return nil }
        return TaipeiTime.businessDate(c.at, cutoffHour: model.store.businessDayCutoffHour) == model.businessDate ? c : nil
    }

    /// 健身房：沒有能入場的卡（過期、用完）就提醒（續約在那張卡上）
    private func entryProblem(_ account: MemberAccount?, now: Date) -> String? {
        guard model.mode.usesCheckIn, let account, account.checkInPasses(at: now).isEmpty else { return nil }
        let entry = account.passes.filter { $0.spec.checkIn && $0.status != .cancelled }
        guard let latest = entry.max(by: { ($0.expiresAt ?? $0.startsAt) < ($1.expiresAt ?? $1.startsAt) }) else {
            return "還沒有會籍或課程卡：入場要先買卡（右邊的「\(vocab.buyPass)」），或收單次入場"
        }
        if let e = latest.expiresAt, e <= now {
            let days = max(1, Int((now.timeIntervalSince(e) / 86_400).rounded(.up)))
            return "\(latest.name)已經過期 \(days) 天，續約後才能入場"
        }
        if latest.spec.kind == .visits && (latest.remaining ?? 0) <= 0 {
            return "\(latest.name)用完了，再買才能入場"
        }
        return nil
    }

    // MARK: 儲值金、課程卡

    private func accountSection(_ m: Member, account: MemberAccount, now: Date) -> some View {
        let topUps = model.memberProducts(.storedValue)
        let showWallet = m.wallet != nil || account.wallet.cents != 0 || !topUps.isEmpty
        let passes = sortedPasses(account.passes, now: now)
        let pending = !model.state.pendingAccountMoves(memberId: m.id, excluding: Set(m.accountEventIds ?? [])).isEmpty
        return VStack(alignment: .leading, spacing: 22) {
            if showWallet {
                walletCard(wallet: account.wallet, plans: topUps, pending: pending)
            }
            if !passes.isEmpty {
                passesBlock(passes: passes, now: now)
            }
        }
    }

    /// 儲值金：深色的卡、大大的餘額（儲值在右欄；這裡寫店裡有哪些方案）
    private func walletCard(wallet: Money, plans: [MenuItem], pending: Bool) -> some View {
        let fixed = plans.filter { !$0.openPrice }.map(POSModel.planLabel)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Rectangle().fill(Theme.accent).frame(width: 6, height: 6)
                Text("儲值金")
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.inverseMuted)
            }
            // 深色的卡在淺色、深色模式都是深的：字一律用 onInverse（負的有「−」，紅字在深底上看不清楚）
            MoneyText(money: wallet, role: .stat, color: Theme.onInverse)
            Text(pending ? "含這台今天的儲值、扣款（同步後和後台一樣）" : "後台的餘額")
                .font(.brand(12, .regular))
                .foregroundStyle(Theme.inverseMuted)
            if !fixed.isEmpty {
                Text("儲值方案：" + fixed.joined(separator: "・"))
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.onInverse.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Theme.inverse
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Theme.accent.opacity(0.32))
                        .frame(width: 260, height: 260)
                        .blur(radius: 80)
                        .offset(x: 80, y: -120)
                }
                .overlay {
                    // 卡片上的細線（像一張實體的儲值卡）
                    RoundedRectangle(cornerRadius: Metric.radiusLg - 6, style: .continuous)
                        .strokeBorder(Theme.inverseLine, lineWidth: 1)
                        .padding(6)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func passesBlock(passes: [MemberPass], now: Date) -> some View {
        let usable = passes.filter { $0.isUsable(at: now) }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow(vocab.passesTitle)
                Text(usable > 0 ? "\(usable) 張能用" : "沒有能用的")
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(passes) { p in
                    MembersPassCard(pass: p, now: now)
                }
            }
        }
    }

    /// 能用的先（快到期的在前）、還沒開始的續約、最後是用完過期的（最近三張）
    private func sortedPasses(_ passes: [MemberPass], now: Date) -> [MemberPass] {
        let usable = passes.filter { $0.isUsable(at: now) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let upcoming = passes.filter { !$0.isUsable(at: now) && $0.status == .active && now < $0.startsAt }
            .sorted { $0.startsAt < $1.startsAt }
        let done = passes.filter { p in !usable.contains(p) && !upcoming.contains(p) }
            .sorted { ($0.expiresAt ?? $0.startsAt) > ($1.expiresAt ?? $1.startsAt) }
            .prefix(3)
        return usable + upcoming + Array(done)
    }

    // MARK: 備註（點一下就能改；改了才出現一個「存到後台」）

    private func noteCard(_ m: Member) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow(vocab.noteTitle)
                Spacer(minLength: 8)
                if noteDirty {
                    Button {
                        Task { await saveNote(m) }
                    } label: {
                        if savingNote { ProgressView().controlSize(.small) } else { Text("存到後台") }
                    }
                    .buttonStyle(.brand(.primary, size: .sm))
                    .disabled(savingNote)
                } else if let at = noteSavedAt {
                    Text("已存・\(at.clockText)")
                        .font(.brand(12, .medium))
                        .foregroundStyle(Theme.successFG)
                } else {
                    Text("點一下就能改")
                        .font(.brand(12, .medium))
                        .foregroundStyle(Theme.faint)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $noteDraft)
                    .font(.brand(17, .regular))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .focused($editing, equals: .note)
                    .frame(minHeight: 112)
                    .accessibilityLabel(vocab.noteTitle)
                if noteDraft.isEmpty {
                    Text(vocab.notePlaceholder)
                        .font(.brand(17, .regular))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            if let noteProblem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HeroIcon("information-circle", size: 14)
                    Text(noteProblem)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.brand(12.5, .medium))
                .foregroundStyle(Theme.warningFG)
            }
        }
        .padding(.vertical, 20)
        .padding(.leading, 24)
        .padding(.trailing, 20)
        .background {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous).fill(Theme.sheet)
        }
        .overlay(alignment: .topTrailing) {
            // 大大的引號：這一張是寫給下一次的自己看的
            Text("”")
                .font(.serif(88))
                .foregroundStyle(Theme.accent.opacity(0.16))
                .offset(x: -14, y: -18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 3)
                .padding(.vertical, 22)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(editing == .note ? Theme.focus : Theme.line, lineWidth: editing == .note ? 2 : 1)
        }
        .animation(anim, value: editing)
    }

    private var noteDirty: Bool {
        noteDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (loadedNote ?? "")
    }

    // MARK: 來店紀錄

    private func history(_ m: Member) -> some View {
        let entries = model.memberHistory(for: m).prefix(12).map(timelineItem)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(vocab.historyTitle)
                Spacer(minLength: 8)
                if !entries.isEmpty {
                    Text("最近 \(entries.count) 次")
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
            if entries.isEmpty {
                Text("還沒有消費紀錄")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                        MembersTimelineRow(entry: e, isLast: i == entries.count - 1)
                    }
                }
                .padding(compact ? 16 : 20)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
                .overlay { RoundedRectangle(cornerRadius: Metric.radiusLg).strokeBorder(Theme.line) }
            }
        }
    }

    private func timelineItem(_ e: MemberHistoryEntry) -> MembersTimelineItem {
        let people = e.staffNames.map { name in
            MembersTimelineItem.Person(name: name, swatch: model.staff.first { $0.name == name }?.swatch ?? MembersStyle.swatch(for: name))
        }
        var badges: [String] = []
        if e.redeemed > 0 { badges.append("扣卡 ×\(e.redeemed)") }
        if e.prepaid.cents > 0 { badges.append("儲值金 \(e.prepaid.short)") }
        if e.refunded.cents > 0 { badges.append("已退 \(e.refunded.short)") }
        let day: String
        if Calendar.taipei.isDateInToday(e.at) {
            day = "今天"
        } else if Calendar.taipei.isDateInYesterday(e.at) {
            day = "昨天"
        } else {
            day = e.at.weekdayText
        }
        return MembersTimelineItem(id: e.ticketId, at: e.at, dayLabel: day, number: e.number, total: e.total, items: e.items, staff: people,
                                   badges: badges, note: e.note, onThisDevice: e.onThisDevice)
    }

    // MARK: - 查不到、查詢中、出錯

    private var notFound: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.accentSoft)
                    HeroIcon("user", size: 30).foregroundStyle(Theme.accent)
                }
                .frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 6) {
                    Headline("A new *face*", role: .h3)
                    Text("\(MemberRef(phone: focus.phone).maskedPhone) 還不是會員")
                        .textRole(.body)
                        .foregroundStyle(Theme.ink2)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("當場加入")
                TextField("稱呼（可以之後再補）", text: $enrollName)
                    .font(.brand(18, .regular))
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(editing == .enroll ? Theme.focus : Theme.line, lineWidth: editing == .enroll ? 2 : 1)
                    }
                    .focused($editing, equals: .enroll)
                    .submitLabel(.join)
                    .onSubmit { Task { await enroll() } }
                Text("按右邊的「加入會員」；不加就按右上的 ×")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                if let enrollProblem {
                    Text(enrollProblem)
                        .textRole(.xs)
                        .foregroundStyle(Theme.dangerFG)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous).fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous).strokeBorder(Theme.line)
        }
        .padding(.bottom, 24)
        .reveal(0)
    }

    private var loading: some View {
        let name = focus.ref?.name ?? MemberRef(phone: focus.phone).maskedPhone
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                MembersAvatar(name: name, seed: focus.ref?.id ?? focus.phone, size: compact ? 72 : 96)
                VStack(alignment: .leading, spacing: 8) {
                    Text(name)
                        .font(.brand(compact ? 26 : 32, .medium))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("向後台查 \(MemberRef(phone: focus.phone).maskedPhone)…")
                            .textRole(.small)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            RoundedRectangle(cornerRadius: Metric.radius).fill(Theme.press).frame(height: 72)
            RoundedRectangle(cornerRadius: Metric.radius).fill(Theme.press).frame(height: 120)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(0.9)
    }

    /// 查不到（出錯）：「再試一次」在右欄
    private func failed(_ why: String) -> some View {
        EmptyState(icon: "exclamation-triangle", title: "查不到 \(MemberRef(phone: focus.phone).maskedPhone)", message: why)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 動作

    /// 打開就向後台重查（先顯示這台記得的）
    private func refresh() async {
        sync(member)
        phase = .loading
        switch await model.searchMember(phone: focus.phone) {
        case .found:
            phase = .fresh(Date())
        case .cached(_, let why):
            phase = .offline(why)
        case .notFound:
            phase = member == nil ? .notFound : .offline("後台查不到這支電話")
        case .failed(let why):
            phase = member == nil ? .failed(why) : .offline(why)
        }
    }

    /// 後台的資料換了：沒在改的欄位跟著換，正在改的不動
    private func sync(_ m: Member?) {
        guard let m else { return }
        let name = m.name ?? ""
        if !editingName { nameDraft = name }
        loadedName = name
        let note = m.note ?? ""
        if loadedNote == nil || noteDraft.trimmingCharacters(in: .whitespacesAndNewlines) == loadedNote { noteDraft = note }
        loadedNote = note
    }

    private func topUp(_ m: Member) {
        Task { await model.askTopUp(for: m) }
    }

    private func sell(_ item: MenuItem, to m: Member) {
        Task { await model.sellPass(item, to: m) }
    }

    private func editBirthday(_ m: Member) {
        Task { headerProblem = await model.askBirthday(for: m) }
    }

    private func startNameEdit() {
        headerProblem = nil
        nameDraft = loadedName ?? ""
        editingName = true
        editing = .name
    }

    private func cancelNameEdit() {
        nameDraft = loadedName ?? ""
        editingName = false
        editing = nil
    }

    private func saveName(_ m: Member) async {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (loadedName ?? "") else {
            cancelNameEdit()
            return
        }
        guard !savingName else { return }
        savingName = true
        let problem = await model.saveMemberName(trimmed, for: m)
        savingName = false
        headerProblem = problem
        if problem == nil {
            loadedName = trimmed
            nameDraft = trimmed
            editingName = false
            editing = nil
            model.show("名字改好了：\(trimmed)")
        }
    }

    private func saveNote(_ m: Member) async {
        guard noteDirty, !savingNote else { return }
        savingNote = true
        let problem = await model.saveMemberNote(noteDraft, for: m)
        savingNote = false
        noteProblem = problem
        if problem == nil {
            let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            loadedNote = trimmed
            noteDraft = trimmed
            noteSavedAt = Date()
            editing = nil
        }
    }

    private func enroll() async {
        guard !enrolling else { return }
        enrolling = true
        enrollProblem = nil
        let outcome = await model.enrollMember(phone: focus.phone, name: enrollName)
        enrolling = false
        switch outcome {
        case .found:
            editing = nil
            phase = .fresh(Date())
        case .failed(let why):
            enrollProblem = why
        case .cached, .notFound:
            break
        }
    }
}
