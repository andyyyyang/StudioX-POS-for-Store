import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 只接橫的拖：一開始的方向就決定（橫的比直的多才開始），直的交給外面的 ScrollView（不會兩個打架）。
/// 開始了就鎖住橫的：之後手指歪了也不會變成捲動；一開始是直的，這一次碰到就不會再變成橫拖。
///
/// 用在單子的一行（SwipeRow）、菜單左右滑換分類（CategorySwipeArea）、手機從左邊邊往右滑回上一頁（SwipeBack）
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// 橫的要是直的幾倍才開始（1 ≈ 斜 45 度以內都算、1.3 ≈ 37 度以內）
    var ratio: CGFloat = 1.3
    /// 從螢幕左右邊這麼近的地方開始的不接（留給系統的手勢、拿手機的手指）
    var edgeInset: CGFloat = 0
    /// 只接從螢幕左邊這麼近的地方開始、往右拖的（回上一頁）；0＝哪裡開始都可以
    var leadingEdge: CGFloat = 0
    /// 另外的條件（例如菜單剛捲過不算）
    var shouldBegin: () -> Bool = { true }
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(ratio: ratio, edgeInset: edgeInset, leadingEdge: leadingEdge, shouldBegin: shouldBegin)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.ratio = ratio
        context.coordinator.edgeInset = edgeInset
        context.coordinator.leadingEdge = leadingEdge
        context.coordinator.shouldBegin = shouldBegin
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            onBegan()
            onChanged(dx)
        case .changed:
            onChanged(dx)
        case .ended:
            onEnded(dx, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var ratio: CGFloat
        var edgeInset: CGFloat
        var leadingEdge: CGFloat
        var shouldBegin: () -> Bool

        init(ratio: CGFloat, edgeInset: CGFloat, leadingEdge: CGFloat, shouldBegin: @escaping () -> Bool) {
            self.ratio = ratio
            self.edgeInset = edgeInset
            self.leadingEdge = leadingEdge
            self.shouldBegin = shouldBegin
        }

        /// 橫的比直的多才接手（偏太多的、直的交給捲動）；從螢幕邊邊開始的、外面說不行的也不接
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            // 看已經拖的方向（比一瞬間的速度穩，手指抖一下不會判錯）；才剛動一點點就看速度
            let t = pan.translation(in: pan.view)
            let v = pan.velocity(in: pan.view)
            let d = hypot(t.x, t.y) >= 6 ? t : v
            guard abs(d.x) > abs(d.y) * ratio else { return false }
            if let window = pan.view?.window, edgeInset > 0 || leadingEdge > 0 {
                // 手指一開始按下去的地方（現在的位置往回扣已經拖的）
                let x = pan.location(in: window).x - pan.translation(in: window).x
                if edgeInset > 0, x < edgeInset || x > window.bounds.width - edgeInset { return false }
                if leadingEdge > 0, x > leadingEdge || d.x <= 0 { return false }
            }
            return shouldBegin()
        }

        /// 外面的拖（ScrollView 的捲動、sheet 往下滑關掉）等這一個先放棄：直的一動這一個就放棄，橫的就是這一個的
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view !== gestureRecognizer.view
        }
    }
}
