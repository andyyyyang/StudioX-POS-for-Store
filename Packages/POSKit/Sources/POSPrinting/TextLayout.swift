import Foundation

/// 出單機的紙寬
public enum PaperWidth: String, Codable, Sendable, CaseIterable, Hashable {
    /// 58 mm（電子發票證明聯 5.7 公分；384 點）
    case mm58
    /// 80 mm（576 點）
    case mm80

    /// 一列幾個半形字（12×24 字型）
    public var columns: Int { self == .mm58 ? 32 : 48 }
    /// 可印的點數（203 dpi）
    public var dots: Int { self == .mm58 ? 384 : 576 }
    public var label: String { self == .mm58 ? "58 mm" : "80 mm" }
}

/// 半形／全形：中文、全形符號佔兩格。出單機文字模式排版（對齊金額）要算格數，不能算字數
public enum TextWidth {
    public static func of(_ ch: Character) -> Int {
        guard let s = ch.unicodeScalars.first else { return 1 }
        let v = s.value
        if v < 0x1100 { return 1 }
        // 半形片假名、半形符號
        if (0xFF61...0xFFDC).contains(v) || (0xFFE8...0xFFEE).contains(v) { return 1 }
        // CJK、全形、韓文、注音、符號
        if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v) {
            return 2
        }
        return 1
    }

    public static func of(_ s: String) -> Int { s.reduce(0) { $0 + of($1) } }

    /// 截到 width 格（超過的話最後一格放「…」）
    public static func truncate(_ s: String, to width: Int) -> String {
        guard of(s) > width else { return s }
        var out = "", used = 0
        for ch in s {
            let w = of(ch)
            if used + w > width - 1 { break }
            out.append(ch)
            used += w
        }
        return out + "…"
    }

    /// 斷行（不切斷英文字以外的東西；中文每個字都能斷）
    public static func wrap(_ s: String, width: Int) -> [String] {
        guard width > 0 else { return [s] }
        var lines: [String] = [], cur = "", used = 0
        for ch in s {
            if ch == "\n" { lines.append(cur); cur = ""; used = 0; continue }
            let w = of(ch)
            if used + w > width { lines.append(cur); cur = ""; used = 0 }
            cur.append(ch)
            used += w
        }
        if !cur.isEmpty || lines.isEmpty { lines.append(cur) }
        return lines
    }

    public static func pad(_ s: String, to width: Int, alignRight: Bool = false) -> String {
        let gap = max(width - of(s), 0)
        let spaces = String(repeating: " ", count: gap)
        return alignRight ? spaces + s : s + spaces
    }

    /// 左邊字、右邊金額，中間補空白（左邊太長就換行，金額在最後一行）
    public static func row(_ left: String, _ right: String, width: Int) -> [String] {
        let rw = of(right)
        let avail = width - rw - 1
        guard avail > 0 else { return [left, pad(right, to: width, alignRight: true)] }
        var lines = wrap(left, width: avail)
        let last = lines.removeLast()
        lines.append(pad(last, to: width - rw) + right)
        return lines
    }
}
