import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 菜單左右滑換分類：往左滑＝下一類、往右滑＝上一類（到頭就停，不繞回去）。
///
/// 好滑、也不會誤觸：
/// - 斜的也算：偏上偏下 45 度以內都是左右滑；更斜的是捲動。一開始就決定，開始了就鎖住（之後手指歪了也不會變成捲動）
/// - 菜單還在捲、剛停下來 0.12 秒內不算（那一下多半是要按住捲動）；從螢幕最邊邊開始的、兩根手指不算
/// - 品項緊跟著手指走、邊邊浮出下一類的名字：拉過一段（至少 80 點）名字變成實心、輕震一下＝放開就換；
///   沒拉到、或放開前往回拉＝不換，彈回去
/// - 甩一下也行：夠快、也拉了 44 點以上
/// - 點品項、點價錢鍵不受影響（開始橫拖了，那一下點擊就取消，不會又加品項又換分類）
/// - 拖的時候只有品項那一層跟著動（SwipeShift），整個菜單不用每一格重畫，跟手不卡
enum CategorySwipe {
    /// 拉多遠放開就換（看菜單寬：手機 80、iPad 大約 120，最多 140）
    static func distance(for width: CGFloat) -> CGFloat {
        min(max(width * 0.2, 80), 140)
    }

    /// 放開時換不換：拉夠遠，或甩得夠快（也拉了一段）；放開前是往回拉的＝反悔，不換
    static func commits(dx: CGFloat, velocity vx: CGFloat, width: CGFloat) -> Bool {
        guard dx != 0 else { return false }
        let forward = (vx < 0) == (dx < 0)
        if !forward && abs(vx) > 220 { return false }
        let far = abs(dx) >= distance(for: width)
        let flick = forward && abs(vx) > 500 && abs(dx) >= 44
        return far || flick
    }

    /// 品項跟著手指走多少：緊跟著（八成）；過了「放開就換」的線慢慢變緊
    static func follow(_ dx: CGFloat, distance d: CGFloat) -> CGFloat {
        let a = abs(dx)
        let f = a <= d ? a * 0.8 : d * 0.8 + (a - d) * 0.3
        return dx < 0 ? -f : f
    }

    /// 到頭了（沒有上／下一類）：只能拉一點點
    static func resist(_ dx: CGFloat) -> CGFloat {
        let f = 28 * (1 - 1 / (abs(dx) / 90 + 1))
        return dx < 0 ? -f : f
    }

    /// 現在這一類往前／往後一類（到頭了 nil）
    static func neighbor(of id: String?, by step: Int, in categories: [MenuCategory]) -> String? {
        guard let id, let i = categories.firstIndex(where: { $0.id == id }) else { return categories.first?.id }
        let j = i + step
        guard categories.indices.contains(j) else { return nil }
        return categories[j].id
    }

    /// 新的品項從哪一邊推進來：往後一類從右邊、往前一類從左邊
    static func edge(from old: String?, to new: String, in categories: [MenuCategory]) -> Edge {
        let a = old.flatMap { o in categories.firstIndex { $0.id == o } } ?? 0
        let b = categories.firstIndex { $0.id == new } ?? 0
        return b >= a ? .trailing : .leading
    }
}

/// 菜單剛捲過嗎（還在捲、剛停 0.12 秒內）：不觸發畫面更新，只給手勢開始前問
final class ScrollSettle {
    private var moving = false
    private var stoppedAt = Date.distantPast

    func update(_ phase: ScrollPhase) {
        switch phase {
        case .interacting, .decelerating, .animating:
            moving = true
        default:
            if moving { stoppedAt = Date() }
            moving = false
        }
    }

    var isSettled: Bool { !moving && Date().timeIntervalSince(stoppedAt) > 0.12 }
}

/// 左右滑時品項跟著手指走的距離：放在這裡（不是外面頁面的 @State），拖的時候只有 SwipeShifted 那一層重畫
@Observable
final class SwipeShift {
    var x: CGFloat = 0
}

/// 品項那一層：跟著 SwipeShift 左右移（菜單其他地方不用跟著重畫）
struct SwipeShifted<Content: View>: View {
    let shift: SwipeShift
    @ViewBuilder var content: Content

