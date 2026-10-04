import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 會員頁（側欄「會員」）：左邊是今天的名單，右邊是一位會員的資料卡。
///
///   ┌ Your regulars ─────────────────────────────── ● 右邊的鍵盤：打手機號碼 ┐
///   │ ■ 今天預約              │ (怡君) 陳怡君  金卡會員 · 本月壽星 10/18                 │
///   │  怡君 陳怡君  14:00 …   │ 0911-***-333・後台的資料 14:05                          │
///   │ ■ 今天來過              │ 累積消費 │ 來店 │ 上次來 │ 生日                         │
///   │  柏翰 黃柏翰  結帳 …    │ [⋯] [儲值] [預約] [ 開單 ──────────────── ]             │
///   │ ■ 最近查過              │ 儲值金・次數卡（卡片自己的「續約」）・配方・來店紀錄     │
///   └──────────────────────────────────────────────────────────────────────────┘
///
/// 按鈕照 docs/DESIGN.md：名單的每一列沒有按鈕（點一下打開、再點一下收起）；動作都在資料卡的一條動作列
/// （一個主要「開單」、最多兩個次要、其他收進「⋯」）。窄的時候（直的 iPad）名單與資料卡輪流佔滿。
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

    /// 名單的寬度；工作區比這個寬很多才並排
    private let rosterWidth: CGFloat = 280

    var body: some View {
        let board = model.memberBoard()
        GeometryReader { geo in
            let wide = geo.size.width >= 880
            VStack(alignment: .leading, spacing: 18) {
                header(board, compact: !wide)
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        roster(board)
                            .frame(width: rosterWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                        Rule(vertical: true)
                            .padding(.horizontal, 20)
                        detail(board, compact: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                } else if focus != nil {
                    detail(board, compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    roster(board)
                        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, wide ? 28 : 20)
            .padding(.top, 22)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .task(id: armToken) { await searchLoop() }
        .onAppear { restore() }
        .onDisappear { releaseKeypad() }
    }

    // MARK: - 上面

    /// 頁首右上只有一樣東西：鍵盤在等電話時是狀態，沒在等時是「查會員」（細框）
    private func header(_ board: MemberBoard, compact: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            PageTitle(title: "Your *regulars*", subtitle: subtitle(board))
            Spacer(minLength: 12)
            if waitingForPhone {
                HStack(spacing: 10) {
                    LiveDot(color: Theme.accent)
                    Text(compact ? "右邊鍵盤打電話" : "右邊的鍵盤：打手機號碼或掃會員條碼")
                        .font(.brand(13.5, .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.accentSoft, in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    armToken += 1
                } label: {
                    Label { Text("查會員") } icon: { HeroIcon("magnifying-glass", size: 16) }
                }
                .buttonStyle(.brand(.ghost, size: .md))
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

    // MARK: - 名單（每一列沒有按鈕：點一下打開、再點一下收起）

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
        if let id = s.ref.id, let m = model.rememberedMember(phone: focus.phone) { return id == m.id }
        return !s.ref.phone.isEmpty && s.ref.phone == focus.phone
    }

    // MARK: - 資料卡

    @ViewBuilder
    private func detail(_ board: MemberBoard, compact: Bool) -> some View {
        if let focus {
            MembersProfile(focus: focus, compact: compact, onClose: { close() }, onKeypadDone: { rearm() })
                .id(focus.phone)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            welcome(board)
        }
    }

    /// 還沒打開任何人：說怎麼查（沒有按鈕：查人用右側鍵盤或左邊的名單）
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
                HStack(spacing: 8) {
                    Circle().strokeBorder(Theme.accent, lineWidth: 2).frame(width: 14, height: 14)
                    Text("\(inStore.count) 位在店裡：名單上有橘色圈的那幾位")
                        .textRole(.small)
                        .foregroundStyle(Theme.ink2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
        .reveal(0, .scale)
    }

    // MARK: - 動作

    /// 點名單的一列：打開那一位；已經打開的再點一下就收起
    private func open(_ s: MemberSighting) {
        if isSelected(s) {
            close()
            return
        }
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

    /// 資料卡用完右側鍵盤（生日、儲值取消了）：鍵盤回來等下一位的電話（已經在結帳就不搶）
    private func rearm() {
        guard model.checkoutTicketId == nil, !keypad.isAsking else { return }
        armToken += 1
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

/// 一位會員：頭像、名字（壽星有小蛋糕）、電話與等級、今天的事、時間。整列可以點，裡面沒有按鈕
struct MembersRosterRow: View {
    let sighting: MemberSighting
    let member: Member?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let name = sighting.ref.name ?? member?.name ?? sighting.ref.maskedPhone
        let tier = sighting.ref.tierName ?? member?.tierName
        let phone = sighting.ref.phone.isEmpty ? "沒留電話" : sighting.ref.maskedPhone
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                MembersAvatar(name: name, seed: sighting.id, photoURL: member?.photoURL, size: 42, inStore: sighting.inStore)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name)
                            .font(.brand(15.5, .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if POSModel.isBirthdayMonth(member?.birthday) {
                            MembersBirthdayBadge(text: POSModel.birthdayText(member?.birthday) ?? "", compact: true)
                        }
                        Spacer(minLength: 4)
                        if let at = sighting.at {
                            Text(sighting.source == .recent ? at.relativeText : at.clockText)
                                .font(.brand(12, .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    Text(tier.map { "\(phone)・\($0)" } ?? phone)
                        .font(.brand(12.5, .regular))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(sighting.detail)
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(sighting.inStore ? Theme.accentText : Theme.ink2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityHint(selected ? "再點一下收起" : "打開會員資料")
    }
}
