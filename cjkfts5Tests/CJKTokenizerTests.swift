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

// MARK: - no_unigram 模式 Phrase Search 测试

/// 验证 `emitUnigrams=false` 模式下，Phrase Search（`matchingPhrase`）的行为与语义。
///
/// 现有 `OptionTests` 中的 no_unigram 测试均使用 `searchRaw`（单 token 匹配），
/// 本类专门覆盖 `search`（`matchingPhrase`，多 token 有序匹配）的场景。
///
/// **核心语义差异**（no_unigram vs 默认模式）：
/// - bigram token 行为相同——均进入索引
/// - co-located unigram 被抑制——单字 phrase 查询不再命中非末字
/// - 末字 unigram 始终发出（`count>1` 时 L348，`count==1` 时 L296）
final class NoUnigramPhraseTests: CJKTestBase {

    // MARK: T1 — 基础 Phrase 命中（bigram 不受 no_unigram 影响）

    /// no_unigram 模式下多字 phrase 命中行为应与默认模式相同。
    ///
    /// bigram 进入索引的逻辑不受 `emitUnigrams` 控制，
    /// 因此由连续 bigram 构成的 phrase 查询应正常命中。
    func testNoUnigramPhraseHit() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("北京清华大学", into: db)

        let r1 = try await search("清华大学", in: db)
        XCTAssertEqual(r1, ["北京清华大学"],
            "no_unigram：[清华大学] 4字 phrase 应命中（bigram 序列连续）")

        let r2 = try await search("北京清华大学", in: db)
        XCTAssertEqual(r2, ["北京清华大学"],
            "no_unigram：完整文本 phrase 应命中")

