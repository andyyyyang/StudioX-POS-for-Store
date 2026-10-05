import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 手機：從螢幕左邊邊往右滑＝回上一頁（和 iOS 一樣）。
///
///   ┃‹ 點餐 ┃  頁面          ← 頁面跟著手指往右走，左邊露出要回去的地方
///
/// - 從左邊 28 點以內開始、往右拖才算（中間的左右滑留給頁面自己：換分類、單子的一行）
/// - 拉過三分之一（或往右甩一下）名字變實心、輕震＝放開就回去；沒拉到、往回拉＝彈回來
/// - 拖的時候只有這一層在動（頁面本身不重畫）
struct SwipeBack: ViewModifier {
    /// 要回去的地方（「點餐」「更多」）
    let title: String
    var enabled = true
    let back: () -> Void

    @State private var dx: CGFloat = 0
    @State private var width: CGFloat = 390
    @State private var armed = false

    func body(content: Content) -> some View {
        content
            // 頁面左邊一道淡淡的影子（跟著頁面走）
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.18)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14)
                    .offset(x: -14)
                    .opacity(dx > 0 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .offset(x: dx)
            .background(alignment: .leading) { hint }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = max($0, 1) })
            .gesture(HorizontalPan(
                isEnabled: enabled,
                ratio: 1,
                leadingEdge: 28,
                onBegan: {},
                onChanged: { x in move(x) },
                onEnded: { x, vx in end(x, velocity: vx) },
                onCancelled: { reset() }
            ))
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now }
    }

    private var threshold: CGFloat { width * 0.33 }

    private func move(_ x: CGFloat) {
        dx = max(x, 0)
        let now = dx > threshold
        if now != armed {
            withAnimation(Motion.fast) { armed = now }
        }
    }

    private func end(_ x: CGFloat, velocity vx: CGFloat) {
        let goes = (x > threshold && vx > -200) || (vx > 600 && x > 40)
        armed = false
        guard goes else {
            withAnimation(Motion.spring) { dx = 0 }
            return
        }
        // 整頁滑出去、再回上一頁（新的頁面出來時這一層歸零，不再動一次）
        withAnimation(.easeOut(duration: 0.18)) { dx = width }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            back()
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { dx = 0 }
        }
    }

    private func reset() {
        armed = false
        withAnimation(Motion.spring) { dx = 0 }
    }

    /// 左邊露出來的：「‹ 點餐」，越拉越清楚，過線變實心
    @ViewBuilder
    private var hint: some View {
        let progress = min(dx / max(threshold, 1), 1)
        if dx > 0 {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.brand(15, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(armed ? Theme.page : Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(armed ? Theme.ink : Theme.surface, in: .capsule)
            .overlay { Capsule().strokeBorder(armed ? Color.clear : Theme.line) }
            .opacity(Double(min(progress * 1.5, 1)))
            .scaleEffect(0.9 + 0.1 * progress)
            .padding(.leading, 14)
            .frame(maxHeight: .infinity)
            .frame(width: max(dx, 0), alignment: .leading)
            .background(Theme.pageAlt)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// 手機：從左邊邊往右滑回上一頁（title：要回去的地方）
    func swipeBack(_ title: String, enabled: Bool = true, back: @escaping () -> Void) -> some View {
        modifier(SwipeBack(title: title, enabled: enabled, back: back))
    }
}
