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

    /// CJK Bigram+Unigram 分词器描述符（推荐入口：传入完整 options）。
    ///
    /// ```swift
    /// t.tokenizer = .cjk(options: .recommended)  // 折叠 + 中英文停用词
    /// t.tokenizer = .cjk(options: CJKTokenizerOptions(emitUnigrams: false))
    /// ```
    ///
    /// - Note: 默认 `CJKTokenizerOptions()` **不含**停用词；需要过滤时用 `.recommended`
    ///   或设置 `stopwords: StopwordPresets.cjkCommon`。
    public static func cjk(options: CJKTokenizerOptions = CJKTokenizerOptions()) -> FTS5TokenizerDescriptor {
        CJKTokenizer.tokenizerDescriptor(options: options)
    }

    /// CJK Bigram+Unigram 分词器描述符（便捷参数版，与 GRDB 内置风格一致）。
    ///
    /// ```swift
    /// // 默认配置（全折叠，无停用词）
    /// t.tokenizer = .cjk()
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
    ///   - widthFolding: 是否进行全半角宽度折叠。默认 `true`。
    ///   - diacriticFolding: 是否折叠变音符。默认 `true`。
    ///   - stopwords: 停用词集合；`nil` 表示不过滤（默认）。
    /// - Returns: 可赋值给 `FTS5TableDefinition.tokenizer` 的描述符。
    public static func cjk(
        emitUnigrams: Bool = true,
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil
    ) -> FTS5TokenizerDescriptor {
        cjk(options: CJKTokenizerOptions(
            emitUnigrams: emitUnigrams,
            caseFolding: caseFolding,
            widthFolding: widthFolding,
            diacriticFolding: diacriticFolding,
            stopwords: stopwords
        ))
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