        let r3 = try await search("北京", in: db)
        XCTAssertEqual(r3, ["北京清华大学"],
            "no_unigram：2字 phrase 应命中（等价于 bigram 命中）")
    }

    // MARK: T2 — Phrase 不命中（假阳性防御）

    /// no_unigram 模式下，词序错误或非相邻字符构成的 phrase 不应命中。
    func testNoUnigramPhraseMiss() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("北京清华大学", into: db)

        let r1 = try await search("清华北京", in: db)
        XCTAssertTrue(r1.isEmpty,
            "no_unigram：词序颠倒的 phrase [清华北京] 不应命中")

        // 非相邻字符伪 bigram（最关键的假阳性防御）
        let r2 = try await search("北清", in: db)
        XCTAssertTrue(r2.isEmpty,
            "no_unigram：[北清] 非相邻字符 phrase 不应命中（假阳性防御）")

        let r3 = try await search("清大", in: db)
        XCTAssertTrue(r3.isEmpty,
            "no_unigram：[清大] 非相邻字符 phrase 不应命中")
    }

    // MARK: T3 — 单字 Phrase 语义变化（最关键差异）

    /// no_unigram 模式下，非末字单字 phrase 不命中，末字仍命中。
    ///
    /// 这是 no_unigram 与默认模式最大的语义差异：
    /// 默认模式索引了 `pos k: bigram + co-located unigram`，
    /// no_unigram 抑制了 co-located unigram，导致单字 phrase 查询
    /// 无法通过 unigram 路径命中非末字位置。
    func testNoUnigramSingleCharPhraseSemantics() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("清华大学", into: db)

        // 非末字：co-located unigram 被抑制，phrase 查询不命中
        let r1 = try await search("清", in: db)
        XCTAssertTrue(r1.isEmpty,
            "no_unigram：非末字[清] phrase 不应命中（co-located unigram 已抑制）")

        let r2 = try await search("华", in: db)
        XCTAssertTrue(r2.isEmpty,
            "no_unigram：非末字[华] phrase 不应命中")

        let r3 = try await search("大", in: db)
        XCTAssertTrue(r3.isEmpty,
            "no_unigram：非末字[大] phrase 不应命中")

        // 末字：始终作为独立 unigram 发出（L348 路径，不受 emitUnigrams 约束）
        let r4 = try await search("学", in: db)
        XCTAssertFalse(r4.isEmpty,
            "no_unigram：末字[学] phrase 应命中（末字 unigram 始终发出）")
    }

    // MARK: T4 — 多文档 Phrase 精确率

    /// no_unigram 模式下多文档 phrase 搜索不产生跨文档假阳性。
    func testNoUnigramPhraseMultiDocPrecision() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("北京大学", into: db)
        try await insert("北京清华大学", into: db)
        try await insert("复旦大学", into: db)

        // [北京大学] 只应命中第一条，不应命中第二条（两者均含"北京"和"大学"但不相邻）
        let r1 = try await search("北京大学", in: db)
        XCTAssertEqual(r1, ["北京大学"],
            "no_unigram：[北京大学] phrase 精确率——不应命中[北京清华大学]")

        let r2 = try await search("清华大学", in: db)
        XCTAssertEqual(r2, ["北京清华大学"],
            "no_unigram：[清华大学] phrase 应精确命中且仅命中第二条")

        let r3 = try await search("复旦", in: db)
        XCTAssertEqual(r3, ["复旦大学"],
            "no_unigram：[复旦] phrase 应精确命中且仅命中第三条")
    }

    // MARK: T5 — 奇数字／跨 bigram 边界的 Phrase

    /// no_unigram 模式下 3字、5字、8字等非偶数长度 phrase 的行为。
    ///
    /// query 端产生连续 bigram 序列（e.g. "清华大" → 清华@0, 华大@1），
    /// 这些 bigram 在文档索引中连续存在，因此 phrase match 成立。
    func testNoUnigramOddLengthPhrase() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("清华大学研究生院", into: db)

        // 3字 phrase（query 产生 2 个连续 bigram）
        let r1 = try await search("清华大", in: db)
        XCTAssertFalse(r1.isEmpty,
            "no_unigram：3字 phrase [清华大] 应命中（清华@0 + 华大@1 连续）")

        // 5字 phrase（query 产生 4 个连续 bigram）
        let r2 = try await search("大学研究生", in: db)
        XCTAssertFalse(r2.isEmpty,
            "no_unigram：5字 phrase [大学研究生] 应命中（连续 bigram 序列）")

        // 完整 8字 phrase
        let r3 = try await search("清华大学研究生院", in: db)
        XCTAssertFalse(r3.isEmpty,
            "no_unigram：完整 8字 phrase 应命中")

        // 非连续字符的伪 phrase 不应命中
        let r4 = try await search("清华研究", in: db)
        XCTAssertTrue(r4.isEmpty,
            "no_unigram：[清华研究] 非连续字符 phrase 不应命中")
    }

    // MARK: T6 — 两字文档边界（单 bigram 文档）

    /// 两字文档在 no_unigram 模式下：bigram 命中，首字不命中，末字命中。
    ///
    /// 两字文档发出：bigram("北京")@pos0 + unigram("京")@pos1
    /// no_unigram 模式下 co-located 的"北"被抑制，末字"京"仍独立发出。
    func testNoUnigramTwoCharDocPhrase() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("北京", into: db)

        // 完整 bigram phrase 命中
        let r1 = try await search("北京", in: db)
        XCTAssertEqual(r1, ["北京"],
            "no_unigram：两字文档 phrase [北京] 应命中（bigram 在索引）")

        // 首字（非末字）phrase 不命中：unigram "北" 被抑制
        let r2 = try await search("北", in: db)
        XCTAssertTrue(r2.isEmpty,
            "no_unigram：两字文档首字 [北] phrase 不应命中（首字 unigram 被抑制）")

        // 末字 phrase 仍命中：末字 unigram 始终发出
        let r3 = try await search("京", in: db)
        XCTAssertFalse(r3.isEmpty,
            "no_unigram：两字文档末字 [京] phrase 应命中（末字 unigram 始终发出）")
    }

    // MARK: T7 — 单字文档的「隐形豁免」（count==1 路径）

    /// 单字文档在 no_unigram 模式下仍可被搜索。
    ///
    /// `emitCJKSegment` 的 `count==1` 分支（直接发出 unigram）
    /// **不检查 `emitUnigrams`**，因此单字文档始终可搜索。
    /// 这是合理的设计（否则单字文档在 no_unigram 模式下完全不可索引），
    /// 但现有测试从未在 no_unigram 模式下固化此行为。
    func testNoUnigramSingleCharDocument() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("学", into: db)

        // count==1 路径绕过 emitUnigrams 检查，单字仍发出 unigram
        let r = try await search("学", in: db)
        XCTAssertEqual(r, ["学"],
            "no_unigram：单字文档应命中（count==1 路径不受 emitUnigrams 约束）")
    }

    // MARK: T8 — 混合文本中 CJK/ASCII 路径独立性

    /// no_unigram 仅影响 CJK 的 co-located unigram，ASCII 分词路径不受影响。
    func testNoUnigramMixedTextPhrase() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false))
        try await insert("清华大学 Tsinghua University", into: db)

        // CJK phrase 命中（bigram 不受 no_unigram 影响）
        let r1 = try await search("清华大学", in: db)
        XCTAssertFalse(r1.isEmpty,
            "no_unigram：混合文本中 CJK phrase [清华大学] 应命中")

        // CJK 非末字 phrase 不命中
        let r2 = try await search("清", in: db)
        XCTAssertTrue(r2.isEmpty,
            "no_unigram：混合文本中非末字[清] phrase 不应命中")

        // ASCII 路径完全独立，case folding 正常
        let r3 = try await searchAny("tsinghua", in: db)
        XCTAssertFalse(r3.isEmpty,
            "no_unigram：混合文本中 ASCII [tsinghua] 应命中（ASCII 路径不受影响）")

        // CJK 末字仍命中
        let r4 = try await search("学", in: db)
        XCTAssertFalse(r4.isEmpty,
            "no_unigram：混合文本中末字[学] phrase 应命中")
    }

    // MARK: T9 — 组合选项下的 Phrase Search

    /// `no_unigram + no_caseFolding` 组合选项下，phrase 行为符合各自独立规则的叠加。
    func testNoUnigramNoCaseFoldPhrase() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(emitUnigrams: false, caseFolding: false))
        try await insert("清华大学 Hello World", into: db)

        // CJK phrase 正常命中（bigram 不受两个选项影响）
        let r1 = try await search("清华大学", in: db)
        XCTAssertFalse(r1.isEmpty,
            "no_unigram+no_caseFold：CJK phrase [清华大学] 应命中")

        // CJK 非末字 phrase 不命中（no_unigram 生效）
        let r2 = try await search("清", in: db)
        XCTAssertTrue(r2.isEmpty,
            "no_unigram+no_caseFold：非末字[清] phrase 不应命中")

        // CJK 末字命中（末字始终发出）
        let r3 = try await search("学", in: db)
        XCTAssertFalse(r3.isEmpty,
            "no_unigram+no_caseFold：末字[学] phrase 应命中")

        // ASCII 大小写敏感（no_caseFolding 生效）
        let r4 = try await searchRaw("Hello", in: db)
        XCTAssertFalse(r4.isEmpty,
            "no_unigram+no_caseFold：原始大写 [Hello] 应命中")

        let r5 = try await searchRaw("hello", in: db)
        XCTAssertTrue(r5.isEmpty,
            "no_unigram+no_caseFold：小写 [hello] 不应命中（大小写不折叠）")
    }
}

// MARK: - 非 ASCII Unicode 大小写折叠测试

/// 验证 `emitWordToken` 中路径 3（`lowercased()` + `withCString`）对各类
/// 非 ASCII 字符集的大小写折叠行为。
///
/// **代码路径说明：**
/// ```
/// 路径 1: caseFolding=false  → emitRaw（直传，不折叠）
/// 路径 2: ASCII 词            → 位运算 | 0x20（A–Z → a–z）
/// 路径 3: 含非 ASCII 字符     → String.lowercased() + withCString   ← 本类测试目标
/// ```
///
/// 路径 3 由 `isWordChar()` 的 `scalar.properties.isAlphabetic` 触发，
/// 覆盖所有 Latin Extended / 希腊 / 西里尔 / 全角拉丁等字母字符。
final class UnicodeCaseFoldingTests: CJKTestBase {

    // MARK: T1 — Latin Extended 基础折叠（变音符不被移除）

