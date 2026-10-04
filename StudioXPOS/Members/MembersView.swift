import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 會員頁（側欄「會員」）：左邊是今天的名單，右邊是一位會員的資料卡。
///
///   ┌ Your regulars ──────────────────────────────── ● 右邊的鍵盤：打手機號碼 ┐
///   │ ■ 今天預約                   │ (怡君)  陳怡君  金卡會員  🎂 本月壽星 10/18   [開單][預約] │
///   │  怡君 陳怡君  14:00 染髮…    │ 0911-***-333・已更新 14:05                              │
///   │ ■ 今天來過                   │ 累積消費 NT$48,600 │ 來店 31 次 │ 上次 35 天前          │
///   │  柏翰 黃柏翰  結帳 A004…     │ ┌ 儲值金 NT$5,400 [儲值] ┐ ┌(7) 剪髮 10 次卡 ┐          │
///   │ ■ 最近查過                   │ ■ 配方與偏好（可以直接改）                             │
///   │                              │ ■ 來店紀錄（時間軸：日期、項目、設計師、金額）         │
///   └──────────────────────────────────────────────────────────────────────────┘
///
/// 查會員用右側鍵盤（打電話、或掃會員條碼：掃描器打的數字會進鍵盤）；不用系統的 sheet，鍵盤一直看得到。
/// 後台是真的資料：打開一位就先顯示這台記得的，同時向後台重查一次（iPad 只留最近幾天的單）。
struct MembersView: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var focus: MembersFocus?
    /// 改這個就重新叫出右側鍵盤等電話
    @State private var armToken = 0

    var body: some View {
        let board = model.memberBoard()
        VStack(alignment: .leading, spacing: 18) {
            header(board)
            HStack(alignment: .top, spacing: 0) {
                roster(board)
                    .frame(width: 300)
                    .frame(maxHeight: .infinity, alignment: .top)
                Rule(vertical: true)
                    .padding(.horizontal, 20)
                detail(board)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: armToken) { await searchLoop() }
        .onAppear { restore() }
        .onDisappear { releaseKeypad() }
    }

    // MARK: - 上面

    private func header(_ board: MemberBoard) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            PageTitle(title: "Your *regulars*", subtitle: subtitle(board))
            Spacer(minLength: 12)
            if waitingForPhone {
                HStack(spacing: 10) {
                    LiveDot(color: Theme.accent)
                    Text("右邊的鍵盤：打手機號碼或掃會員條碼")
                        .font(.brand(13.5, .medium))
                        .foregroundStyle(Theme.ink2)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.accentSoft, in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Button {
                    armToken += 1
                } label: {
                    Label { Text("查會員") } icon: { HeroIcon("magnifying-glass", size: 16) }
                }
                .buttonStyle(.brand(.primary, size: .md))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.fast, value: waitingForPhone)
    }

    private func subtitle(_ board: MemberBoard) -> String {
        var parts = ["會員"]
        if !board.visits.isEmpty { parts.append("今天 \(board.visits.count) 位來過") }
        let inStore = board.visits.filter(\.inStore).count + board.bookings.filter(\.inStore).count
        if inStore > 0 { parts.append("\(inStore) 位在店裡") }
        if !board.bookings.isEmpty { parts.append("\(board.bookings.count) 位預約") }
        return parts.joined(separator: "・")
    }

    /// 右側鍵盤現在在等會員頁的電話
    private var waitingForPhone: Bool { keypad.request?.spec == POSModel.memberSearchSpec }

    // MARK: - 左邊：今天的名單

    private func roster(_ board: MemberBoard) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if board.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("今天")
                        Text("還沒有會員來。打電話查到的人會留在這裡，方便再點開。")
                            .textRole(.small)
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 6)
                }
                group("今天預約", board.bookings, first: true)
                group("今天來過", board.visits, first: board.bookings.isEmpty)
                group("最近查過", board.recent, first: board.bookings.isEmpty && board.visits.isEmpty)
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func group(_ title: String, _ list: [MemberSighting], first: Bool) -> some View {
        if !list.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(title)
                Spacer(minLength: 6)
                Text("\(list.count)")
                    .font(.brand(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
            }
            .padding(.top, first ? 4 : 18)
            .padding(.bottom, 6)
            .padding(.horizontal, 4)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                MembersRosterRow(sighting: s, member: model.rememberedMember(s.ref), selected: isSelected(s)) {
                    open(s)
                }
                .reveal(i, .fade)
            }
        }
    }

    private func isSelected(_ s: MemberSighting) -> Bool {
        guard let focus else { return false }
        if let id = s.ref.id, let fid = focus.ref?.id { return id == fid }
        return !s.ref.phone.isEmpty && s.ref.phone == focus.phone
    }

    // MARK: - 右邊：資料卡

    @ViewBuilder
    private func detail(_ board: MemberBoard) -> some View {
        if let focus {
            MembersProfile(focus: focus) { close() }
                .id(focus.phone)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            welcome(board)
        }
    }

    private func welcome(_ board: MemberBoard) -> some View {
        let inStore = (board.bookings + board.visits).filter(\.inStore)
        return VStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 92, height: 92)
                HeroIcon("user-group", size: 36).foregroundStyle(Theme.accent)
            }
            VStack(spacing: 8) {
                Headline("Who's *in* today?", role: .h3)
                Text("在右邊的鍵盤打會員的手機號碼（掃描器掃會員條碼也可以），或從左邊的名單點一位。")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if !inStore.isEmpty {
                VStack(spacing: 10) {
                    Eyebrow("在店裡")
                    FlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(inStore.prefix(8)) { s in
                            Button {
                                open(s)
                            } label: {
                                HStack(spacing: 8) {
                                    MembersAvatar(name: s.ref.name ?? s.ref.maskedPhone, seed: s.id, size: 26)
                                    Text(s.ref.name ?? s.ref.maskedPhone)
                                        .font(.brand(14, .medium))
                                        .foregroundStyle(Theme.ink)
                                }
                                .padding(.leading, 5)
                                .padding(.trailing, 12)
                                .frame(height: 38)
                                .background(Theme.surface, in: .capsule)
                                .overlay { Capsule().strokeBorder(Theme.line) }
                            }
                            .buttonStyle(.press)
                        }
                    }
                    .frame(maxWidth: 460)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
        .reveal(0, .scale)
    }

    // MARK: - 動作

    private func open(_ s: MemberSighting) {
        let phone = s.ref.phone.isEmpty ? (model.rememberedMember(s.ref)?.phone ?? "") : s.ref.phone
        guard !phone.isEmpty else {
            model.show("\(s.ref.name ?? "這位客人") 沒有留電話，查不到會員資料", tone: .warning)
            return
        }
        select(MembersFocus(phone: phone, ref: s.ref))
    }

    private func select(_ f: MembersFocus?) {
        withAnimation(reduceMotion ? nil : Motion.ease) { focus = f }
        MembersMemory.remember(f, store: memoryKey)
    }

    private func close() {
        select(nil)
    }

    /// 結帳（儲值、買卡）時這頁會換成付款畫面；回來時打開剛剛那一位（重新向後台查）
    private func restore() {
        guard focus == nil, let f = MembersMemory.focus(store: memoryKey) else { return }
        focus = MembersFocus(phone: f.phone, ref: f.ref)
    }

    private var memoryKey: String { "\(model.isDemo ? "demo" : "live")|\(model.store.name)" }

    /// 右側鍵盤等電話：打完就打開那一位，接著等下一位（按 × 或去做別的就停，按「查會員」再叫出來）
    private func searchLoop() async {
        while !Task.isCancelled {
            guard let entry = await keypad.ask(POSModel.memberSearchSpec) else { return }
            select(MembersFocus(phone: entry.digits, ref: nil))
        }
    }

    private func releaseKeypad() {
        if waitingForPhone { keypad.cancel() }
    }
}

