import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 菜單左右滑換分類：往左滑＝下一類、往右滑＝上一類（到頭就停，不繞回去）。
/// 只認明顯橫的滑（橫的比直的多很多、夠長），直的照樣捲；點品項、點價錢鍵不受影響
enum CategorySwipe {
    /// 放開時決定要不要換：往左 +1、往右 −1、不算 nil
    static func step(for value: DragGesture.Value) -> Int? {
        let dx = value.translation.width
        let dy = value.translation.height
        // 快速甩一下也算（距離短一點，但速度夠）
        let flick = abs(value.predictedEndTranslation.width) > 160
        guard abs(dx) > abs(dy) * 1.8, abs(dx) > 70 || (flick && abs(dx) > 36) else { return nil }
        return dx < 0 ? 1 : -1
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
