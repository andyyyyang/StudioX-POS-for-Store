import Foundation

// 電文外面那一層（聯卡中心端末程式的收送）：
//
//   RS-232：STX 資料 ETX LRC。LRC＝資料加 ETX 逐位元組 XOR（STX 不算）；對方收好回 ACK ACK、壞了回 NAK NAK，最多重送 3 次。
//   UDP（區網，刷卡機預設 50002）：SOH＋16 碼標頭（POSTxUniqueNo）＋STX 資料 ETX LRC＋EOT；LRC 一樣只算資料加 ETX。
//     刷卡機回覆時原樣帶回標頭：靠它認出是哪一筆的回覆（前一筆遲到的回覆不會被當成這一筆）。
//     端末程式寫「最多 5 個封包」：一框太長時拆成幾個 UDP 封包、照順序接回來（怎麼拆是推的，見 docs/PAYMENTS-INSTORE.md）。

/// 控制字元
public enum ECRControl {
    public static let soh: UInt8 = 0x01
    public static let stx: UInt8 = 0x02
    public static let etx: UInt8 = 0x03
    public static let eot: UInt8 = 0x04
    public static let ack: UInt8 = 0x06
    public static let nak: UInt8 = 0x15
}

public enum ECRSignal: Sendable, Hashable {
    case ack, nak
}

public enum ECRError: Error, Sendable, Hashable {
    case invalidAmount(String)
    case invalidField(String)
    case badLength(expected: Int, got: Int)
    case badFrame(String)
    case badChecksum
    case tooManyPackets
    /// 還沒設定刷卡機（IP）
    case notConfigured
    /// 這家銀行的格式還沒做
    case unsupported(String)
    /// 刷卡機正在處理別的
    case busy
    /// 第一個封包就送不出去：刷卡機一定沒收到
    case notSent(String)
    case unreachable(String)
    /// 等不到結果。heardBack：刷卡機有回過東西（ACK）
    case noResponse(heardBack: Bool)
    /// 刷卡機一直回 NAK
    case rejected
    /// 查上一筆：刷卡機上沒有這一筆（沒有扣款）
    case notOnTerminal

    public var message: String {
        switch self {
        case .invalidAmount(let r): "金額不對：\(r)"
        case .invalidField(let r): "電文欄位不對：\(r)"
        case .badLength(let expected, let got): "刷卡機回的電文長度不對（\(got)，應該是 \(expected)）"
        case .badFrame(let r): "刷卡機回的封包壞了（\(r)）"
        case .badChecksum: "刷卡機回的封包檢查碼不對"
        case .tooManyPackets: "電文太長，超過 5 個封包"
        case .notConfigured: "還沒設定刷卡機的 IP"
        case .unsupported(let r): r
        case .busy: "刷卡機正在處理上一筆"
        case .notSent(let r): "送不到刷卡機：\(r)"
        case .unreachable(let r): "連不到刷卡機：\(r)"
        case .noResponse(let heard):
            heard ? "刷卡機收到了，但沒有回結果" : "刷卡機沒有回應（IP、連接埠，或銀行還沒開收銀機連線）"
        case .rejected: "刷卡機一直回 NAK（電文格式不對）"
        case .notOnTerminal: "刷卡機上沒有這一筆"
        }
    }

    /// 可能已經到刷卡機了（之後要查上一筆才知道有沒有扣款）。
    /// 組電文就錯、沒設定、第一個封包就送不出去的：一定沒有扣款
    public var mayHaveReachedTerminal: Bool {
        switch self {
        case .invalidAmount, .invalidField, .notConfigured, .unsupported, .busy, .notSent: false
        default: true
        }
    }
}

public enum ECRFraming {
    public static let udpHeaderLength = 16
    public static let udpMaxPackets = 5
    public static let defaultUDPPort = 50002

    /// 收好了回兩個 ACK、壞了回兩個 NAK（端末程式收的時候要連續兩個才算）
    public static let ackBytes: [UInt8] = [ECRControl.ack, ECRControl.ack]
    public static let nakBytes: [UInt8] = [ECRControl.nak, ECRControl.nak]

    /// 資料加 ETX 逐位元組 XOR（STX、SOH、標頭不算）
    public static func lrc<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0, ^)
    }

    /// RS-232 的一框：STX 資料 ETX LRC（資料裡的 0x00 換成空白，和端末程式一樣）
    public static func frame(_ data: [UInt8]) -> [UInt8] {
        let body = data.map { $0 == 0 ? 0x20 : $0 } + [ECRControl.etx]
        return [ECRControl.stx] + body + [lrc(body)]
    }

    /// 拆 RS-232 的一框：STX、ETX 位置、LRC 都要對
    public static func unframe(_ frame: [UInt8], dataLength: Int) throws -> [UInt8] {
        guard frame.count >= dataLength + 3 else { throw ECRError.badLength(expected: dataLength + 3, got: frame.count) }
        guard frame[0] == ECRControl.stx else { throw ECRError.badFrame("開頭不是 STX") }
        guard frame[dataLength + 1] == ECRControl.etx else { throw ECRError.badFrame("第 \(dataLength + 2) 個位元組不是 ETX") }
        let body = frame[1...(dataLength + 1)]
        guard lrc(body) == frame[dataLength + 2] else { throw ECRError.badChecksum }
        return Array(frame[1...dataLength])
    }

    /// ACK／NAK（端末程式送兩個；收的時候一個也算，中間夾雜訊不算）
    public static func signal(_ bytes: [UInt8]) -> ECRSignal? {
        guard !bytes.isEmpty else { return nil }
        if bytes.allSatisfy({ $0 == ECRControl.ack }) { return .ack }
        if bytes.allSatisfy({ $0 == ECRControl.nak }) { return .nak }
        return nil
    }

    // MARK: UDP

    /// SOH 標頭(16) STX 資料 ETX LRC EOT
    public static func udpFrame(_ data: [UInt8], header: String) throws -> [UInt8] {
        let h = Array(header.utf8)
        guard h.count == udpHeaderLength, h.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            throw ECRError.invalidField("UDP 標頭要剛好 16 個英數字")
        }
        return [ECRControl.soh] + h + frame(data) + [ECRControl.eot]
    }

    /// 一框拆成幾個 UDP 封包（每個最多 maxPacketSize）；超過 5 個不送
    public static func udpPackets(_ frame: [UInt8], maxPacketSize: Int) throws -> [[UInt8]] {
        let size = max(maxPacketSize, 1)
        var out: [[UInt8]] = []
        var i = 0
        while i < frame.count {
            out.append(Array(frame[i..<min(i + size, frame.count)]))
            i += size
        }
        guard out.count <= udpMaxPackets else { throw ECRError.tooManyPackets }
        return out
    }

    /// UDP 一框的總長度
    public static func udpFrameLength(dataLength: Int) -> Int { 1 + udpHeaderLength + dataLength + 4 }
}

