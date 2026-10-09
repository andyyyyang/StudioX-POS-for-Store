import Foundation
import Testing
@testable import POSCore

/// 在第 offset 碼（從 0 起算）放字：測試自己排版面，不靠被測的程式
private func layout(_ fields: [(Int, String)]) -> String {
    var chars = [Character](repeating: " ", count: 400)
    for (offset, s) in fields {
        for (i, ch) in s.enumerated() { chars[offset + i] = ch }
    }
    return String(chars)
}

/// 聯卡中心 8N1 標準（400）：組、拆、金額
struct ECRMessageTests {
    @Test func layoutsAddUpTo400() {
        for fields in [NCCC8N1.standardLayout, NCCC8N1.walletLayout] {
            var at = 0
            for f in fields {
                #expect(f.offset == at, "\(f.name) 應該從 \(at) 開始")
                at = f.end
            }
            #expect(at == 400)
        }
        // 端末程式的欄位表從 1 起算
        #expect(NCCC8N1.amount.offset + 1 == 43)
        #expect(NCCC8N1.approvalNo.offset + 1 == 67)
        #expect(NCCC8N1.responseCode.offset + 1 == 77)
        #expect(NCCC8N1.storeId.offset + 1 == 116)
        #expect(NCCC8N1.installmentPeriod.offset + 1 == 175)
        #expect(NCCC8N1.cardType.offset + 1 == 213)
        #expect(NCCC8N1.batchNo.offset + 1 == 215)
        #expect(NCCC8N1.happyGo.offset + 1 == 323)
    }

    @Test func packSale() throws {
        let m = try ECRRequest.sale(Money(dollars: 1_280)).pack()
        let expected = "I260116 01N03" + String(repeating: " ", count: 29) + "000000128000" + String(repeating: " ", count: 346)
        #expect(expected.count == 400)
        #expect(m.text == expected)
        #expect(m.bytes.count == 400)
        #expect(m.text == layout([(0, "I260116 01N03"), (42, "000000128000")]))
    }

    @Test func packOtherRequests() throws {
        let void = try ECRRequest.void(receiptNo: "123", amount: Money(dollars: 1_280)).pack()
        #expect(void.text == layout([(0, "I260116 30N03000123"), (42, "000000128000")]))

        let refund = try ECRRequest.refund(Money(dollars: 500), approvalNo: "AB1234").pack()
        #expect(refund.text == layout([(0, "I260116 02N03"), (42, "000000050000"), (66, "AB1234")]))

        let installment = try ECRRequest.installment(Money(dollars: 36_000), periods: 6).pack()
        #expect(installment.text == layout([(0, "I260116 04N03"), (42, "000003600000"), (174, "06")]))

        let wallet = try ECRRequest.sale(Money(dollars: 85), kind: .wallet).pack()
        #expect(wallet.text == layout([(0, "I260116 01W08"), (42, "000000008500")]))
        let walletRefund = try ECRRequest.refund(Money(dollars: 85), kind: .wallet, walletOrderId: "DEMO000124").pack()
        #expect(walletRefund[NCCC8N1.walletOrderId] == "DEMO000124" + String(repeating: " ", count: 20))

        let ticket = try ECRRequest.sale(Money(dollars: 120), kind: .eTicket).pack()
        #expect(ticket[NCCC8N1.paymentKind] == "E")
        #expect(ticket[NCCC8N1.hostId] == "06")

        // 查詢類只有交易別
        #expect(try ECRRequest.echo.pack().text == layout([(0, "I260116 98")]))
        #expect(try ECRRequest.lastTransaction.pack().text == layout([(0, "I260116 62")]))
        #expect(try ECRRequest.settlement.pack().text == layout([(0, "I260116 50")]))
        #expect(try ECRRequest.walletQuery().pack().text == layout([(0, "I260116 68W08")]))
    }

