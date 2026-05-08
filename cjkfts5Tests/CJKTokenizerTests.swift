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

    // MARK: - 扩展 B–I、扩展 G 边界测试（新增）

    func testCJKExtBBoundary() {
        // CJK 扩展 B U+20000–U+2A6DF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x20000)!),  "U+20000 扩展B 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2A6DF)!),  "U+2A6DF 扩展B 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1FFFF)!), "U+1FFFF 扩展B 前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2A6E0)!), "U+2A6E0 扩展B 后，不是 CJK")
    }

    func testCJKExtCBoundary() {
        // CJK 扩展 C U+2A700–U+2B73F（Unicode 6.0，~4,149字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2A700)!),  "U+2A700 扩展C 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B73F)!),  "U+2B73F 扩展C 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2A6FF)!), "U+2A6FF 扩展C 前（扩展B外），不是 CJK")
        // U+2B740 是扩展D起始，也是 CJK（扩展C与D地址连续）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B740)!),  "U+2B740 扩展D 起始，仍是 CJK")
    }

    func testCJKExtDBoundary() {
        // CJK 扩展 D U+2B740–U+2B81F（Unicode 6.3，~222字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B740)!),  "U+2B740 扩展D 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B81F)!),  "U+2B81F 扩展D 结尾")
        // U+2B820 是扩展E起始，也是 CJK（扩展D与E地址连续）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B820)!),  "U+2B820 扩展E 起始，仍是 CJK")
        // 扩展B与C之间的间隙（U+2A6E0–U+2A6FF）不是 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2A6FF)!), "U+2A6FF 扩展B/C 间隙，不是 CJK")
    }


    func testCJKExtEBoundary() {
        // CJK 扩展 E U+2B820–U+2CEAF（Unicode 8.0，~5,762字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2B820)!),  "U+2B820 扩展E 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2CEAF)!),  "U+2CEAF 扩展E 结尾")
        // U+2CEB0 是扩展F起始，也是 CJK（扩展E与F地址连续）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2CEB0)!),  "U+2CEB0 扩展F 起始，仍是 CJK")
    }

    func testCJKExtFBoundary() {
        // CJK 扩展 F U+2CEB0–U+2EBEF（Unicode 10.0，~7,473字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2CEB0)!),  "U+2CEB0 扩展F 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2EBEF)!),  "U+2EBEF 扩展F 结尾")
        // U+2EBF0 是扩展I起始，也是 CJK（扩展F与I地址连续）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2EBF0)!),  "U+2EBF0 扩展I 起始，仍是 CJK")
        // 扩展F/I之后的真正非CJK区域
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2EE60)!), "U+2EE60 扩展I 之后，不是 CJK")
    }

    func testCJKExtIBoundary() {
        // CJK 扩展 I U+2EBF0–U+2EE5F（Unicode 15.1，~622字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2EBF0)!),  "U+2EBF0 扩展I 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x2EE5F)!),  "U+2EE5F 扩展I 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2EE60)!), "U+2EE60 扩展I 后，不是 CJK")
    }

    func testCJKExtGBoundary() {
        // CJK 扩展 G U+30000–U+3134F（Unicode 13.0，~4,939字）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x30000)!),  "U+30000 扩展G 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3134F)!),  "U+3134F 扩展G 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x2FFFF)!), "U+2FFFF 扩展G 前，不是 CJK")
        // U+31350 是 CJK 扩展 H 起始，应为 CJK（修复旧断言）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31350)!),  "U+31350 扩展H 起始，是 CJK")
    }

    func testHangulJamoBoundary() {
        // 韩文字母 Jamo U+1100–U+11FF
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1100)!),   "U+1100 ㄱ Jamo 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x11FF)!),   "U+11FF Jamo 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x10FF)!),  "U+10FF Jamo 前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1200)!),  "U+1200 Jamo 后，不是 CJK")

        // 韩文兼容字母 U+3130–U+318F
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3130)!),   "U+3130 兼容Jamo 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x318F)!),   "U+318F 兼容Jamo 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x312F)!),  "U+312F 兼容Jamo 前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x3190)!),  "U+3190 兼容Jamo 后，不是 CJK")
    }

    func testKatakanaExtensionBoundary() {
        // 片假名扩展 U+31F0–U+31FF（爱努语）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31F0)!),   "U+31F0 片假名扩展起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31FF)!),   "U+31FF 片假名扩展结尾")
        // 注：U+31F0 紧接在片假名（U+30A0–U+30FF）之后，中间 U+3100–U+31EF 不应是 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x3100)!),  "U+3100 片假名后、扩展前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x3200)!),  "U+3200 片假名扩展后，不是 CJK")
    }

    // MARK: - 新增：CJK 扩展 H 边界测试（Unicode 15.0）

    func testCJKExtHBoundary() {
        // CJK 扩展 H U+31350–U+323AF（Unicode 15.0，~4,192字）
        // 位于第三汉字平面（TIP，Tertiary Ideographic Plane），Script=Han
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31350)!),  "U+31350 扩展H 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x323AF)!),  "U+323AF 扩展H 结尾")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x31800)!),  "U+31800 扩展H 中间字符")
        // 扩展 G（U+30000–U+3134F）与扩展 H 相邻，下方是最后一个 G 字符
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x3134F)!),  "U+3134F 扩展G 结尾，仍是 CJK")
        // 扩展 H 结尾之后不应是 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x323B0)!), "U+323B0 扩展H 后，不是 CJK")
    }

    // MARK: - 新增：SMP 假名区块边界测试

    func testKanaExtendedBBoundary() {
        // Kana Extended-B U+1AFF0–U+1AFFF（Unicode 14.0，台湾假名）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1AFF0)!),  "U+1AFF0 Kana Extended-B 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1AFFF)!),  "U+1AFFF Kana Extended-B 结尾")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1AFEF)!), "U+1AFEF Kana Extended-B 前，不是 CJK")
        // U+1B000 是 Katakana Supplement 起始，应是 CJK
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B000)!),  "U+1B000 Katakana Supplement 起始，是 CJK")
    }

    func testKatakanaSMPBlocksBoundary() {
        // 三个相邻区块合并判断：U+1B000–U+1B16F
        // Katakana Supplement U+1B000–U+1B0FF（Unicode 6.0）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B000)!),  "U+1B000 Katakana Supplement 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B0FF)!),  "U+1B0FF Katakana Supplement 结尾")
        // Kana Extended-A U+1B100–U+1B12F（Unicode 10.0，Hentaigana）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B100)!),  "U+1B100 Kana Extended-A 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B12F)!),  "U+1B12F Kana Extended-A 结尾")
        // Small Kana Extension U+1B130–U+1B16F（Unicode 12.0）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B130)!),  "U+1B130 Small Kana Extension 起始")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B16F)!),  "U+1B16F Small Kana Extension 结尾")
        // 区块前后不应是 CJK
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1AFEF)!), "U+1AFEF SMP 假名块前，不是 CJK")
        XCTAssertFalse(CJKUnicode.isCJK(Unicode.Scalar(0x1B170)!), "U+1B170 Small Kana Extension 后，不是 CJK")
        // 验证已赋值字符（Small Kana Extension 中的 9 个字符）
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B132)!),  "U+1B132 𛄲 HIRAGANA SMALL KO")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B155)!),  "U+1B155 𛅕 KATAKANA SMALL KO")
        XCTAssertTrue(CJKUnicode.isCJK(Unicode.Scalar(0x1B167)!),  "U+1B167 𛅧 KATAKANA SMALL N")
    }
}

