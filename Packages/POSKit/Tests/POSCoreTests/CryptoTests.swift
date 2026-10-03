import Testing
@testable import POSCore

/// 標準測試向量：和 iPad、後台（Node crypto）算的要逐位元一樣
struct CryptoTests {
    @Test func sha256KnownVectors() {
        #expect(Crypto.SHA256.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Crypto.SHA256.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Crypto.SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // 剛好 64、55、56 bytes：補位的邊界
        #expect(Crypto.SHA256.hex(String(repeating: "a", count: 64)) == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
        #expect(Crypto.SHA256.hex(String(repeating: "a", count: 55)) == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        #expect(Crypto.SHA256.hex(String(repeating: "a", count: 56)) == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        // 中文（UTF-8）
        var s = Crypto.SHA256()
        s.update("珍珠")
        s.update("奶茶")
        #expect(Crypto.hex(s.finalize()) == Crypto.SHA256.hex("珍珠奶茶"))
    }

    @Test func hmacRFC4231() {
        // Test Case 2
        let mac = Crypto.hmacSHA256(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))
        #expect(Crypto.hex(mac) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        // Test Case 6：金鑰比區塊長
        let longKey = [UInt8](repeating: 0xaa, count: 131)
        let mac6 = Crypto.hmacSHA256(key: longKey, message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))
        #expect(Crypto.hex(mac6) == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    @Test func pbkdf2RFC7914() {
        let dk = Crypto.pbkdf2SHA256(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, keyLength: 64)
        #expect(Crypto.hex(dk) == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        // RFC 6070 的 SHA-256 版本（常見對照值）
        let dk2 = Crypto.pbkdf2SHA256(password: Array("password".utf8), salt: Array("salt".utf8), iterations: 4096, keyLength: 32)
        #expect(Crypto.hex(dk2) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    @Test func aesFIPS197() {
        let aes = Crypto.AES128(key: Crypto.bytes(hex: "000102030405060708090a0b0c0d0e0f")!)!
        let ct = aes.encryptBlock(Crypto.bytes(hex: "00112233445566778899aabbccddeeff")!)
        #expect(Crypto.hex(ct) == "69c4e0d86a7b0430d8cdb78070b4c55a")
    }

    @Test func aesCBCSP80038A() {
        let aes = Crypto.AES128(key: Crypto.bytes(hex: "2b7e151628aed2a6abf7158809cf4f3c")!)!
        let iv = Crypto.bytes(hex: "000102030405060708090a0b0c0d0e0f")!
        let pt = Crypto.bytes(hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")!
        let ct = aes.encryptCBC(pt, iv: iv)
        // 前兩個區塊是標準答案；第三個是 PKCS#7 補的一整塊
        #expect(Crypto.hex(Array(ct.prefix(32))) == "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2")
        #expect(ct.count == 48)
        #expect(Crypto.AES128(key: [1, 2, 3]) == nil)
    }

    @Test func hexRoundTrip() {
        #expect(Crypto.bytes(hex: "00ff10Ab") == [0, 255, 16, 171])
        #expect(Crypto.bytes(hex: "abc") == nil)
        #expect(Crypto.bytes(hex: "zz") == nil)
        #expect(Crypto.constantTimeEquals([1, 2], [1, 2]))
        #expect(!Crypto.constantTimeEquals([1, 2], [1, 3]))
        #expect(Crypto.randomBytes(16).count == 16)
    }
}