    @Test func rejectsBadRequests() {
        #expect(throws: ECRError.self) { try ECRRequest.void(receiptNo: "").pack() }
        #expect(throws: ECRError.self) { try ECRRequest.void(receiptNo: "12A").pack() }
        #expect(throws: ECRError.self) { try ECRRequest.void(receiptNo: "1234567").pack() }
        #expect(throws: ECRError.self) { try ECRRequest.installment(Money(dollars: 100), periods: 1).pack() }
        #expect(throws: ECRError.self) { try ECRRequest(.sale).pack() }
        #expect(throws: ECRError.self) { try ECRRequest.refund(Money(dollars: 1), approvalNo: "1234567890").pack() }
        #expect(throws: ECRError.self) { try ECRRequest.refund(Money(dollars: 1), approvalNo: "授權").pack() }
    }

    @Test func amounts() throws {
        #expect(try ECRAmount.encode(Money(dollars: 1)) == "000000000100")
        #expect(try ECRAmount.encode(Money(dollars: 1_280)) == "000000128000")
        #expect(try ECRAmount.encode(Money(dollars: 9_999_999_999)) == "999999999900")
        // 超過 12 碼、有角分、0、負的：不送
        #expect(throws: ECRError.self) { try ECRAmount.encode(Money(dollars: 10_000_000_000)) }
        #expect(throws: ECRError.self) { try ECRAmount.encode(Money(cents: 128_050)) }
        #expect(throws: ECRError.self) { try ECRAmount.encode(.zero) }
        #expect(throws: ECRError.self) { try ECRAmount.encode(Money(dollars: -5)) }
        #expect(ECRAmount.decode("000000128000") == Money(dollars: 1_280))
        #expect(ECRAmount.decode("999999999900") == Money(dollars: 9_999_999_999))
        #expect(ECRAmount.decode("            ") == nil)
        #expect(ECRAmount.decode("00000012800A") == nil)
        #expect(ECRAmount.decode("-00000003000") == Money(dollars: -30))
    }

    static let approvedCard = layout([
        (0, "I"), (1, "260116"), (8, "01"), (10, "N"), (11, "03"), (13, "000123"), (19, "431195******1234"),
        (42, "000000128000"), (54, "261009"), (60, "143015"), (66, "AB1234"), (75, "V"), (76, "0000"),
        (80, "000812345678901"), (95, "13990001"), (115, "STORE-07"), (212, "02"), (214, "000042"),
    ])

    @Test func unpackApprovedCard() throws {
        let r = try ECRResponse(Self.approvedCard)
        #expect(r.transType == .sale)
        #expect(r.kind == .card)
        #expect(r.hostId == "03")
        #expect(r.receiptNo == "000123")
        #expect(r.cardNo == "431195******1234")
        #expect(r.amount == Money(dollars: 1_280))
        #expect(r.transDate == "261009")
        #expect(r.transTime == "143015")
        #expect(r.approvalNo == "AB1234")
        #expect(r.waveIndicator == "V")
        #expect(r.responseCode == "0000")
        #expect(r.merchantId == "000812345678901")
        #expect(r.terminalId == "13990001")
        #expect(r.storeId == "STORE-07")
        #expect(r.brand == .visa)
        #expect(r.batchNo == "000042")
        #expect(r.wallet == nil)

        let result = ECRResult(r, requested: .sale)
        #expect(result.isApproved)
        #expect(result.last4 == "1234")
        #expect(result.reference == "授權 AB1234・調閱 000123")
        #expect(result.message == "已核准・Visa ****1234")
        let ref = result.terminalRef(format: .nccc)
        #expect(ref.format == "nccc")
        #expect(ref.kind == "N")
        #expect(ref.terminalId == "13990001")
        #expect(ref.merchantId == "000812345678901")
        #expect(ref.batchNo == "000042")
        #expect(ref.receiptNo == "000123")
        #expect(ref.approvalNo == "AB1234")
        #expect(ref.brand == "Visa")
        #expect(ref.hostId == "03")
        #expect(ref.at == "261009143015")
        #expect(ref.key == result.terminalKey)
        #expect(ref.summary == "調閱 000123・授權 AB1234・批次 000042")
    }

