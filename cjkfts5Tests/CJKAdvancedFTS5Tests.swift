// CJKAdvancedFTS5Tests.swift
// cjkfts5Tests
//
// FTS5 高级匹配语法与多语言复杂混排测试

import XCTest
import GRDB
@testable import cjkfts5

final class CJKAdvancedFTS5Tests: CJKTestBase, @unchecked Sendable {

    // 1. FTS5 NEAR(...) 邻近搜索与位置保持测试
    func testFTS5NearQuery() async throws {
        let db = try makeDB(options: .recommended)
        try await insert("清华大学位于北京", into: db)
        try await insert("北京与上海都是大城市，而清华大学在北方", into: db)

        // 查找 "清华" 和 "北京" 在相距 10 个 token 以内的文档
        let docs = try await searchRaw("NEAR(清华 北京, 10)", in: db)

        XCTAssertEqual(docs.count, 2)
        XCTAssertTrue(docs.contains("清华大学位于北京"))
    }

    // 2. FTS5 前缀通配符匹配 ("word*")
    func testFTS5PrefixMatchQuery() async throws {
        let db = try makeDB()
        try await insert("Hello World", into: db)
        try await insert("Headline News", into: db)

        // 前缀通配符搜索 "head*"
        let docs = try await searchRaw("head*", in: db)

        XCTAssertEqual(docs, ["Headline News"])
    }

    // 3. FTS5 逻辑运算符 (OR / NOT / AND)
    func testFTS5BooleanLogicQuery() async throws {
        let db = try makeDB()
        try await insert("北京大学", into: db)
        try await insert("清华大学", into: db)
        try await insert("浙江大学", into: db)

        // a) OR 查询
        let docsOR = try await searchRaw("北京 OR 清华", in: db)
        XCTAssertEqual(Set(docsOR), ["北京大学", "清华大学"])

        // b) NOT 查询 (大学 NOT 北京)
        let docsNOT = try await searchRaw("大学 NOT 北京", in: db)
        XCTAssertEqual(Set(docsNOT), ["清华大学", "浙江大学"])
    }

    // 4. 全标点 / 全停用词极限文本输入
    func testPunctuationAndAllStopwordsInput() async throws {
        let db = try makeDB(options: .recommended)

        // 插入全标点与全停用词文档（不崩溃，正常处理）
        try await insert("，。！？；：", into: db)
        try await insert("的 了 和 于 所", into: db)
        try await insert("正常文本内容", into: db)

        // 查询普通词不受噪音文档干扰
        let docs = try await searchAny("内容", in: db)
        XCTAssertEqual(docs, ["正常文本内容"])
    }

    // 5. 复杂多语言混排（变音符 + Emoji + 标点 + 数字）
    func testMultilingualAccentsAndEmoji() async throws {
        let db = try makeDB(options: .recommended)
        try await insert("Café Resume 在 iPhone 16 Pro (正式版 📱) 运行良好", into: db)

        // a) 搜变音符折叠 "cafe"
        let r1 = try await searchAny("cafe", in: db)
        XCTAssertEqual(r1.count, 1)

        // b) 搜数字 + CJK 混排 "iPhone 16"
        let r2 = try await searchAny("iPhone 16", in: db)
        XCTAssertEqual(r2.count, 1)

        // c) 搜 CJK 部分 "正式版"
        let r3 = try await searchAny("正式版", in: db)
        XCTAssertEqual(r3.count, 1)
    }
}
