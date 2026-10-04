import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 會員頁的零件：頭像、等級與生日的標籤、課程卡的圓環卡片、儲值金卡、消費時間軸的一列，
// 還有照行業換的說法（美業的「配方」、健身的「會籍」、服飾的「尺寸」）。

// MARK: - 照行業換的說法

struct MembersVocabulary {
    /// 備註卡的標題
    var noteTitle: String
    var notePlaceholder: String
    /// 課程卡區的標題
    var passesTitle: String
    /// 買卡的按鈕
    var buyPass: String
    /// 消費紀錄的標題
    var historyTitle: String
    /// 預約的按鈕（沒有預約表的店不顯示）
    var book: String
    /// 消費紀錄裡「誰做的」
    var staffWord: String

    init(mode: ServiceMode) {
        staffWord = mode.staffTitle
        switch mode {
        case .salon:
            noteTitle = "配方與偏好"
            notePlaceholder = "例：6N+7.1 1:1（雙氧 6%）停 30 分鐘；頭皮敏感；瀏海不要打太薄"
            passesTitle = "次數卡"
            buyPass = "買次數卡"
            historyTitle = "來店紀錄"
            book = "預約"
        case .fitness:
            noteTitle = "身體狀況與目標"
            notePlaceholder = "例：左膝舊傷，避免跳躍；目標增肌；每週二、四找教練"
            passesTitle = "會籍與堂數"
            buyPass = "續約・買堂數"
            historyTitle = "訓練與消費"
            book = "約教練"
        case .apparel, .retail:
            noteTitle = "尺寸與偏好"
            notePlaceholder = "例：上衣 M、褲子 S（腰 25）；喜歡大地色、寬版"
            passesTitle = "課程卡"
            buyPass = "買課程卡"
            historyTitle = "購買紀錄"
            book = "預約"
        case .tableService, .counter, .cafe:
            noteTitle = "偏好與過敏"
            notePlaceholder = "例：不吃香菜、燕麥奶、靠窗的位子"
            passesTitle = "課程卡"
            buyPass = "買課程卡"
            historyTitle = "消費紀錄"
            book = "訂位"
        }
    }
}

// MARK: - 頭像、顏色

enum MembersStyle {
    /// 同一個人永遠同一個色（id 或電話算出來；不用 hashValue：每次開 App 都不一樣）
    static func swatch(for seed: String) -> Swatch {
        let all = Swatch.allCases
        let sum = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return all[sum % all.count]
    }

    /// 頭像上的字：中文名取名字（「陳怡君」→「怡君」），英文取縮寫（「Leslie K.」→「LK」）
    static func monogram(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return "?" }
        if first.value >= 0x2E80 {
            let chars = Array(trimmed)
            return chars.count >= 3 ? String(chars.suffix(2)) : trimmed
        }
        let words = trimmed.split(separator: " ")
        let letters = words.prefix(2).compactMap { w in w.first.map { String($0) } }.joined()
        return letters.isEmpty ? String(trimmed.prefix(1)) : letters.uppercased()
    }

    /// 課程卡的狀態（決定顏色）
    enum PassState {
        case active
        /// 快到期（14 天內）或快用完（剩 2 次以下）
        case expiring
        /// 續約的、還沒開始
        case upcoming
        /// 過期、用完、退費
        case finished
    }

    static func state(of p: MemberPass, at now: Date) -> PassState {
        if !p.isUsable(at: now) {
            return p.status == .active && now < p.startsAt ? .upcoming : .finished
        }
        if let d = p.daysLeft(at: now), d <= 14 { return .expiring }
        if p.spec.kind == .visits, (p.remaining ?? 0) <= 2 { return .expiring }
        return .active
    }

    static func tint(_ s: PassState) -> Color {
        switch s {
        case .active: Theme.live
        case .expiring: Theme.accent
        case .upcoming: Theme.infoFG
        case .finished: Theme.faint
        }
    }

    /// 「10/4」
    static func monthDay(_ d: Date) -> String {
        let c = TaipeiTime.components(d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
}

/// 會員的頭像：有照片用照片（健身房報到核對），沒有就是名字＋色塊
struct MembersAvatar: View {
    let name: String
    let seed: String
    var photoURL: String? = nil
    var size: CGFloat = 40
    /// 人在店裡：外面一圈品牌橘
    var inStore = false

    var body: some View {
        let mono = MembersStyle.monogram(name)
        ZStack {
            Circle().fill(Theme.swatch(MembersStyle.swatch(for: seed)))
            Text(mono)
                .font(.brand(size * (mono.count > 1 ? 0.34 : 0.42), .semibold))
                .foregroundStyle(Theme.tileInk)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(size * 0.1)
            if let url = photoURL.flatMap({ URL(string: $0) }) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if inStore {
                Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-4)
            }
        }
        .accessibilityLabel(name)
    }
}

/// 會員等級的小標（金卡、VIP…）
struct MembersTierTag: View {
    let tier: String

    var body: some View {
        Text(tier)
            .font(.brand(11, .semibold))
            .foregroundStyle(premium ? Theme.accentText : Theme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(premium ? Theme.accentSoft : Theme.press, in: .rect(cornerRadius: Metric.chip))
            .lineLimit(1)
    }

    private var premium: Bool {
        ["金", "白金", "VIP", "黑", "鑽"].contains { tier.contains($0) }
    }
}

/// 當月壽星的標籤
struct MembersBirthdayBadge: View {
    let text: String
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            HeroIcon("cake", size: compact ? 12 : 14)
            if !compact { Text(text) }
        }
        .font(.brand(12.5, .semibold))
        .foregroundStyle(Theme.accentText)
        .padding(.horizontal, compact ? 5 : 9)
        .padding(.vertical, compact ? 3 : 5)
        .background(Theme.accentSoft, in: .capsule)
        .accessibilityLabel("當月壽星 \(text)")
    }
}

