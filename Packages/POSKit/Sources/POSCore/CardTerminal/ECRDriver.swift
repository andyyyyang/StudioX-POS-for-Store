import Foundation

// 刷卡機的「司機」：每家銀行的電文格式不一樣（台新和聯卡中心就不同），POS 只認 ECRDriver。
// 聯卡中心 8N1 標準是第一個（NCCCDriver）；連線（UDP、序列轉網路盒）由 ECRTransport 接，App 用 Network.framework 做 UDP。
//
// 不重複扣款：
//   - 交易只送一次；刷卡機回 NAK 才用「同一個標頭」重送（刷卡機認得是同一筆）
//   - 等不到結果（逾時、斷線、按了取消）→ 查上一筆（62；上一筆是電子錢包再查 68），金額、交易別對得上、
//     又不是已經記過的調閱編號，才算這一筆成功；對不上＝沒有扣款；連查都查不到＝不確定，交給人看刷卡機
//   - 不會自動再送一次交易

/// 刷卡機的電文格式（哪一家）
public enum ECRFormat: String, Codable, Sendable, Hashable, CaseIterable {
    /// 聯卡中心 8N1 標準（400）
    case nccc
    /// 台新：格式不同（TransType、DataLen、CRC、SQNo），還沒做
    case taishin
    /// 其他銀行
    case other

    public var label: String {
        switch self {
        case .nccc: "聯卡中心 NCCC"
        case .taishin: "台新銀行"
        case .other: "其他銀行"
        }
    }

    public var detail: String {
        switch self {
        case .nccc: "8N1 標準、UDP 收銀機連線"
        case .taishin, .other: "即將支援"
        }
    }

    public var isSupported: Bool { self == .nccc }
}

/// 連線：送一個封包、等下一個封包（timeout 內沒有回 nil）
public protocol ECRTransport: Sendable {
    func send(_ packet: [UInt8]) async throws
    func receive(timeout: Duration) async throws -> [UInt8]?
}

/// 交易進行到哪
public enum ECRProgress: Sendable, Hashable {
    /// 送出去了
    case sent
    /// 刷卡機收到了（ACK）：等客人刷卡
    case acknowledged
    /// 按了取消：等刷卡機回
    case cancelling
    /// 等不到結果：查上一筆
    case checking
}

/// 看著一筆交易：進度、取消。取消不是馬上斷線——刷卡機可能已經在扣款，要等它回（或查上一筆）才知道
public final class ECRWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let onProgress: @Sendable (ECRProgress) -> Void

    public init(progress: @escaping @Sendable (ECRProgress) -> Void = { _ in }) {
        onProgress = progress
    }

    public var isCancelRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func requestCancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { onProgress(.cancelling) }
    }

    public func report(_ p: ECRProgress) {
        onProgress(p)
    }
}

/// 一家銀行的刷卡機
public protocol ECRDriver: Sendable {
    var format: ECRFormat { get }
    /// 消費；installments 有值＝分期
    func sale(_ amount: Money, kind: ECRPaymentKind, installments: Int?, watch: ECRWatch?) async throws -> ECRResult
    /// 退貨（客人要再刷原卡）
    func refund(_ amount: Money, kind: ECRPaymentKind, original: CardTerminalRef?, watch: ECRWatch?) async throws -> ECRResult
    /// 取消（同一批還沒結帳，用原交易的調閱編號）
    func void(_ original: CardTerminalRef, amount: Money?, watch: ECRWatch?) async throws -> ECRResult
    /// 刷卡機結帳（日結）
    func settle() async throws -> ECRResult
    func lastTransaction() async throws -> ECRResult
    func walletQuery(orderId: String?) async throws -> ECRResult
    func echo() async throws -> ECRResult
}

// MARK: - 聯卡中心 8N1 標準（UDP）

public struct NCCCDriver: ECRDriver {
    public struct Options: Sendable, Hashable {
        /// 等客人刷卡、主機授權的時間
        public var responseTimeout: Duration
        /// 連線測試、查上一筆
        public var quickTimeout: Duration
        /// 刷卡機結帳（要連主機，比較久）
        public var settlementTimeout: Duration
        /// 按了取消之後還等多久（刷卡機上按取消會回「使用者終止」；客人剛好刷了也會回核准）
        public var cancelGrace: Duration
        /// NAK 最多重送幾次
        public var retries: Int
        /// 一個 UDP 封包最多多大
        public var maxPacketSize: Int
        public var ecrIndicator: String
        public var versionDate: String

        public init(responseTimeout: Duration = .seconds(90), quickTimeout: Duration = .seconds(10), settlementTimeout: Duration = .seconds(180),
                    cancelGrace: Duration = .seconds(20), retries: Int = 3, maxPacketSize: Int = 1024, ecrIndicator: String = "I",
                    versionDate: String = NCCC8N1.currentVersion) {
            self.responseTimeout = responseTimeout; self.quickTimeout = quickTimeout; self.settlementTimeout = settlementTimeout
            self.cancelGrace = cancelGrace; self.retries = retries; self.maxPacketSize = maxPacketSize
            self.ecrIndicator = ecrIndicator; self.versionDate = versionDate
        }
    }