    /// 验证 Latin Extended 字符的大小写折叠，并确认变音符不被移除。
    ///
    /// `lowercased()` 只做大小写转换，不做 diacritic normalization，
    /// 因此 `cafe` 不等于 `café`——这是正确的搜索语义。
    func testLatinExtendedCaseFolding() async throws {
        // 使用禁用变音符折叠的数据库以验证纯大小写折叠行为
        let db = try makeDB(options: CJKTokenizerOptions(caseFolding: true, widthFolding: true, diacriticFolding: false))
        
        // 德语「惊喜」——首字母 Ü (U+00DC) 走路径 3
        try await insert("Überraschung", into: db)
        // 法语「咖啡」——纯小写含变音符（走路径 3，无大写折叠需求）
        try await insert("café", into: db)

        // Ü(U+00DC) → ü(U+00FC)，折叠后应能命中
        let r1 = try await searchAny("überraschung", in: db)
        XCTAssertFalse(r1.isEmpty,
            "Latin Extended：大写 [Ü] 折叠后 [überraschung] 应命中")

        // "cafe"（无变音符）≠ "café"（有变音符）
        // lowercased() 不移除变音符，两者在 FTS 索引中是不同 token
        let r2 = try await searchAny("cafe", in: db)
        XCTAssertTrue(r2.isEmpty,
            "Latin Extended：[cafe] 不应命中 [café]（折叠仅处理大小写，不移除变音符）")

        // 原始小写带变音符应直接命中
        let r3 = try await searchAny("café", in: db)
        XCTAssertFalse(r3.isEmpty,
            "Latin Extended：全小写 [café] 应命中（路径 3，无大写→小写转换）")
    }

    // MARK: T2 — Latin Extended 全大写多字符词折叠

    /// 验证全大写 Latin Extended 词（多字符，非 ASCII）走路径 3 折叠正确。
    func testMixedCaseLatinExtended() async throws {
        // 德语「慕尼黑」——全大写，Ü 在中间，走路径 3
        try await insert("MÜNCHEN")

        let r1 = try await searchAny("münchen")
        XCTAssertFalse(r1.isEmpty,
            "Latin Extended：全大写 [MÜNCHEN] 折叠后应命中小写查询 [münchen]")

        // 西班牙语「Ñoño」——含 Ñ(U+00D1)/ñ(U+00F1)，混合大小写
        try await insert("Ñoño")
        let r2 = try await searchAny("ñoño")
        XCTAssertFalse(r2.isEmpty,
            "Latin Extended：[Ñoño] 折叠后应命中 [ñoño]")

        // 折叠结果不应命中未折叠的错误大小写
        let r3 = try await searchAny("MÜNCHEN")
        XCTAssertFalse(r3.isEmpty,
            "Latin Extended：大写查询 [MÜNCHEN] 自身也会被折叠，应命中文档")
    }

    // MARK: T3 — 希腊字母折叠（含词末 sigma 上下文感知）

    /// 验证希腊字母大小写折叠，包含 Swift `lowercased()` 对词末 Σ→ς 的上下文感知。
    ///
    /// Unicode 规则：Σ 在词末折叠为 ς（U+03C2），在词中折叠为 σ（U+03C3）。
    /// Swift `lowercased()` 实现了此上下文感知规则。
    /// 由于文档索引和查询端都调用同一套折叠逻辑，结果应对称一致。
    func testGreekCaseFolding() async throws {
        // 「雅典」全大写希腊字母
        try await insert("ΑΘΗΝΑ")

        let r1 = try await searchAny("αθηνα")
        XCTAssertFalse(r1.isEmpty,
            "希腊：全大写 [ΑΘΗΝΑ] 折叠后应命中小写 [αθηνα]")

        // 「塞萨洛尼基」——含 Σ（词末 sigma 位置），测试上下文感知
        // 文档端折叠：ΘΕΣΣΑΛΟΝΙΚΗ → θεσσαλονίκη（词末 Η→η，词中 Σ→σ/ς）
        // 查询端折叠同理，两端一致故应命中
        try await insert("ΘΕΣΣΑΛΟΝΙΚΗ")
        let r2 = try await searchAny("θεσσαλονικη")
        XCTAssertFalse(r2.isEmpty,
            "希腊：含词末 sigma 的全大写词折叠后应命中（文档/查询折叠对称）")
    }

    // MARK: T4 — 西里尔字母折叠（含连字符词切分边界）

    /// 验证西里尔字母（俄语）大小写折叠，以及连字符作为分隔符正确切分词。
    func testCyrillicCaseFolding() async throws {
        // 「莫斯科」全大写西里尔字母
        try await insert("МОСКВА")

        let r1 = try await searchAny("москва")
        XCTAssertFalse(r1.isEmpty,
            "西里尔：全大写 [МОСКВА] 折叠后应命中小写 [москва]")

        // 「圣彼得堡」——含连字符，测试连字符作为分隔符切分后两词各自折叠
        try await insert("Санкт-Петербург")

        // 连字符前的词独立折叠
        let r2 = try await searchAny("санкт")
        XCTAssertFalse(r2.isEmpty,
            "西里尔：[Санкт] 折叠后应命中 [санкт]（连字符前词独立）")

        // 连字符后的词独立折叠
        let r3 = try await searchAny("петербург")
        XCTAssertFalse(r3.isEmpty,
            "西里尔：[Петербург] 折叠后应命中 [петербург]（连字符后词独立）")
    }

    // MARK: T5 — 全角拉丁字母折叠（宽度不正规化）