// MARK: - CJKUnicodeHelper 工具方法单元测试

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

// MARK: - 扩展 CJK 字符集成搜索测试

/// 验证扩展 C-G/I 字符在真实 FTS5 分词与搜索中行为正确。
/// 使用 CJKTestBase 继承内存数据库与辅助方法。
final class ExtendedUnicodeSearchTests: CJKTestBase {

    // MARK: 扩展 C：U+2A700–U+2B73F（Unicode 6.0）

    func testExtCCharSearch() async throws {
        // U+2A700 𪜀 是扩展 C 第一个字符，与普通汉字混合
        // 用 Unicode scalar 构造字符串以避免编辑器字体问题
        let extCChar = String(Unicode.Scalar(0x2A700)!)  // 𪜀
        let text = extCChar + "清华"                       // "𪜀清华"
        try await insert(text)

        // 扩展C字符应当被识别为 CJK，与后续汉字构成连续 CJK 段
        // bigram「𪜀清」应存在于索引中
        let r1 = try await searchAny(extCChar + "清")
        XCTAssertFalse(r1.isEmpty, "扩展C字符与普通汉字的跨段 bigram 应命中")

        // 单字扩展C字符 unigram 应命中
        let r2 = try await searchAny(extCChar)
        XCTAssertFalse(r2.isEmpty, "扩展C 单字 unigram 应命中")
    }

