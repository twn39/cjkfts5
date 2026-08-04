// CJKTokenGoldenTests.swift
// cjkfts5Tests
//
// Token 序列金标、规范化契约、Options 往返、半角浊点

import XCTest
import GRDB
@testable import cjkfts5

// MARK: - 规范化契约

final class TokenNormalizerContractTests: XCTestCase {

    func testNormalizeWordMatchesStopwordSetHelper() {
        let opts = CJKTokenizerOptions(
            caseFolding: true,
            widthFolding: true,
            diacriticFolding: true
        )
        let samples = ["Café", "Ｔｈｅ", "the", "的", "Hello", "１２３"]
        for s in samples {
            XCTAssertEqual(
                TokenNormalizer.normalizeWord(s, options: opts),
                StopwordSet.normalizeWord(s, options: opts),
                "normalize 应对齐: \(s)"
            )
        }
    }

    func testStopwordBuildBytesMatchEmittedLatinTokens() throws {
        let opts = CJKTokenizerOptions(
            caseFolding: true,
            widthFolding: true,
            diacriticFolding: true,
            stopwords: ["Café", "Ｔｈｅ"]
        )
        let set = StopwordSet(stopwords: opts.stopwords!, options: opts)

        for raw in ["cafe", "the", "CAFÉ", "ｔｈｅ"] {
            let normalized = TokenNormalizer.normalizeWord(raw, options: opts)
            let isStop = normalized.utf8.withContiguousStorageIfAvailable { buf in
                set.contains(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
            } ?? false
            XCTAssertTrue(isStop, "规范化后应命中停用词表: \(raw) → \(normalized)")
        }
    }

    func testCJKStopwordUnigramBytesAlignWithFoldWidth() {
        let opts = CJKTokenizerOptions(stopwords: ["的", "关于"])
        let set = StopwordSet(stopwords: opts.stopwords!, options: opts)

        // 「的」U+7684 — 建表与 isUnigramStopword 均用 UTF-8 编码
        let de = "的"
        let hit = de.utf8.withContiguousStorageIfAvailable { buf in
            set.contains(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        } ?? false
        XCTAssertTrue(hit)

        let about = "关于"
        let hit2 = about.utf8.withContiguousStorageIfAvailable { buf in
            set.contains(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        } ?? false
        XCTAssertTrue(hit2)
    }
}

// MARK: - Options 编解码

final class TokenizerOptionsCodecTests: XCTestCase {

    func testArgumentsRoundTripFlags() {
        let opts = CJKTokenizerOptions(
            emitUnigrams: false,
            caseFolding: false,
            widthFolding: false,
            diacriticFolding: false,
            stopwords: nil
        )
        let restored = CJKTokenizerOptions(arguments: opts.arguments)
        XCTAssertEqual(restored.emitUnigrams, false)
        XCTAssertEqual(restored.caseFolding, false)
        XCTAssertEqual(restored.widthFolding, false)
        XCTAssertEqual(restored.diacriticFolding, false)
        XCTAssertNil(restored.stopwords)
    }

    func testStopwordEscapeRoundTripWithComma() {
        let words: Set = ["a,b", "c\\d", "plain"]
        let encoded = CJKTokenizerOptions.encodeStopwordList(words)
        let decoded = CJKTokenizerOptions.decodeStopwordList(encoded)
        XCTAssertEqual(decoded, words)
    }

    func testArgumentsRoundTripCustomStopwordsWithComma() {
        let opts = CJKTokenizerOptions(stopwords: ["foo,bar", "baz"])
        let restored = CJKTokenizerOptions(arguments: opts.arguments)
        XCTAssertEqual(restored.stopwords, opts.stopwords)
    }

    func testPresetEncodingShortForm() {
        let opts = CJKTokenizerOptions(stopwords: StopwordPresets.english)
        let args = opts.arguments
        XCTAssertTrue(args.contains("stopwords_preset"))
        XCTAssertTrue(args.contains("en"))
        XCTAssertFalse(args.contains("stopwords"), "预设应使用紧凑形式而非全量列表")

        let restored = CJKTokenizerOptions(arguments: args)
        XCTAssertEqual(restored.stopwords, StopwordPresets.english)
    }

    func testRecommendedUsesCJKCommonStopwords() {
        XCTAssertEqual(CJKTokenizerOptions.recommended.stopwords, StopwordPresets.cjkCommon)
    }

    func testMinimalIndexProfile() {
        let opts = CJKTokenizerOptions.minimalIndex
        XCTAssertFalse(opts.emitUnigrams)
        XCTAssertTrue(opts.caseFolding && opts.widthFolding && opts.diacriticFolding)
        XCTAssertNil(opts.stopwords)
        XCTAssertTrue(opts.arguments.contains("no_unigram"))
    }

    func testStrictMatchProfile() {
        let opts = CJKTokenizerOptions.strictMatch
        XCTAssertTrue(opts.emitUnigrams)
        XCTAssertFalse(opts.caseFolding)
        XCTAssertFalse(opts.widthFolding)
        XCTAssertFalse(opts.diacriticFolding)
        XCTAssertNil(opts.stopwords)
        let args = opts.arguments
        XCTAssertTrue(args.contains("no_case_fold"))
        XCTAssertTrue(args.contains("no_width_fold"))
        XCTAssertTrue(args.contains("no_diacritic_fold"))
    }

    func testLegacyAliasesPointToPresets() {
        XCTAssertEqual(CJKTokenizerOptions.englishStopwords, StopwordPresets.english)
        XCTAssertEqual(CJKTokenizerOptions.chineseStopwords, StopwordPresets.chinese)
    }

    func testStopwordSetSingleCodepointFastPath() {
        let opts = CJKTokenizerOptions(stopwords: StopwordPresets.chinese)
        let set = StopwordSet(stopwords: opts.stopwords!, options: opts)
        XCTAssertTrue(set.containsCodepoint(0x7684)) // 的
        XCTAssertFalse(set.mayContainCJKMultiCodepointStopwords)
        // cjkCommon：英文多码点 + 中文单码点 → CJK bigram 应可短路
        let common = StopwordSet(stopwords: StopwordPresets.cjkCommon, options: CJKTokenizerOptions())
        XCTAssertFalse(common.mayContainCJKMultiCodepointStopwords)
        XCTAssertTrue(common.containsCodepoint(0x7684))
        // 含多字中文停用词时标志应为 true
        let multi = StopwordSet(stopwords: ["关于", "的"], options: CJKTokenizerOptions())
        XCTAssertTrue(multi.mayContainCJKMultiCodepointStopwords)
        let about = "关于"
        let hit = about.utf8.withContiguousStorageIfAvailable { buf in
            multi.contains(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        } ?? false
        XCTAssertTrue(hit)
    }
}

// MARK: - Token 金标（document / query）

final class TokenGoldenTests: CJKTestBase, @unchecked Sendable {

    private struct Tok: Equatable {
        let token: String
        let colocated: Bool
    }

    private func tokens(
        _ text: String,
        options: CJKTokenizerOptions = CJKTokenizerOptions(),
        query: Bool = false
    ) throws -> [Tok] {
        try dbQueue.read { db in
            let tokenizer = try db.makeTokenizer(CJKTokenizer.tokenizerDescriptor(options: options))
            let raw: [(token: String, flags: FTS5TokenFlags)]
            if query {
                raw = try tokenizer.tokenize(query: text).map { t in
                    (t.token, t.flags)
                }
            } else {
                raw = try tokenizer.tokenize(document: text).map { t in
                    (t.token, t.flags)
                }
            }
            return raw.map { Tok(token: $0.token, colocated: $0.flags.contains(.colocated)) }
        }
    }

    func testDocumentGoldenTsinghua() throws {
        let t = try tokens("清华大学")
        // pos0: 清华 + colocated 清; pos1: 华大 + 华; pos2: 大学 + 大; pos3: 学
        XCTAssertEqual(t.map(\.token), ["清华", "清", "华大", "华", "大学", "大", "学"])
        XCTAssertEqual(t.map(\.colocated), [false, true, false, true, false, true, false])
    }

    func testQueryGoldenTsinghuaExactSequence() throws {
        // query：仅 bigram 主 token，无 colocated、无末字独立位
        let t = try tokens("清华大学", query: true)
        XCTAssertEqual(t.map(\.token), ["清华", "华大", "大学"])
        XCTAssertEqual(t.map(\.colocated), [false, false, false])
        XCTAssertFalse(t.map(\.token).contains("学"))
        XCTAssertFalse(t.map(\.token).contains("清"))
    }

    func testDocumentNoUnigrams() throws {
        let opts = CJKTokenizerOptions.minimalIndex
        let t = try tokens("清华", options: opts)
        // emitUnigrams=false：不发 colocated unigram，但段末字仍占独立位置（phrase/尾字索引）
        XCTAssertEqual(t.map(\.token), ["清华", "华"])
        XCTAssertEqual(t.map(\.colocated), [false, false])
        XCTAssertFalse(t.map(\.token).contains("清"), "不应出现 colocated 首字 unigram")
    }

    func testLatinCaseFoldGolden() throws {
        let t = try tokens("Hello World")
        XCTAssertEqual(t.map(\.token), ["hello", "world"])
    }

    func testStrictMatchPreservesCase() throws {
        let t = try tokens("Hello", options: .strictMatch)
        XCTAssertEqual(t.map(\.token), ["Hello"])
    }

    func testWidthFoldGoldenFullwidthDigits() throws {
        let folded = try tokens("１２３")
        let ascii = try tokens("123")
        XCTAssertEqual(folded.map(\.token), ascii.map(\.token))
        let strict = try tokens("１２３", options: .strictMatch)
        XCTAssertNotEqual(strict.map(\.token), ascii.map(\.token),
                          "strictMatch 关闭宽度折叠后全角数字应与半角不同")
    }

    func testDiacriticFoldGolden() throws {
        let a = try tokens("café")
        let b = try tokens("cafe")
        XCTAssertEqual(a.map(\.token), b.map(\.token))
    }

    func testStopwordPromotionDocumentTokens() throws {
        let opts = CJKTokenizerOptions(stopwords: ["关于"])
        let t = try tokens("关于北京", options: opts)
        // 「关于」bigram 过滤后「关」晋升为主 token；「于北」「北京」「京」仍在
        XCTAssertEqual(
            t.map(\.token),
            ["关", "于北", "于", "北京", "北", "京"]
        )
        XCTAssertFalse(t.map(\.token).contains("关于"))
    }

    func testStopwordPromotionQueryTokens() throws {
        let opts = CJKTokenizerOptions(stopwords: ["关于"])
        let t = try tokens("关于北京", options: opts, query: true)
        // query：bigram「关于」过滤 → 「关」晋升；其余 bigram 无 colocated
        XCTAssertEqual(t.map(\.token), ["关", "于北", "北京"])
        XCTAssertEqual(t.map(\.colocated), [false, false, false])
    }

    func testRecommendedFiltersChineseStopwordUnigram() throws {
        let t = try tokens("我的", options: .recommended)
        // 「的」为中文停用词：不作为独立/ colocated token 保留检索
        XCTAssertFalse(t.map(\.token).contains("的"))
    }

    func testHalfwidthDakutenComposesToVoicedKatakana() throws {
        // ガ fullwidth vs ｶﾞ halfwidth base+dakuten
        let full = try tokens("ガ")
        let half = try tokens("ｶﾞ")
        XCTAssertEqual(full.map(\.token), half.map(\.token),
                       "半角片假名+浊点应合成与全角浊音相同的 token")
    }

    func testHalfwidthDakutenSearchInterop() async throws {
        try await insert("ガラス")
        let r = try await searchAny("ｶﾞﾗｽ")
        XCTAssertEqual(r, ["ガラス"], "半角浊点查询应命中全角浊音文档")
    }
}

// MARK: - Phrase + 停用词位置

final class StopwordPhrasePositionTests: CJKTestBase, @unchecked Sendable {

    func testPhraseAcrossPromotedStopword() async throws {
        let stopwords: Set<String> = ["关于"]
        let db = try makeDB(options: CJKTokenizerOptions(stopwords: stopwords))
        try await insert("北京关于上海", into: db)

        let phrase = try await search("北京关于上海", in: db)
        XCTAssertEqual(phrase, ["北京关于上海"])

        // 晋升后单字仍可搜
        let any = try await searchAny("关", in: db)
        XCTAssertEqual(any, ["北京关于上海"])
    }

    func testQueryAndDocumentStopwordPositionSymmetry() async throws {
        let opts = CJKTokenizerOptions(stopwords: ["的"])
        let db = try makeDB(options: opts)
        try await insert("我的大学", into: db)

        // phrase 与 any 均应能围绕停用词工作
        let r1 = try await searchAny("大学", in: db)
        XCTAssertEqual(r1, ["我的大学"])

        let r2 = try await searchAny("我", in: db)
        XCTAssertEqual(r2, ["我的大学"])

        let r3 = try await searchAny("的", in: db)
        XCTAssertTrue(r3.isEmpty, "停用词本身不可检索")
    }
}