    public var format: ECRFormat { .nccc }
    public let transport: any ECRTransport
    public var options: Options
    let headers: ECRHeaderSource

    public init(transport: any ECRTransport, options: Options = Options(), headers: ECRHeaderSource = ECRHeaderSource()) {
        self.transport = transport
        self.options = options
        self.headers = headers
    }

    public func sale(_ amount: Money, kind: ECRPaymentKind, installments: Int?, watch: ECRWatch?) async throws -> ECRResult {
        let request = installments.map { ECRRequest.installment(amount, periods: $0) } ?? ECRRequest.sale(amount, kind: kind)
        return try await run(request, timeout: options.responseTimeout, watch: watch)
    }

    public func refund(_ amount: Money, kind: ECRPaymentKind, original: CardTerminalRef?, watch: ECRWatch?) async throws -> ECRResult {
        let request = ECRRequest.refund(amount, kind: kind, approvalNo: original?.approvalNo, walletOrderId: original?.walletOrderId)
        return try await run(request, timeout: options.responseTimeout, watch: watch)
    }

    public func void(_ original: CardTerminalRef, amount: Money?, watch: ECRWatch?) async throws -> ECRResult {
        guard let receipt = original.receiptNo, !receipt.isEmpty else { throw ECRError.invalidField("原交易沒有調閱編號") }
        let kind = original.kind.flatMap(ECRPaymentKind.init(rawValue:)) ?? .card
        return try await run(ECRRequest.void(receiptNo: receipt, amount: amount, kind: kind), timeout: options.responseTimeout, watch: watch)
    }

    public func settle() async throws -> ECRResult {
        try await run(.settlement, timeout: options.settlementTimeout, watch: nil)
    }

    public func lastTransaction() async throws -> ECRResult {
        try await run(.lastTransaction, timeout: options.quickTimeout, watch: nil)
    }

    public func walletQuery(orderId: String?) async throws -> ECRResult {
        try await run(.walletQuery(orderId: orderId), timeout: options.quickTimeout, watch: nil)
    }

    public func echo() async throws -> ECRResult {
        try await run(.echo, timeout: options.quickTimeout, watch: nil)
    }

    func run(_ request: ECRRequest, timeout: Duration, watch: ECRWatch?) async throws -> ECRResult {
        var r = request
        r.ecrIndicator = options.ecrIndicator
        r.versionDate = options.versionDate
        let response = try await exchange(r, timeout: timeout, watch: watch)
        return ECRResult(response, requested: request.transType)
    }

    /// 送一則、收它的回覆：回 ACK、壞了回 NAK；別筆的回覆（標頭不同）不理
    public func exchange(_ request: ECRRequest, timeout: Duration, watch: ECRWatch?) async throws -> ECRResponse {
        let message = try request.pack()
        let header = headers.next()
        let packets = try ECRFraming.udpPackets(ECRFraming.udpFrame(message.bytes, header: header), maxPacketSize: options.maxPacketSize)
        do {
            try await sendAll(packets)
        } catch let e as ECRError {
            throw e.mayHaveReachedTerminal ? ECRError.notSent(e.message) : e
        } catch {
            throw ECRError.notSent("\(error)")
        }
        watch?.report(.sent)

        var reassembler = ECRUDPReassembler(dataLength: NCCC8N1.length)
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: timeout)
        var graceStarted = false
        var heardBack = false
        var naks = 0
        var corrupt = 0

        while true {
            // 按了取消：再等一下刷卡機的答覆（刷卡機上按取消會回；客人剛好刷了也會回核准）
            if let watch, !graceStarted, watch.isCancelRequested {
                graceStarted = true
                deadline = min(deadline, clock.now.advanced(by: options.cancelGrace))
            }
            let now = clock.now
            guard now < deadline else { throw ECRError.noResponse(heardBack: heardBack) }
            let wait = min(now.duration(to: deadline), .milliseconds(500))
            let received: [UInt8]?
            do {
                received = try await transport.receive(timeout: wait)
            } catch let e as ECRError {
                throw e.mayHaveReachedTerminal ? e : ECRError.unreachable(e.message)
            } catch {
                throw ECRError.noResponse(heardBack: heardBack)
            }
            guard let packet = received, let event = reassembler.append(packet) else { continue }
            switch event {
            case .signal(.ack):
                if !heardBack { watch?.report(.acknowledged) }
                heardBack = true
            case .signal(.nak):
                heardBack = true
                naks += 1
                guard naks <= options.retries else { throw ECRError.rejected }
                // 同一個標頭重送：刷卡機認得是同一筆，不會變成兩筆
                try await sendAll(packets)
            case .corrupt(let h, let reason):
                // 別筆的不管；這一筆的請刷卡機重送
                if let h, !h.isEmpty, h != header { continue }
                heardBack = true
                corrupt += 1
                guard corrupt <= options.retries else { throw reason }
                try? await transport.send(ECRFraming.nakBytes)
            case .message(let h, let data):
                // 前一筆遲到的回覆：標頭不同，不是這一筆
                if !h.isEmpty, h != header { continue }
                heardBack = true
                guard let response = try? ECRResponse(bytes: data) else {
                    corrupt += 1
                    guard corrupt <= options.retries else { throw ECRError.badLength(expected: NCCC8N1.length, got: data.count) }
                    try? await transport.send(ECRFraming.nakBytes)
                    continue
                }
                // 沒有標頭可以比：交易別也要對（查上一筆的回覆可能帶上一筆的交易別，不比）
                if h.isEmpty, request.transType != .lastTransaction, request.transType != .walletQuery,
                   response.transTypeCode != request.transType.rawValue {
                    continue
                }
                try? await transport.send(ECRFraming.ackBytes)
                return response
            }
        }
    }

    private func sendAll(_ packets: [[UInt8]]) async throws {
        for p in packets { try await transport.send(p) }
    }
}

