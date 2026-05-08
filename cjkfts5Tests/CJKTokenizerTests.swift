// CJKTokenizerTests.swift
// cjkfts5Tests
//
// CJKTokenizer 单元测试套件
// 覆盖：分词正确性、Phrase Search、配置选项、边界条件、Unicode 范围、精确率验证

import XCTest
import GRDB
@testable import cjkfts5

// MARK: - 基础测试基类

/// 提供标准内存数据库和辅助方法，所有子测试类继承此基类。
class CJKTestBase: XCTestCase {

    var dbQueue: DatabaseQueue!

    override func setUp() async throws {
        try await super.setUp()
        dbQueue = try makeDB()
    }

    override func tearDown() async throws {
        dbQueue = nil
        try await super.tearDown()
    }

    /// 创建使用指定选项的内存 FTS5 数据库（含 docs 表）
    func makeDB(options: CJKTokenizerOptions = CJKTokenizerOptions()) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(tokenizer: CJKTokenizer.self)
        }
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                t.tokenizer = CJKTokenizer.tokenizerDescriptor(options: options)
                t.column("content")
            }
        }
        return db
    }

    func insert(_ text: String, into db: DatabaseQueue? = nil) async throws {
        let target = db ?? dbQueue!
        try await target.write { db in
            try db.execute(sql: "INSERT INTO docs(content) VALUES (?)", arguments: [text])
        }
    }

    /// phrase 查询（matchingPhrase）
    func search(_ query: String, in db: DatabaseQueue? = nil) async throws -> [String] {
        let target = db ?? dbQueue!
        return try await target.read { db in
            let pattern = FTS5Pattern(matchingPhrase: query)
            return try String.fetchAll(db, sql: "SELECT content FROM docs WHERE docs MATCH ?",
                                       arguments: [pattern])
        }
    }

    /// any-token 查询（matchingAnyTokenIn）
    func searchAny(_ query: String, in db: DatabaseQueue? = nil) async throws -> [String] {
        let target = db ?? dbQueue!
        return try await target.read { db in
            let pattern = FTS5Pattern(matchingAnyTokenIn: query)
            return try String.fetchAll(db, sql: "SELECT content FROM docs WHERE docs MATCH ?",
                                       arguments: [pattern])
        }
    }

    /// raw pattern 查询（精确控制 FTS5 query token）
    func searchRaw(_ rawPattern: String, in db: DatabaseQueue? = nil) async throws -> [String] {
        let target = db ?? dbQueue!
        return try await target.read { db in
            let pattern = try FTS5Pattern(rawPattern: rawPattern)
            return try String.fetchAll(db, sql: "SELECT content FROM docs WHERE docs MATCH ?",
                                       arguments: [pattern])
        }
    }
}

// MARK: - 单字查询测试

final class SingleCharSearchTests: CJKTestBase {

    func testSingleCharHit() async throws {
        try await insert("清华大学")

        let r1 = try await searchAny("清")
        XCTAssertEqual(r1, ["清华大学"], "首字 unigram 应命中")

        let r2 = try await searchAny("学")
        XCTAssertEqual(r2, ["清华大学"], "末字 unigram 应命中")

        let r3 = try await searchAny("华")
        XCTAssertEqual(r3, ["清华大学"], "中间字 unigram 应命中")
    }

    func testSingleCharMiss() async throws {
        try await insert("清华大学")
        let r = try await searchAny("京")
        XCTAssertTrue(r.isEmpty, "[京] 不在文档中，应无命中")
    }

    func testSingleCharDocument() async throws {
        try await insert("学")
        let r = try await searchAny("学")
        XCTAssertEqual(r, ["学"], "单字文档应能被单字查询精确命中")
    }
}

// MARK: - Bigram 查询测试

final class BigramSearchTests: CJKTestBase {

    func testBigramHit() async throws {
        try await insert("北京清华大学")

        let r1 = try await searchAny("清华")
        XCTAssertEqual(r1, ["北京清华大学"], "[清华] bigram 应命中")

        let r2 = try await searchAny("北京")
        XCTAssertEqual(r2, ["北京清华大学"], "[北京] bigram 应命中")

        // 跨词边界 bigram 也应存在于索引
        let r3 = try await searchAny("华大")
        XCTAssertEqual(r3, ["北京清华大学"], "[华大] 跨词边界 bigram 应命中")
    }

