import Foundation

/// 語音點餐：把說的話（或 Apple 的模型整理好的一行）對到菜單。
///
///   「鴨胸 140 兩份、鴨心一串」 → 鴨胸（140）×2、鴨心 ×1
///
/// 手機上先請 Apple 的模型（Foundation Models）整理成一行一行（品名、規格、幾份、備註），再用這裡對到菜單；
/// 沒有模型（不支援的手機）就直接用 parse 從整句話裡找品名與數量。純函式，不碰畫面、不連網路
public enum VoiceOrderText {
    /// 對到菜單的一樣
    public struct Line: Sendable, Hashable {
        public var item: MenuItem
        /// 有規格的品項：說了哪一個（沒說、對不到是 nil）
        public var variant: ItemVariant?
        public var quantity: Int
        public var note: String

        public init(item: MenuItem, variant: ItemVariant?, quantity: Int, note: String = "") {
            self.item = item; self.variant = variant; self.quantity = quantity; self.note = note
        }

        /// 有規格卻沒說哪一個（「鴨胸」沒說 140 還是 150）
        public var needsVariant: Bool { item.hasVariants && variant == nil }
    }

    // MARK: 數字

    private static let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                                                  "六": 6, "七": 7, "八": 8, "九": 9]

    /// 「3」「３」「三」「兩」「十二」「二十」「二十五」→ 數字（1–999）；不是數字回 nil
    public static func number(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let ascii = String(t.map { c -> Character in
            // 全形數字
            if let v = c.unicodeScalars.first?.value, (0xFF10...0xFF19).contains(v), let u = UnicodeScalar(v - 0xFF10 + 0x30) { return Character(u) }
            return c
        })
        if ascii.allSatisfy(\.isASCII), let n = Int(ascii) { return n }
        // 口語「一百四」＝140、「兩百五」＝250（百後面只有一個數字）
        let cs = Array(t)
        if cs.count == 3, cs[1] == "百", let h = digits[cs[0]], let tens = digits[cs[2]], tens > 0 {
            return h * 100 + tens * 10
        }
        // 中文：十、十二、二十、二十五、一百二十
        var total = 0
        var current = 0
        var sawAny = false
        for c in t {
            if let d = digits[c] {
                current = d
                sawAny = true
            } else if c == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
                sawAny = true
            } else if c == "百" {
                total += (current == 0 ? 1 : current) * 100
                current = 0
                sawAny = true
            } else {
                return nil
            }
        }
        guard sawAny else { return nil }
        let n = total + current
        return n > 0 ? n : nil
    }

    // MARK: 對到菜單

    /// 品名對到菜單：一模一樣（含簡稱）> 菜單的名字在裡面 > 說的在菜單名字裡 > 共同的字最多（至少一半）。賣完的照樣對（加的時候再說）
    public static func match(name raw: String, in catalog: Catalog) -> MenuItem? {
        let name = normalized(raw)
        guard !name.isEmpty else { return nil }
        let items = catalog.items
        if let exact = items.first(where: { normalized($0.name) == name || $0.shortName.map(normalized) == name }) { return exact }
        // 菜單的名字被整個說出來了（「鴨胸肉」裡有「鴨胸」）：長的先（「鴨胸」與「鴨」都在時是鴨胸）
        if let contained = items.filter({ name.contains(normalized($0.name)) }).max(by: { $0.name.count < $1.name.count }) { return contained }
        if let partial = items.filter({ normalized($0.name).contains(name) }).min(by: { $0.name.count < $1.name.count }) { return partial }
        let chars = Set(name)
        let scored = items.map { item -> (MenuItem, Double) in
            let n = Set(normalized(item.name))
            let common = Double(n.intersection(chars).count)
            return (item, common / Double(max(n.count, 1)))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.5 else { return nil }
        return best.0
    }

    /// 規格：「140」對到價錢 140 的、「大」對到選項有「大」的；只有一個規格就是它
    public static func variant(_ raw: String, of item: MenuItem) -> ItemVariant? {
        let options = item.activeVariants
        guard !options.isEmpty else { return nil }
        let text = normalized(raw)
        if !text.isEmpty {
            if let n = number(text) ?? Int(text.filter(\.isNumber)),
               let byPrice = options.first(where: { item.price(of: $0).cents == n * 100 }) { return byPrice }
            if let byLabel = options.first(where: { v in v.options.contains { o in normalized(o) == text || text.contains(normalized(o)) } }) {
                return byLabel
            }
        }
        return options.count == 1 ? options[0] : nil
    }

    // MARK: 沒有模型時：整句話直接找

    /// 從整句話裡找菜單上的品名（長的先、不重疊），再分配數量與價錢（規格）：
    /// - 標點、「跟」「和」「還有」「然後」「另外」把一句話分成好幾段
    /// - 緊接在品名前面的數字（「兩份鴨胸」）就是它的；不然看後面同一段裡的（「鴨胸兩份」）；一個數字只給一樣
    /// - 後面說的數字剛好是某個規格的價錢（「鴨胸 140」）＝那個規格
    /// 「鴨胸 140 兩份、鴨心一串，還有三個鴨頭」→ [鴨胸 140 ×2, 鴨心 ×1, 鴨頭 ×3]
    public static func parse(_ text: String, catalog: Catalog) -> [Line] {
        let s = Array(segmented(text, catalog: catalog))
        guard !s.isEmpty else { return [] }
        // 每一個位置往後找最長的品名
        let names = catalog.items.flatMap { item in
            ([item.name] + [item.shortName].compactMap { $0 }).map { (Array(normalized($0)), item) }
        }.filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }
        var hits: [(range: Range<Int>, item: MenuItem)] = []
        var i = 0
        while i < s.count {
            if let hit = names.first(where: { n in i + n.0.count <= s.count && Array(s[i..<(i + n.0.count)]) == n.0 }) {
                hits.append((i..<(i + hit.0.count), hit.1))
                i += hit.0.count
            } else {
                i += 1
            }
        }
        let nums = numbers(in: s)
        var used = Set<Int>()
        var out: [Line] = []
        for (k, hit) in hits.enumerated() {
            let nextStart = k + 1 < hits.count ? hits[k + 1].range.lowerBound : s.count
            let prevEnd = k > 0 ? hits[k - 1].range.upperBound : 0
            // 後面同一段（到下一個分隔或下一樣為止）
            let afterEnd = (hit.range.upperBound..<nextStart).first { s[$0] == boundary } ?? nextStart
            let after = nums.filter { $0.start >= hit.range.upperBound && $0.end <= afterEnd }
            // 緊接在前面的（同一段、沒被前一樣用掉）
            let beforeStart = ((prevEnd..<hit.range.lowerBound).last { s[$0] == boundary }).map { $0 + 1 } ?? prevEnd
            let before = nums.last { $0.start >= beforeStart && $0.end == hit.range.lowerBound && !used.contains($0.start) }

            let priced = after.first { n in hit.item.activeVariants.contains { hit.item.price(of: $0).cents == n.value * 100 } }
            var variant = priced.flatMap { p in hit.item.activeVariants.first { hit.item.price(of: $0).cents == p.value * 100 } }
            if variant == nil {
                variant = labelVariant(in: String(s[hit.range.upperBound..<afterEnd]), of: hit.item)
                    ?? (hit.item.activeVariants.count == 1 ? hit.item.activeVariants.first : nil)
            }
            var quantity = 1
            if let b = before {
                quantity = b.value
                used.insert(b.start)
            } else if let a = after.first(where: { $0.start != priced?.start && $0.value < 100 && !used.contains($0.start) }) {
                quantity = a.value
                used.insert(a.start)
            }
            if let p = priced { used.insert(p.start) }
            out.append(Line(item: hit.item, variant: variant, quantity: max(1, min(quantity, 99))))
        }
        return out
    }

    // MARK: 小工具

    /// 去掉空白、標點，全形轉半形、轉小寫（對名字用）
    static func normalized(_ s: String) -> String {
        let skip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where !skip.contains(u) {
            // 全形英數（Ａ、１）→ 半形
            if (0xFF01...0xFF5E).contains(u.value), let half = UnicodeScalar(u.value - 0xFEE0) {
                out.append(half)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    private static let asciiDigits = Set("0123456789")
    private static let chineseNumerals = Set("零〇一二兩两三四五六七八九十百")
    private static let units = Set("份個串盒包碗杯支塊片條隻顆粒袋")

    /// 一句話裡的數字：位置（end 含後面的量詞「份」「個」）與值。阿拉伯數字和中文數字分開算（「140兩份」是 140 和 兩）
    private static func numbers(in chars: [Character]) -> [(value: Int, start: Int, end: Int)] {
        var out: [(value: Int, start: Int, end: Int)] = []
        var i = 0
        while i < chars.count {
            let kind: Set<Character>? = asciiDigits.contains(chars[i]) ? asciiDigits : (chineseNumerals.contains(chars[i]) ? chineseNumerals : nil)
            guard let kind else { i += 1; continue }
            var j = i
            while j < chars.count, kind.contains(chars[j]) { j += 1 }
            if let n = number(String(chars[i..<j])) {
                let end = j < chars.count && units.contains(chars[j]) ? j + 1 : j
                out.append((value: n, start: i, end: end))
            }
            i = j
        }
        return out
    }

    /// 分段的記號（標點、「跟」「還有」換成它）
    private static let boundary: Character = "|"
    private static let joiners = ["還有", "然後", "另外", "再來", "跟", "和"]

    /// 去掉空白，標點與連接詞換成分段記號（菜單上有品名用到的連接詞不換：「和風沙拉」的「和」）
    static func segmented(_ s: String, catalog: Catalog) -> String {
        var t = s
        for j in joiners where !catalog.items.contains(where: { $0.name.contains(j) }) {
            t = t.replacingOccurrences(of: j, with: String(boundary))
        }
        let breaks = CharacterSet.punctuationCharacters.union(.symbols)
        var out = String.UnicodeScalarView()
        for u in t.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(u) { continue }
            if breaks.contains(u) { out.append(UnicodeScalar(UInt8(ascii: "|"))); continue }
            if (0xFF01...0xFF5E).contains(u.value), let half = UnicodeScalar(u.value - 0xFEE0) {
                out.append(half)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    /// 後面說的話裡有某個規格的名字（「大」「小」「辣」）
    private static func labelVariant(in s: String, of item: MenuItem) -> ItemVariant? {
        item.activeVariants.first { v in v.options.contains { o in !o.isEmpty && Int(o) == nil && s.contains(normalized(o)) } }
    }
}
