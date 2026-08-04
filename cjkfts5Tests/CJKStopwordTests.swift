// CJKStopwordTests.swift
// cjkfts5Tests
//
// 停用词过滤集成测试

import XCTest
import GRDB
@testable import cjkfts5

final class StopwordTests: CJKTestBase, @unchecked Sendable {

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

    // 4b. 测试停用词位于中间时的 Phrase Search 连续匹配
    func testStopwordsInMiddlePhraseQuery() async throws {
        let stopwords: Set<String> = ["关于"]
        let db = try makeDB(options: CJKTokenizerOptions(stopwords: stopwords))

        try await insert("北京关于上海", into: db)

        // 查询 "北京关于上海"
        let r1 = try await search("北京关于上海", in: db)
        XCTAssertEqual(r1, ["北京关于上海"], "停用词在中间时，Phrase 搜索仍应正确命中")
    }

    // 5. 停用词 100% 零堆分配测试
    func testStopwordsZeroAllocation() async throws {
        let stopwords = StopwordPresets.cjkCommon
        let db = try makeDB(options: CJKTokenizerOptions(stopwords: stopwords))

        try await db.write { db in
            // 使用 options.arguments 往返，覆盖 preset 紧凑编码路径
            let tokenizer = try CJKTokenizer(db: db, arguments: CJKTokenizerOptions(stopwords: stopwords).arguments)

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

                loggerPtr.pointee = { (type, _, _, _, _, _) in
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

            #if !DEBUG
            // 仅在 Release 优化编译模式下进行零分配断言。
            XCTAssertEqual(cjkAlloc, 0, "启用停用词时 CJK 分词堆分配超标")
            XCTAssertEqual(asciiAlloc, 0, "启用停用词时 ASCII 分词堆分配超标")
            #endif
        }
    }
}

private struct ZeroAllocationTracker {
    // malloc_logger C 回调与主测试线程共享；测试串行控制启停
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var enabled = false
}