    func testBigramMiss() async throws {
        try await insert("北京清华大学")
        let r = try await searchAny("北清")
        XCTAssertTrue(r.isEmpty, "[北清] 非相邻字符，不应命中（防止假阳性）")
    }

    func testTwoCharDocument() async throws {
        try await insert("北京")

        let r1 = try await searchAny("北京")
        XCTAssertEqual(r1, ["北京"], "两字文档 bigram 应命中")

        let r2 = try await searchAny("北")
        XCTAssertEqual(r2, ["北京"], "两字文档首字 unigram 应命中")

        let r3 = try await searchAny("京")
        XCTAssertEqual(r3, ["北京"], "两字文档末字 unigram 应命中")
    }

    /// 多文档场景下验证搜索精确率（不产生假阳性）
    func testBigramPrecisionMultiDoc() async throws {
        try await insert("北京大学")
        try await insert("清华大学")
        try await insert("复旦大学")

        let r1 = try await searchAny("北京")
        XCTAssertEqual(r1, ["北京大学"], "[北京] 应精确命中且仅命中北京大学")

        let r2 = try await searchAny("清华")
        XCTAssertEqual(r2, ["清华大学"], "[清华] 应精确命中且仅命中清华大学")

        // "大学" 三文档均有
        let r3 = try await searchAny("大学")
        XCTAssertEqual(r3.count, 3, "[大学] bigram 应命中全部三个文档")
    }
}

// MARK: - Phrase 查询测试

final class PhraseSearchTests: CJKTestBase {

    func testPhraseHit() async throws {
        try await insert("北京清华大学")

        let r1 = try await search("清华大学")
        XCTAssertEqual(r1, ["北京清华大学"], "[清华大学] phrase 应命中")

        let r2 = try await search("北京清华大学")
        XCTAssertEqual(r2, ["北京清华大学"], "完整短语应命中")

        let r3 = try await search("北京")
        XCTAssertEqual(r3, ["北京清华大学"], "[北京] phrase 应命中")
    }

    func testPhraseMiss() async throws {
        try await insert("北京清华大学")

        // "京大" bigram 不存在，所以 "北京大学" 作为 phrase 不能命中
        let r1 = try await search("北京大学")
        XCTAssertTrue(r1.isEmpty, "[北京大学] phrase 不应命中（[京大] bigram 不存在于文档）")

        let r2 = try await search("清华北京")
        XCTAssertTrue(r2.isEmpty, "词序错误，不应命中")
    }

    func testPhraseMultiDocPrecision() async throws {
        try await insert("北京大学")
        try await insert("北京清华大学")

        let r = try await search("北京大学")
        XCTAssertEqual(r, ["北京大学"], "[北京大学] phrase 应精确命中且仅命中第一条")
    }
}

// MARK: - 混合文本测试

final class MixedTextTests: CJKTestBase {

    func testMixedCJKAndASCII() async throws {
        try await insert("清华大学 Tsinghua University 2024")

        let r1 = try await searchAny("清华")
        XCTAssertFalse(r1.isEmpty, "CJK bigram 应命中")

        let r2 = try await searchAny("tsinghua")
        XCTAssertFalse(r2.isEmpty, "英文小写应命中")

        let r3 = try await searchAny("Tsinghua")
        XCTAssertFalse(r3.isEmpty, "英文大写应命中（case folding）")

        let r4 = try await searchAny("2024")
        XCTAssertFalse(r4.isEmpty, "数字应命中")
    }

    func testLongChineseText() async throws {
        let text = "中国共产党第二十次全国代表大会于2022年10月16日至22日在北京召开"
        try await insert(text)

        let r1 = try await searchAny("北京")
        XCTAssertEqual(r1, [text], "长文本中 bigram 应精确命中")

        let r2 = try await searchAny("2022")
        XCTAssertEqual(r2, [text], "长文本中数字应命中")

        let r3 = try await search("全国代表大会")
        XCTAssertFalse(r3.isEmpty, "长文本中多字 phrase 应命中")
    }
}

// MARK: - 多语言测试

final class MultiLanguageTests: CJKTestBase {

    func testJapaneseHiragana() async throws {
        try await insert("とうきょうだいがく")  // 東京大学（平假名）

        let r1 = try await searchAny("とう")
        XCTAssertEqual(r1, ["とうきょうだいがく"], "平假名 bigram 应命中")

        let r2 = try await searchAny("だい")
        XCTAssertEqual(r2, ["とうきょうだいがく"], "平假名 bigram 应命中")
    }