    // MARK: 扩展 E：U+2B820–U+2CEAF（Unicode 8.0，含大量传统汉字）

    func testExtECharSearch() async throws {
        let extEChar = String(Unicode.Scalar(0x2B820)!)  // 第一个扩展E字符
        let text = "北京" + extEChar + "大学"
        try await insert(text)

        // 扩展E字符应在连续 CJK 段中参与 bigram
        let r1 = try await searchAny("北京")
        XCTAssertFalse(r1.isEmpty, "含扩展E字符的文本中，普通 bigram [北京] 应命中")

        let r2 = try await searchAny("大学")
        XCTAssertFalse(r2.isEmpty, "含扩展E字符的文本中，普通 bigram [大学] 应命中")
    }

    // MARK: 扩展 F：U+2CEB0–U+2EBEF（Unicode 10.0）

    func testExtFCharSearch() async throws {
        let extFChar = String(Unicode.Scalar(0x2CEB0)!)  // 第一个扩展F字符
        let text = extFChar + extFChar  // 两个扩展F字符，产生一个 bigram
        try await insert(text)

        let r = try await searchAny(extFChar + extFChar)
        XCTAssertFalse(r.isEmpty, "两个扩展F字符构成的 bigram 应命中")
    }

    // MARK: 扩展 G：U+30000–U+3134F（Unicode 13.0）

    func testExtGCharSearch() async throws {
        let extGChar = String(Unicode.Scalar(0x30000)!)  // 第一个扩展G字符
        let text = extGChar + "大学"
        try await insert(text)

        let r1 = try await searchAny(extGChar)
        XCTAssertFalse(r1.isEmpty, "扩展G 单字 unigram 应命中")

        let r2 = try await searchAny("大学")
        XCTAssertFalse(r2.isEmpty, "扩展G字符后的普通汉字 bigram 应命中")
    }

    // MARK: 段连续性：确保扩展字符不会错误打断 CJK 段

    func testExtCharDoesNotBreakCJKSegment() async throws {
        // 关键回归测试：修复前，扩展C/D/E/F/G 字符被误判为非CJK，
        // 会把连续汉字段错误切割，导致正常 bigram 失效。
        let extCChar  = String(Unicode.Scalar(0x2A700)!)   // 扩展C
        let mixedText = "北京" + extCChar + "大学"            // 全部应在同一 CJK 段内
        try await insert(mixedText)

        // 若扩展C被误判为非CJK，bigram「𪜀大」不会存在，
        // 但「北京」和「大学」会各自成独立段，仍可命中。
        // 正确行为：「京𪜀」「𪜀大」bigram 均存在。
        let r1 = try await searchAny("北京")
        XCTAssertFalse(r1.isEmpty, "CJK段连续性：[北京] bigram 应命中")

        let r2 = try await searchAny("大学")
        XCTAssertFalse(r2.isEmpty, "CJK段连续性：[大学] bigram 应命中")

        // 跨扩展字符的 bigram 应存在（段连续性验证）
        let crossBigram = String(Unicode.Scalar(0x4EAC)!) + extCChar  // 「京𪜀」
        let r3 = try await searchAny(crossBigram)
        XCTAssertFalse(r3.isEmpty, "跨扩展C字符的 bigram [京𪜀] 应命中（段连续性）")
    }