/// 每筆交易的 16 碼標頭（POSTxUniqueNo）：台北時間 yyMMddHHmmss＋4 碼流水號。同一台 iPad 不會重複
public final class ECRHeaderSource: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: Int

    public init(seed: Int = Int.random(in: 0..<10_000)) {
        counter = seed
    }

    public func next(at date: Date = Date()) -> String {
        lock.lock()
        counter = (counter + 1) % 10_000
        let n = counter
        lock.unlock()
        let c = TaipeiTime.components(date)
        return String(format: "%02d%02d%02d%02d%02d%02d%04d", (c.year ?? 2026) % 100, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, n)
    }
}

/// 把收到的 UDP 封包接回一框。不是 SOH 開頭、又沒在接的：當成 ACK／NAK 看
public struct ECRUDPReassembler: Sendable {
    public enum Event: Sendable, Hashable {
        case signal(ECRSignal)
        /// 一框收齊、LRC 對。header 空的＝刷卡機沒包 UDP 標頭（直接 STX 開頭）
        case message(header: String, data: [UInt8])
        /// 收齊了但壞了（要回 NAK 請對方重送）；header 拆得出來才有
        case corrupt(header: String?, ECRError)
    }

    public let dataLength: Int
    private var buffer: [UInt8] = []
    private var packets = 0

    public init(dataLength: Int = NCCC8N1.length) {
        self.dataLength = dataLength
    }

    public var isAssembling: Bool { !buffer.isEmpty }

    public mutating func reset() {
        buffer = []
        packets = 0
    }

    /// 收到一個封包；還沒收齊回 nil
    public mutating func append(_ packet: [UInt8]) -> Event? {
        guard let first = packet.first else { return nil }
        let total = ECRFraming.udpFrameLength(dataLength: dataLength)
        // 又一個 SOH 開頭、接上去也湊不剛好：前面那一框放棄，從這個重新開始（LRC 剛好是 0x01 的尾巴照樣接）
        if !buffer.isEmpty, first == ECRControl.soh, buffer.count + packet.count != total {
            reset()
        }
        if buffer.isEmpty {
            if first == ECRControl.stx {
                // 沒包 UDP 標頭的一框（像 RS-232 轉網路盒）
                do {
                    return .message(header: "", data: try ECRFraming.unframe(packet, dataLength: dataLength))
                } catch let e as ECRError {
                    return .corrupt(header: nil, e)
                } catch {
                    return .corrupt(header: nil, .badFrame("拆不開"))
                }
            }
            guard first == ECRControl.soh else {
                return ECRFraming.signal(packet).map { Event.signal($0) }
            }
            // 包了標頭的 ACK／NAK：SOH 標頭 ACK [EOT]
            if packet.count <= ECRFraming.udpHeaderLength + 3, packet.count > ECRFraming.udpHeaderLength + 1 {
                let rest = packet[(ECRFraming.udpHeaderLength + 1)...].filter { $0 != ECRControl.eot }
                if let s = ECRFraming.signal(Array(rest)) { return Event.signal(s) }
            }
        }
        buffer += packet
        packets += 1
        if buffer.count < total {
            guard packets < ECRFraming.udpMaxPackets else {
                let header = Self.header(in: buffer)
                reset()
                return .corrupt(header: header, .tooManyPackets)
            }
            return nil
        }
        let frame = Array(buffer.prefix(total))
        reset()
        return Self.parse(frame, dataLength: dataLength)
    }

    static func header(in bytes: [UInt8]) -> String? {
        guard bytes.count > ECRFraming.udpHeaderLength else { return nil }
        return String(decoding: bytes[1...ECRFraming.udpHeaderLength], as: UTF8.self)
    }

    static func parse(_ frame: [UInt8], dataLength: Int) -> Event {
        let h = ECRFraming.udpHeaderLength
        let header = Self.header(in: frame)
        guard frame[0] == ECRControl.soh else { return .corrupt(header: header, .badFrame("開頭不是 SOH")) }
        guard frame[frame.count - 1] == ECRControl.eot else { return .corrupt(header: header, .badFrame("結尾不是 EOT")) }
        do {
            let data = try ECRFraming.unframe(Array(frame[(h + 1)..<(frame.count - 1)]), dataLength: dataLength)
            return .message(header: header ?? "", data: data)
        } catch let e as ECRError {
            return .corrupt(header: header, e)
        } catch {
            return .corrupt(header: header, .badFrame("拆不開"))
        }
    }
}