    func testJapaneseKatakana() async throws {
        try await insert("トウキョウダイガク")  // 東京大学（片假名）

        let r1 = try await searchAny("トウ")
        XCTAssertEqual(r1, ["トウキョウダイガク"], "片假名 bigram 应命中")

        let r2 = try await searchAny("ダイ")
        XCTAssertEqual(r2, ["トウキョウダイガク"], "片假名 bigram 应命中")
    }

    func testKoreanHangul() async throws {
        try await insert("서울대학교")  // 首尔大学

        let r1 = try await searchAny("서울")
        XCTAssertEqual(r1, ["서울대학교"], "韩文 bigram 应命中")

        let r2 = try await searchAny("대학")
        XCTAssertEqual(r2, ["서울대학교"], "韩文 bigram 应命中")
    }

    /// 验证三种语言互不干扰
    func testCJKLanguagesIsolation() async throws {
        try await insert("中文")
        try await insert("とうきょう")
        try await insert("서울")

        let r1 = try await searchAny("中文")
        XCTAssertEqual(r1, ["中文"], "中文查询应仅命中中文文档")

        let r2 = try await searchAny("とう")
        XCTAssertEqual(r2, ["とうきょう"], "日文查询应仅命中日文文档")

        let r3 = try await searchAny("서울")
        XCTAssertEqual(r3, ["서울"], "韩文查询应仅命中韩文文档")
    }
}

// MARK: - 边界条件测试

final class EdgeCaseTests: CJKTestBase {

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

    func testSingleCJKChar() async throws {
        try await insert("学")
        let r = try await searchAny("学")
        XCTAssertEqual(r, ["学"], "单字文档应能被精确命中")
    }

    func testRepeatedChars() async throws {
        try await insert("哈哈哈哈")

        let r1 = try await searchAny("哈哈")
        XCTAssertFalse(r1.isEmpty, "重复字符的 bigram 应命中")

        let r2 = try await searchAny("哈")
        XCTAssertFalse(r2.isEmpty, "重复字符的 unigram 应命中")
    }

    func testNumericString() async throws {
        try await insert("12345")
        let r = try await searchAny("12345")
        XCTAssertFalse(r.isEmpty, "纯数字文档应命中")
    }
}

// MARK: - 配置选项测试

final class OptionTests: CJKTestBase {

    // MARK: no_unigram

    func testNoUnigramBigramStillWorks() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("清华大学", into: db)

        let r = try await searchRaw("清华", in: db)
        XCTAssertEqual(r, ["清华大学"], "no_unigram 模式下 bigram 仍应命中")
    }

    func testNoUnigramNonTrailingCharMisses() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("清华大学", into: db)

        // 非末字 unigram 不在索引中
        let r = try await searchRaw("清", in: db)
        XCTAssertTrue(r.isEmpty, "no_unigram 模式下非末字单字查询应无命中")
    }

    func testNoUnigramTrailingCharHits() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("清华大学", into: db)

        // "学" 是末字，no_unigram 模式下末字仍作为独立 unigram 发出
        let r = try await searchRaw("学", in: db)
        XCTAssertFalse(r.isEmpty, "no_unigram 模式下末字仍应命中（末字总是独立 unigram）")
    }

    // MARK: case folding

    func testCaseFoldingEnabled() async throws {
        try await insert("Hello World")

        let r1 = try await searchAny("hello")
        XCTAssertFalse(r1.isEmpty, "case folding 开启：小写应命中大写文档")

        let r2 = try await searchAny("HELLO")
        XCTAssertFalse(r2.isEmpty, "case folding 开启：全大写应命中")

        let r3 = try await searchAny("Hello")
        XCTAssertFalse(r3.isEmpty, "case folding 开启：混合大小写应命中")
    }

    func testCaseFoldingDisabled() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(caseFolding: false))
        try await insert("Hello World", into: db)

        // caseFolding=false 时，文档 token 保留原始大小写 "Hello"
        // 注意：matchingAnyTokenIn 内部用 ascii tokenizer 会折叠为小写，
        // 因此这里用 rawPattern 直接指定 token，验证索引中存储的是原始大小写
        let r1 = try await searchRaw("Hello", in: db)
        XCTAssertFalse(r1.isEmpty, "case folding 关闭：原始大写 token 应命中")

        let r2 = try await searchRaw("hello", in: db)
        XCTAssertTrue(r2.isEmpty, "case folding 关闭：小写 token 不应命中大写文档")
    }

    // MARK: 组合选项

    func testCombinedNoUnigramNoCaseFold() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false, caseFolding: false))
        try await insert("清华 Hello", into: db)

        let r1 = try await searchRaw("清", in: db)
        XCTAssertTrue(r1.isEmpty, "no_unigram+no_case_fold：非末字单字应无命中")

        let r2 = try await searchAny("hello", in: db)
        XCTAssertTrue(r2.isEmpty, "no_case_fold：小写不应命中大写文档")

        let r3 = try await searchRaw("清华", in: db)
        XCTAssertFalse(r3.isEmpty, "组合选项下 bigram 仍应命中")
    }
}