/// 打開的是哪一位（token 每次都換：同一位再點一次也會重新向後台查）
struct MembersFocus: Equatable {
    var phone: String
    var ref: MemberRef?
    var token = UUID()
}

/// 會員頁在結帳時會被付款畫面換掉：記住剛剛打開的是誰（只在這次開著的時候、同一家店）
enum MembersMemory {
    private static var last: (store: String, focus: MembersFocus)?

    static func remember(_ f: MembersFocus?, store: String) {
        if let f {
            last = (store: store, focus: f)
        } else {
            last = nil
        }
    }

    static func focus(store: String) -> MembersFocus? {
        guard let last, last.store == store else { return nil }
        return last.focus
    }
}

// MARK: - 名單的一列

struct MembersRosterRow: View {
    let sighting: MemberSighting
    let member: Member?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let name = sighting.ref.name ?? member?.name ?? sighting.ref.maskedPhone
        let tier = sighting.ref.tierName ?? member?.tierName
        Button(action: action) {
            HStack(spacing: 12) {
                MembersAvatar(name: name, seed: sighting.id, photoURL: member?.photoURL, size: 42, inStore: sighting.inStore)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.brand(15.5, .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        if let tier { MembersTierTag(tier: tier) }
                        if POSModel.isBirthdayMonth(member?.birthday) {
                            MembersBirthdayBadge(text: POSModel.birthdayText(member?.birthday) ?? "", compact: true)
                        }
                    }
                    Text(sighting.ref.phone.isEmpty ? "沒留電話" : sighting.ref.maskedPhone)
                        .font(.brand(12.5, .regular))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    Text(sighting.detail)
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(sighting.inStore ? Theme.accentText : Theme.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let at = sighting.at {
                    Text(sighting.source == .recent ? at.relativeText : at.clockText)
                        .font(.brand(12, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Theme.press : Color.clear, in: .rect(cornerRadius: Metric.radius))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Theme.accent).frame(width: 3).padding(.vertical, 12)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
