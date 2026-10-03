import Foundation

/// 加解密（純 Swift，iPad 與 Linux 算出來一模一樣）。
///
/// 為什麼不用 CryptoKit：測試跑在 Linux（GitHub Actions 便宜），而事件日誌的雜湊鏈、員工 PIN、
/// 電子發票 QR Code 的加密驗證碼在 iPad、伺服器、測試三邊都要逐位元相同。這幾個演算法都很短，
/// 用標準測試向量驗過（見 Tests/POSCoreTests/CryptoTests.swift）。
public enum Crypto {}

extension Crypto {
    /// SHA-256（FIPS 180-4）
    public struct SHA256: Sendable {
        private var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        private var buffer: [UInt8] = []
        private var length: UInt64 = 0

        private static let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        public init() {}

        public mutating func update<D: Sequence>(_ data: D) where D.Element == UInt8 {
            update(bytes: Array(data))
        }

        public mutating func update(bytes data: [UInt8]) {
            length &+= UInt64(data.count)
            var i = 0
            if !buffer.isEmpty {
                let take = min(64 - buffer.count, data.count)
                buffer += data[0..<take]
                i = take
                if buffer.count == 64 {
                    compress(buffer[...])
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            while data.count - i >= 64 {
                compress(data[i..<i + 64])
                i += 64
            }
            if i < data.count { buffer += data[i...] }
        }

        public mutating func update(_ string: String) { update(Array(string.utf8)) }

        public mutating func finalize() -> [UInt8] {
            let bitLength = length &* 8
            var pad: [UInt8] = [0x80]
            let rem = (buffer.count + 1) % 64
            pad += [UInt8](repeating: 0, count: rem <= 56 ? 56 - rem : 120 - rem)
            for i in (0..<8).reversed() { pad.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
            let savedLength = length
            update(bytes: pad)
            length = savedLength
            var out: [UInt8] = []
            out.reserveCapacity(32)
            for word in h {
                out += [UInt8(word >> 24), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff), UInt8(word & 0xff)]
            }
            return out
        }

        private mutating func compress(_ block: ArraySlice<UInt8>) {
            var w = [UInt32](repeating: 0, count: 64)
            let base = block.startIndex
            for i in 0..<16 {
                w[i] = UInt32(block[base + i * 4]) << 24 | UInt32(block[base + i * 4 + 1]) << 16 | UInt32(block[base + i * 4 + 2]) << 8 | UInt32(block[base + i * 4 + 3])
            }
            for i in 16..<64 {
                let s0 = w[i - 15].rotr(7) ^ w[i - 15].rotr(18) ^ (w[i - 15] >> 3)
                let s1 = w[i - 2].rotr(17) ^ w[i - 2].rotr(19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = e.rotr(6) ^ e.rotr(11) ^ e.rotr(25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ Self.k[i] &+ w[i]
                let S0 = a.rotr(2) ^ a.rotr(13) ^ a.rotr(22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }

        public static func hash<D: Sequence>(_ data: D) -> [UInt8] where D.Element == UInt8 {
            var s = SHA256()
            s.update(data)
            return s.finalize()
        }

        public static func hash(_ string: String) -> [UInt8] { hash(Array(string.utf8)) }

        /// 小寫十六進位
        public static func hex(_ string: String) -> String { Crypto.hex(hash(string)) }
    }

    /// HMAC-SHA256（RFC 2104）
    public static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? SHA256.hash(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        var inner = SHA256()
        inner.update(k.map { $0 ^ 0x36 })
        inner.update(message)
        let ih = inner.finalize()
        var outer = SHA256()
        outer.update(k.map { $0 ^ 0x5c })
        outer.update(ih)
        return outer.finalize()
    }

    /// PBKDF2-HMAC-SHA256（RFC 8018）：員工 PIN 的雜湊。後台用 Node 的 `crypto.pbkdf2Sync(pin, salt, n, 32, 'sha256')` 算同一個值
    public static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int = 32) -> [UInt8] {
        // HMAC 的金鑰每一輪都一樣：先把 ipad／opad 那一塊壓進去存起來，每輪從存好的狀態接著算（快一倍以上）
        var k = password.count > 64 ? SHA256.hash(password) : password
        k += [UInt8](repeating: 0, count: 64 - k.count)
        var innerBase = SHA256(), outerBase = SHA256()
        innerBase.update(k.map { $0 ^ 0x36 })
        outerBase.update(k.map { $0 ^ 0x5c })
        func prf(_ message: [UInt8]) -> [UInt8] {
            var inner = innerBase
            inner.update(message)
            var outer = outerBase
            outer.update(inner.finalize())
            return outer.finalize()
        }

        var out: [UInt8] = []
        var block: UInt32 = 1
        while out.count < keyLength {
            var u = prf(salt + [UInt8(block >> 24), UInt8((block >> 16) & 0xff), UInt8((block >> 8) & 0xff), UInt8(block & 0xff)])
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = prf(u)
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            out += t
            block += 1
        }
        return Array(out.prefix(keyLength))
    }

    // MARK: 編碼

    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s.append(digits[Int(b >> 4)])
            s.append(digits[Int(b & 0x0f)])
        }
        return s
    }

    /// 十六進位字串 → 位元組（大小寫都可以；格式不對回 nil）
    public static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 65...70: c - 55
        case 97...102: c - 87
        default: nil
        }
    }

    /// 比對兩段位元組，花的時間和內容無關（比對 PIN 雜湊、簽章用）
    public static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// 安全的亂數位元組
    public static func randomBytes(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
}

extension UInt32 {
    @inline(__always) fileprivate func rotr(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
}
