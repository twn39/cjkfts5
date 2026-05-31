// CJKTokenizerOptions.swift
// cjkfts5
//
// 分词器选项与公共类型定义

import Foundation

// MARK: - 分词器选项

/// `CJKTokenizer` 的配置选项
///
/// 通过 `tokenizerDescriptor(options:)` 传入，作为 FTS5 tokenizer 参数：
/// ```swift
/// let opts = CJKTokenizerOptions(emitUnigrams: true, caseFolding: true)
/// t.tokenizer = CJKTokenizer.tokenizerDescriptor(options: opts)
/// ```
public struct CJKTokenizerOptions: Sendable {
    /// 是否同时在 bigram 同一位置额外发出单字 unigram token。
    ///
    /// - `true`（默认）：单字查询（如"清"）和双字查询（如"清华"）均可命中
    /// - `false`：仅发出 bigram，索引体积略小，但单字查询无法命中
    public var emitUnigrams: Bool

    /// 是否对非 CJK token（ASCII / Latin）进行小写折叠。
    ///
    /// - `true`（默认）：大小写不敏感搜索（"Apple" 和 "apple" 均命中）
    /// - `false`：保留原始大小写
    public var caseFolding: Bool

    /// 是否进行 Unicode 宽度正规化（全角转半角，半角假名转全角假名）。
    ///
    /// - `true`（默认）：全半角混排文本可互相搜索（"１２３"与"123"、"ﾃｽﾄ"与"测试"均命中）
    /// - `false`：保留原始宽度，全角半角不互通
    public var widthFolding: Bool

    /// 是否对非 CJK token（ASCII / Latin）进行变音符折叠。
    ///
    /// - `true`（默认）：变音符不敏感搜索（"café" 和 "cafe" 均命中）
    /// - `false`：保留变音符，严格匹配
    public var diacriticFolding: Bool

    public init(
        emitUnigrams: Bool = true,
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true
    ) {
        self.emitUnigrams = emitUnigrams
        self.caseFolding = caseFolding
        self.widthFolding = widthFolding
        self.diacriticFolding = diacriticFolding
    }

    // MARK: 内部：与 FTS5 arguments 字符串互转

    /// 将选项转为 FTS5 tokenizer argument 列表
    var arguments: [String] {
        var args: [String] = []
        if !emitUnigrams { args.append("no_unigram") }
        if !caseFolding  { args.append("no_case_fold") }
        if !widthFolding { args.append("no_width_fold") }
        if !diacriticFolding { args.append("no_diacritic_fold") }
        return args
    }

    /// 从 FTS5 tokenizer argument 列表还原选项
    init(arguments: [String]) {
        emitUnigrams = !arguments.contains("no_unigram")
        caseFolding  = !arguments.contains("no_case_fold")
        widthFolding = !arguments.contains("no_width_fold")
        diacriticFolding = !arguments.contains("no_diacritic_fold")
    }
}
