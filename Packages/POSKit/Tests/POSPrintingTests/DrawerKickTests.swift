import Foundation
import Testing
@testable import POSPrinting

/// 錢櫃：市面上的錢櫃接在出單機的 DK 埠，指令、接腳、通電長度不一樣
struct DrawerKickTests {
    @Test func standardIsTheClassicEscP() {
        // 以前一直送的、Epson 文件的建議值
        #expect(DrawerKick.standard.bytes == [0x1B, 0x70, 0, 25, 250])
        var e = ESCPOS()
        e.openDrawer()
        #expect(e.bytes == DrawerKick.standard.bytes)
    }

    @Test func pins() {
        #expect(DrawerKick(pin: .pin5).bytes == [0x1B, 0x70, 1, 25, 250])
        #expect(DrawerKick(pin: .both).bytes == [0x1B, 0x70, 0, 25, 250, 0x1B, 0x70, 1, 25, 250])
    }

    @Test func pulseLength() {
        #expect(DrawerKick(pulseMs: 100).bytes == [0x1B, 0x70, 0, 50, 250])
        #expect(DrawerKick(pulseMs: 200).bytes == [0x1B, 0x70, 0, 100, 250])
        // t2 不能比 t1 短
        #expect(DrawerKick(pulseMs: 600).bytes == [0x1B, 0x70, 0, 255, 255])
        #expect(DrawerKick(pulseMs: 0).bytes == [0x1B, 0x70, 0, 1, 250])
    }

    @Test func epsonRealtime() {
        #expect(DrawerKick(command: .realtime).bytes == [0x10, 0x14, 0x01, 0, 1])
        #expect(DrawerKick(command: .realtime, pin: .both, pulseMs: 200).bytes == [0x10, 0x14, 0x01, 0, 2, 0x10, 0x14, 0x01, 1, 2])
        #expect(DrawerKick(command: .realtime, pulseMs: 5000).bytes == [0x10, 0x14, 0x01, 0, 8])
    }

    @Test func star() {
        #expect(DrawerKick(command: .star).bytes == [0x07])
        #expect(DrawerKick(command: .star, pin: .pin5).bytes == [0x1A])
        #expect(DrawerKick(command: .star, pin: .both).bytes == [0x07, 0x1A])
    }

    @Test func savedSettingsRoundTrip() throws {
        let k = DrawerKick(command: .realtime, pin: .both, pulseMs: 100)
        let back = try JSONDecoder().decode(DrawerKick.self, from: JSONEncoder().encode(k))
        #expect(back == k)
    }
}
