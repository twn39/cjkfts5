// CJKTokenizerTests.swift
// cjkfts5Tests
//
// CJKTokenizer 单元测试套件
// 覆盖：分词正确性、Phrase Search、配置选项、边界条件、Unicode 范围、精确率验证

import XCTest
import GRDB
@testable import cjkfts5

// MARK: - 基础测试基类 / FTS fixture

/// 内存 FTS5 夹具：统一注册 `CJKTokenizer`、建 `docs` 表，并提供 insert / search 辅助。
///
/// 集成测试应优先复用本基类，避免各文件重复 `prepareDatabase` 样板。
/// 变更默认 options 时会大面积影响子类——视作契约变更并同步 golden / 设计文档。
///
/// `@unchecked Sendable`：`DatabaseQueue`/`DatabasePool` 自身线程安全；测试夹具可在 TaskGroup 中捕获 `self`。
class CJKTestBase: XCTestCase, @unchecked Sendable {

    /// 默认套件使用的内存库（`setUp` 中按 default options 创建）
    var dbQueue: DatabaseQueue!

    override func setUp() async throws {
        try await super.setUp()
        dbQueue = try makeDB()
    }

    override func tearDown() async throws {
        dbQueue = nil
        try await super.tearDown()
    }

    // MARK: Fixture factory

    /// 创建使用指定 options 的内存 FTS5 数据库（虚拟表名固定为 `docs`）
    func makeDB(options: CJKTokenizerOptions = CJKTokenizerOptions()) throws -> DatabaseQueue {
        var config = Configuration()
        config.addCJKTokenizer()
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.create(virtualTable: "docs", using: FTS5()) { t in
                t.tokenizer = .cjk(options: options)
                t.column("content")
            }
        }
        return db
    }

    // MARK: Mutations & queries

    func insert(_ text: String, into db: DatabaseQueue? = nil) async throws {
        let target = db ?? dbQueue!
        try await target.write { db in
            try db.execute(sql: "INSERT INTO docs(content) VALUES (?)", arguments: [text])
        }
    }

    /// phrase 查询（`matchingPhrase`）
    func search(_ query: String, in db: DatabaseQueue? = nil) async throws -> [String] {
        let target = db ?? dbQueue!
        return try await target.read { db in
            let pattern = FTS5Pattern(matchingPhrase: query)
            return try String.fetchAll(db, sql: "SELECT content FROM docs WHERE docs MATCH ?",
                                       arguments: [pattern])
        }
    }

    /// any-token 查询（`matchingAnyTokenIn`；GRDB 侧辅助分词为 ascii，见 docs/GRDB_COMPATIBILITY.md）
    func searchAny(_ query: String, in db: DatabaseQueue? = nil) async throws -> [String] {
        let target = db ?? dbQueue!
        return try await target.read { db in
            let pattern = FTS5Pattern(matchingAnyTokenIn: query)
            return try String.fetchAll(db, sql: "SELECT content FROM docs WHERE docs MATCH ?",
                                       arguments: [pattern])
        }
    }

    /// raw pattern 查询（精确控制 FTS5 query 字符串）
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

final class SingleCharSearchTests: CJKTestBase, @unchecked Sendable {

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

final class BigramSearchTests: CJKTestBase, @unchecked Sendable {

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

final class PhraseSearchTests: CJKTestBase, @unchecked Sendable {

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

final class MixedTextTests: CJKTestBase, @unchecked Sendable {

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

final class MultiLanguageTests: CJKTestBase, @unchecked Sendable {

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

final class EdgeCaseTests: CJKTestBase, @unchecked Sendable {

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

final class OptionTests: CJKTestBase, @unchecked Sendable {

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
final class NoUnigramPhraseTests: CJKTestBase, @unchecked Sendable {

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

// MARK: - 扩展 CJK 字符集成搜索测试

/// 验证扩展 C-G/I 字符在真实 FTS5 分词与搜索中行为正确。
/// 使用 CJKTestBase 继承内存数据库与辅助方法。
final class ExtendedUnicodeSearchTests: CJKTestBase, @unchecked Sendable {

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