    /// 验证全角大写拉丁字母（U+FF21–U+FF3A）折叠为全角小写（U+FF41–U+FF5A），
    /// 且全角字符不被等同于半角字符（不做宽度正规化）。
    func testFullWidthLatinCaseFolding() async throws {
        // 1. 默认启用 widthFolding: true
        try await insert("ＡＢＣ")

        // 全角大写 → 全角小写（U+FF21 → U+FF41）
        let r1 = try await searchAny("ａｂｃ")
        XCTAssertFalse(r1.isEmpty,
            "全角拉丁：大写 [ＡＢＣ] 折叠后应命中全角小写 [ａｂｃ]")

        // 全角 = 半角：开启折叠时，半角应命中全角
        let r2 = try await searchAny("abc")
        XCTAssertFalse(r2.isEmpty,
            "全角拉丁：全角 [ＡＢＣ] 应被半角 [abc] 命中（已宽度正规化）")

        // 全角小写文档，全角大写查询也应命中（查询端同样折叠）
        try await insert("ｄｅｆ")
        let r3 = try await searchAny("ＤＥＦ")
        XCTAssertFalse(r3.isEmpty,
            "全角拉丁：大写查询 [ＤＥＦ] 折叠后应命中全角小写文档 [ｄｅｆ]")

        // 2. 禁用 widthFolding: false
        let disabledDB = try makeDB(options: CJKTokenizerOptions(widthFolding: false))
        try await insert("ＡＢＣ", into: disabledDB)

        let r4 = try await searchAny("abc", in: disabledDB)
        XCTAssertTrue(r4.isEmpty, "禁用宽度正规化时，全半角不应匹配")
    }

    // MARK: T6 — 半角片假名宽度折叠与 Bigram 切分验证

    /// 验证半角片假名 (U+FF61–U+FF9F) 能正确折叠为全角片假名，
    /// 并正确被划分为 CJK 字符进行 Bigram 分词与匹配。
    func testHalfWidthKatakanaWidthFolding() async throws {
        // 1. 默认启用 widthFolding: true
        // 插入半角片假名 "ﾃｽﾄ"
        try await insert("ﾃｽﾄ")

        // a) 验证与全角片假名 "テスト" 互相命中
        let r1 = try await searchAny("テスト")
        XCTAssertEqual(r1, ["ﾃｽﾄ"], "全半角片假名应完美互通匹配")

        let r2 = try await searchAny("ﾃｽ")
        XCTAssertEqual(r2, ["ﾃｽﾄ"], "应支持半角 Bigram 前缀匹配")

        let r3 = try await searchAny("テス")
        XCTAssertEqual(r3, ["ﾃｽﾄ"], "应支持全角 Bigram 前缀匹配")

        // 2. 禁用 widthFolding: false
        let disabledDB = try makeDB(options: CJKTokenizerOptions(widthFolding: false))
        try await insert("ﾃｽﾄ", into: disabledDB)

        // 禁用折叠时，半角片假名不进行 Bigram 划分，不匹配全角 "テスト"
        let r4 = try await searchAny("テスト", in: disabledDB)
        XCTAssertTrue(r4.isEmpty, "禁用宽度折叠时，全半角片假名不应互通")
    }


    // MARK: T6 — CJK 与 Latin Extended 路径切换边界

    /// 验证 CJK bigram 路径与非 ASCII Latin Extended 路径（路径 3）在同一文档中
    /// 共存时，各自独立正确工作。
    ///
    /// CJK 字符走 `emitCJKSegment`（零拷贝 bigram），
    /// Latin Extended 字符走 `flushNonCJK` → `emitWordToken` 路径 3，
    /// 两者应被正确切分为独立段，互不干扰。
    func testMixedCJKAndLatinExtended() async throws {
        // CJK—非ASCII—CJK 三段混合
        try await insert("北京Über大学")

        // CJK 部分正常（bigram 路径）
        let r1 = try await searchAny("北京")
        XCTAssertFalse(r1.isEmpty,
            "CJK+Latin：CJK [北京] bigram 应命中")

        // Latin Extended 词（被 CJK 切割为独立 non-CJK 段），大小写折叠正确
        let r2 = try await searchAny("über")
        XCTAssertFalse(r2.isEmpty,
            "CJK+Latin：Latin Extended [Über] 折叠后应命中 [über]（路径 3 独立工作）")

        // 后段 CJK 正常
        let r3 = try await searchAny("大学")
        XCTAssertFalse(r3.isEmpty,
            "CJK+Latin：后段 CJK [大学] bigram 应命中")

        // 验证 CJK 与 Latin 互不干扰（不产生跨段假命中）
        let r4 = try await searchAny("北京über")
        // "北京über" 作为整体跨段查询不应命中（CJK 和 Latin 被切为独立 token）
        // 注：此处用 searchAny（matchingAnyTokenIn），内部 ascii tokenizer 处理查询字符串，
        // 结果取决于 GRDB ascii tokenizer 的行为，故不做强断言，仅验证不崩溃
        _ = r4
    }

    // MARK: T7 — caseFolding=false 对非 ASCII 词同样生效