    @Test func unpackWalletAndETicket() throws {
        let w = try ECRResponse(layout([
            (0, "I260116 01W08000124"), (42, "000000008500"), (76, "0000"), (80, "000812345678901"), (95, "13990001"),
            (212, "21"), (214, "000042"), (220, "DEMO000124"), (256, "/ABC+123"), (336, "2026100912345678"),
        ]))
        #expect(w.kind == .wallet)
        #expect(w.hostId == "08")
        #expect(w.brand == .linePay)
        #expect(w.brand?.isWallet == true)
        #expect(w.wallet == ECRWalletBlock(orderId: "DEMO000124", carrier: "/ABC+123", refundTradeNo: "", transactionId: "2026100912345678"))
        let wr = ECRResult(w, requested: .sale)
        #expect(wr.isApproved)
        #expect(wr.approvalNo == nil)
        #expect(wr.last4 == nil)
        #expect(wr.reference == "LINE Pay 2026100912345678・調閱 000124")
        #expect(wr.terminalRef(format: .nccc).walletOrderId == "DEMO000124")

        let e = try ECRResponse(layout([
            (0, "I260116 01E06000125"), (19, "1***1733"), (42, "000000012000"), (75, "Z"), (76, "0000"),
            (176, "000000050000"), (188, "000000038000"), (212, "11"),
        ]))
        #expect(e.kind == .eTicket)
        #expect(e.brand == .easyCard)
        #expect(e.brand?.isETicket == true)
        #expect(e.balanceBefore == Money(dollars: 500))
        #expect(e.balanceAfter == Money(dollars: 380))
        #expect(e.autoloadAmount == nil)
    }

    @Test func responseCodes() throws {
        let declined = ECRResult(try ECRResponse(layout([(0, "I260116 01N03"), (76, "0001")])), requested: .sale)
        #expect(declined.status == .declined)
        #expect(!declined.isApproved)
        #expect(declined.message.contains("0001"))
        // 0010 只有查上一筆時是「上一筆是電子錢包」
        let walletLast = ECRResult(try ECRResponse(layout([(0, "I260116 62W"), (76, "0010")])), requested: .lastTransaction)
        #expect(walletLast.status == .walletLast)
        let other = ECRResult(try ECRResponse(layout([(0, "I260116 01N03"), (76, "0010")])), requested: .sale)
        #expect(other.status == .declined)
        // 空白的回應碼不算成功
        let blank = ECRResult(try ECRResponse(layout([(0, "I260116 01N03")])), requested: .sale)
        #expect(blank.status == .declined)

        let settle = try ECRResponse(layout([(0, "I260116 50"), (38, "0012"), (42, "000001536000"), (76, "0000")]))
        #expect(settle.settlementCount == 12)
        #expect(settle.settlementTotal == Money(dollars: 15_360))

        #expect(ECRResult.last4(fromMasked: "4311-95**-****-1234") == "1234")
        #expect(ECRResult.last4(fromMasked: "12345678**") == nil)
        #expect(ECRResult.last4(fromMasked: "") == nil)

        #expect(throws: ECRError.badLength(expected: 400, got: 5)) { try ECRResponse("short") }
        // 0x00 當空白
        var bytes = Array(Self.approvedCard.utf8)
        bytes[399] = 0
        #expect(try ECRResponse(bytes: bytes).message.bytes[399] == 0x20)
    }
}

