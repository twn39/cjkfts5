// CJKIntegration.swift
// cjkfts5
//
// 与 GRDB 的集成便捷 API
//
// 提供两个扩展，在不破坏现有调用的前提下大幅减少样板代码：
//   1. FTS5TokenizerDescriptor.cjk() — 与内置 .unicode61()/.porter() 风格完全一致
//   2. Configuration.addCJKTokenizer() — 一行完成分词器注册

import GRDB

// MARK: - FTS5TokenizerDescriptor 静态工厂

extension FTS5TokenizerDescriptor {

    /// CJK Bigram+Unigram 分词器描述符。
    ///
    /// 与 GRDB 内置的 `.unicode61()`、`.porter()` 调用风格完全一致：
    ///
    /// ```swift
    /// // 默认配置（推荐）
    /// try db.create(virtualTable: "documents", using: FTS5()) { t in
    ///     t.tokenizer = .cjk()
    ///     t.column("title")
    ///     t.column("body")
    /// }
    ///
    /// // 关闭单字索引（减小约 30% 索引体积，单字查询将无法命中）
    /// t.tokenizer = .cjk(emitUnigrams: false)
    ///
    /// // 大小写敏感搜索
    /// t.tokenizer = .cjk(caseFolding: false)
    /// ```
    ///
    /// 作为 `FTS5TokenizerDescriptor`，还可传给 `db.makeTokenizer()` 用于调试：
    ///
    /// ```swift
    /// let tokenizer = try db.makeTokenizer(.cjk())
    /// let tokens = try tokenizer.tokenize(document: "清华大学 Hello")
    /// // → [("清华", []), ("华大", []), ("大学", []), ("学", []), ("hello", [])]
    /// ```
    ///
    /// - Parameters:
    ///   - emitUnigrams: 是否同时在 bigram 同一位置发出单字 unigram token。
    ///     默认 `true`，设为 `false` 可减小约 30% 的索引体积，
    ///     但单字查询（如搜索"清"）将无法命中。
    ///   - caseFolding: 是否对非 CJK token（ASCII / Latin Extended 等）
    ///     进行 Unicode 大小写折叠。默认 `true`（大小写不敏感）。
    /// - Returns: 可赋值给 `FTS5TableDefinition.tokenizer` 的描述符。
    public static func cjk(
        emitUnigrams: Bool = true,
        caseFolding: Bool = true
    ) -> FTS5TokenizerDescriptor {
        CJKTokenizer.tokenizerDescriptor(
            options: CJKTokenizerOptions(
                emitUnigrams: emitUnigrams,
                caseFolding: caseFolding
            )
        )
    }
}

// MARK: - Configuration 便捷注册

extension Configuration {

    /// 向此 `Configuration` 注册 `CJKTokenizer`。
    ///
    /// 等价于但更简洁于：
    /// ```swift
    /// config.prepareDatabase { db in
    ///     db.add(tokenizer: CJKTokenizer.self)
    /// }
    /// ```
    ///
    /// **典型用法：**
    /// ```swift
    /// var config = Configuration()
    /// config.addCJKTokenizer()
    /// let dbQueue = try DatabaseQueue(path: path, configuration: config)
    /// ```
    ///
    /// 对 `DatabasePool` 同样有效：GRDB 会对每个连接执行 `prepareDatabase` 闭包，
    /// 确保所有读写连接均已注册分词器。
    ///
    /// - Note: 可安全地多次调用（每次调用追加一个 `prepareDatabase` 闭包），
    ///   但通常只需调用一次。
    public mutating func addCJKTokenizer() {
        prepareDatabase { db in
            db.add(tokenizer: CJKTokenizer.self)
        }
    }
}