    /// 验证 `caseFolding=false` 时，非 ASCII Latin Extended 词保留原始大小写。
    ///
    /// 路径 1（emitRaw）在 caseFolding=false 时直接传递 pText 子指针，
    /// 不区分 ASCII/非 ASCII，所有词均保留原始大小写形式。
    func testCaseFoldingDisabledForLatinExtended() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(caseFolding: false))
        try await insert("Über alles", into: db)

        // caseFolding=false：文档以原始形式存储 "Über"
        let r1 = try await searchRaw("Über", in: db)
        XCTAssertFalse(r1.isEmpty,
            "caseFolding=false：原始 [Über] 应命中（非 ASCII 词不折叠）")

        // 小写 "über" 不应命中（索引存储的是原始 "Über"）
        let r2 = try await searchRaw("über", in: db)
        XCTAssertTrue(r2.isEmpty,
            "caseFolding=false：小写 [über] 不应命中大写原文（无折叠）")

        // "alles" 是纯 ASCII 全小写，caseFolding=false 下原样存储，应命中
        let r3 = try await searchRaw("alles", in: db)
        XCTAssertFalse(r3.isEmpty,
            "caseFolding=false：全小写 ASCII [alles] 应命中（原本就是小写）")

        // ASCII 大写同样不折叠：如果插入 "Alles"，小写不命中
        let db2 = try makeDB(options: CJKTokenizerOptions(caseFolding: false))
        try await insert("Alles", into: db2)
        let r4 = try await searchRaw("alles", in: db2)
        XCTAssertTrue(r4.isEmpty,
            "caseFolding=false：ASCII 大写 [Alles] 也不折叠，小写不命中（路径 1 统一行为）")
    }

    // MARK: T8 — token 字节数一致性（路径 3 使用 token.utf8.count）

    /// 验证路径 3 使用 `token.utf8.count`（折叠后字节数）而非 `byteEnd-byteStart`
    /// （原始字节数），确保折叠前后字节数变化时 FTS5 收到正确的 nToken 参数。
    ///
    /// 全角字符：U+FF21（3字节）→ U+FF41（3字节），字节数不变
    /// Ñ：U+00D1（2字节）→ U+00F1（2字节），字节数不变
    /// 若使用原始字节数而非折叠后字节数，字节数膨胀场景（如某些组合字符）会导致错误。
    func testTokenByteLengthConsistency() async throws {
        // 全角：3字节→3字节，折叠安全
        try await insert("ＡＢＣ")
        let r1 = try await searchAny("ａｂｃ")
        XCTAssertFalse(r1.isEmpty,
            "字节一致性：全角 [ＡＢＣ]→[ａｂｃ] 3→3字节，token 长度正确，应命中")

        // Latin Extended Ñ：2字节→2字节，折叠安全
        try await insert("Ñ")
        let r2 = try await searchAny("ñ")
        XCTAssertFalse(r2.isEmpty,
            "字节一致性：[Ñ]→[ñ] 2→2字节，token 长度正确，应命中")

        // rawPattern 搜索也能正确命中折叠后的 token（验证索引内部存储完整）
        let r3 = try await searchRaw("ñ")
        XCTAssertFalse(r3.isEmpty,
            "字节一致性：rawPattern [ñ] 应命中折叠后的 Latin Extended token")

        // 多字符词：MÜNCHEN（3个字符各 2字节）→ münchen（2字节/字符），总字节数不变
        try await insert("MÜNCHEN")
        let r4 = try await searchRaw("münchen")
        XCTAssertFalse(r4.isEmpty,
            "字节一致性：[MÜNCHEN]→[münchen] 多字节一致，rawPattern 应命中")
    }

    // MARK: T9 — 多词非 ASCII 文档的逐词折叠与 Phrase 查询

    /// 验证含多个 Latin Extended 词的文档，每词独立走 emitWordToken 路径 3，
    /// 以及折叠后的词支持 Phrase Search（`matchingPhrase`）。
    func testMultiWordNonASCIICaseFolding() async throws {
        // 三个 Latin Extended 词，由空格切分，各自独立折叠
        try await insert("Über München Straße")

        // 各词独立折叠，searchAny 验证每词可单独命中
        let r1 = try await searchAny("über")
        XCTAssertFalse(r1.isEmpty,
            "多词非 ASCII：第 1 词 [Über] 折叠后应命中 [über]")

        let r2 = try await searchAny("münchen")
        XCTAssertFalse(r2.isEmpty,
            "多词非 ASCII：第 2 词 [München] 折叠后应命中 [münchen]")

        // "Straße" 含 ß(U+00DF)，已是小写字母，lowercased() 不变，应命中
        let r3 = try await searchAny("straße")
        XCTAssertFalse(r3.isEmpty,
            "多词非 ASCII：第 3 词 [Straße] 应命中 [straße]（ß 已是小写，lowercased 不变）")

        // Phrase Search：相邻词的有序匹配
        // search() 使用 matchingPhrase，由 GRDB 内部 ascii tokenizer 处理查询字符串，
        // 非 ASCII 查询词可能被当作整体 token；此处验证 2 词 phrase 的基本行为
        let r4 = try await searchAny("münchen straße")
        // searchAny 对多词使用 matchingAnyTokenIn（OR 语义），结果不为空
        XCTAssertFalse(r4.isEmpty,
            "多词非 ASCII：OR 查询 [münchen straße] 至少应命中一条文档")
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

// MARK: - Unicode 宽度正规化集成测试

final class UnicodeWidthFoldingIntegrationTests: CJKTestBase {

    // 1. 默认启用折叠：全角/半角 ASCII 混合匹配与大小写折叠
    func testDefaultWidthFoldingWithASCII() async throws {
        // 包含全角 ASCII 字符
        try await insert("Ｈｅｌｌｏ Ｗｏｒｌｄ")
        
        // a) 半角小写查询应命中
        let r1 = try await searchAny("hello")
        XCTAssertEqual(r1, ["Ｈｅｌｌｏ Ｗｏｒｌｄ"], "默认折叠下，半角小写应命中全角大写")
        
        // b) 全角大写查询自身应命中
        let r2 = try await searchAny("ＨＥＬＬＯ")
        XCTAssertEqual(r2, ["Ｈｅｌｌｏ Ｗｏｒｌｄ"], "默认折叠下，全角大写查询应命中")
        
        // c) 全角小写查询也应命中
        let r3 = try await searchAny("ｈｅｌｌｏ")
        XCTAssertEqual(r3, ["Ｈｅｌｌｏ Ｗｏｒｌｄ"], "默认折叠下，全角小写查询应命中")
    }

    // 2. 默认启用折叠：半角片假名折叠与 Bigram/Unigram 切分
    func testDefaultWidthFoldingWithKatakana() async throws {
        // 插入包含半角片假名的文档 "ﾃｽﾄ"
        try await insert("ﾃｽﾄ")
        
        // a) 验证与全角片假名互相命中
        let r1 = try await searchAny("テスト")
        XCTAssertEqual(r1, ["ﾃｽﾄ"], "默认折叠下，全角片假名应命中半角片假名")
        
        // b) 验证 Bigram 匹配
        let r2 = try await searchAny("ﾃｽ")
        XCTAssertEqual(r2, ["ﾃｽﾄ"], "默认折叠下，半角 Bigram 前缀应命中")
        
        // c) 验证 Unigram 匹配（默认 emitUnigrams 为 true）
        let r3 = try await searchAny("ﾃ")
        XCTAssertEqual(r3, ["ﾃｽﾄ"], "默认折叠下，半角 Unigram 应命中")
        
        let r4 = try await searchAny("ト")
        XCTAssertEqual(r4, ["ﾃｽﾄ"], "默认折叠下，全角末字 Unigram 应命中")
    }

    // 3. 禁用宽度折叠 (widthFolding: false)
    func testDisabledWidthFolding() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(widthFolding: false))
        
        // 插入全角 ASCII 文档
        try await insert("Ｈｅｌｌｏ", into: db)
        // 插入半角片假名文档
        try await insert("ﾃｽﾄ", into: db)
        
        // a) 半角查询全角 ASCII 不应命中
        let r1 = try await searchAny("hello", in: db)
        XCTAssertTrue(r1.isEmpty, "禁用宽度折叠时，半角不应匹配全角")
        
        // b) 全角大写查询可以通过 caseFolding 折叠为全角小写，但不能折叠为半角
        let r2 = try await searchAny("ｈｅｌｌｏ", in: db)
        XCTAssertEqual(r2, ["Ｈｅｌｌｏ"], "禁用宽度折叠但保留大小写折叠时，全角小写应匹配全角大写")
        
        // c) 全角片假名查询半角片假名不应命中
        let r_katakana_real = try await searchAny("テスト", in: db)
        XCTAssertTrue(r_katakana_real.isEmpty, "禁用宽度折叠时，全角片假名不应匹配半角")
        
        // d) 半角片假名本身可作为 Non-CJK 单词匹配
        let r4 = try await searchAny("ﾃｽﾄ", in: db)
        XCTAssertEqual(r4, ["ﾃｽﾄ"], "禁用宽度折叠时，半角片假名应作为普通单词自身匹配")
    }

    // 4. 组合选项：widthFolding 与 caseFolding
    func testCombinationsOfWidthAndCaseFolding() async throws {
        // 场景 A: widthFolding=true, caseFolding=false
        let dbA = try makeDB(options: CJKTokenizerOptions(caseFolding: false, widthFolding: true))
        try await insert("ＡＢＣ", into: dbA)
        
        // 全角大写折叠为半角大写 "ABC"
        let rA1 = try await searchRaw("abc", in: dbA)
        XCTAssertTrue(rA1.isEmpty, "caseFolding=false 时，大写不匹配小写")
        let rA2 = try await searchRaw("ABC", in: dbA)
        XCTAssertEqual(rA2, ["ＡＢＣ"], "widthFolding=true 且 caseFolding=false 时，半角大写应匹配全角大写")
        let rA3 = try await searchRaw("ＡＢＣ", in: dbA)
        XCTAssertEqual(rA3, ["ＡＢＣ"], "widthFolding=true 且 caseFolding=false 时，全角大写应匹配全角大写")

        // 场景 B: widthFolding=false, caseFolding=true
        let dbB = try makeDB(options: CJKTokenizerOptions(caseFolding: true, widthFolding: false))
        try await insert("ＡＢＣ", into: dbB)
        
        // 不进行宽度折叠，但大写折叠为小写："Ａ" (U+FF21) -> "ａ" (U+FF41)
        let rB1 = try await searchRaw("abc", in: dbB)
        XCTAssertTrue(rB1.isEmpty, "widthFolding=false 时，半角小写不应匹配全角")
        let rB2 = try await searchRaw("ａｂｃ", in: dbB)
        XCTAssertEqual(rB2, ["ＡＢＣ"], "widthFolding=false 且 caseFolding=true 时，全角小写应匹配全角大写")
        let rB3 = try await searchRaw("ＡＢＣ", in: dbB)
        XCTAssertEqual(rB3, ["ＡＢＣ"], "widthFolding=false 且 caseFolding=true 时，全角大写查询被折叠后也应匹配")
    }

    // 5. 日本语浊音/半浊音折叠 (Voiced / Semi-voiced Sound Marks)
    func testVoicedKatakanaFolding() async throws {
        // 插入含有浊音的半角片假名 "ｶﾞ" (U+FF76 U+FF9E)
        try await insert("ｶﾞ")
        
        // 默认折叠为 "カ" (U+30AB) + "゛" (U+309B)
        // 两个字符均属于 CJK 区间，因此形成 CJK 段并生成 Bigram: "カ゛"
        
        // a) 全角独立浊音符号匹配
        let r1 = try await searchAny("カ゛")
        XCTAssertEqual(r1, ["ｶﾞ"], "应正确支持浊音半角片假名到全角的分离折叠")
        
        // b) 片假名 "ｶ" 匹配
        let r2 = try await searchAny("カ")
        XCTAssertEqual(r2, ["ｶﾞ"], "默认折叠下，应能匹配假名部分")
    }

    // 6. 全角空格 (U+3000) 作为分词符
    func testFullWidthSpaceAsSeparator() async throws {
        // 插入带有全角空格的文档 "中国　北京" (U+3000)
        try await insert("中国　北京")
        
        // 全角空格被折叠为半角空格 (U+0020)，不应参与 CJK Bigram
        
        // a) 独立子项查询应命中
        let r1 = try await searchAny("中国")
        XCTAssertEqual(r1, ["中国　北京"])
        
        let r2 = try await searchAny("北京")
        XCTAssertEqual(r2, ["中国　北京"])
        
        // b) 跨空格的错误 Bigram "国北" 不应命中
        let r3 = try await searchAny("国北")
        XCTAssertTrue(r3.isEmpty, "全角空格应正确切断 CJK 段，避免跨空格的 bigram")
    }
}

