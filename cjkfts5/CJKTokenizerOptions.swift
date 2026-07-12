// CJKTokenizerOptions.swift
// cjkfts5
//
// 分词器选项与公共类型定义

import Foundation

// MARK: - 分词器选项

/// `CJKTokenizer` 的配置选项
///
/// 通过 `tokenizerDescriptor(options:)` 或 `.cjk(options:)` 传入，作为 FTS5 tokenizer 参数：
/// ```swift
/// let opts = CJKTokenizerOptions(emitUnigrams: true, caseFolding: true)
/// t.tokenizer = .cjk(options: opts)
/// ```
///
/// **默认行为说明：** `.cjk()` / 默认 `CJKTokenizerOptions()` **不会**启用停用词过滤。
/// 若需要中英文常用停用词，请使用 `.recommended` 或显式传入 `StopwordPresets`。
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
    /// - `true`（默认）：全半角混排文本可互相搜索（"１２３"与"123"、"ﾃｽﾄ"与"テスト"均命中）
    /// - `false`：保留原始宽度，全角半角不互通
    public var widthFolding: Bool

    /// 是否对非 CJK token（ASCII / Latin）进行变音符折叠。
    ///
    /// - `true`（默认）：变音符不敏感搜索（"café" 和 "cafe" 均命中）
    /// - `false`：保留变音符，严格匹配
    public var diacriticFolding: Bool

    /// 自定义停用词集合。如果为 `nil` 或为空，则不进行停用词过滤。
    public var stopwords: Set<String>?

    public init(
        emitUnigrams: Bool = true,
        caseFolding: Bool = true,
        widthFolding: Bool = true,
        diacriticFolding: Bool = true,
        stopwords: Set<String>? = nil
    ) {
        self.emitUnigrams = emitUnigrams
        self.caseFolding = caseFolding
        self.widthFolding = widthFolding
        self.diacriticFolding = diacriticFolding
        self.stopwords = stopwords
    }

    /// 推荐配置：全折叠开启 + 中英文常用停用词。
    ///
    /// 与裸 `.cjk()`（无停用词）不同；适合多数中英混合全文检索场景。
    public static var recommended: CJKTokenizerOptions {
        CJKTokenizerOptions(stopwords: StopwordPresets.cjkCommon)
    }

    // MARK: Built-in 默认停用词集（兼容别名）

    /// 默认英文停用词表（等同 `StopwordPresets.english`）
    public static var englishStopwords: Set<String> { StopwordPresets.english }

    /// 默认中文常见停用词表（等同 `StopwordPresets.chinese`）
    public static var chineseStopwords: Set<String> { StopwordPresets.chinese }

    // MARK: 内部：与 FTS5 arguments 字符串互转

    /// 将选项转为 FTS5 tokenizer argument 列表
    var arguments: [String] {
        var args: [String] = []
        if !emitUnigrams { args.append("no_unigram") }
        if !caseFolding { args.append("no_case_fold") }
        if !widthFolding { args.append("no_width_fold") }
        if !diacriticFolding { args.append("no_diacritic_fold") }
        if let stopwords, !stopwords.isEmpty {
            if let preset = StopwordPresets.presetID(matching: stopwords) {
                args.append("stopwords_preset")
                args.append(preset)
            } else {
                args.append("stopwords")
                args.append(Self.encodeStopwordList(stopwords))
            }
        }
        return args
    }

    /// 从 FTS5 tokenizer argument 列表还原选项
    init(arguments: [String]) {
        emitUnigrams = !arguments.contains("no_unigram")
        caseFolding = !arguments.contains("no_case_fold")
        widthFolding = !arguments.contains("no_width_fold")
        diacriticFolding = !arguments.contains("no_diacritic_fold")

        var words: Set<String> = []
        if let idx = arguments.firstIndex(of: "stopwords_preset"), idx + 1 < arguments.count,
           let preset = StopwordPresets.resolve(preset: arguments[idx + 1]) {
            words.formUnion(preset)
        }
        if let idx = arguments.firstIndex(of: "stopwords"), idx + 1 < arguments.count {
            words.formUnion(Self.decodeStopwordList(arguments[idx + 1]))
        }
        stopwords = words.isEmpty ? nil : words
    }

    // MARK: - 停用词列表编解码（支持逗号转义）

    /// 编码停用词列表：`,` 与 `\` 转义为 `\,` / `\\`，词之间用 `,` 分隔。
    static func encodeStopwordList(_ words: Set<String>) -> String {
        words.sorted().map(escapeStopwordComponent).joined(separator: ",")
    }

    /// 解码停用词列表（与 `encodeStopwordList` 对称）。
    static func decodeStopwordList(_ encoded: String) -> Set<String> {
        var result: [String] = []
        var current = ""
        var escaped = false
        for ch in encoded {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "," {
                if !current.isEmpty {
                    result.append(current)
                }
                current = ""
                continue
            }
            current.append(ch)
        }
        if escaped {
            // 尾部孤立 `\`：按字面保留
            current.append("\\")
        }
        if !current.isEmpty {
            result.append(current)
        }
        return Set(result)
    }

    private static func escapeStopwordComponent(_ word: String) -> String {
        var out = ""
        out.reserveCapacity(word.count)
        for ch in word {
            if ch == "\\" || ch == "," {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}
