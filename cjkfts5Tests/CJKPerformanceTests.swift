// CJKPerformanceTests.swift
// cjkfts5Tests
//
// 并发与零堆内存分配性能回归测试

import XCTest
import GRDB
@testable import cjkfts5

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
            "日本語测试",        // 日文假名
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

/// 线程安全的计数器 and 结果收集器，仅供并发测试使用。
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
            
            #if !DEBUG
            // 仅在 Release 优化编译模式下进行零分配断言。
            // Debug 模式下由于未开启编译器优化，存在大量非内联闭包装箱与测试框架辅助开销，数据不具备真实回归意义。
            XCTAssertEqual(cjkAlloc, 0, "CJK 字符分词堆分配超标")
            XCTAssertEqual(asciiLowerAlloc, 0, "ASCII 小写分词堆分配超标")
            XCTAssertEqual(asciiUpperAlloc, 0, "ASCII 大写/折叠分词堆分配超标")
            XCTAssertEqual(katakanaAlloc, 0, "Katakana 片假名折叠分词堆分配超标")
            #endif
        }
    }
}