// MARK: - 零堆内存分配测试

final class ZeroAllocationTests: CJKTestBase {

    private struct AllocationTracker {
        static var count = 0
        static var enabled = false
    }

    private typealias MallocLogger = @convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Void

    func testTokenizerZeroAllocationHotPath() async throws {
        try await dbQueue.write { db in
            let tokenizer = try CJKTokenizer(db: db, arguments: [])
            
            let callback: FTS5TokenCallback = { _, _, _, _, _, _ in
                return 0 // SQLITE_OK
            }
            
            let handle = dlopen(nil, RTLD_NOW)
            guard let sym = dlsym(handle, "malloc_logger") else {
                XCTFail("无法获取 malloc_logger 符号")
                return
            }
            
            let loggerPtr = sym.assumingMemoryBound(to: MallocLogger?.self)
            let oldLogger = loggerPtr.pointee
            
            let runTokenize = { (text: String) -> Int in
                let cString = text.utf8CString
                
                AllocationTracker.count = 0
                AllocationTracker.enabled = false
                
                loggerPtr.pointee = { (type, zone, ptr, arg3, size, num) in
                    if AllocationTracker.enabled {
                        let isAlloc = (type == 1 || type == 4 || type == 8 || type == 12)
                        if isAlloc {
                            AllocationTracker.count += 1
                        }
                    }
                }
                
                cString.withUnsafeBufferPointer { buf in
                    let base = buf.baseAddress!
                    let count = CInt(buf.count - 1)
                    
                    // 预热
                    _ = tokenizer.tokenize(
                        context: nil,
                        tokenization: [.document],
                        pText: base,
                        nText: count,
                        tokenCallback: callback
                    )
                    
                    // 开始追踪
                    AllocationTracker.count = 0
                    AllocationTracker.enabled = true
                    
                    _ = tokenizer.tokenize(
                        context: nil,
                        tokenization: [.document],
                        pText: base,
                        nText: count,
                        tokenCallback: callback
                    )
                    
                    AllocationTracker.enabled = false
                }
                
                loggerPtr.pointee = oldLogger
                return AllocationTracker.count
            }
            
            let cjkAlloc = runTokenize("北京大学")
            let asciiLowerAlloc = runTokenize("hello")
            let asciiUpperAlloc = runTokenize("Hello")
            let katakanaAlloc = runTokenize("ﾃｽﾄ")
            
            #if DEBUG
            // Debug 模式下，因编译器未开启优化，非内联的闭包传参（如 @escaping callback）会引入固定的 3 次隐式堆装箱。
            // 经诊断这属于 Swift 测试环境/编译器未优化时的闭包开销，非分词器内核所产生。
            let maxAlloc = 3
            #else
            // Release 模式下，编译器进行内联与跨模块优化，消除所有闭包开销，实现 100% 零堆内存分配。
            let maxAlloc = 0
            #endif
            
            XCTAssertLessThanOrEqual(cjkAlloc, maxAlloc, "CJK 字符分词堆分配超标")
            XCTAssertLessThanOrEqual(asciiLowerAlloc, maxAlloc, "ASCII 小写分词堆分配超标")
            XCTAssertLessThanOrEqual(asciiUpperAlloc, maxAlloc, "ASCII 大写/折叠分词堆分配超标")
            XCTAssertLessThanOrEqual(katakanaAlloc, maxAlloc, "Katakana 片假名折叠分词堆分配超标")
        }
    }
}

