import Foundation
import Testing
@testable import POSCore

/// 門市人員的 PIN 雜湊是選填的：個人的裝置拿不到（docs/API.md「用 StudioX 帳號登入」第 5 步）
struct StaffPinTests {
    private func member(_ id: String, _ role: StaffRole, pin: String?, active: Bool = true) -> StaffMember {
        guard let pin else { return StaffMember(id: id, name: id, role: role, isActive: active) }
        return StaffMember(id: id, name: id, role: role, pinHash: Staff.hash(pin: pin, salt: "s-\(id)", iterations: 64), pinSalt: "s-\(id)",
                           pinIterations: 64, isActive: active)
    }

    @Test func staffWithoutHashCannotVerifyLocally() {
        let s = member("leslie", .manager, pin: nil)
        #expect(!s.hasPin && s.pinHash == nil && s.pinSalt == nil && s.pinIterations == nil)
        #expect(!s.verify(pin: "1234") && !s.verify(pin: ""))
        #expect(s.can(.refund))
    }

    @Test func iterationsDefaultOnlyWithAHash() {
        // 有雜湊、沒給迭代次數：用預設（和以前一樣寫進 JSON）
        let withHash = StaffMember(id: "a", name: "A", role: .cashier, pinHash: Staff.hash(pin: "1234", salt: "x"), pinSalt: "x")
        #expect(withHash.pinIterations == Staff.defaultIterations && withHash.verify(pin: "1234"))
        // 後台沒給迭代次數（只給雜湊與 salt）：照預設驗
        var noIterations = withHash
        noIterations.pinIterations = nil
        #expect(noIterations.verify(pin: "1234") && !noIterations.verify(pin: "1235"))
        // 壞掉的雜湊、空的雜湊、0 次：一律不過（不會因為長度 0 而「相等」）
        var empty = withHash
        empty.pinHash = ""
        #expect(!empty.hasPin && !empty.verify(pin: "1234"))
        var zero = withHash
        zero.pinIterations = 0
        #expect(!zero.verify(pin: "1234"))
        var noSalt = withHash
        noSalt.pinSalt = nil
        #expect(!noSalt.hasPin && !noSalt.verify(pin: "1234"))
    }

    @Test func decodingToleratesMissingPinFields() throws {
        let json = #"{"id":"s1","name":"王小美","role":"owner","swatch":"rose","isActive":true,"title":"負責人"}"#
        let s = try JSONDecoder().decode(StaffMember.self, from: Data(json.utf8))
        #expect(s.name == "王小美" && s.role == .owner && s.title == "負責人" && !s.hasPin)
        // 寫回去也沒有 pin 開頭的欄位
        #expect(!String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("pin"))
        // null 也當作沒有
        let nulls = #"{"id":"s2","name":"x","role":"cashier","swatch":"sand","isActive":true,"pinHash":null,"pinSalt":null,"pinIterations":null}"#
        #expect(try JSONDecoder().decode(StaffMember.self, from: Data(nulls.utf8)).hasPin == false)
    }

    @Test func matchSkipsStaffWithoutHash() {
        let shared = member("cameron", .cashier, pin: "2580")
        let unknown = member("leslie", .manager, pin: nil)
        #expect(Staff.match(pin: "2580", in: [unknown, shared]) == shared)
        #expect(Staff.match(pin: "1234", in: [unknown]) == nil)
        // 停用的人、兩個人同一個 PIN：照舊
        #expect(Staff.match(pin: "2580", in: [member("cameron", .cashier, pin: "2580", active: false)]) == nil)
        #expect(Staff.match(pin: "2580", in: [shared, member("jacob", .supervisor, pin: "2580")]) == nil)
    }
}