/// 外面那一層：STX…ETX LRC、ACK／NAK、UDP 的標頭與分封包
struct ECRFramingTests {
    @Test func lrcAndRS232Frame() throws {
        // LRC 只算資料加 ETX（STX 不算）：0x41 ^ 0x42 ^ 0x03 = 0x00
        #expect(ECRFraming.frame([0x41, 0x42]) == [0x02, 0x41, 0x42, 0x03, 0x00])
        #expect(ECRFraming.frame([0x31]) == [0x02, 0x31, 0x03, 0x32])
        // 0x00 當空白送
        #expect(ECRFraming.frame([0x00]) == [0x02, 0x20, 0x03, 0x23])

        let data = try ECRRequest.sale(Money(dollars: 1_280)).pack().bytes
        let framed = ECRFraming.frame(data)
        #expect(framed.count == 403)
        #expect(framed[402] == ECRFraming.lrc(data + [0x03]))
        #expect(try ECRFraming.unframe(framed, dataLength: 400) == data)
        var bad = framed
        bad[100] ^= 0x01
        #expect(throws: ECRError.badChecksum) { try ECRFraming.unframe(bad, dataLength: 400) }
        var noEtx = framed
        noEtx[401] = 0x20
        #expect(throws: ECRError.self) { try ECRFraming.unframe(noEtx, dataLength: 400) }

        #expect(ECRFraming.ackBytes == [0x06, 0x06])
        #expect(ECRFraming.nakBytes == [0x15, 0x15])
        #expect(ECRFraming.signal([0x06, 0x06]) == .ack)
        #expect(ECRFraming.signal([0x06]) == .ack)
        #expect(ECRFraming.signal([0x15, 0x15]) == .nak)
        #expect(ECRFraming.signal([0x06, 0x41]) == nil)
        #expect(ECRFraming.signal([]) == nil)
    }

    @Test func udpFrameLayout() throws {
        let data = try ECRRequest.echo.pack().bytes
        let header = "2610091430150001"
        let f = try ECRFraming.udpFrame(data, header: header)
        #expect(f.count == 421)
        #expect(f.count == ECRFraming.udpFrameLength(dataLength: 400))
        #expect(f[0] == 0x01)
        #expect(String(decoding: f[1...16], as: UTF8.self) == header)
        #expect(f[17] == 0x02)
        #expect(Array(f[18..<418]) == data)
        #expect(f[418] == 0x03)
        // 標頭、SOH、STX 不算進 LRC
        #expect(f[419] == ECRFraming.lrc(data + [0x03]))
        #expect(f[420] == 0x04)
        #expect(throws: ECRError.self) { try ECRFraming.udpFrame(data, header: "short") }
        #expect(ECRFraming.defaultUDPPort == 50002)
    }

    @Test func udpMultiPacketRoundTrip() throws {
        let data = try ECRRequest.sale(Money(dollars: 999)).pack().bytes
        let header = "2610091430150002"
        let frame = try ECRFraming.udpFrame(data, header: header)
        let packets = try ECRFraming.udpPackets(frame, maxPacketSize: 100)
        #expect(packets.map(\.count) == [100, 100, 100, 100, 21])
        #expect(packets.flatMap { $0 } == frame)

        var r = ECRUDPReassembler()
        for p in packets.dropLast() {
            #expect(r.append(p) == nil)
            #expect(r.isAssembling)
        }
        #expect(r.append(packets[4]) == .message(header: header, data: data))
        #expect(!r.isAssembling)
        // 一個封包就是一框
        #expect(try ECRFraming.udpPackets(frame, maxPacketSize: 1024).count == 1)
        #expect(r.append(frame) == .message(header: header, data: data))
        // 超過 5 個封包不送
        #expect(throws: ECRError.tooManyPackets) { try ECRFraming.udpPackets(frame, maxPacketSize: 80) }
        // 對方拆成 6 個：第 5 個還沒收齊就放棄
        var r6 = ECRUDPReassembler()
        let six = stride(from: 0, to: frame.count, by: 80).map { Array(frame[$0..<min($0 + 80, frame.count)]) }
        #expect(six.count == 6)
        var events: [ECRUDPReassembler.Event] = []
        for p in six { if let e = r6.append(p) { events.append(e) } }
        #expect(events.first == .corrupt(header: header, .tooManyPackets))
    }