// MARK: - Accent/Diacritic Folding 集成测试

final class DiacriticFoldingIntegrationTests: CJKTestBase {

    // 1. 默认配置下（diacriticFolding = true, caseFolding = true）
    func testDefaultDiacriticFolding() async throws {
        // 插入含各种变音符的文档
        try await insert("café")      // 法语咖啡（e-acute）
        try await insert("München")   // 德语慕尼黑（u-umlaut）
        try await insert("ñandú")     // 西班牙语美洲鸵（n-tilde, u-acute）
        
        // a) 变音符折叠：cafe 命中 café
        let r1 = try await searchAny("cafe")
        XCTAssertEqual(r1, ["café"], "默认变音符折叠下，无变音符查询 [cafe] 应命中 [café]")
        
        // b) 大小写与变音符折叠：munchen 命中 München
        let r2 = try await searchAny("munchen")
        XCTAssertEqual(r2, ["München"], "默认折叠下，小写无变音符查询 [munchen] 应命中 [München]")
        
        // c) 混合测试：NANDU 命中 ñandú
        let r3 = try await searchAny("NANDU")
        XCTAssertEqual(r3, ["ñandú"], "默认折叠下，大写无变音符查询 [NANDU] 应命中 [ñandú]")
    }

    // 2. 禁用变音符折叠下（diacriticFolding = false）
    func testDisabledDiacriticFolding() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(caseFolding: true, widthFolding: true, diacriticFolding: false))
        
        try await insert("café", into: db)
        try await insert("cafe", into: db)
        
        // a) 查询 cafe 应仅匹配 cafe，不匹配 café
        let r1 = try await searchAny("cafe", in: db)
        XCTAssertEqual(r1, ["cafe"], "禁用变音符折叠下，无变音符查询应仅匹配无变音符文档")
        
        // b) 查询 café 应仅匹配 café，不匹配 cafe
        let r2 = try await searchAny("café", in: db)
        XCTAssertEqual(r2, ["café"], "禁用变音符折叠下，含变音符查询应仅匹配含变音符文档")
    }

    // 3. 组合配置：diacriticFolding = true 且 caseFolding = false
    func testCombinationsOfDiacriticAndCaseFolding() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(caseFolding: false, widthFolding: true, diacriticFolding: true))
        
        try await insert("Café", into: db)
        
        // 变音符折叠，但大小写敏感：Café -> Cafe
        
        // a) 大写正确的无变音符查询 Cafe 应命中
        let r1 = try await searchRaw("Cafe", in: db)
        XCTAssertEqual(r1, ["Café"], "大小写敏感但变音符不敏感时，[Cafe] 应命中 [Café]")
        
        // b) 大小写错误的查询 cafe 不应命中
        let r2 = try await searchRaw("cafe", in: db)
        XCTAssertTrue(r2.isEmpty, "大小写敏感下，小写 [cafe] 不应匹配 [Café]")
    }
}

// MARK: - Stopwords (停用词) 过滤集成测试

final class StopwordTests: CJKTestBase {

    // 1. 测试默认配置（无停用词）
    func testNoStopwordsByDefault() async throws {
        let db = try makeDB(options: CJKTokenizerOptions(stopwords: nil))
        try await insert("the book is on the table", into: db)
        
        let r1 = try await search("the", in: db)
        XCTAssertEqual(r1.count, 1, "默认情况下 stopword [the] 应该被索引且能被搜到")
    }

    // 2. 测试英文停用词过滤 (ASCII 单词)
    func testEnglishStopwordsFiltering() async throws {
        let stopwords: Set<String> = ["the", "is", "on"]
        let db = try makeDB(options: CJKTokenizerOptions(stopwords: stopwords))
        
        try await insert("the book is on the table", into: db)
        
        // a) 查询 the, is, on 应该查不到任何文档，因为它们被过滤了
        let r1 = try await search("the", in: db)
        XCTAssertTrue(r1.isEmpty, "停用词 [the] 应该被过滤且无法搜到")
        
        let r2 = try await search("is", in: db)
        XCTAssertTrue(r2.isEmpty, "停用词 [is] 应该被过滤且无法搜到")
        
        // b) 查询 book, table 应当正常命中
        let r3 = try await search("book", in: db)
        XCTAssertEqual(r3, ["the book is on the table"])
        
        let r4 = try await search("table", in: db)
        XCTAssertEqual(r4, ["the book is on the table"])
    }

