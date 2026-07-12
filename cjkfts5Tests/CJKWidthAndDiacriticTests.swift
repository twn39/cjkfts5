// CJKWidthAndDiacriticTests.swift
// cjkfts5Tests
//
// Unicode 宽度与变音符折叠集成测试

import XCTest
import GRDB
@testable import cjkfts5

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
        // 宽度折叠时合成为单个全角浊音 "ガ" (U+30AC)，而非 "カ"+"゛" 两个码点
        try await insert("ｶﾞ")

        // a) 全角合成浊音应命中
        let r1 = try await searchAny("ガ")
        XCTAssertEqual(r1, ["ｶﾞ"], "半角基字+浊点应合成为全角浊音并可检索")

        // b) 清音 "カ" 不应误匹配已合成的浊音 "ガ"
        let r2 = try await searchAny("カ")
        XCTAssertTrue(r2.isEmpty, "合成后不应再按清音基字误命中")

        // c) 半角查询与全角文档互通（反向在 TokenGoldenTests 覆盖）
        try await insert("パ")
        let r3 = try await searchAny("ﾊﾟ", in: dbQueue)
        // 半浊点 FF9F：ﾊﾟ → パ
        XCTAssertEqual(r3, ["パ"], "半角半浊点应合成全角半浊音")
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