// MARK: - 圓環

/// 課程卡的圓環：次數卡是剩幾次、會籍是剩幾天（進來的時候畫上去）
struct MembersRing: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 7

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let target = min(max(progress, 0), 1)
        ZStack {
            Circle().stroke(Theme.line, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown || reduceMotion ? max(target, 0.001) : 0.001)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear {
            guard !shown else { return }
            withAnimation(Motion.slow.delay(0.15)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 課程卡

/// 一張課程卡、會籍：圓環＋名字＋剩幾次／到哪天（顏色照狀態：有效、快到期、還沒開始、結束）。
/// 只有狀態，沒有按鈕：續約、再買一張在右欄（「買卡」的面板）
struct MembersPassCard: View {
    let pass: MemberPass
    let now: Date

    var body: some View {
        let state = MembersStyle.state(of: pass, at: now)
        let tint = MembersStyle.tint(state)
        let finished = state == .finished
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                MembersRing(progress: progress, tint: tint)
                VStack(spacing: 0) {
                    Text(centerValue)
                        .font(.brand(22, .medium))
                        .monospacedDigit()
                        .foregroundStyle(finished ? Theme.muted : Theme.ink)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(centerUnit)
                        .font(.brand(10.5, .medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(10)
            }
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 5) {
                Text(pass.name)
                    .font(.brand(16, .medium))
                    .foregroundStyle(finished ? Theme.muted : Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pass.spec.summary)
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(pass.statusText(at: now) + (pass.spec.checkIn && !finished ? "・入場用" : ""))
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(state == .expiring ? Theme.accentText : (finished ? Theme.muted : Theme.ink2))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(finished ? 0.03 : 0.10), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(state == .expiring ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1)
        }
        .opacity(finished ? 0.72 : 1)
        .accessibilityElement(children: .combine)
    }

    /// 圓環要畫多滿
    private var progress: Double {
        switch pass.spec.kind {
        case .visits:
            let total = max(pass.spec.visits ?? 1, 1)
            return Double(max(pass.remaining ?? 0, 0)) / Double(total)
        case .period:
            guard let days = pass.daysLeft(at: now), let valid = pass.spec.validDays, valid > 0 else { return 1 }
            return Double(max(days, 0)) / Double(valid)
        }
    }

    private var centerValue: String {
        switch pass.spec.kind {
        case .visits: return "\(max(pass.remaining ?? 0, 0))"
        case .period:
            if now < pass.startsAt { return MembersStyle.monthDay(pass.startsAt) }
            return pass.daysLeft(at: now).map { "\(max($0, 0))" } ?? "∞"
        }
    }

    private var centerUnit: String {
        switch pass.spec.kind {
        case .visits: return "/ \(pass.spec.visits ?? 0) 次"
        case .period: return now < pass.startsAt ? "開始" : "天"
        }
    }
}

// MARK: - 消費時間軸

/// 時間軸的一筆：日期、品項（小方塊）、誰做的（頭像）、金額
struct MembersTimelineRow: View {
    let entry: MembersTimelineItem
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(MembersStyle.monthDay(entry.at))
                    .font(.brand(17, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text(entry.dayLabel)
                    .font(.brand(11.5, .regular))
                    .foregroundStyle(Theme.muted)
            }
            .frame(width: 58, alignment: .trailing)

            // 線與點
            VStack(spacing: 0) {
                Circle()
                    .fill(entry.onThisDevice ? Theme.accent : Theme.ink.opacity(0.5))
                    .frame(width: 9, height: 9)
                    .padding(.top, 6)
                if !isLast {
                    Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(.brand(13, .medium))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm))
                            .overlay { RoundedRectangle(cornerRadius: Metric.radiusSm).strokeBorder(Theme.hair) }
                    }
                }
                HStack(spacing: 10) {
                    if !entry.staff.isEmpty {
                        HStack(spacing: -6) {
                            ForEach(Array(entry.staff.prefix(3).enumerated()), id: \.offset) { _, s in
                                StaffAvatar(name: s.name, swatch: s.swatch, size: 22)
                                    .overlay { Circle().strokeBorder(Theme.page, lineWidth: 1.5) }
                            }
                        }
                        Text(entry.staff.map(\.name).joined(separator: "、"))
                            .textRole(.xs)
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                    ForEach(entry.badges, id: \.self) { b in
                        Text(b)
                            .font(.brand(11, .semibold))
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.chip))
                    }
                }
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.serif(15, italic: true))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, isLast ? 0 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(money: entry.total, role: .h4, color: entry.total.isZero ? Theme.muted : Theme.ink)
                Text(entry.number)
                    .font(.brand(11.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
            }
            .frame(minWidth: 86, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 時間軸一筆要顯示的東西（畫面算好給列用）
struct MembersTimelineItem: Identifiable {
    struct Person: Hashable {
        var name: String
        var swatch: Swatch
    }

    var id: String
    var at: Date
    var dayLabel: String
    var number: String
    var total: Money
    var items: [String]
    var staff: [Person]
    var badges: [String]
    var note: String?
    var onThisDevice: Bool
}
