import Foundation
@testable import POSCore

/// 測試用：一台裝置照順序產生事件（流水號、Lamport、雜湊鏈都接好）
struct Device {
    let id: String
    var seq = 0
    var lamport = 0
    var prev = POSEvent.genesis
    var clock = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    init(_ id: String) { self.id = id }

    mutating func emit(_ body: EventBody, staff: String? = "s1", advance: TimeInterval = 60) -> POSEvent {
        seq += 1
        lamport += 1
        clock = clock.addingTimeInterval(advance)
        let e = try! POSEvent(id: "\(id)-\(seq)", deviceId: id, seq: seq, lamport: lamport, at: clock, staffId: staff, body: body, prevHash: prev)
        prev = e.hash
        return e
    }

    /// 看到別台的事件：時鐘調到比它大
    mutating func observe(_ events: [POSEvent]) {
        lamport = max(lamport, events.map(\.lamport).max() ?? 0)
    }
}

enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func line(_ id: String, _ name: String, _ price: Int, qty: Int = 1, mods: [AppliedModifier] = [], discount: Discount? = nil, category: String = "drinks") -> TicketLine {
        TicketLine(id: id, itemId: "item-\(name)", name: name, categoryId: category, categoryName: category == "drinks" ? "飲料" : "炸物",
                   unitPrice: Money(dollars: price), modifiers: mods, quantity: qty, discount: discount, addedAt: now, addedBy: "s1")
    }

    static let floor = FloorPlan(areas: [
        FloorArea(id: "1f", name: "1F", tables: [
            DiningTable(id: "t1", areaId: "1f", name: "A1"),
            DiningTable(id: "t2", areaId: "1f", name: "A2"),
        ]),
    ])
}