    // MARK: 韩文 Jamo（U+1100–U+11FF）搜索

    func testHangulJamoSearch() async throws {
        // ㄱ (U+1100) 是韩文字母，与音节不同，直接搜索
        let jamo1 = String(Unicode.Scalar(0x1100)!)  // ㄱ
        let jamo2 = String(Unicode.Scalar(0x1161)!)  // ᅡ
        let text = jamo1 + jamo2 + "서울"             // 混合 Jamo 和音节
        try await insert(text)

        let r = try await searchAny(jamo1 + jamo2)
        XCTAssertFalse(r.isEmpty, "韩文 Jamo bigram 应命中")
    }

    // MARK: CJK 扩展 H（U+31350–U+323AF，Unicode 15.0）端到端搜索

    func testExtHCharSearch() async throws {
        // U+31350 是扩展 H 第一个字符
        let extHChar = String(Unicode.Scalar(0x31350)!)
        let text = extHChar + "大学"
        try await insert(text)

        // 扩展 H 字符应被识别为 CJK，与后续汉字构成连续 CJK 段
        let r1 = try await searchAny(extHChar)
        XCTAssertFalse(r1.isEmpty, "扩展H 单字 unigram 应命中")

        let r2 = try await searchAny("大学")
        XCTAssertFalse(r2.isEmpty, "扩展H字符后的普通汉字 bigram 应命中")

        // 扩展H字符与后续汉字构成的跨段 bigram 应存在
        let crossBigram = extHChar + "大"
        let r3 = try await searchAny(crossBigram)
        XCTAssertFalse(r3.isEmpty, "扩展H字符与普通汉字的跨段 bigram [\(crossBigram)] 应命中")
    }

    // MARK: SMP 假名区块（Kana Extended-B / Katakana Supplement / Kana Extended-A）端到端搜索

    func testKanaExtendedBSearch() async throws {
        // U+1AFF0 是 Kana Extended-B（台湾假名）第一个字符
        let kanaB = String(Unicode.Scalar(0x1AFF0)!)
        let kanaB2 = String(Unicode.Scalar(0x1AFF1)!)
        let text = kanaB + kanaB2 + "台湾"
        try await insert(text)

        // Kana Extended-B 字符应被识别为 CJK，参与 bigram 分词
        let r1 = try await searchAny(kanaB + kanaB2)
        XCTAssertFalse(r1.isEmpty, "Kana Extended-B bigram 应命中")

        let r2 = try await searchAny("台湾")
        XCTAssertFalse(r2.isEmpty, "Kana Extended-B 后的普通汉字 bigram 应命中")
    }

    func testKatakanaSupplementSearch() async throws {
        // U+1B000 是 Katakana Supplement 第一个字符
        let kataSup = String(Unicode.Scalar(0x1B000)!)
        let kataSup2 = String(Unicode.Scalar(0x1B001)!)
        let text = kataSup + kataSup2 + "日本"
        try await insert(text)

        let r1 = try await searchAny(kataSup + kataSup2)
        XCTAssertFalse(r1.isEmpty, "Katakana Supplement bigram 应命中")

        let r2 = try await searchAny("日本")
        XCTAssertFalse(r2.isEmpty, "Katakana Supplement 后的普通汉字 bigram 应命中")
    }
}

// MARK: - 并发安全测试

/// 验证 CJKTokenizer 和工具函数在并发场景下的正确性与安全性。
///
/// 覆盖五个维度：
/// - 维度 A：静态工具函数（isCJK / decodeScalar）并发确定性
/// - 维度 B：DatabaseQueue 并发读一致性
/// - 维度 C：DatabasePool 多连接真正并发读
/// - 维度 D：读写并发不干扰正确性
/// - 维度 E：高压力分词结果确定性
///
/// ⚠️ 开启 Thread Sanitizer 运行此测试类以获得最大检测效果：
///    Xcode → Edit Scheme → Test → Diagnostics → Thread Sanitizer: ✓
///    命令行：swift test --sanitize thread
///    TSan 可检测：对象非原子性读写竞争、无保护全局变量访问、无序内存操作
final class ConcurrencyTests: CJKTestBase {

