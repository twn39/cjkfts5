// CJKUnicodeHelperTests.swift
// cjkfts5Tests
//
// Unicode 范围与工具方法单元测试

import XCTest
@testable import cjkfts5

final class UnicodeRangeTests: XCTestCase {

    func testCJKUnifiedBoundary() {
        // CJK 统一汉字 U+4E00–U+9FFF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x4E00)!), "U+4E00 CJK 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x9FFF)!), "U+9FFF CJK 结尾")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x6E05)!), "[清] U+6E05 应是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x4DFF)!), "U+4DFF 不是 CJK（起始前）")
    }

    func testCJKExtABoundary() {
        // CJK 扩展 A U+3400–U+4DBF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3400)!), "U+3400 扩展A 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x4DBF)!), "U+4DBF 扩展A 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x33FF)!), "U+33FF 扩展A 前，不是 CJK")
    }

    func testCJKCompatBoundary() {
        // CJK 兼容汉字 U+F900–U+FAFF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xF900)!), "U+F900 兼容汉字起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xFAFF)!), "U+FAFF 兼容汉字结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0xFB00)!), "U+FB00 兼容汉字后，不是 CJK")
    }

    func testHiraganaBoundary() {
        // 平假名 U+3040–U+309F
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3041)!), "U+3041 ぁ 平假名起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3042)!), "U+3042 あ 平假名")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x309F)!), "U+309F 平假名结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x303F)!), "U+303F 平假名前，不是 CJK")
    }

    func testKatakanaBoundary() {
        // 片假名 U+30A0–U+30FF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30A0)!), "U+30A0 片假名起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30A2)!), "U+30A2 ア 片假名")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30FF)!), "U+30FF 片假名结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x3100)!), "U+3100 片假名后，不是 CJK")
    }

    func testHangulBoundary() {
        // 韩文音节 U+AC00–U+D7AF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xAC00)!), "U+AC00 가 韩文起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xD7AF)!), "U+D7AF 韩文结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0xABFF)!), "U+ABFF 韩文前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0xD7B0)!), "U+D7B0 韩文后，不是 CJK")
    }

    func testNonCJKChars() {
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar("A")), "'A' 不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar("z")), "'z' 不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar("1")), "'1' 不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(" ")), "空格不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(".")), "句号不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x00E9)!), "U+00E9 é 不是 CJK")
    }

    // MARK: - 扩展 B–I、扩展 G 边界测试（新增）

    func testCJKExtBBoundary() {
        // CJK 扩展 B U+20000–U+2A6DF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x20000)!), "U+20000 扩展B 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2A6DF)!), "U+2A6DF 扩展B 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1FFFF)!), "U+1FFFF 扩展B 前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2A6E0)!), "U+2A6E0 扩展B 后，不是 CJK")
    }

    func testCJKExtCBoundary() {
        // CJK 扩展 C U+2A700–U+2B73F（Unicode 6.0，~4,149字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2A700)!), "U+2A700 扩展C 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B73F)!), "U+2B73F 扩展C 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2A6FF)!), "U+2A6FF 扩展C 前（扩展B外），不是 CJK")
        // U+2B740 是扩展D起始，也是 CJK（扩展C与D地址连续）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B740)!), "U+2B740 扩展D 起始，仍是 CJK")
    }

    func testCJKExtDBoundary() {
        // CJK 扩展 D U+2B740–U+2B81F（Unicode 6.3，~222字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B740)!), "U+2B740 扩展D 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B81F)!), "U+2B81F 扩展D 结尾")
        // U+2B820 是扩展E起始，也是 CJK（扩展D与E地址连续）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B820)!), "U+2B820 扩展E 起始，仍是 CJK")
        // 扩展B与C之间的间隙（U+2A6E0–U+2A6FF）不是 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2A6FF)!), "U+2A6FF 扩展B/C 间隙，不是 CJK")
    }

    func testCJKExtEBoundary() {
        // CJK 扩展 E U+2B820–U+2CEAF（Unicode 8.0，~5,762字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B820)!), "U+2B820 扩展E 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2CEAF)!), "U+2CEAF 扩展E 结尾")
        // U+2CEB0 是扩展F起始，也是 CJK（扩展E与F地址连续）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2CEB0)!), "U+2CEB0 扩展F 起始，仍是 CJK")
    }

    func testCJKExtFBoundary() {
        // CJK 扩展 F U+2CEB0–U+2EBEF（Unicode 10.0，~7,473字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2CEB0)!), "U+2CEB0 扩展F 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2EBEF)!), "U+2EBEF 扩展F 结尾")
        // U+2EBF0 是扩展I起始，也是 CJK（扩展F与I地址连续）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2EBF0)!), "U+2EBF0 扩展I 起始，仍是 CJK")
        // 扩展F/I之后的真正非CJK区域
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2EE60)!), "U+2EE60 扩展I 之后，不是 CJK")
    }

    func testCJKExtIBoundary() {
        // CJK 扩展 I U+2EBF0–U+2EE5F（Unicode 15.1，~622字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2EBF0)!), "U+2EBF0 扩展I 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2EE5F)!), "U+2EE5F 扩展I 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2EE60)!), "U+2EE60 扩展I 后，不是 CJK")
    }

    func testCJKExtGBoundary() {
        // CJK 扩展 G U+30000–U+3134F（Unicode 13.0，~4,939字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30000)!), "U+30000 扩展G 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3134F)!), "U+3134F 扩展G 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2FFFF)!), "U+2FFFF 扩展G 前，不是 CJK")
        // U+31350 是 CJK 扩展 H 起始，应为 CJK（修复旧断言）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31350)!), "U+31350 扩展H 起始，是 CJK")
    }

    func testHangulJamoBoundary() {
        // 韩文字母 Jamo U+1100–U+11FF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1100)!), "U+1100 ㄱ Jamo 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x11FF)!), "U+11FF Jamo 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x10FF)!), "U+10FF Jamo 前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1200)!), "U+1200 Jamo 后，不是 CJK")

        // 韩文兼容字母 U+3130–U+318F
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3130)!), "U+3130 兼容Jamo 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x318F)!), "U+318F 兼容Jamo 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x312F)!), "U+312F 兼容Jamo 前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x3190)!), "U+3190 兼容Jamo 后，不是 CJK")
    }

    func testKatakanaExtensionBoundary() {
        // 片假名扩展 U+31F0–U+31FF（爱努语）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31F0)!), "U+31F0 片假名扩展起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31FF)!), "U+31FF 片假名扩展结尾")
        // 注：U+31F0 紧接在片假名（U+30A0–U+30FF）之后，中间 U+3100–U+31EF 不应是 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x3100)!), "U+3100 片假名后、扩展前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x3200)!), "U+3200 片假名扩展后，不是 CJK")
    }

    // MARK: - 新增：CJK 扩展 H 边界测试（Unicode 15.0）

    func testCJKExtHBoundary() {
        // CJK 扩展 H U+31350–U+323AF（Unicode 15.0，~4,192字）
        // 位于第三汉字平面（TIP，Tertiary Ideographic Plane），Script=Han
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31350)!), "U+31350 扩展H 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x323AF)!), "U+323AF 扩展H 结尾")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31800)!), "U+31800 扩展H 中间字符")
        // 扩展 G（U+30000–U+3134F）与扩展 H 相邻，下方是最后一个 G 字符
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3134F)!), "U+3134F 扩展G 结尾，仍是 CJK")
        // 扩展 H 结尾之后不应是 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x323B0)!), "U+323B0 扩展H 后，不是 CJK")
    }

    // MARK: - 新增：SMP 假名区块边界测试

    func testKanaExtendedBBoundary() {
        // Kana Extended-B U+1AFF0–U+1AFFF（Unicode 14.0，台湾假名）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1AFF0)!), "U+1AFF0 Kana Extended-B 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1AFFF)!), "U+1AFFF Kana Extended-B 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1AFEF)!), "U+1AFEF Kana Extended-B 前，不是 CJK")
        // U+1B000 是 Katakana Supplement 起始，应是 CJK
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B000)!), "U+1B000 Katakana Supplement 起始，是 CJK")
    }

    func testKatakanaSMPBlocksBoundary() {
        // 三个相邻区块合并判断：U+1B000–U+1B16F
        // Katakana Supplement U+1B000–U+1B0FF（Unicode 6.0）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B000)!), "U+1B000 Katakana Supplement 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B0FF)!), "U+1B0FF Katakana Supplement 结尾")
        // Kana Extended-A U+1B100–U+1B12F（Unicode 10.0，Hentaigana）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B100)!), "U+1B100 Kana Extended-A 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B12F)!), "U+1B12F Kana Extended-A 结尾")
        // Small Kana Extension U+1B130–U+1B16F（Unicode 12.0）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B130)!), "U+1B130 Small Kana Extension 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B16F)!), "U+1B16F Small Kana Extension 结尾")
        // 区块前后不应是 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1AFEF)!), "U+1AFEF SMP 假名块前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1B170)!), "U+1B170 Small Kana Extension 后，不是 CJK")
        // 验证已赋值字符（Small Kana Extension 中的 9 个字符）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B132)!), "U+1B132 𛄲 HIRAGANA SMALL KO")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B155)!), "U+1B155 𛅕 KATAKANA SMALL KO")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B167)!), "U+1B167 𛅧 KATAKANA SMALL N")
    }
}

