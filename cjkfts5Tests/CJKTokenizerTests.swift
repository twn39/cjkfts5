// CJKTokenizerTests.swift
// cjkfts5Tests
//
// CJKTokenizer 单元测试
// 覆盖：分词正确性、Phrase Search 对称性、混合文本、边界条件

import XCTest
import GRDB
@testable import cjkfts5

final class CJKTokenizerTests: XCTestCase {

    // MARK: 测试数据库（内存数据库，每个 test 独立）

    private var dbQueue: DatabaseQueue!

    override func setUp() async throws {
        try await super.setUp()
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(tokenizer: CJKTokenizer.self)
        }
        dbQueue = try DatabaseQueue(configuration: config)

        try await dbQueue.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                t.tokenizer = CJKTokenizer.tokenizerDescriptor()
                t.column("content")
            }
        }
    }

    override func tearDown() async throws {
        dbQueue = nil
        try await super.tearDown()
    }

    // MARK: 辅助方法

    private func insert(_ text: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO docs(content) VALUES (?)", arguments: [text])
        }
    }

    private func search(_ query: String) async throws -> [String] {
        try await dbQueue.read { db in
            let pattern = FTS5Pattern(matchingPhrase: query)
            return try String.fetchAll(db, sql: "SELECT content FROM docs WHERE docs MATCH ?",
                                       arguments: [pattern])
        }
    }

    private func searchAny(_ query: String) async throws -> [String] {
        try await dbQueue.read { db in
            let pattern = FTS5Pattern(matchingAnyTokenIn: query)
            return try String.fetchAll(db, sql: "SELECT content FROM docs WHERE docs MATCH ?",
                                       arguments: [pattern])
        }
    }

    // MARK: - 测试：单字 CJK 查询

    func testSingleCharacterSearch() async throws {
        try await insert("清华大学")

        // 单字查询（命中 unigram）
        let r1 = try await searchAny("清")
        XCTAssertFalse(r1.isEmpty, "单字[清]应能命中[清华大学]")

        let r2 = try await searchAny("学")
        XCTAssertFalse(r2.isEmpty, "单字[学]应能命中[清华大学]")

        let r3 = try await searchAny("京")
        XCTAssertTrue(r3.isEmpty, "[京]不在文档中，应无命中")
    }

    // MARK: - 测试：双字 CJK 查询（bigram 直接命中）

    func testBigramSearch() async throws {
        try await insert("北京清华大学")

        let r1 = try await searchAny("清华")
        XCTAssertFalse(r1.isEmpty, "[清华] bigram 应命中文档")

        let r2 = try await searchAny("北京")
        XCTAssertFalse(r2.isEmpty, "[北京] bigram 应命中文档")

        let r3 = try await searchAny("华大")
        XCTAssertFalse(r3.isEmpty, "[华大] 跨词边界 bigram 应命中文档")

        let r4 = try await searchAny("北清")
        XCTAssertTrue(r4.isEmpty, "[北清] 不是相邻字符，应无命中")
    }

    // MARK: - 测试：多字短语查询（Phrase Match 核心正确性）

    func testPhraseSearch() async throws {
        try await insert("北京清华大学")

        // ✅ 应命中
        let match1 = try await search("清华大学")
        XCTAssertFalse(match1.isEmpty, "[清华大学] phrase 应命中")

        let match2 = try await search("北京清华大学")
        XCTAssertFalse(match2.isEmpty, "[北京清华大学] 完整短语应命中")

        let match3 = try await search("北京")
        XCTAssertFalse(match3.isEmpty, "[北京] phrase 应命中")

        // ❌ 不应命中（关键：避免误判）
        let noMatch1 = try await search("北京大学")
        XCTAssertTrue(noMatch1.isEmpty,
            "[北京大学] phrase 不应命中[北京清华大学]（[京大] bigram 不存在于文档）")

        let noMatch2 = try await search("清华北京")
        XCTAssertTrue(noMatch2.isEmpty, "词序错误，不应命中")
    }

    // MARK: - 测试：短文档（单字）

    func testSingleCharDocument() async throws {
        try await insert("学")
        let r = try await searchAny("学")
        XCTAssertFalse(r.isEmpty, "单字文档应能被单字查询命中")
    }

    // MARK: - 测试：两字文档

    func testTwoCharDocument() async throws {
        try await insert("北京")
        let r1 = try await searchAny("北京")
        XCTAssertFalse(r1.isEmpty, "两字文档 bigram 应命中")

        let r2 = try await searchAny("北")
        XCTAssertFalse(r2.isEmpty, "两字文档的首字 unigram 应命中")

        let r3 = try await searchAny("京")
        XCTAssertFalse(r3.isEmpty, "两字文档的末字应命中（末字为独立 unigram）")
    }

    // MARK: - 测试：中英混合文本

    func testMixedCJKAndASCII() async throws {
        try await insert("清华大学 Tsinghua University 2024")

        // CJK 部分
        let r1 = try await searchAny("清华")
        XCTAssertFalse(r1.isEmpty, "混合文本中的 CJK bigram 应命中")

        // 英文部分（大小写不敏感）
        let r2 = try await searchAny("tsinghua")
        XCTAssertFalse(r2.isEmpty, "混合文本中的英文（小写）应命中")

        let r3 = try await searchAny("Tsinghua")
        XCTAssertFalse(r3.isEmpty, "混合文本中的英文（大写）应命中（case folding）")

        // 数字
        let r4 = try await searchAny("2024")
        XCTAssertFalse(r4.isEmpty, "混合文本中的数字应命中")
    }

    // MARK: - 测试：日文（平假名/片假名）

    func testJapaneseHiragana() async throws {
        try await insert("とうきょうだいがく")  // 东京大学（平假名）

        let r1 = try await searchAny("とう")
        XCTAssertFalse(r1.isEmpty, "日文平假名 bigram 应命中")

        let r2 = try await searchAny("だい")
        XCTAssertFalse(r2.isEmpty, "日文平假名 bigram 应命中")
    }

    func testJapaneseKatakana() async throws {
        try await insert("トウキョウダイガク")  // 东京大学（片假名）

        let r1 = try await searchAny("トウ")
        XCTAssertFalse(r1.isEmpty, "日文片假名 bigram 应命中")
    }

    // MARK: - 测试：韩文（谚文）

    func testKoreanHangul() async throws {
        try await insert("서울대학교")  // 首尔大学（韩文）

        let r1 = try await searchAny("서울")
        XCTAssertFalse(r1.isEmpty, "韩文 bigram 应命中")

        let r2 = try await searchAny("대학")
        XCTAssertFalse(r2.isEmpty, "韩文 bigram 应命中")
    }

    // MARK: - 测试：边界条件

    func testEmptyDocument() async throws {
        try await insert("")
        let r = try await searchAny("清")
        XCTAssertTrue(r.isEmpty, "空文档不应有命中")
    }

    func testWhitespaceOnlyDocument() async throws {
        try await insert("   \t\n  ")
        let r = try await searchAny("清")
        XCTAssertTrue(r.isEmpty, "纯空白文档不应有命中")
    }

    func testPunctuationOnlyDocument() async throws {
        try await insert("，。！？《》【】")
        let r = try await searchAny("，")
        XCTAssertTrue(r.isEmpty, "纯标点文档不应有命中（标点不发出 token）")
    }

    func testLongChineseText() async throws {
        let text = "中国共产党第二十次全国代表大会于2022年10月16日至22日在北京召开"
        try await insert(text)

        let r1 = try await searchAny("北京")
        XCTAssertFalse(r1.isEmpty, "长文本中的 bigram 应命中")

        let r2 = try await searchAny("2022")
        XCTAssertFalse(r2.isEmpty, "长文本中的数字应命中")
    }

    // MARK: - 测试：no_unigram 选项

    func testNoUnigramOption() async throws {
        // 关闭 unigram：单字查询应失效
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(tokenizer: CJKTokenizer.self)
        }
        let db2 = try DatabaseQueue(configuration: config)

        try await db2.write { db in
            try db.create(virtualTable: "docs2", using: FTS5()) { t in
                t.tokenizer = CJKTokenizer.tokenizerDescriptor(
                    options: CJKTokenizerOptions(emitUnigrams: false)
                )
                t.column("content")
            }
            try db.execute(sql: "INSERT INTO docs2(content) VALUES (?)", arguments: ["清华大学"])
        }

        try await db2.read { db in
            // bigram 仍然有效。
            // 现在 query tokenization 已修复（末字不再产生新位置 AND 约束），
            // 直接用 rawPattern 即可正确命中 bigram 索引。
            let pattern = try FTS5Pattern(rawPattern: "清华")
            let r1 = try String.fetchAll(db, sql: "SELECT content FROM docs2 WHERE docs2 MATCH ?",
                                          arguments: [pattern])
            XCTAssertFalse(r1.isEmpty, "no_unigram 模式下 bigram 仍应命中")

            // 单字应失效（非末字 unigram 不在 no_unigram 模式的索引中）
            let pattern2 = try FTS5Pattern(rawPattern: "清")
            let r2 = try String.fetchAll(db, sql: "SELECT content FROM docs2 WHERE docs2 MATCH ?",
                                          arguments: [pattern2])
            XCTAssertTrue(r2.isEmpty, "no_unigram 模式下非末字的单字查询应无命中")
        }

    }

    // MARK: - 测试：CJKUnicodeHelper 范围覆盖

    func testCJKRangeDetection() {
        // 常用汉字
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x4E00)!),  "U+4E00 应是 CJK")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x9FFF)!),  "U+9FFF 应是 CJK")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x6E05)!),  "[清] (U+6E05) 应是 CJK")

        // 平假名
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3042)!),  "U+3042 あ 应是 CJK")

        // 片假名
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30A2)!),  "U+30A2 ア 应是 CJK")

        // 韩文
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xAC00)!),  "U+AC00 가 应是 CJK")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xD7AF)!),  "U+D7AF 应是 CJK")

        // 非 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar("A")),  "'A' 不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(" ")),  "空格不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar("1")),  "'1' 不是 CJK")
    }
}