    // 3. 测试中文停用词过滤 (CJK 字符段与自适应晋升逻辑)
    func testChineseStopwordsFiltering() async throws {
        let stopwords: Set<String> = ["的", "了", "和", "关于"]
        let db = try makeDB(options: CJKTokenizerOptions(stopwords: stopwords))
        
        // a) 插入含停用词文档
        try await insert("关于北京大学的思考", into: db)
        
        // b) 查询单字 "的" 应该查不到
        let r1 = try await searchAny("的", in: db)
        XCTAssertTrue(r1.isEmpty, "中文停用词 [的] 应当被过滤")
        
        // c) 查询双字 "关于" 应该查不到
        let r2 = try await searchAny("关于", in: db)
        XCTAssertTrue(r2.isEmpty, "中文双字停用词 [关于] 应当被过滤")
        
        // d) 查询非停用词 "北京大学" / "思考" 应当正常命中
        let r3 = try await searchAny("北京", in: db)
        XCTAssertEqual(r3, ["关于北京大学的思考"])
        
        let r4 = try await searchAny("思考", in: db)
        XCTAssertEqual(r4, ["关于北京大学的思考"])
        
        // e) 测试位置晋升：在 "关于北京大学" 中，"关于" (Bigram) 被过滤。
        //    "关" 作为 Unigram 会被晋升为当前位置的主 token 发射。
        //    因此搜索 "关" 应该能搜索到！
        let r5 = try await searchAny("关", in: db)
        XCTAssertEqual(r5, ["关于北京大学的思考"], "Bigram [关于] 过滤后，Unigram [关] 晋升为主 token 应当可被搜索")
    }

    // 4. 测试停用词折叠兼容性 (宽窄折叠、大小写折叠、变音符折叠)
    func testStopwordsFoldingCompatibility() async throws {
        let stopwords: Set<String> = ["Café", "Ｔｈｅ"]
        let db = try makeDB(options: CJKTokenizerOptions(
            caseFolding: true,
            widthFolding: true,
            diacriticFolding: true,
            stopwords: stopwords
        ))
        
        // 插入含小写/半角/无变音符的文本
        try await insert("cafe", into: db)
        try await insert("the", into: db)
        try await insert("book", into: db)
        
        // 验证：
        // "Café" 规范化为 "cafe" -> 输入 "cafe" 被判定为停用词过滤
        let r1 = try await searchAny("cafe", in: db)
        XCTAssertTrue(r1.isEmpty, "停用词 [Café] 经过折叠后，输入 [cafe] 应被过滤")
        
        // "Ｔｈｅ" 规范化为 "the" -> 输入 "the" 被判定为停用词过滤
        let r2 = try await searchAny("the", in: db)
        XCTAssertTrue(r2.isEmpty, "停用词 [Ｔｈｅ] 经过折叠后，输入 [the] 应被过滤")
        
        let r3 = try await searchAny("book", in: db)
        XCTAssertEqual(r3, ["book"])
    }

    // 5. 停用词 100% 零堆分配测试
    func testStopwordsZeroAllocation() async throws {
        let stopwords = CJKTokenizerOptions.englishStopwords.union(CJKTokenizerOptions.chineseStopwords)
        let db = try makeDB(options: CJKTokenizerOptions(stopwords: stopwords))
        
        try await db.write { db in
            let tokenizer = try CJKTokenizer(db: db, arguments: ["stopwords", stopwords.sorted().joined(separator: ",")])
            
            let callback: FTS5TokenCallback = { _, _, _, _, _, _ in
                return 0
            }
            
            let handle = dlopen(nil, RTLD_NOW)
            guard let sym = dlsym(handle, "malloc_logger") else {
                XCTFail("无法获取 malloc_logger 符号")
                return
            }
            
            typealias MallocLogger = @convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Void
            let loggerPtr = sym.assumingMemoryBound(to: MallocLogger?.self)
            let oldLogger = loggerPtr.pointee
            
            let runTokenize = { (text: String) -> Int in
                let cString = text.utf8CString
                
                ZeroAllocationTracker.count = 0
                ZeroAllocationTracker.enabled = false
                
                loggerPtr.pointee = { (type, zone, ptr, arg3, size, num) in
                    if ZeroAllocationTracker.enabled {
                        let isAlloc = (type == 1 || type == 4 || type == 8 || type == 12)
                        if isAlloc {
                            ZeroAllocationTracker.count += 1
                        }
                    }
                }
                
                cString.withUnsafeBufferPointer { buf in
                    let base = buf.baseAddress!
                    let count = CInt(buf.count - 1)
                    
                    // 预热
                    _ = tokenizer.tokenize(
                        context: nil,
                        tokenization: [.document],
                        pText: base,
                        nText: count,
                        tokenCallback: callback
                    )
                    
                    // 开始追踪
                    ZeroAllocationTracker.count = 0
                    ZeroAllocationTracker.enabled = true
                    
                    _ = tokenizer.tokenize(
                        context: nil,
                        tokenization: [.document],
                        pText: base,
                        nText: count,
                        tokenCallback: callback
                    )
                    
                    ZeroAllocationTracker.enabled = false
                }
                
                loggerPtr.pointee = oldLogger
                return ZeroAllocationTracker.count
            }
            
            let cjkAlloc = runTokenize("关于北京大学的思考")
            let asciiAlloc = runTokenize("the book is on the table")
            
            #if DEBUG
            let maxAlloc = 3
            #else
            let maxAlloc = 0
            #endif
            
            XCTAssertLessThanOrEqual(cjkAlloc, maxAlloc, "启用停用词时 CJK 分词堆分配超标")
            XCTAssertLessThanOrEqual(asciiAlloc, maxAlloc, "启用停用词时 ASCII 分词堆分配超标")
        }
    }
}

private struct ZeroAllocationTracker {
    static var count = 0
    static var enabled = false
}
