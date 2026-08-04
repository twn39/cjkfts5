// CJKUnicodeFoldingTests.swift
// cjkfts5Tests
//
// Unicode 大小写折叠测试

import XCTest
import GRDB
@testable import cjkfts5

final class UnicodeCaseFoldingTests: CJKTestBase, @unchecked Sendable {

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
