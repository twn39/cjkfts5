// CJKEdgeCaseCoverageTests.swift
// cjkfts5Tests
//
// 覆盖率死角与底层边界条件测试

import XCTest
import GRDB
@testable import cjkfts5

final class CJKEdgeCaseCoverageTests: XCTestCase, @unchecked Sendable {

    // 1. 测试 StopwordPresets.resolve(preset:) 与 presetID(matching:) 的全分支覆盖
    func testStopwordPresetsResolveAndPresetID() {
        XCTAssertNotNil(StopwordPresets.resolve(preset: "en"))
        XCTAssertNotNil(StopwordPresets.resolve(preset: "english"))

        XCTAssertNotNil(StopwordPresets.resolve(preset: "zh"))
        XCTAssertNotNil(StopwordPresets.resolve(preset: "chinese"))
        XCTAssertNotNil(StopwordPresets.resolve(preset: "cn"))

        XCTAssertNotNil(StopwordPresets.resolve(preset: "en+zh"))
        XCTAssertNotNil(StopwordPresets.resolve(preset: "zh+en"))
        XCTAssertNotNil(StopwordPresets.resolve(preset: "cjk"))
        XCTAssertNotNil(StopwordPresets.resolve(preset: "common"))

        XCTAssertNil(StopwordPresets.resolve(preset: "unknown_language"))
        XCTAssertNil(StopwordPresets.resolve(preset: ""))

        // presetID 匹配测试
        XCTAssertEqual(StopwordPresets.presetID(matching: StopwordPresets.english), "en")
        XCTAssertEqual(StopwordPresets.presetID(matching: StopwordPresets.chinese), "zh")
        XCTAssertEqual(StopwordPresets.presetID(matching: StopwordPresets.cjkCommon), "en+zh")
        XCTAssertNil(StopwordPresets.presetID(matching: ["custom_word"]))
    }

    // 2. 测试 StopwordSet.isEmpty 属性与 CJK 探测短路标志
    func testStopwordSetIsEmpty() {
        let options = CJKTokenizerOptions()
        let emptySet = StopwordSet(stopwords: [], options: options)
        XCTAssertTrue(emptySet.isEmpty)
        XCTAssertFalse(emptySet.mayContainCJKMultiCodepointStopwords)

        let nonEmptySet = StopwordSet(stopwords: ["the"], options: options)
        XCTAssertFalse(nonEmptySet.isEmpty)
    }

    // 3. 测试 CJKTokenizerOptions 停用词转义解码（含尾部孤立转义符 `\`）
    func testTokenizerOptionsArgumentParsingEdgeCases() {
        // 编码转义测试
        let encoded = CJKTokenizerOptions.encodeStopwordList(["a,b", "c\\d"])
        let decoded = CJKTokenizerOptions.decodeStopwordList(encoded)
        XCTAssertEqual(decoded, ["a,b", "c\\d"])

        // 尾部孤立 `\` 参数解析 (覆盖 escaped = true 边界)
        let trailingEscaped = CJKTokenizerOptions.decodeStopwordList("word\\")
        XCTAssertTrue(trailingEscaped.contains("word\\"))

        // fts5 argument 初始化
        let opts = CJKTokenizerOptions(arguments: ["no_unigram", "stopwords_preset", "zh", "stopwords", "the\\"])
        XCTAssertFalse(opts.emitUnigrams)
        XCTAssertNotNil(opts.stopwords)
        XCTAssertTrue(opts.stopwords!.contains("the\\"))
    }

    // 4. 测试 UTF-8 解码与编码底层边界 (CJKUnicode.decodeCodepoint 及各溢出分支)
    func testUnicodeHelperDecodeAndEncodeEdgeCases() {
        // 0xF1-0xF3 后跟无效 continuation byte
        let invalidF1: [UInt8] = [0xF1, 0x00, 0x80, 0x80]
        invalidF1.withUnsafeBytes { ptr in
            XCTAssertNil(CJKUnicode.decodeCodepoint(ptr, at: 0))
        }

        // 0xF4 开头但续接字节超出范围 (0x90..0xBF)
        let invalidF4: [UInt8] = [0xF4, 0xFF, 0x80, 0x80]
        invalidF4.withUnsafeBytes { ptr in
            XCTAssertNil(CJKUnicode.decodeCodepoint(ptr, at: 0))
        }

        // 0xE0 开头但续接字节不在 (0xA0..0xBF)
        let invalidE0: [UInt8] = [0xE0, 0x80, 0x80]
        invalidE0.withUnsafeBytes { ptr in
            XCTAssertNil(CJKUnicode.decodeCodepoint(ptr, at: 0))
        }

        // 0xED 开头但续接字节不在 (0x80..0x9F)
        let invalidED: [UInt8] = [0xED, 0xA0, 0x80]
        invalidED.withUnsafeBytes { ptr in
            XCTAssertNil(CJKUnicode.decodeCodepoint(ptr, at: 0))
        }

        // 完全越界/非法首字节
        let invalidFirst: [UInt8] = [0xFF, 0x80]
        invalidFirst.withUnsafeBytes { ptr in
            XCTAssertNil(CJKUnicode.decodeCodepoint(ptr, at: 0))
        }
    }

    // 5. 测试片假名浊点/半浊点合成边缘逻辑
    func testVoicedKatakanaMarkEdgeCases() {
        // ウ (0x30A6) + 半浊点 (0xFF9F) -> nil (无此合成字符)
        let invalidUCombine = CJKUnicode.composeHalfwidthKatakana(base: 0x30A6, mark: 0xFF9F)
        XCTAssertNil(invalidUCombine)

        // 普通假名 + 无效标点码点 -> nil
        let invalidMark = CJKUnicode.composeHalfwidthKatakana(base: 0x30AB, mark: 0x0041)
        XCTAssertNil(invalidMark)

        // 不支持合音的普通字符 -> nil
        let nonKatakana = CJKUnicode.composeHalfwidthKatakana(base: 0x4E00, mark: 0xFF9E)
        XCTAssertNil(nonKatakana)
    }

    // 6. 测试 StopwordSet 内部 normalize 遇到多码点非 ASCII UTF-8 解码与二分匹配
    func testStopwordSetNormalizationBoundary() {
        var options = CJKTokenizerOptions()
        options.diacriticFolding = false
        let words: Set<String> = ["café", "𠮷野家"]
        let set = StopwordSet(stopwords: words, options: options)
        XCTAssertFalse(set.isEmpty)

        // 多码点词校验
        let cafeBytes = Array("café".utf8)
        cafeBytes.withUnsafeBufferPointer { buf in
            XCTAssertTrue(set.contains(buf))
        }

        // CChar 接口校验
        "café".withCString { cStr in
            XCTAssertTrue(set.contains(cStr, count: cafeBytes.count))
        }
    }
}
