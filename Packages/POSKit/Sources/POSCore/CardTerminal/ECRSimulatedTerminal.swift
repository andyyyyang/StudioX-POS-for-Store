import Foundation

/// 模擬的聯卡中心刷卡機（不連網路）：示範模式、測試用。收到交易先回 ACK，過 delay 回核准；
/// 查上一筆、電子錢包查詢、取消、退貨、刷卡機結帳、連線測試都照電文回。
/// 測試可以排好下一筆怎麼反應（拒絕、不理、做了但結果沒回來），看 POS 會不會重複扣款
public actor ECRSimulatedTerminal: ECRTransport {
    public enum Reaction: Sendable, Hashable {
        case approve
        case decline(String)
        /// 收了不理：不回 ACK、不做、不回（像封包掉了）
        case ignore
        /// 做了、也記成上一筆，但結果沒回來（像回程斷線）
        case approveSilently
    }

    public let terminalId = "13990001"
    public let merchantId = "000812345678901"

    /// 等客人刷卡要多久
    public var delay: Duration
    /// 查上一筆、連線測試要多久
    public var queryDelay: Duration
    public var sendsAck: Bool
    /// 斷線：送來的都收不到、也不回
    public private(set) var offline = false
    /// 收到的每一則電文（測試看送了什麼）
    public private(set) var received: [ECRMessage] = []

    private struct Entry {
        var message: ECRMessage
        var due: ContinuousClock.Instant
        var voided = false
    }

    private let clock = ContinuousClock()
    private var script: [Reaction] = []
    private var corruptNext = false
    private var outbox: [(due: ContinuousClock.Instant, packet: [UInt8])] = []
    private var lastFrame: [UInt8]?
    private var reassembler = ECRUDPReassembler()
    private var receipt = 0
    private var batch = 1
    /// 這一批做完的交易（到了 due 才算做完）
    private var journal: [Entry] = []

    public init(delay: Duration = .seconds(2), queryDelay: Duration = .milliseconds(300), sendsAck: Bool = true) {
        self.delay = delay
        self.queryDelay = queryDelay
        self.sendsAck = sendsAck
    }

    /// 接下來幾筆交易怎麼反應（沒排的就核准）
    public func queue(_ reactions: [Reaction]) {
        script += reactions
    }

    /// 下一個回覆的 LRC 弄壞（收到 NAK 再送好的）
    public func corruptNextResponse() {
        corruptNext = true
    }

    public func setOffline(_ value: Bool) {
        offline = value
    }

    public func setDelay(_ value: Duration) {
        delay = value
    }

    /// 直接塞一個封包給 POS（測試：前一筆遲到的回覆）
    public func inject(_ packet: [UInt8]) {
        outbox.append((due: clock.now, packet: packet))
    }

    /// 店員在刷卡機上按了取消：還沒做完的那一筆不做了、也不回（POS 查上一筆會查不到它）
    public func cancelPending() {
        let now = clock.now
        journal.removeAll { $0.due > now }
        outbox.removeAll { $0.due > now }
    }

    // MARK: ECRTransport

    public func send(_ packet: [UInt8]) async throws {
        guard !offline, let event = reassembler.append(packet) else { return }
        switch event {
        case .signal(.nak):
            if let lastFrame { outbox.append((due: clock.now, packet: lastFrame)) }
        case .signal(.ack):
            break
        case .corrupt:
            outbox.append((due: clock.now, packet: ECRFraming.nakBytes))
        case .message(let header, let data):
            guard let request = try? ECRMessage(bytes: data) else { return }
            received.append(request)
            handle(request, header: header)
        }
    }

    public func receive(timeout: Duration) async throws -> [UInt8]? {
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let now = clock.now
            if !offline, let i = outbox.indices.filter({ outbox[$0].due <= now }).min(by: { outbox[$0].due < outbox[$1].due }) {
                return outbox.remove(at: i).packet
            }
            if now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: 刷卡機

    private func handle(_ request: ECRMessage, header: String) {
        let type = ECRTransType(rawValue: request.value(NCCC8N1.transType))
        let moves = type.map { $0.needsAmount || $0 == .void } ?? false
        let reaction: Reaction = moves && !script.isEmpty ? script.removeFirst() : .approve
        if reaction == .ignore { return }
        if sendsAck { outbox.append((due: clock.now, packet: ECRFraming.ackBytes)) }
        let now = clock.now
        switch type {
        case .echo?:
            reply(answer(request, code: "0000"), header: header, at: now.advanced(by: queryDelay))
        case .lastTransaction?:
            reply(lastAnswer(request, now: now), header: header, at: now.advanced(by: queryDelay))
        case .walletQuery?:
            let last = completed(now).last { $0.message.value(NCCC8N1.paymentKind) == ECRPaymentKind.wallet.rawValue }
            reply(last?.message ?? answer(request, code: "0001"), header: header, at: now.advanced(by: queryDelay))
        case .settlement?:
            reply(settle(request, now: now), header: header, at: now.advanced(by: queryDelay))
        case .void?:
            reply(void(request, reaction: reaction, now: now), header: header, at: now.advanced(by: delay), silent: reaction == .approveSilently)
        case .some(let t) where t.needsAmount:
            let m = transaction(request, reaction: reaction)
            let due = now.advanced(by: delay)
            if m.value(NCCC8N1.responseCode) == "0000" { journal.append(Entry(message: m, due: due)) }
            reply(m, header: header, at: due, silent: reaction == .approveSilently)
        default:
            reply(answer(request, code: "0001"), header: header, at: now.advanced(by: queryDelay))
        }
    }

    private func reply(_ m: ECRMessage, header: String, at due: ContinuousClock.Instant, silent: Bool = false) {
        guard !silent, let frame = try? ECRFraming.udpFrame(m.bytes, header: header) else { return }
        lastFrame = frame
        if corruptNext {
            corruptNext = false
            var bad = frame
            bad[20] ^= 0x01
            outbox.append((due: due, packet: bad))
        } else {
            outbox.append((due: due, packet: frame))
        }
    }

    private func completed(_ now: ContinuousClock.Instant) -> [Entry] {
        journal.filter { $0.due <= now }
    }

    /// 回一則：照抄收銀機送的，填回應碼、端末、日期時間
    private func answer(_ request: ECRMessage, code: String) -> ECRMessage {
        var m = request
        let c = TaipeiTime.components(Date())
        try? m.set(NCCC8N1.transDate, digits: String(format: "%02d%02d%02d", (c.year ?? 2026) % 100, c.month ?? 1, c.day ?? 1))
        try? m.set(NCCC8N1.transTime, digits: String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0))
        try? m.set(NCCC8N1.responseCode, digits: code)
        try? m.set(NCCC8N1.merchantId, text: merchantId)
        try? m.set(NCCC8N1.terminalId, text: terminalId)
        return m
    }

    private func transaction(_ request: ECRMessage, reaction: Reaction) -> ECRMessage {
        if case .decline(let code) = reaction { return answer(request, code: code) }
        var m = answer(request, code: "0000")
        receipt += 1
        try? m.set(NCCC8N1.receiptNo, digits: String(receipt))
        try? m.set(NCCC8N1.batchNo, digits: String(batch))
        let kind = ECRPaymentKind(rawValue: request.value(NCCC8N1.paymentKind)) ?? .card
        let tail = String(format: "%04d", (receipt * 7_919 + 1_234) % 10_000)
        switch kind {
        case .eTicket:
            try? m.set(NCCC8N1.cardNo, text: "1***\(tail)")
            try? m.set(NCCC8N1.cardType, digits: ECRCardBrand.easyCard.rawValue)
            try? m.set(NCCC8N1.approvalNo, text: String(format: "%06d", receipt))
            try? m.set(NCCC8N1.waveIndicator, text: "Z")
            try? m.set(NCCC8N1.downPayment, digits: "50000")
            try? m.set(NCCC8N1.installmentPayment, digits: "38000")
        case .wallet:
            try? m.set(NCCC8N1.cardType, digits: ECRCardBrand.linePay.rawValue)
            try? m.set(NCCC8N1.walletOrderId, text: "DEMO\(String(format: "%06d", receipt))")
            try? m.set(NCCC8N1.walletTransactionId, text: "2026\(String(format: "%012d", receipt * 104_729))")
        default:
            try? m.set(NCCC8N1.cardNo, text: "431195******\(tail)")
            try? m.set(NCCC8N1.cardType, digits: ECRCardBrand.visa.rawValue)
            try? m.set(NCCC8N1.approvalNo, text: String(format: "%06d", (receipt * 104_729) % 1_000_000))
            try? m.set(NCCC8N1.waveIndicator, text: "V")
        }
        return m
    }

    /// 取消：找這一批還沒取消的原交易（調閱編號），金額照原交易
    private func void(_ request: ECRMessage, reaction: Reaction, now: ContinuousClock.Instant) -> ECRMessage {
        if case .decline(let code) = reaction { return answer(request, code: code) }
        let want = Int(request.value(NCCC8N1.receiptNo))
        guard let i = journal.indices.first(where: { journal[$0].due <= now && !journal[$0].voided
            && Int(journal[$0].message.value(NCCC8N1.receiptNo)) == want
            && journal[$0].message.value(NCCC8N1.transType) != ECRTransType.void.rawValue }) else {
            return answer(request, code: "0001")
        }
        journal[i].voided = true
        var m = journal[i].message
        try? m.set(NCCC8N1.transType, digits: ECRTransType.void.rawValue)
        let done = answer(m, code: "0000")
        journal.append(Entry(message: done, due: now.advanced(by: delay)))
        return done
    }

    /// 查上一筆：上一筆是電子錢包回 0010（要改用 68 查）
    private func lastAnswer(_ request: ECRMessage, now: ContinuousClock.Instant) -> ECRMessage {
        guard let last = completed(now).last else { return answer(request, code: "0001") }
        if last.message.value(NCCC8N1.paymentKind) == ECRPaymentKind.wallet.rawValue {
            var m = answer(request, code: "0010")
            try? m.set(NCCC8N1.paymentKind, text: ECRPaymentKind.wallet.rawValue)
            return m
        }
        return last.message
    }

    /// 刷卡機結帳：這一批的筆數、金額（取消的不算），換下一批
    private func settle(_ request: ECRMessage, now: ContinuousClock.Instant) -> ECRMessage {
        let sales = completed(now).filter {
            !$0.voided && $0.message.value(NCCC8N1.transType) != ECRTransType.void.rawValue
                && $0.message.value(NCCC8N1.transType) != ECRTransType.refund.rawValue
        }
        let total = sales.compactMap { ECRAmount.decode($0.message[NCCC8N1.amount])?.cents }.reduce(0, +)
        var m = answer(request, code: "0000")
        try? m.set(NCCC8N1.cardExpiry, digits: String(sales.count))
        if total > 0 { try? m.set(NCCC8N1.amount, digits: String(total)) }
        try? m.set(NCCC8N1.batchNo, digits: String(batch))
        batch += 1
        journal = []
        return m
    }
}
