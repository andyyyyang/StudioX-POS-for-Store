import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 菜單左右滑換分類：往左滑＝下一類、往右滑＝上一類（到頭就停，不繞回去）。
///
/// 防誤觸（忙的時候手指歪一下、捲一捲，不會跳到別的分類）：
/// - 一開始就要是橫的（橫的速度是直的 2 倍以上）；一開始是直的＝捲動，這一次碰到就不會變成換分類
/// - 菜單還在捲、剛停下來 0.3 秒內不算（那時候的橫拖多半是要按住捲動）
/// - 從螢幕左右邊邊開始的不算；兩根手指不算
/// - 品項跟著手指走一點、邊邊浮出下一類的名字：拉過一段（至少 96 點）名字變成實心、輕震一下＝放開就換；
///   沒拉到、或放開前往回拉＝不換，彈回去
/// - 短短的甩一下：要甩得夠快、也拉了 56 點以上才算
/// - 點品項、點價錢鍵不受影響（開始橫拖了，那一下點擊就取消，不會又加品項又換分類）
enum CategorySwipe {
    /// 拉多遠放開就換（看菜單寬：手機 96、iPad 大約 130，最多 160）
    static func distance(for width: CGFloat) -> CGFloat {
        min(max(width * 0.22, 96), 160)
    }

    /// 放開時換不換：拉夠遠，或甩得夠快（也拉了一段）；放開前是往回拉的＝反悔，不換
    static func commits(dx: CGFloat, velocity vx: CGFloat, width: CGFloat) -> Bool {
        guard dx != 0 else { return false }
        let forward = (vx < 0) == (dx < 0)
        if !forward && abs(vx) > 220 { return false }
        let far = abs(dx) >= distance(for: width)
        let flick = forward && abs(vx) > 650 && abs(dx) >= 56
        return far || flick
    }

    /// 品項跟著手指走多少：一半；過了「放開就換」的線越拉越緊
    static func follow(_ dx: CGFloat, distance d: CGFloat) -> CGFloat {
        let a = abs(dx)
        let f = a <= d ? a * 0.5 : d * 0.5 + (a - d) * 0.15
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

/// 菜單剛捲過嗎（還在捲、剛停 0.3 秒內）：不觸發畫面更新，只給手勢開始前問
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

    var isSettled: Bool { !moving && Date().timeIntervalSince(stoppedAt) > 0.3 }
}

/// 放在菜單的 ScrollView 上：左右滑換分類（防誤觸見 CategorySwipe）。
/// shift＝品項跟著手指走的距離，外面放在品項的 `.offset(x:)`（分類方塊不動）
struct CategorySwipeArea: ViewModifier {
    let categories: [MenuCategory]
    let current: String?
    /// 搜尋中、客製的卡開著：不換
    let enabled: Bool
    @Binding var shift: CGFloat
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
                ratio: 2,
                edgeInset: 22,
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
        shift = has ? CategorySwipe.follow(x, distance: d) : CategorySwipe.resist(x)
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
        withAnimation(Motion.spring) { shift = 0 }
    }

    private func reset() {
        dragging = false
        armed = false
        dx = 0
        withAnimation(Motion.spring) { shift = 0 }
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
    func categorySwipe(_ categories: [MenuCategory], current: String?, enabled: Bool, shift: Binding<CGFloat>,
                       select: @escaping (String) -> Void) -> some View {
        modifier(CategorySwipeArea(categories: categories, current: current, enabled: enabled, shift: shift, select: select))
    }
}