// MARK: - 一筆交易，到確定有沒有扣款為止

/// 要刷卡機做的事（會動到錢的）
public enum ECROperation: Sendable, Hashable {
    case sale(Money, kind: ECRPaymentKind, installments: Int?)
    case refund(Money, kind: ECRPaymentKind, original: CardTerminalRef?)
    case void(CardTerminalRef, amount: Money?)

    public var transType: ECRTransType {
        switch self {
        case .sale(_, _, let n): n == nil ? .sale : .installment
        case .refund: .refund
        case .void: .void
        }
    }
}

public enum ECROutcome: Sendable, Hashable {
    /// 核准。recovered：沒收到回覆，是查上一筆才確認的
    case approved(ECRResult, recovered: Bool)
    /// 刷卡機回了不核准：沒有扣款，可以再試
    case declined(ECRResult)
    /// 沒有扣款：送不出去，或查上一筆不是這一筆
    case notCharged(ECRError)
    /// 不確定：連上一筆都查不到，要看刷卡機的畫面或簽單
    case unknown(ECRError)
}

public enum ECRCharge {
    /// 做一筆；等不到結果就查上一筆。不會自動再送一次交易
    public static func run(_ driver: any ECRDriver, _ op: ECROperation, known: Set<String>, watch: ECRWatch? = nil,
                           checkAttempts: Int = 3, retryDelay: Duration = .seconds(2)) async -> ECROutcome {
        let result: ECRResult
        do {
            result = try await perform(driver, op, watch: watch)
        } catch let e as ECRError where !e.mayHaveReachedTerminal {
            return .notCharged(e)
        } catch {
            watch?.report(.checking)
            let cause = (error as? ECRError) ?? .noResponse(heardBack: false)
            return await verify(driver, op, known: known, cause: cause, attempts: checkAttempts, retryDelay: retryDelay)
        }
        return result.isApproved ? .approved(result, recovered: false) : .declined(result)
    }

    /// 查上一筆，看這一筆到底有沒有做（上一筆是電子錢包再查 68）
    public static func verify(_ driver: any ECRDriver, _ op: ECROperation, known: Set<String>, cause: ECRError = .noResponse(heardBack: false),
                              attempts: Int = 3, retryDelay: Duration = .seconds(2)) async -> ECROutcome {
        var lastError = cause
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 { try? await Task.sleep(for: retryDelay) }
            do {
                var last = try await driver.lastTransaction()
                if last.status == .walletLast { last = try await driver.walletQuery(orderId: nil) }
                return matches(last, op, known: known) ? .approved(last, recovered: true) : .notCharged(.notOnTerminal)
            } catch let e as ECRError {
                lastError = e
            } catch {
                lastError = .noResponse(heardBack: false)
            }
        }
        return .unknown(lastError)
    }

    /// 上一筆是不是這一筆：核准、交易別對、金額對、不是已經記過的那一筆；取消比原交易的調閱編號
    public static func matches(_ last: ECRResult, _ op: ECROperation, known: Set<String>) -> Bool {
        guard last.isApproved else { return false }
        let type = last.response.transType
        if let type, type != .lastTransaction, type != .walletQuery, type != op.transType { return false }
        switch op {
        case .sale(let amount, _, _), .refund(let amount, _, _):
            guard let got = last.amount, got == amount, last.receiptNo != nil else { return false }
            return !known.contains(last.terminalKey)
        case .void(let original, _):
            // 取消的回覆一定要寫是取消，調閱編號是原交易的
            guard type == .void, let got = last.receiptNo, let want = original.receiptNo else { return false }
            return Int(got) == Int(want)
        }
    }

    static func perform(_ driver: any ECRDriver, _ op: ECROperation, watch: ECRWatch?) async throws -> ECRResult {
        switch op {
        case .sale(let amount, let kind, let installments):
            try await driver.sale(amount, kind: kind, installments: installments, watch: watch)
        case .refund(let amount, let kind, let original):
            try await driver.refund(amount, kind: kind, original: original, watch: watch)
        case .void(let original, let amount):
            try await driver.void(original, amount: amount, watch: watch)
        }
    }
}
