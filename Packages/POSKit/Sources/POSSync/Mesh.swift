import Foundation
import POSCore

/// 同一家店、同一個 Wi-Fi 的 iPad 互相同步（網路斷了，櫃台照樣看得到手持機點的單、廚房照樣出單）。
///
/// 傳輸在 App（Network.framework＋Bonjour `_studiox-pos._tcp`）；這裡是訊息格式與簽章：
/// 每則訊息用店家的 mesh 金鑰做 HMAC-SHA256，不是這家店的裝置送來的、或被改過的，直接丟掉。
/// 收到的事件一樣走 Ledger.merge（驗雜湊、去重），所以從雲端或區網來的同一筆事件只會記一次。
public struct MeshEnvelope: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// 新事件（記了就廣播）
        case events
        /// 「我每台看到哪裡了」（剛連上時交換，對方補給我缺的）
        case summary
        /// 「請給我這些裝置在這些流水號之後的事件」
        case request
    }

    public var kind: Kind
    public var from: String
    public var sentAt: String
    public var events: [POSEvent]
    /// summary／request：裝置 → 看過的最大流水號
    public var seen: [String: Int]
    public var mac: String

    public init(kind: Kind, from: String, events: [POSEvent] = [], seen: [String: Int] = [:], key: [UInt8], at date: Date = Date()) throws {
        self.kind = kind
        self.from = from
        self.sentAt = EventCoding.timestamp(date)
        self.events = events
        self.seen = seen
        self.mac = ""
        self.mac = try Self.sign(self, key: key)
    }

    static func sign(_ e: MeshEnvelope, key: [UInt8]) throws -> String {
        var copy = e
        copy.mac = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Crypto.hex(Crypto.hmacSHA256(key: key, message: Array(try encoder.encode(copy))))
    }

    /// 簽章對、而且不是太久以前的（防止錄下來重播；5 分鐘）
    public func isAuthentic(key: [UInt8], now: Date = Date()) -> Bool {
        guard let expected = try? Self.sign(self, key: key) else { return false }
        guard Crypto.constantTimeEquals(Array(expected.utf8), Array(mac.utf8)) else { return false }
        guard let sent = EventCoding.parseTimestamp(sentAt) else { return false }
        return abs(now.timeIntervalSince(sent)) < 300
    }

    /// 每台裝置看過的最大流水號
    public static func seen(in events: [POSEvent]) -> [String: Int] {
        var out: [String: Int] = [:]
        for e in events { out[e.deviceId] = max(out[e.deviceId] ?? 0, e.seq) }
        return out
    }

    /// 對方看到的比我少：我手上有、他沒有的事件
    public static func missing(theirs: [String: Int], from events: [POSEvent]) -> [POSEvent] {
        events.filter { $0.seq > (theirs[$0.deviceId] ?? 0) }.sorted(by: POSEvent.replayOrder)
    }
}