    var body: some View {
        content.offset(x: shift.x)
    }
}

/// 放在菜單的 ScrollView 上：左右滑換分類（見 CategorySwipe）。
/// shift＝品項跟著手指走的距離，外面用 SwipeShifted 包住品項（分類方塊不動）
struct CategorySwipeArea: ViewModifier {
    let categories: [MenuCategory]
    let current: String?
    /// 搜尋中、客製的卡開著：不換
    let enabled: Bool
    let shift: SwipeShift
    let select: (String) -> Void

    @State private var width: CGFloat = 0
    @State private var dx: CGFloat = 0
    @State private var dragging = false
    /// 拉過「放開就換」的線
    @State private var armed = false
    @State private var settle = ScrollSettle()

    func body(content: Content) -> some View {
        let s = settle
        return content
            .onScrollPhaseChange { _, phase in s.update(phase) }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
            .gesture(HorizontalPan(
                isEnabled: enabled && categories.count > 1,
                // 偏上偏下 45 度以內都算左右滑
                ratio: 1,
                edgeInset: 10,
                shouldBegin: { s.isSettled },
                onBegan: { dragging = true },
                onChanged: { x in move(x) },
                onEnded: { x, vx in end(x, velocity: vx) },
                onCancelled: { reset() }
            ))
            .overlay(alignment: dx < 0 ? .trailing : .leading) { hint }
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now }
            .onChange(of: enabled) { _, on in
                if !on { reset() }
            }
    }

    /// 往這邊拉會換到哪一類（到頭了 nil）
    private func target(_ x: CGFloat) -> MenuCategory? {
        guard x != 0, let id = CategorySwipe.neighbor(of: current, by: x < 0 ? 1 : -1, in: categories) else { return nil }
        return categories.first { $0.id == id }
    }

    private func move(_ x: CGFloat) {
        dx = x
        let d = CategorySwipe.distance(for: width)
        let has = target(x) != nil
        shift.x = has ? CategorySwipe.follow(x, distance: d) : CategorySwipe.resist(x)
        let now = has && abs(x) >= d
        if now != armed {
            withAnimation(Motion.fast) { armed = now }
        }
    }

    private func end(_ x: CGFloat, velocity vx: CGFloat) {
        let next = CategorySwipe.commits(dx: x, velocity: vx, width: width) ? target(x) : nil
        dragging = false
        armed = false
        dx = 0
        if let next { select(next.id) }
        withAnimation(Motion.spring) { shift.x = 0 }
    }

    private func reset() {
        dragging = false
        armed = false
        dx = 0
        withAnimation(Motion.spring) { shift.x = 0 }
    }

    /// 邊邊浮出來的下一類：越拉越清楚，過線變成實心（放開就換）
    @ViewBuilder
    private var hint: some View {
        let d = CategorySwipe.distance(for: width)
        let progress = min(abs(dx) / max(d, 1), 1)
        if dragging, progress > 0.12, let c = target(dx) {
            let forward = dx < 0
            HStack(spacing: 6) {
                if !forward {
                    HeroIcon("chevron-right", size: 13)
                        .scaleEffect(x: -1)
                }
                Circle()
                    .fill(Theme.swatch(c.swatch))
                    .frame(width: 8, height: 8)
                Text(c.name)
                    .font(.brand(14, .semibold))
                    .lineLimit(1)
                if forward {
                    HeroIcon("chevron-right", size: 13)
                }
            }
            .foregroundStyle(armed ? Theme.page : Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(armed ? Theme.ink : Theme.surface, in: .capsule)
            .overlay { Capsule().strokeBorder(armed ? Color.clear : Theme.line) }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .opacity(min(progress * 1.5, 1))
            .offset(x: (forward ? 1 : -1) * (1 - progress) * 28)
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// 菜單左右滑換分類（放在菜單的 ScrollView 上）
    func categorySwipe(_ categories: [MenuCategory], current: String?, enabled: Bool, shift: SwipeShift,
                       select: @escaping (String) -> Void) -> some View {
        modifier(CategorySwipeArea(categories: categories, current: current, enabled: enabled, shift: shift, select: select))
    }
}