    @Test func reassemblerSignalsAndCorruption() throws {
        var r = ECRUDPReassembler()
        #expect(r.append(ECRFraming.ackBytes) == .signal(.ack))
        #expect(r.append(ECRFraming.nakBytes) == .signal(.nak))
        #expect(r.append([0x41, 0x42]) == nil)
        let header = "2610091430150003"
        // 包了標頭的 ACK
        #expect(r.append([0x01] + Array(header.utf8) + [0x06, 0x04]) == .signal(.ack))

        let data = try ECRRequest.echo.pack().bytes
        var broken = try ECRFraming.udpFrame(data, header: header)
        broken[30] ^= 0x01
        #expect(r.append(broken) == .corrupt(header: header, .badChecksum))

        // 接到一半又來一個新的框：前面那一半丟掉
        let good = try ECRFraming.udpFrame(data, header: header)
        #expect(r.append(Array(good.prefix(50))) == nil)
        #expect(r.append(good) == .message(header: header, data: data))
        // 沒包 UDP 標頭的（直接 STX）
        #expect(r.append(ECRFraming.frame(data)) == .message(header: "", data: data))
    }

    @Test func headersAreUnique() {
        let source = ECRHeaderSource(seed: 9_998)
        let at = Date(timeIntervalSince1970: 1_791_527_415) // 2026-10-09 14:30:15 台北
        let a = source.next(at: at)
        let b = source.next(at: at)
        let c = source.next(at: at)
        #expect(a == "2610091430159999")
        #expect(b == "2610091430150000")
        #expect(c == "2610091430150001")
        #expect(a.count == 16)
    }
}

/// 連到（模擬的）刷卡機：交易、查上一筆、取消、退貨、結帳；最重要的是不會重複扣款
struct ECRDriverTests {
    static let fast = NCCCDriver.Options(responseTimeout: .milliseconds(900), quickTimeout: .milliseconds(400), cancelGrace: .milliseconds(500))

    func terminal(delay: Duration = .milliseconds(50)) -> ECRSimulatedTerminal {
        ECRSimulatedTerminal(delay: delay, queryDelay: .milliseconds(20))
    }

    func driver(_ sim: ECRSimulatedTerminal) -> NCCCDriver {
        NCCCDriver(transport: sim, options: Self.fast)
    }

    static let sale = ECROperation.sale(Money(dollars: 450), kind: .card, installments: nil)

    @Test func echoAndSale() async throws {
        let sim = terminal()
        let d = driver(sim)
        #expect(try await d.echo().isApproved)
        let r = try await d.sale(Money(dollars: 1_280), kind: .card, installments: nil, watch: nil)
        #expect(r.isApproved)
        #expect(r.amount == Money(dollars: 1_280))
        #expect(r.receiptNo == "000001")
        #expect(r.last4 != nil)
        #expect(r.approvalNo != nil)
        #expect(r.terminalId == "13990001")
        let sent = await sim.received
        #expect(sent.map { $0[NCCC8N1.transType] } == ["98", "01"])
        #expect(sent.last?[NCCC8N1.amount] == "000000128000")
    }

    @Test func approvedOutcome() async {
        let outcome = await ECRCharge.run(driver(terminal()), Self.sale, known: [])
        guard case .approved(let r, let recovered) = outcome else {
            Issue.record("應該核准：\(outcome)")
            return
        }
        #expect(!recovered)
        #expect(r.amount == Money(dollars: 450))
    }

    /// 刷卡機做了、結果沒回來：查上一筆找回來（不會再送一次交易）
    @Test func silentApprovalIsRecovered() async {
        let sim = terminal()
        await sim.queue([.approveSilently])
        let outcome = await ECRCharge.run(driver(sim), Self.sale, known: [], retryDelay: .milliseconds(10))
        guard case .approved(let r, let recovered) = outcome else {
            Issue.record("應該查得到：\(outcome)")
            return
        }
        #expect(recovered)
        #expect(r.amount == Money(dollars: 450))
        let types = await sim.received.map { $0[NCCC8N1.transType] }
        #expect(types.filter { $0 == "01" }.count == 1)
        #expect(types.last == "62")
    }

