import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 一位會員的資料卡：大頭像與名字（直接改）、等級與壽星、累積消費；今天的預約與開著的單；
/// 儲值金（大數字＋儲值）、課程卡與會籍（圓環卡片＋買卡、續約）；備註卡（美業的配方、健身的身體狀況）；來店時間軸。
///
/// 後台是真的資料：打開時先顯示這台記得的，同時向後台重查一次。儲值、買卡都是開一張這位會員的單、直接結帳。
struct MembersProfile: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let focus: MembersFocus
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
    @State private var nameDraft = ""
    @State private var noteDraft = ""
    @State private var loadedName: String? = nil
    @State private var loadedNote: String? = nil
    @State private var savingName = false
    @State private var savingNote = false
    @State private var nameProblem: String? = nil
    @State private var noteProblem: String? = nil
    @State private var noteSavedAt: Date? = nil
    /// 正在選要賣的儲值或課程卡
    @State private var selling: ItemKind? = nil
    @State private var enrollName = ""
    @State private var enrolling = false
    @State private var enrollProblem: String? = nil
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
        .task(id: focus.token) { await refresh() }
        .onChange(of: member) { _, m in sync(m) }
    }

    // MARK: - 資料卡

    private func card(_ m: Member) -> some View {
        let now = Date()
        let account = model.account(for: m.ref)
        let problem = entryProblem(account, now: now)
        let renew: (label: String, run: () -> Void)? = model.memberProducts(.pass).isEmpty ? nil : (label: "續約", run: { toggle(.pass) })
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero(m, now: now)
                    .reveal(0)
                if let problem {
                    Banner(text: problem, tone: .warning, action: renew)
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
        // 在店裡：單子開著，或預約已到店（做完結帳的預約也是「服務中」狀態，不算）
        let inStore = !open.isEmpty || model.memberBookings(for: m).contains { $0.status == .arrived }
        return VStack(alignment: .leading, spacing: 22) {
            heroIdentity(m, now: now, inStore: inStore)
            stats(m, now: now)
            heroActions(m, open: open)
        }
        .padding(24)
        .background { heroBackground(seed: m.id) }
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
        }
    }

    /// 大頭像、等級、壽星、名字（直接改）、電話與同步狀態
    private func heroIdentity(_ m: Member, now: Date, inStore: Bool) -> some View {
        let display = (m.name?.isEmpty ?? true) ? m.ref.maskedPhone : (m.name ?? "")
        return HStack(alignment: .top, spacing: 20) {
            MembersAvatar(name: display, seed: m.id, photoURL: m.photoURL, size: 96, inStore: inStore)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let tier = m.tierName { MembersTierTag(tier: tier) }
                    if POSModel.isBirthdayMonth(m.birthday, now: now), let b = POSModel.birthdayText(m.birthday) {
                        MembersBirthdayBadge(text: "本月壽星 \(b)")
                    }
                    if inStore { StatusBadge("在店裡", tone: .gold) }
                }
                nameField(m)
                HStack(spacing: 12) {
                    Text(m.ref.maskedPhone)
                        .font(.brand(14, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                    syncStatus
                }
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                HeroIcon("x-mark", size: 15)
            }
            .buttonStyle(SquareIconButtonStyle(size: 36))
            .accessibilityLabel("關閉")
        }
    }

    /// 開單（已經有開著的單就接著點）、預約、報到
    private func heroActions(_ m: Member, open: [Ticket]) -> some View {
        HStack(spacing: 10) {
            Button {
                model.openMemberTicket(m)
            } label: {
                Label { Text(open.last.map { "接著點 \($0.number)" } ?? "開單") } icon: { HeroIcon("plus", size: 15) }
            }
            .buttonStyle(.brand(.primary, size: .md, arrow: true))
            if model.visibleSections.contains(.appointments) {
                Button {
                    model.go(.appointments)
                } label: {
                    Label { Text(vocab.book) } icon: { HeroIcon("calendar", size: 15) }
                }
                .buttonStyle(.brand(.ghost, size: .md))
            }
            if model.mode.usesCheckIn && model.visibleSections.contains(.checkIn) {
                Button {
                    model.go(.checkIn)
                } label: {
                    Label { Text("報到") } icon: { HeroIcon("qr-code", size: 15) }
                }
                .buttonStyle(.brand(.ghost, size: .md))
            }
        }
    }

    /// 頭的底：紙色卡片，左上角一團這位會員的顏色暈開
    private func heroBackground(seed: String) -> some View {
        // 暈開的色塊放在 overlay 裡：不會把底撐得比卡片大
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
    private func nameField(_ m: Member) -> some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("輸入名字", text: $nameDraft)
                .font(.brand(32, .medium))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .submitLabel(.done)
                .focused($editing, equals: .name)
                .onSubmit { Task { await saveName(m) } }
                .accessibilityLabel("會員名字")
            if nameDirty {
                Button {
                    Task { await saveName(m) }
                } label: {
                    if savingName { ProgressView().controlSize(.small) } else { HeroIcon("check", size: 16) }
                }
                .buttonStyle(SquareIconButtonStyle(size: 36))
                .accessibilityLabel("儲存名字")
                Button {
                    nameDraft = loadedName ?? ""
                    nameProblem = nil
                    editing = nil
                } label: {
                    HeroIcon("arrow-uturn-left", size: 14)
                }
                .buttonStyle(SquareIconButtonStyle(size: 36))
                .accessibilityLabel("還原名字")
            } else if editing != .name {
                HeroIcon("pencil-square", size: 16)
                    .foregroundStyle(Theme.faint)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(editing == .name ? Theme.accent : Color.clear)
                .frame(height: 1.5)
                .offset(y: 3)
        }
        if let nameProblem {
            Text(nameProblem)
                .textRole(.xs)
                .foregroundStyle(Theme.warningFG)
        }
    }

    private var nameDirty: Bool {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (loadedName ?? "")
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
            HStack(spacing: 6) {
                Circle().fill(Theme.warningFG).frame(width: 6, height: 6)
                Text("這台記得的資料：\(why)")
                    .lineLimit(1)
            }
            .font(.brand(12.5, .medium))
            .foregroundStyle(Theme.warningFG)
        case .notFound, .failed:
            EmptyView()
        }
    }

    // MARK: 數字

    private func stats(_ m: Member, now: Date) -> some View {
        HStack(alignment: .top, spacing: 0) {
            stat("累積消費") {
                MoneyText(money: m.lifetimeSpend, role: .number)
            }
            statDivider
            stat("來店") {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(m.visits)").textRole(.number)
                    Text("次").font(.brand(13, .medium)).foregroundStyle(Theme.muted)
                }
            }
            statDivider
            stat("上次來") {
                Text(lastSeenText(m, now: now))
                    .font(.brand(22, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            statDivider
            stat("生日") {
                Text(POSModel.birthdayText(m.birthday) ?? "—")
                    .font(.brand(22, .medium))
                    .monospacedDigit()
                    .foregroundStyle(POSModel.isBirthdayMonth(m.birthday, now: now) ? Theme.accentText : Theme.ink)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rule() }
        .overlay(alignment: .bottom) { Rule() }
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

    // MARK: 今天

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
                        Button {
                            model.openExistingTicket(t)
                        } label: {
                            todayChip(icon: "queue-list", text: "單子開著 \(t.number)・\(t.totals.total.formatted)", badge: "打開", tone: .gold)
                        }
                        .buttonStyle(.press)
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
                .lineLimit(1)
            if let badge { StatusBadge(badge, tone: tone) }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
        .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
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

    /// 健身房：沒有能入場的卡（過期、用完）就提醒
    private func entryProblem(_ account: MemberAccount?, now: Date) -> String? {
        guard model.mode.usesCheckIn, let account, account.checkInPasses(at: now).isEmpty else { return nil }
        let entry = account.passes.filter { $0.spec.checkIn && $0.status != .cancelled }
        guard let latest = entry.max(by: { ($0.expiresAt ?? $0.startsAt) < ($1.expiresAt ?? $1.startsAt) }) else {
            return "還沒有會籍或課程卡：入場要先買卡，或收單次入場"
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
        let passItems = model.memberProducts(.pass)
        let showWallet = m.wallet != nil || account.wallet.cents != 0 || !topUps.isEmpty
        let passes = sortedPasses(account.passes, now: now)
        let showPasses = !passes.isEmpty || !passItems.isEmpty
        let pending = !model.state.pendingAccountMoves(memberId: m.id, excluding: Set(m.accountEventIds ?? [])).isEmpty
        return VStack(alignment: .leading, spacing: 22) {
            if showWallet {
                walletCard(m, wallet: account.wallet, items: topUps, pending: pending)
            }
            if showPasses {
                passesBlock(m, passes: passes, items: passItems, now: now)
            }
        }
    }

    /// 儲值金：深色的卡、大大的餘額、品牌橘的「儲值」
    private func walletCard(_ m: Member, wallet: Money, items: [MenuItem], pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Rectangle().fill(Theme.accent).frame(width: 6, height: 6)
                        Text("儲值金")
                            .font(.brand(12.5, .medium))
                            .foregroundStyle(Theme.inverseMuted)
                    }
                    MoneyText(money: wallet, role: .stat, color: wallet.isNegative ? Theme.dangerFG : Theme.onInverse)
                    Text(pending ? "含這台今天的儲值、扣款（同步後和後台一樣）" : "後台的餘額")
                        .font(.brand(12, .regular))
                        .foregroundStyle(Theme.inverseMuted)
                }
                Spacer(minLength: 12)
                if !items.isEmpty {
                    Button {
                        toggle(.storedValue)
                    } label: {
                        Label { Text(selling == .storedValue ? "收起" : "儲值") } icon: {
                            HeroIcon(selling == .storedValue ? "chevron-down" : "plus", size: 15)
                        }
                    }
                    .buttonStyle(.brand(.accent, size: .md))
                }
            }
            if selling == .storedValue {
                VStack(alignment: .leading, spacing: 10) {
                    Text("選一個方案：開一張單、直接結帳")
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.inverseMuted)
                    sellChips(m, items: items, kind: .storedValue)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
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
        .animation(anim, value: selling)
    }

    private func passesBlock(_ m: Member, passes: [MemberPass], items: [MenuItem], now: Date) -> some View {
        let usable = passes.filter { $0.isUsable(at: now) }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow(vocab.passesTitle)
                Text(usable > 0 ? "\(usable) 張能用" : "沒有能用的")
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                if !items.isEmpty {
                    Button {
                        toggle(.pass)
                    } label: {
                        Label { Text(selling == .pass ? "收起" : vocab.buyPass) } icon: {
                            HeroIcon(selling == .pass ? "chevron-down" : "plus", size: 14)
                        }
                    }
                    .buttonStyle(.brand(.ghost, size: .sm))
                }
            }
            if selling == .pass {
                sellChips(m, items: items, kind: .pass)
                    .padding(14)
                    .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if passes.isEmpty {
                Text("還沒有\(vocab.passesTitle)")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 4)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(passes) { p in
                        MembersPassCard(pass: p, now: now)
                    }
                }
            }
        }
        .animation(anim, value: selling)
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

    private func sellChips(_ m: Member, items: [MenuItem], kind: ItemKind) -> some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(items) { item in
                OptionChip(title: item.openPrice ? "自訂金額" : item.name, detail: chipDetail(item, m), selected: false) {
                    selling = nil
                    Task {
                        if kind == .storedValue {
                            await model.sellTopUp(item, to: m)
                        } else {
                            await model.sellPass(item, to: m)
                        }
                    }
                }
            }
        }
    }

    private func chipDetail(_ item: MenuItem, _ m: Member) -> String {
        if item.openPrice { return "右邊鍵盤打金額" }
        if item.itemKind == .storedValue {
            if let credit = item.credit, credit > item.price { return "\(item.price.short) 入 \(credit.short)" }
            return item.price.short
        }
        if let start = model.renewalStart(of: item, for: m) {
            return "\(item.price.short)・接在 \(MembersStyle.monthDay(start)) 後"
        }
        return item.price.short
    }

    private func toggle(_ kind: ItemKind) {
        withAnimation(anim) { selling = selling == kind ? nil : kind }
    }

    // MARK: 備註

    private func noteCard(_ m: Member) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow(vocab.noteTitle)
                Spacer(minLength: 8)
                if noteDirty {
                    Button("還原") {
                        noteDraft = loadedNote ?? ""
                        noteProblem = nil
                        editing = nil
                    }
                    .buttonStyle(.brand(.quiet, size: .sm))
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
                HStack(spacing: 6) {
                    HeroIcon("information-circle", size: 14)
                    Text(noteProblem)
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
                .padding(20)
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
                HStack(spacing: 10) {
                    Button {
                        Task { await enroll() }
                    } label: {
                        if enrolling { ProgressView().controlSize(.small) } else { Text("加入會員") }
                    }
                    .buttonStyle(.brand(.accent, size: .lg, arrow: true))
                    .disabled(enrolling)
                    Button("不用了", action: onClose)
                        .buttonStyle(.brand(.quiet, size: .lg))
                }
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
                MembersAvatar(name: name, seed: focus.ref?.id ?? focus.phone, size: 96)
                VStack(alignment: .leading, spacing: 8) {
                    Text(name)
                        .font(.brand(32, .medium))
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

    private func failed(_ why: String) -> some View {
        VStack(spacing: 14) {
            EmptyState(icon: "exclamation-triangle", title: "查不到 \(MemberRef(phone: focus.phone).maskedPhone)", message: why)
                .frame(maxHeight: 220)
            Button("再試一次") {
                Task { await refresh() }
            }
            .buttonStyle(.brand(.ghost, size: .md))
        }
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
        if loadedName == nil || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == loadedName { nameDraft = name }
        loadedName = name
        let note = m.note ?? ""
        if loadedNote == nil || noteDraft.trimmingCharacters(in: .whitespacesAndNewlines) == loadedNote { noteDraft = note }
        loadedNote = note
    }

    private func saveName(_ m: Member) async {
        guard nameDirty else {
            editing = nil
            return
        }
        guard !savingName else { return }
        savingName = true
        let problem = await model.saveMemberName(nameDraft, for: m)
        savingName = false
        nameProblem = problem
        if problem == nil {
            let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            loadedName = trimmed
            nameDraft = trimmed
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