final class UnicodeHelperTests: XCTestCase {

    // MARK: utf8ScalarLength 测试

    func testUTF8ScalarLengthASCII() {
        // ASCII leading byte 0x00–0x7F → 1 字节
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0x00), 1, "NUL: 1字节")
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0x41), 1, "'A': 1字节")
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0x7F), 1, "DEL: 1字节")
    }

    func testUTF8ScalarLength2Bytes() {
        // 0xC2–0xDF → 2 字节（Latin 扩展）
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xC2), 2, "2字节序列起始")
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xDF), 2, "2字节序列终")
    }

    func testUTF8ScalarLength3Bytes() {
        // 0xE0–0xEF → 3 字节（包含所有常用 CJK BMP 字符）
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xE0), 3, "3字节序列起始")
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xE6), 3, "常用CJK leading byte")
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xEF), 3, "3字节序列终")
    }

    func testUTF8ScalarLength4Bytes() {
        // 0xF0–0xF4 → 4 字节（SMP，含 CJK 扩展 B-G）
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xF0), 4, "4字节序列起始")
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xF4), 4, "4字节序列终")
    }

    func testUTF8ScalarLengthInvalid() {
        // continuation byte 和无效字节返回 1（跳过策略）
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0x80), 1, "continuation byte → 1")
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xBF), 1, "continuation byte → 1")
        XCTAssertEqual(CJKUnicode.utf8ScalarLength(leadingByte: 0xFF), 1, "无效字节 → 1")
    }

    // MARK: decodeScalar 测试

    func testDecodeScalarASCII() {
        // "a" = 0x61，1 字节
        "a".utf8.withContiguousStorageIfAvailable { buf in
            let raw = UnsafeRawBufferPointer(buf)
            let result = CJKUnicode.decodeScalar(raw, at: 0)
            XCTAssertNotNil(result)
            XCTAssertEqual(result?.0, Unicode.Scalar("a"), "解码 'a' 正确")
            XCTAssertEqual(result?.1, 1, "'a' 占 1 字节")
        }
    }

    func testDecodeScalarCJK() {
        // "清" = U+6E05，3 字节：E6 B8 85
        "清".utf8.withContiguousStorageIfAvailable { buf in
            let raw = UnsafeRawBufferPointer(buf)
            let result = CJKUnicode.decodeScalar(raw, at: 0)
            XCTAssertNotNil(result)
            XCTAssertEqual(result?.0, Unicode.Scalar(0x6E05)!, "解码 '清' (U+6E05) 正确")
            XCTAssertEqual(result?.1, 3, "'清' 占 3 字节")
        }
    }

    func testDecodeScalarSMP() {
        // U+20000（CJK 扩展 B 起始），4 字节
        let smpChar = String(Unicode.Scalar(0x20000)!)
        smpChar.utf8.withContiguousStorageIfAvailable { buf in
            let raw = UnsafeRawBufferPointer(buf)
            let result = CJKUnicode.decodeScalar(raw, at: 0)
            XCTAssertNotNil(result)
            XCTAssertEqual(result?.0, Unicode.Scalar(0x20000)!, "解码 SMP 字符正确")
            XCTAssertEqual(result?.1, 4, "SMP 字符占 4 字节")
        }
    }

    func testDecodeScalarSequential() {
        // 验证连续解码：「ab清」
        let text = "ab清"
        text.utf8.withContiguousStorageIfAvailable { buf in
            let raw = UnsafeRawBufferPointer(buf)
            var pos = 0
            // 'a'
            var r = CJKUnicode.decodeScalar(raw, at: pos)!
            XCTAssertEqual(r.0, Unicode.Scalar("a")); pos += r.1
            // 'b'
            r = CJKUnicode.decodeScalar(raw, at: pos)!
            XCTAssertEqual(r.0, Unicode.Scalar("b")); pos += r.1
            // '清'
            r = CJKUnicode.decodeScalar(raw, at: pos)!
            XCTAssertEqual(r.0, Unicode.Scalar(0x6E05)!)
            XCTAssertEqual(r.1, 3)
            pos += r.1
            XCTAssertEqual(pos, raw.count, "解码后字节位置应等于总字节数")
        }
    }

    func testDecodeScalarOutOfBounds() {
        // 空缓冲区返回 nil
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        XCTAssertNil(CJKUnicode.decodeScalar(empty, at: 0), "空缓冲区返回 nil")
    }

    // MARK: - RFC 3629 §4 合规性测试

    /// 从裸字节数组构造 UnsafeRawBufferPointer 并调用 decodeScalar 的辅助方法
    private func decode(_ bytes: [UInt8]) -> (Unicode.Scalar, Int)? {
        bytes.withUnsafeBytes { CJKUnicode.decodeScalar($0, at: 0) }
    }

    // ── Overlong 编码拒绝测试 ────────────────────────────────────────────────

    func testRejectOverlong2Byte_C0_80() {
        // C0 80 → U+0000 的 2 字节 Overlong 编码（经典 Null byte bypass）
        // leading byte 0xC0 在 switch 的 default 分支，直接返回 nil
        XCTAssertNil(decode([0xC0, 0x80]), "C0 80（Overlong U+0000）必须拒绝")
    }

    func testRejectOverlong2Byte_C1_BF() {
        // C1 BF → U+007F 的 2 字节 Overlong 编码
        XCTAssertNil(decode([0xC1, 0xBF]), "C1 BF（Overlong U+007F）必须拒绝")
    }

    func testAcceptMinValid2Byte() {
        // C2 80 → U+0080，2 字节最小合法值
        let r = decode([0xC2, 0x80])
        XCTAssertNotNil(r, "C2 80（U+0080）是最小合法 2 字节序列")
        XCTAssertEqual(r?.0.value, 0x0080)
    }

    func testRejectOverlong3Byte_E0_80_80() {
        // E0 80 80 → U+0000 的 3 字节 Overlong 编码
        // b0==E0 时 b1 必须 >= 0xA0，此处 b1==0x80 违规
        XCTAssertNil(decode([0xE0, 0x80, 0x80]), "E0 80 80（Overlong U+0000）必须拒绝")
    }

    func testRejectOverlong3Byte_E0_9F_BF() {
        // E0 9F BF → U+07FF 的 3 字节 Overlong 编码（b1==0x9F，临界值）
        // U+07FF 应使用 2 字节（DF BF）；3 字节 E0 9F BF 是非法的
        XCTAssertNil(decode([0xE0, 0x9F, 0xBF]), "E0 9F BF（Overlong U+07FF）必须拒绝")
    }

    func testAcceptMinValid3Byte() {
        // E0 A0 80 → U+0800，3 字节最小合法值（b1==0xA0 是 E0 后的最小合法 continuation byte）
        let r = decode([0xE0, 0xA0, 0x80])
        XCTAssertNotNil(r, "E0 A0 80（U+0800）是最小合法 3 字节序列")
        XCTAssertEqual(r?.0.value, 0x0800)
    }

    func testRejectOverlong4Byte_F0_80_80_80() {
        // F0 80 80 80 → U+0000 的 4 字节 Overlong 编码
        // b0==F0 时 b1 必须 >= 0x90，此处 b1==0x80 违规
        XCTAssertNil(decode([0xF0, 0x80, 0x80, 0x80]), "F0 80 80 80（Overlong U+0000）必须拒绝")
    }

    func testRejectOverlong4Byte_F0_8F_BF_BF() {
        // F0 8F BF BF → U+FFFF 的 4 字节 Overlong 编码（b1==0x8F，临界值）
        // U+FFFF 应使用 3 字节（EF BF BF）；4 字节 F0 8F BF BF 是非法的
        XCTAssertNil(decode([0xF0, 0x8F, 0xBF, 0xBF]), "F0 8F BF BF（Overlong U+FFFF）必须拒绝")
    }

    func testAcceptMinValid4Byte() {
        // F0 90 80 80 → U+10000，4 字节最小合法值（b1==0x90 是 F0 后的最小合法 continuation byte）
        let r = decode([0xF0, 0x90, 0x80, 0x80])
        XCTAssertNotNil(r, "F0 90 80 80（U+10000）是最小合法 4 字节序列")
        XCTAssertEqual(r?.0.value, 0x10000)
    }

    // ── 代理对拒绝测试（RFC 3629 §3：UTF-8 不得编码 U+D800–U+DFFF）───────────

    func testRejectSurrogateHigh_ED_A0_80() {
        // ED A0 80 → U+D800（高代理，代理对起始）
        // b0==ED 时 b1 必须 < 0xA0，此处 b1==0xA0 违规
        XCTAssertNil(decode([0xED, 0xA0, 0x80]), "ED A0 80（U+D800 高代理）必须拒绝")
    }

    func testRejectSurrogateLow_ED_BF_BF() {
        // ED BF BF → U+DFFF（低代理，代理对结尾）
        XCTAssertNil(decode([0xED, 0xBF, 0xBF]), "ED BF BF（U+DFFF 低代理）必须拒绝")
    }

    func testAcceptMaxBeforeSurrogate_ED_9F_BF() {
        // ED 9F BF → U+D7FF（b1==0x9F，代理对前的最后一个合法码点）
        let r = decode([0xED, 0x9F, 0xBF])
        XCTAssertNotNil(r, "ED 9F BF（U+D7FF）是代理对前最大合法 3 字节序列")
        XCTAssertEqual(r?.0.value, 0xD7FF)
    }

    // ── 超 Unicode 上限拒绝测试（RFC 3629 §3：最大合法码点 U+10FFFF）─────────

    func testRejectAboveUnicodeMax_F4_90_80_80() {
        // F4 90 80 80 → U+110000（超出 Unicode 上限 U+10FFFF）
        // b0==F4 时 b1 必须 <= 0x8F，此处 b1==0x90 违规
        XCTAssertNil(decode([0xF4, 0x90, 0x80, 0x80]), "F4 90 80 80（U+110000，超 Unicode 上限）必须拒绝")
    }

    func testRejectAboveUnicodeMax_F5_80_80_80() {
        // F5 及以上：RFC 3629 定义的最大 leading byte 为 F4，F5 在 default 分支直接拒绝
        XCTAssertNil(decode([0xF5, 0x80, 0x80, 0x80]), "F5 80 80 80（超范围 leading byte）必须拒绝")
    }

    func testAcceptUnicodeMax_F4_8F_BF_BF() {
        // F4 8F BF BF → U+10FFFF（Unicode 最大合法码点）
        let r = decode([0xF4, 0x8F, 0xBF, 0xBF])
        XCTAssertNotNil(r, "F4 8F BF BF（U+10FFFF）是最大合法 4 字节序列")
        XCTAssertEqual(r?.0.value, 0x10FFFF)
    }

    // ── 孤立 continuation byte 及截断序列拒绝测试 ────────────────────────────

    func testRejectLoneContinuationByte() {
        // 0x80–0xBF 作为首字节无意义
        XCTAssertNil(decode([0x80]), "孤立 continuation byte 0x80 必须拒绝")
        XCTAssertNil(decode([0xBF]), "孤立 continuation byte 0xBF 必须拒绝")
    }

    func testRejectTruncated2Byte() {
        // 2 字节序列只有 1 个字节
        XCTAssertNil(decode([0xC2]), "截断的 2 字节序列（仅 leading byte）必须拒绝")
    }

    func testRejectTruncated3Byte() {
        // 3 字节序列只有 2 个字节
        XCTAssertNil(decode([0xE6, 0xB8]), "截断的 3 字节序列（仅 2 字节）必须拒绝")
    }

    func testRejectTruncated4Byte() {
        // 4 字节序列只有 3 个字节
        XCTAssertNil(decode([0xF0, 0x90, 0x80]), "截断的 4 字节序列（仅 3 字节）必须拒绝")
    }

    func testRejectInvalidContinuationByte() {
        // 3 字节序列中 b1 不是合法 continuation byte
        XCTAssertNil(decode([0xE6, 0x41, 0x80]), "b1 非 continuation byte（0x41='A'）必须拒绝")
        // 3 字节序列中 b2 不是合法 continuation byte
        XCTAssertNil(decode([0xE6, 0xB8, 0x41]), "b2 非 continuation byte（0x41='A'）必须拒绝")
    }

    func testIsWordCharASCII() {
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar("a")), "'a' 应是词字符")
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar("Z")), "'Z' 应是词字符")
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar("5")), "'5' 应是词字符")
        XCTAssertFalse(CJKUnicode.isWordChar(Unicode.Scalar(" ")), "空格不是词字符")
        XCTAssertFalse(CJKUnicode.isWordChar(Unicode.Scalar(".")), "句号不是词字符")
        XCTAssertFalse(CJKUnicode.isWordChar(Unicode.Scalar(",")), "逗号不是词字符")
    }

    func testIsWordCharExtendedLatin() {
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar(0x00E9)!), "U+00E9 é 应是词字符")
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar(0x00FC)!), "U+00FC ü 应是词字符")
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar(0x00F1)!), "U+00F1 ñ 应是词字符")
    }

    func testIsWordCharFullWidthDigit() {
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar(0xFF10)!), "U+FF10 ０ 全角数字应是词字符")
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar(0xFF19)!), "U+FF19 ９ 全角数字应是词字符")
        XCTAssertFalse(CJKUnicode.isWordChar(Unicode.Scalar(0xFF0F)!), "U+FF0F ／ 不是词字符")
    }

    // MARK: - Width Folding Helper Tests

    func testFoldWidthASCII() {
        // Full-width uppercase Latin -> Half-width uppercase Latin
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF21), 0x0041, "Ａ -> A")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF3A), 0x005A, "Ｚ -> Z")

        // Full-width lowercase Latin -> Half-width lowercase Latin
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF41), 0x0061, "ａ -> a")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF5E), 0x007E, "～ -> ~")

        // Full-width digits -> Half-width digits
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF10), 0x0030, "０ -> 0")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF19), 0x0039, "９ -> 9")
    }

    func testFoldWidthSpace() {
        // Full-width ideographic space -> Half-width space
        XCTAssertEqual(CJKUnicode.foldWidth(0x3000), 0x0020, "全角空格 -> 半角空格")
    }

    func testFoldWidthKatakana() {
        // Half-width Katakana -> Full-width Katakana (examples from table)
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF61), 0x3002, "｡ -> 。")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF65), 0x30FB, "･ -> ・")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF71), 0x30A2, "ｱ -> ア")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF76), 0x30AB, "ｶ -> カ")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF9E), 0x309B, "ﾞ -> ゛")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF9F), 0x309C, "ﾟ -> ﾟ (semi-voiced mark)")
    }

    func testFoldWidthNonFoldable() {
        // Standard ASCII
        XCTAssertEqual(CJKUnicode.foldWidth(0x0041), 0x0041, "A -> A")
        XCTAssertEqual(CJKUnicode.foldWidth(0x0020), 0x0020, "space -> space")

        // Normal CJK Ideographs
        XCTAssertEqual(CJKUnicode.foldWidth(0x4E2D), 0x4E2D, "中 -> 中")

        // Normal Katakana / Hiragana
        XCTAssertEqual(CJKUnicode.foldWidth(0x3042), 0x3042, "あ -> あ")
        XCTAssertEqual(CJKUnicode.foldWidth(0x30A2), 0x30A2, "ア -> ア")

        // Outside range boundaries
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF00), 0xFF00, "FF00 -> FF00")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF5F), 0xFF5F, "FF5F -> FF5F")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFF60), 0xFF60, "FF60 -> FF60")
        XCTAssertEqual(CJKUnicode.foldWidth(0xFFA0), 0xFFA0, "FFA0 -> FFA0")
    }

    func testIsHalfWidthKatakana() {
        XCTAssertFalse(CJKUnicode.isHalfWidthKatakana(0xFF60), "U+FF60 is not half-width Katakana")
        XCTAssertTrue(CJKUnicode.isHalfWidthKatakana(0xFF61), "U+FF61 is half-width Katakana")
        XCTAssertTrue(CJKUnicode.isHalfWidthKatakana(0xFF71), "U+FF71 is half-width Katakana")
        XCTAssertTrue(CJKUnicode.isHalfWidthKatakana(0xFF9F), "U+FF9F is half-width Katakana")
        XCTAssertFalse(CJKUnicode.isHalfWidthKatakana(0xFFA0), "U+FFA0 is not half-width Katakana")
    }
}