// MARK: - Unicode 范围覆盖测试

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
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3400)!),  "U+3400 扩展A 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x4DBF)!),  "U+4DBF 扩展A 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x33FF)!), "U+33FF 扩展A 前，不是 CJK")
    }

    func testCJKCompatBoundary() {
        // CJK 兼容汉字 U+F900–U+FAFF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xF900)!),  "U+F900 兼容汉字起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xFAFF)!),  "U+FAFF 兼容汉字结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0xFB00)!), "U+FB00 兼容汉字后，不是 CJK")
    }

    func testHiraganaBoundary() {
        // 平假名 U+3040–U+309F
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3041)!),  "U+3041 ぁ 平假名起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3042)!),  "U+3042 あ 平假名")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x309F)!),  "U+309F 平假名结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x303F)!), "U+303F 平假名前，不是 CJK")
    }

    func testKatakanaBoundary() {
        // 片假名 U+30A0–U+30FF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30A0)!),  "U+30A0 片假名起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30A2)!),  "U+30A2 ア 片假名")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30FF)!),  "U+30FF 片假名结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x3100)!), "U+3100 片假名后，不是 CJK")
    }

    func testHangulBoundary() {
        // 韩文音节 U+AC00–U+D7AF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xAC00)!),  "U+AC00 가 韩文起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0xD7AF)!),  "U+D7AF 韩文结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0xABFF)!), "U+ABFF 韩文前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0xD7B0)!), "U+D7B0 韩文后，不是 CJK")
    }

    func testNonCJKChars() {
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar("A")),     "'A' 不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar("z")),     "'z' 不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar("1")),     "'1' 不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(" ")),     "空格不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(".")),     "句号不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x00E9)!), "U+00E9 é 不是 CJK")
    }
}

// MARK: - CJKUnicodeHelper 工具方法单元测试

final class UnicodeHelperTests: XCTestCase {

    func testComputeByteOffsetsASCII() {
        let scalars = Array("abc".unicodeScalars)
        let offsets = CJKUnicode.computeByteOffsets(of: scalars)
        XCTAssertEqual(offsets, [0, 1, 2, 3], "ASCII 每字符 1 字节，偏移应为 [0,1,2,3]")
    }

    func testComputeByteOffsetsCJK() {
        let scalars = Array("清华".unicodeScalars)
        let offsets = CJKUnicode.computeByteOffsets(of: scalars)
        // 每个汉字 UTF-8 编码 3 字节
        XCTAssertEqual(offsets, [0, 3, 6], "汉字每字符 3 字节，偏移应为 [0,3,6]")
    }

    func testComputeByteOffsetsMixed() {
        let scalars = Array("a清".unicodeScalars)
        let offsets = CJKUnicode.computeByteOffsets(of: scalars)
        // 'a'=1 字节, '清'=3 字节
        XCTAssertEqual(offsets, [0, 1, 4], "混合字符偏移应为 [0,1,4]")
    }

    func testComputeByteOffsetsEmpty() {
        let offsets = CJKUnicode.computeByteOffsets(of: [])
        XCTAssertEqual(offsets, [0], "空数组偏移应返回 [0]")
    }

    func testIsWordCharASCII() {
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar("a")),  "'a' 应是词字符")
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar("Z")),  "'Z' 应是词字符")
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar("5")),  "'5' 应是词字符")
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
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar(0xFF10)!),  "U+FF10 ０ 全角数字应是词字符")
        XCTAssertTrue(CJKUnicode.isWordChar(Unicode.Scalar(0xFF19)!),  "U+FF19 ９ 全角数字应是词字符")
        XCTAssertFalse(CJKUnicode.isWordChar(Unicode.Scalar(0xFF0F)!), "U+FF0F ／ 不是词字符")
    }
}