    // MARK: 维度 A — 静态工具函数并发确定性

    /// 验证 CJKUnicode.isCJK 在 1000 次并发调用下结果完全确定。
    ///
    /// isCJK 是 @inline(__always) 纯函数，无共享可变状态；
    /// 此测试配合 TSan 可验证无数据竞争。
    func testConcurrentStaticFunctionsDeterminism() {
        let testCases: [(Unicode.Scalar, Bool)] = [
            (Unicode.Scalar(0x4E00)!, true),   // CJK 统一汉字起始
            (Unicode.Scalar(0x9FFF)!, true),   // CJK 统一汉字结尾
            (Unicode.Scalar(0x0041)!, false),  // 'A'，非 CJK
            (Unicode.Scalar(0x3040)!, true),   // 平假名起始
            (Unicode.Scalar(0xAC00)!, true),   // 韩文音节起始
            (Unicode.Scalar(0x31350)!, true),  // CJK 扩展 H（Unicode 15.0）
            (Unicode.Scalar(0x1B000)!, true),  // Katakana Supplement
            (Unicode.Scalar(0x0020)!, false),  // 空格，非 CJK
        ]

        let iterations = 1000
        let correctCount = LockProtected(0)

        // DispatchQueue.concurrentPerform：强制真正并发执行，最大化线程争用
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let (scalar, expected) = testCases[i % testCases.count]
            if CJKUnicode.isCJK(scalar) == expected {
                correctCount.increment()
            }
        }

