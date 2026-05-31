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

    // MARK: Built-in 默认停用词集

    /// 默认英文停用词表
    public static let englishStopwords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are", "aren't",
        "as", "at", "be", "because", "been", "before", "being", "below", "between", "both", "but", "by",
        "can't", "cannot", "could", "couldn't", "did", "didn't", "do", "does", "doesn't", "doing", "don't",
        "down", "during", "each", "few", "for", "from", "further", "had", "hadn't", "has", "hasn't", "have",
        "haven't", "having", "he", "he'd", "he'll", "he's", "her", "here", "here's", "hers", "herself",
        "him", "himself", "his", "how", "how's", "i", "i'd", "i'll", "i'm", "i've", "if", "in", "into",
        "is", "isn't", "it", "it's", "its", "itself", "let's", "me", "more", "most", "mustn't", "my",
        "myself", "no", "nor", "not", "of", "off", "on", "once", "only", "or", "other", "ought", "our",
        "ours", "ourselves", "out", "over", "own", "same", "shan't", "she", "she'd", "she'll", "she's",
        "should", "shouldn't", "so", "some", "such", "than", "that", "that's", "the", "their", "theirs",
        "them", "themselves", "then", "there", "there's", "these", "they", "they'd", "they'll", "they're",
        "they've", "this", "those", "through", "to", "too", "under", "until", "up", "very", "was", "wasn't",
        "we", "we'd", "we'll", "we're", "we've", "were", "weren't", "what", "what's", "when", "when's",
        "where", "where's", "which", "while", "who", "who's", "whom", "why", "why's", "with", "won't",
        "would", "wouldn't", "you", "you'd", "you'll", "you're", "you've", "your", "yours", "yourself",
        "yourselves"
    ]

    /// 默认中文常见停用词表
    public static let chineseStopwords: Set<String> = [
        "的", "了", "和", "是", "在", "我", "有", "这", "个", "他", "们", "就", "人", "都", "一", "而",
        "及", "与", "也", "着", "它", "之", "为", "以", "所", "于", "上", "下", "那"
    ]

    // MARK: 内部：与 FTS5 arguments 字符串互转

    /// 将选项转为 FTS5 tokenizer argument 列表
    var arguments: [String] {
        var args: [String] = []
        if !emitUnigrams { args.append("no_unigram") }
        if !caseFolding  { args.append("no_case_fold") }
        if !widthFolding { args.append("no_width_fold") }
        if !diacriticFolding { args.append("no_diacritic_fold") }
        if let stopwords, !stopwords.isEmpty {
            args.append("stopwords")
            args.append(stopwords.sorted().joined(separator: ","))
        }
        return args
    }

    /// 从 FTS5 tokenizer argument 列表还原选项
    init(arguments: [String]) {
        emitUnigrams = !arguments.contains("no_unigram")
        caseFolding  = !arguments.contains("no_case_fold")
        widthFolding = !arguments.contains("no_width_fold")
        diacriticFolding = !arguments.contains("no_diacritic_fold")
        if let idx = arguments.firstIndex(of: "stopwords"), idx + 1 < arguments.count {
            let listStr = arguments[idx + 1]
            let words = listStr.split(separator: ",").map(String.init)
            stopwords = Set(words)
        } else {
            stopwords = nil
        }
    }
}
