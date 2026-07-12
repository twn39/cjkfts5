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

    func testLegacyAliasesPointToPresets() {
        XCTAssertEqual(CJKTokenizerOptions.englishStopwords, StopwordPresets.english)
        XCTAssertEqual(CJKTokenizerOptions.chineseStopwords, StopwordPresets.chinese)
    }
}

// MARK: - Token 金标（document / query）

final class TokenGoldenTests: CJKTestBase {

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

    func testQueryGoldenTsinghuaNoTrailingUnigramAlone() throws {
        // query 模式：末字不单独占新位置；colocated unigram 在非末位置仍可能发出
        let t = try tokens("清华大学", query: true)
        // 典型：清华/清, 华大/华, 大学（末 bigram，无独立「学」位，且 query 常不发 colocated）
        XCTAssertFalse(t.map(\.token).contains("学") && t.last?.token == "学",
                       "query 末字不应作为独立新位置 token")
        XCTAssertTrue(t.map(\.token).contains("清华"))
        XCTAssertTrue(t.map(\.token).contains("大学"))
    }

    func testDocumentNoUnigrams() throws {
        let opts = CJKTokenizerOptions(emitUnigrams: false)
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

    func testStopwordPromotionDocumentTokens() throws {
        let opts = CJKTokenizerOptions(stopwords: ["关于"])
        let t = try tokens("关于北京", options: opts)
        // 「关于」bigram 过滤后「关」晋升为主 token；「于北」「北京」「京」仍在
        XCTAssertTrue(t.map(\.token).contains("关"))
        XCTAssertFalse(t.map(\.token).contains("关于"))
        XCTAssertTrue(t.map(\.token).contains("北京"))
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

final class StopwordPhrasePositionTests: CJKTestBase {

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