    /// 上一筆是已經記過的那一筆（同金額）：這一筆沒有做，不能再記一次
    @Test func alreadyRecordedReceiptIsNotCountedTwice() async {
        let sim = terminal()
        let d = driver(sim)
        let first = await ECRCharge.run(d, Self.sale, known: [])
        guard case .approved(let r, _) = first else {
            Issue.record("第一筆應該成功：\(first)")
            return
        }
        await sim.queue([.ignore])
        let second = await ECRCharge.run(d, Self.sale, known: [r.terminalKey], retryDelay: .milliseconds(10))
        #expect(second == .notCharged(.notOnTerminal))
        // 沒有記過的話（例如記帳失敗）會認成這一筆
        await sim.queue([.ignore])
        let third = await ECRCharge.run(d, Self.sale, known: [], retryDelay: .milliseconds(10))
        guard case .approved(_, true) = third else {
            Issue.record("\(third)")
            return
        }
    }

    /// 連查上一筆都查不到：不能說沒有扣款
    @Test func unreachableIsUnknown() async {
        let sim = terminal()
        await sim.setOffline(true)
        let outcome = await ECRCharge.run(driver(sim), Self.sale, known: [], checkAttempts: 2, retryDelay: .milliseconds(10))
        guard case .unknown = outcome else {
            Issue.record("連不上就不能說沒有扣款：\(outcome)")
            return
        }
    }

    @Test func declinedAndBadAmount() async {
        let sim = terminal()
        await sim.queue([.decline("0001")])
        let d = driver(sim)
        let outcome = await ECRCharge.run(d, Self.sale, known: [])
        guard case .declined(let r) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(r.responseCode == "0001")
        // 有角分：不送出去
        let bad = await ECRCharge.run(d, .sale(Money(cents: 45_050), kind: .card, installments: nil), known: [])
        guard case .notCharged(.invalidAmount) = bad else {
            Issue.record("\(bad)")
            return
        }
        #expect(await sim.received.count == 1)
    }

    /// 回覆壞了：POS 回 NAK，刷卡機重送回覆；交易本身只送一次
    @Test func corruptReplyIsResentAfterNak() async throws {
        let sim = terminal()
        await sim.corruptNextResponse()
        let r = try await driver(sim).sale(Money(dollars: 60), kind: .card, installments: nil, watch: nil)
        #expect(r.isApproved)
        #expect(await sim.received.count == 1)
    }

    /// 前一筆遲到的回覆（別的標頭）：不是這一筆的
    @Test func staleReplyIsIgnored() async throws {
        let sim = terminal()
        var stale = try ECRRequest.sale(Money(dollars: 60)).pack()
        try stale.set(NCCC8N1.responseCode, digits: "0000")
        try stale.set(NCCC8N1.receiptNo, digits: "99")
        await sim.inject(try ECRFraming.udpFrame(stale.bytes, header: "0000000000009999"))
        await sim.queue([.decline("0005")])
        let r = try await driver(sim).sale(Money(dollars: 60), kind: .card, installments: nil, watch: nil)
        #expect(r.responseCode == "0005")
    }