        XCTAssertEqual(correctCount.value, iterations,
            "并发调用 isCJK：\(iterations) 次全部结果正确（实际正确 \(correctCount.value) 次）")
    }

    /// 验证 CJKUnicode.decodeScalar 在 500 次并发调用下结果完全确定。
    ///
    /// 使用「清」（U+6E05，UTF-8: E6 B8 85）作为测试输入，
    /// 验证并发解码不产生错误结果或崩溃。
    func testConcurrentDecodeScalarDeterminism() {
        // 「清」= U+6E05，UTF-8 编码：E6 B8 85（3字节）
        let bytes: [UInt8] = [0xE6, 0xB8, 0x85]
        let expectedScalar = Unicode.Scalar(0x6E05)!
        let iterations = 500
        let correctCount = LockProtected(0)

        bytes.withUnsafeBytes { rawBuffer in
            DispatchQueue.concurrentPerform(iterations: iterations) { _ in
                if let (scalar, len) = CJKUnicode.decodeScalar(rawBuffer, at: 0),
                   scalar == expectedScalar, len == 3 {
                    correctCount.increment()
                }
            }
        }

        XCTAssertEqual(correctCount.value, iterations,
            "\(iterations) 次并发 decodeScalar(「清」) 全部返回正确结果")
    }

    // MARK: 维度 B — DatabaseQueue 并发读一致性

    /// 验证 50 个并发 async 任务同时读取 DatabaseQueue，所有结果完全一致。
    ///
    /// DatabaseQueue 内部串行化读操作，此测试验证：
    /// - 并发 async read 的调度正确性
    /// - 分词结果在排队执行后仍然一致
    func testConcurrentReadsOnDatabaseQueue() async throws {
        let documents = ["北京大学", "清华大学", "复旦大学", "浙江大学", "南京大学"]
        for doc in documents { try await insert(doc) }

        let concurrency = 50
        var allResults = [[String]]()
        var errors = [Error]()

        await withTaskGroup(of: Result<[String], Error>.self) { group in
            for _ in 0..<concurrency {
                group.addTask { [self] in
                    do {
                        let result = try await self.searchAny("大学")
                        return .success(result.sorted())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let rows): allResults.append(rows)
                case .failure(let e): errors.append(e)
                }
            }
        }

        XCTAssertTrue(errors.isEmpty,
            "DatabaseQueue 并发读不应抛出错误：\(errors.map { $0.localizedDescription })")
        XCTAssertEqual(allResults.count, concurrency, "应收到 \(concurrency) 个读结果")

        // 所有并发读结果应与预期文档集完全一致
        let expected = documents.sorted()
        for (i, result) in allResults.enumerated() {
            XCTAssertEqual(result, expected,
                "并发读任务 \(i) 的结果与预期不一致")
        }
    }

    // MARK: 维度 C — DatabasePool 多连接真正并发读

    /// 验证 DatabasePool 多连接场景下，tokenizer 被不同连接并发调用时正确。
    ///
    /// DatabasePool 允许多个 reader 连接真正同时持有数据库，
    /// 这是最能暴露 tokenizer 并发问题的场景。
    /// 使用临时文件路径（DatabasePool 不支持纯内存模式）。
    func testDatabasePoolConcurrentReads() async throws {
        // DatabasePool 需要文件路径；使用系统临时目录下的唯一文件
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cjkfts5_concurrent_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // 建立 DatabasePool（多连接，允许真正并发读）
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(tokenizer: CJKTokenizer.self)
        }
        let pool = try DatabasePool(path: tmpURL.path, configuration: config)
        defer { try? pool.close() }

        try await pool.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                t.tokenizer = CJKTokenizer.tokenizerDescriptor()
                t.column("content")
            }
        }

        // 批量插入包含多种字符类型的文档
        let texts: [String] = [
            "清华大学计算机系",   // CJK
            "Apple iPhone Pro",  // ASCII
            "日本語テスト",        // 日文假名
            "한국어테스트",         // 韩文
            "北京大学工学院",      // CJK
        ]
        try await pool.write { db in
            for text in texts {
                try db.execute(sql: "INSERT INTO docs(content) VALUES (?)",
                               arguments: [text])
            }
        }

        // 30 个并发读任务，每个搜索「大学」
        let concurrency = 30
        var resultSets = [[String]]()
        var errors = [Error]()

        await withTaskGroup(of: Result<[String], Error>.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    do {
                        let result = try await pool.read { db in
                            let pattern = FTS5Pattern(matchingAnyTokenIn: "大学")
                            return try String.fetchAll(db,
                                sql: "SELECT content FROM docs WHERE docs MATCH ?",
                                arguments: [pattern]).sorted()
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let rows): resultSets.append(rows)
                case .failure(let e): errors.append(e)
                }
            }
        }

        XCTAssertTrue(errors.isEmpty,
            "DatabasePool 并发读不应抛出错误：\(errors.map { $0.localizedDescription })")
        XCTAssertEqual(resultSets.count, concurrency)

        // 所有并发读结果应与第一个结果完全一致
        let reference = resultSets[0]
        XCTAssertFalse(reference.isEmpty, "「大学」应至少命中一条文档")
        for (i, result) in resultSets.enumerated() {
            XCTAssertEqual(result, reference,
                "DatabasePool 并发读任务 \(i) 与任务 0 结果不一致")
        }
    }

    // MARK: 维度 D — 读写并发不干扰正确性

    /// 验证并发写入（触发 FTS5 索引/tokenizer）与并发读取不互相干扰。
    ///
    /// 写入时 FTS5 会调用 tokenizer 重建索引，同时读取操作排队等候；
    /// 验证所有操作完成后结果完整正确。
    func testConcurrentReadsDuringBatchWrite() async throws {
        // 预填充基础数据
        let baseTexts = ["清华大学", "北京大学", "复旦大学"]
        for text in baseTexts { try await insert(text) }

        let writeCount = 15
        let readCount = 20
        var writeErrors = [Error]()
        var readErrors = [Error]()

        await withTaskGroup(of: (type: String, error: Error?).self) { group in
            // 写入任务：批量插入新文档（每次写入触发 tokenizer）
            for i in 0..<writeCount {
                group.addTask { [self] in
                    do {
                        try await self.insert("并发写入文档\(i)内容")
                        return ("write", nil)
                    } catch {
                        return ("write", error)
                    }
                }
            }
            // 读取任务：与写入并发执行
            for _ in 0..<readCount {
                group.addTask { [self] in
                    do {
                        _ = try await self.searchAny("大学")
                        return ("read", nil)
                    } catch {
                        return ("read", error)
                    }
                }
            }

            for await result in group {
                if let e = result.error {
                    if result.type == "write" { writeErrors.append(e) }
                    else { readErrors.append(e) }
                }
            }
        }

        XCTAssertTrue(writeErrors.isEmpty,
            "并发写入不应报错：\(writeErrors.map { $0.localizedDescription })")
        XCTAssertTrue(readErrors.isEmpty,
            "读写并发期间读取不应报错：\(readErrors.map { $0.localizedDescription })")

        // 全部写入完成后，新文档应全部可搜
        let finalResults = try await searchAny("并发")
        XCTAssertEqual(finalResults.count, writeCount,
            "写入完成后应能搜到全部 \(writeCount) 条并发写入文档（实际 \(finalResults.count) 条）")
    }

    // MARK: 维度 E — 高压力分词结果确定性

    /// 验证 50 个并发任务，每个使用独立数据库实例进行分词 + 搜索，
    /// 结果与单线程基准完全一致。
    ///
    /// 此测试是 TSan 最容易捕获数据竞争的场景：
    /// 多个 CJKTokenizer 实例在不同连接/线程上同时工作。
    func testHighConcurrencyTokenizationDeterminism() async throws {
        // 测试向量：覆盖所有支持的字符类型
        let testCases: [(doc: String, query: String)] = [
            ("清华大学计算机系", "清华"),                      // 普通 CJK
            ("Apple iPhone 16 Pro Max", "iphone"),          // 纯 ASCII（含大写折叠）
            ("日本語テスト東京大学", "東京"),                   // 日文假名 + 汉字
            ("한국어서울대학교테스트", "서울"),                   // 韩文
            ("混合CJK文本ABC123测试", "测试"),                  // 中英混合
            ("CJK Ext-H \u{31350}\u{31351}字符", "\u{31350}"), // CJK 扩展 H
        ]

        // 步骤 1：建立单线程基准结果
        var baselines = [String: [String]]()
        for (doc, query) in testCases {
            let baseDB = try makeDB()
            try await insert(doc, into: baseDB)
            let result = try await searchAny(query, in: baseDB)
            baselines["\(doc):\(query)"] = result.sorted()
            XCTAssertFalse(result.isEmpty,
                "基准测试 [\(query)] 在文档 [\(doc)] 中应有结果")
        }

        // 步骤 2：50 个并发任务，每个使用独立 DB 实例验证分词结果
        let concurrency = 50
        var failures = [(task: Int, key: String, expected: [String], actual: [String])]()

        await withTaskGroup(of: (Int, String, [String], [String])?.self) { group in
            for i in 0..<concurrency {
                let (doc, query) = testCases[i % testCases.count]
                let key = "\(doc):\(query)"
                group.addTask { [self] in
                    do {
                        let db = try self.makeDB()
                        try await self.insert(doc, into: db)
                        let actual = try await self.searchAny(query, in: db)
                        let expected = baselines[key]!
                        if actual.sorted() != expected {
                            return (i, key, expected, actual.sorted())
                        }
                    } catch { }
                    return nil
                }
            }
            for await failure in group {
                if let f = failure { failures.append(f) }
            }
        }

        XCTAssertTrue(failures.isEmpty,
            "高并发分词结果应与基准完全一致，\(failures.count) 个任务失败：" +
            "\(failures.prefix(3).map { "任务\($0.task)[\($0.key)]" })")
    }
}

// MARK: - 并发测试辅助

/// 线程安全的计数器和结果收集器，仅供并发测试使用。
///
/// 使用 NSLock 实现轻量级互斥，避免引入 actor 或 DispatchQueue 的额外语义。
private final class LockProtected<T> {
    private var _value: T
    private let lock = NSLock()

    init(_ initial: T) { _value = initial }

    var value: T {
        lock.withLock { _value }
    }

    func mutate(_ transform: (inout T) -> Void) {
        lock.withLock { transform(&_value) }
    }
}

extension LockProtected where T == Int {
    func increment() { mutate { $0 += 1 } }
}
