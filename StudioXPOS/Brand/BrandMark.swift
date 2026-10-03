import SwiftUI

/// StudioX 標誌（平面版）：大三角形＋方塊，方塊沿對角線一半是品牌橘（摺角）。
/// 幾何和 atelier-cms 的 lib/brand-mark.ts、studiox.tw 的 Logo 相同（32 單位的方格）；3D 版在歡迎頁（Welcome/）。
/// 主體跟著前景色。
struct BrandMark: View {
    var body: some View {
        ZStack {
            MarkPiece(points: MarkPiece.triangle)
            MarkPiece(points: MarkPiece.inkHalf)
            MarkPiece(points: MarkPiece.accentHalf).fill(Theme.brandOrange)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// 標誌的一塊：方格座標的三角形，角落 0.35 單位的圓角，置中縮放到畫框
nonisolated struct MarkPiece: Shape {
    static let s0: CGFloat = 16.849
    static let triangle = [CGPoint(x: 2, y: 2), CGPoint(x: 30, y: 2), CGPoint(x: 2, y: 30)]
    static let inkHalf = [CGPoint(x: s0, y: s0), CGPoint(x: 30, y: s0), CGPoint(x: 30, y: 30)]
    static let accentHalf = [CGPoint(x: s0, y: s0), CGPoint(x: 30, y: 30), CGPoint(x: s0, y: 30)]

    var points: [CGPoint]
    var corner: CGFloat = 0.35

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 32
        let ox = rect.midX - 16 * s
        let oy = rect.midY - 16 * s
        let pts = points.map { CGPoint(x: ox + $0.x * s, y: oy + $0.y * s) }
        guard let first = pts.first, let last = pts.last, pts.count > 2 else { return Path() }
        var p = Path()
        p.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for i in pts.indices {
            p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % pts.count], radius: corner * s)
        }
        p.closeSubpath()
        return p
    }
}