    @Test func walletLastGoesThroughWalletQuery() async {
        let sim = terminal()
        await sim.queue([.approveSilently])
        let outcome = await ECRCharge.run(driver(sim), .sale(Money(dollars: 85), kind: .wallet, installments: nil), known: [], retryDelay: .milliseconds(10))
        guard case .approved(let r, true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(r.brand == .linePay)
        #expect(r.walletTransactionId != nil)
        let types = await sim.received.map { $0[NCCC8N1.transType] }
        #expect(Array(types.suffix(2)) == ["62", "68"])
    }

    @Test func voidRefundAndSettle() async throws {
        let sim = terminal()
        let d = driver(sim)
        let sale = try await d.sale(Money(dollars: 300), kind: .card, installments: nil, watch: nil)
        let ref = sale.terminalRef(format: .nccc)
        let voided = await ECRCharge.run(d, .void(ref, amount: Money(dollars: 300)), known: [ref.key])
        guard case .approved(let v, false) = voided else {
            Issue.record("\(voided)")
            return
        }
        #expect(v.response.transType == .void)
        #expect(v.receiptNo == ref.receiptNo)
        #expect(await sim.received.last?[NCCC8N1.receiptNo] == ref.receiptNo)
        // 同一筆不能取消兩次
        let again = await ECRCharge.run(d, .void(ref, amount: Money(dollars: 300)), known: [ref.key])
        guard case .declined = again else {
            Issue.record("\(again)")
            return
        }
        // 退貨帶原交易的授權碼
        let refund = await ECRCharge.run(d, .refund(Money(dollars: 100), kind: .card, original: ref), known: [])
        guard case .approved = refund else {
            Issue.record("\(refund)")
            return
        }
        #expect(await sim.received.last.map { $0.value(NCCC8N1.approvalNo) } == ref.approvalNo)

        _ = try await d.sale(Money(dollars: 200), kind: .card, installments: nil, watch: nil)
        let settle = try await d.settle()
        #expect(settle.isApproved)
        #expect(settle.response.settlementCount == 1)
        #expect(settle.response.settlementTotal == Money(dollars: 200))
    }

    /// 按了取消、客人沒刷：等完寬限、查上一筆沒有這一筆 → 沒有扣款
    @Test func cancelWhileWaiting() async throws {
        let sim = terminal(delay: .seconds(5))
        let watch = ECRWatch()
        async let outcome = ECRCharge.run(driver(sim), Self.sale, known: [], watch: watch, retryDelay: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(150))
        watch.requestCancel()
        #expect(watch.isCancelRequested)
        let result = await outcome
        #expect(result == .notCharged(.notOnTerminal))
    }

    /// 按了取消、但客人剛好刷了：照收
    @Test func cancelTooLateStillCounts() async throws {
        let sim = terminal(delay: .milliseconds(350))
        let watch = ECRWatch()
        async let outcome = ECRCharge.run(driver(sim), Self.sale, known: [], watch: watch)
        try await Task.sleep(for: .milliseconds(100))
        watch.requestCancel()
        let result = await outcome
        guard case .approved(_, false) = result else {
            Issue.record("\(result)")
            return
        }
    }
}

/// 付款、退款上的刷卡機資料：選填，舊的資料照樣解得開
struct CardTerminalRefTests {
    @Test func optionalAndBackwardCompatible() throws {
        let plain = Payment(id: "p1", tender: .card, amount: Money(dollars: 100), cardLast4: "1234", at: Fixture.now, by: "s")
        let json = try String(decoding: EventCoding.encoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("terminal"))
        let old = try EventCoding.decoder().decode(Payment.self, from: Data(json.utf8))
        #expect(old == plain)
        #expect(old.terminal == nil)

        let ref = CardTerminalRef(format: "nccc", kind: "N", terminalId: "13990001", batchNo: "000042", receiptNo: "000123", approvalNo: "AB1234")
        var withRef = plain
        withRef.terminal = ref
        let back = try EventCoding.decoder().decode(Payment.self, from: EventCoding.encoder().encode(withRef))
        #expect(back == withRef)
        #expect(back.terminal?.key == "13990001/000042/000123")
        #expect(back != plain)

        let refund = Refund(id: "r1", amount: Money(dollars: 100), tender: .card, reason: "退", invoiceAction: .none, at: Fixture.now, by: "s", terminal: ref)
        let refundJSON = try EventCoding.encoder().encode(refund)
        #expect(try EventCoding.decoder().decode(Refund.self, from: refundJSON).terminal == ref)
        let plainRefund = Refund(id: "r2", amount: Money(dollars: 1), tender: .cash, reason: "退", invoiceAction: .none, at: Fixture.now, by: "s")
        let plainRefundJSON = String(decoding: try EventCoding.encoder().encode(plainRefund), as: UTF8.self)
        #expect(!plainRefundJSON.contains("terminal"))

        // 重播事件：付款上的刷卡機資料留著
        var d = Device("A")
        let events = [
            d.emit(.ticketOpened(TicketOpened(ticketId: "t1", number: "A001", orderType: .takeout, businessDate: "2026-10-09"))),
            d.emit(.paymentAdded(PaymentAdded(ticketId: "t1", payment: withRef))),
        ]
        #expect(events.allSatisfy(\.isHashValid))
        let s = StoreState.replay(events)
        #expect(s.tickets["t1"]?.payments.first?.terminal == ref)
    }
}
