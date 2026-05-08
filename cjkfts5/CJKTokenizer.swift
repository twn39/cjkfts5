// CJKTokenizer.swift
// cjkfts5
//
// 通用 CJK FTS5 分词器 — 基于 Bigram+Unigram 混合策略
//
// ## 算法说明
//
// 对 CJK 字符段（中文/日文/韩文）采用 Bigram 序列发出，同一位置附加 Unigram
// 作为 co-located 同义 token，使单字查询、双字查询、短语查询均能正确命中：
//
//   文档："清华大学"
//   发出：
//     pos 0 → bigram "清华"（主），unigram "清"（co-located）
//     pos 1 → bigram "华大"（主），unigram "华"（co-located）
//     pos 2 → bigram "大学"（主），unigram "大"（co-located）
//     pos 3 → unigram "学"（主，最后一字）
//
//   搜索 "清"       → ✅ 命中（unigram "清" 在 pos 0）
//   搜索 "清华"     → ✅ 命中（bigram "清华" 在 pos 0）
//   搜索 "清华大学" → ✅ phrase match："清华"@0 "华大"@1 "大学"@2 连续
//   搜索 "北京大学" → ❌ 正确地不命中（"京大" bigram 不存在于文档中）
//
// 对非 CJK 段（ASCII / Latin / 数字）采用空格/标点切分 + 小写折叠，
// 与 unicode61 行为兼容。
//
// ## 线程安全
//
// CJKTokenizer 是无状态的（所有操作基于函数参数，无共享可变状态），
// SQLite 可在任意线程并发调用 xTokenize 而无需加锁。

import GRDB
#if canImport(GRDBSQLite)
import GRDBSQLite
#elseif canImport(SQLite3)
import SQLite3
#endif
import Foundation

// MARK: - CJKTokenizer

/// 通用高效 CJK FTS5 分词器
///
/// 支持中文（简/繁）、日文（汉字/平假名/片假名）、韩文（谚文）及
/// 与 ASCII / Latin 的混合文本。
///
/// **快速开始：**
/// ```swift
/// // 1. 注册分词器
/// var config = Configuration()
/// config.prepareDatabase { db in
///     db.add(tokenizer: CJKTokenizer.self)
/// }
/// let dbQueue = try DatabaseQueue(path: path, configuration: config)
///
/// // 2. 建立 FTS5 虚拟表
/// try dbQueue.write { db in
///     try db.create(virtualTable: "documents", using: FTS5()) { t in
///         t.tokenizer = CJKTokenizer.tokenizerDescriptor()
///         t.column("content")
///     }
/// }
///
/// // 3. 搜索（无需对查询做任何预处理）
/// let pattern = FTS5Pattern(matchingPhrase: "清华大学")
/// let results = try Document.matching(pattern).fetchAll(db)
/// ```
///
/// **自定义选项：**
/// ```swift
/// // 关闭单字 unigram（减小索引体积，但单字查询将失效）
/// let opts = CJKTokenizerOptions(emitUnigrams: false)
/// t.tokenizer = CJKTokenizer.tokenizerDescriptor(options: opts)
/// ```
public final class CJKTokenizer: FTS5CustomTokenizer {

    // MARK: FTS5CustomTokenizer 必要属性

    /// FTS5 tokenizer 名称，在 CREATE VIRTUAL TABLE 中引用
    public static let name = "cjk"

    // MARK: 配置

    private let options: CJKTokenizerOptions

    // MARK: 初始化

    /// SQLite 实例化 tokenizer 时调用。
    /// `arguments` 来自 `tokenizerDescriptor(options:)` 编码的参数字符串。
    public required init(db: Database, arguments: [String]) throws {
        options = CJKTokenizerOptions(arguments: arguments)
    }

    // MARK: 便捷工厂

    /// 生成带选项的 `FTS5TokenizerDescriptor`，用于 `t.tokenizer = ...`
    public static func tokenizerDescriptor(
        options: CJKTokenizerOptions = CJKTokenizerOptions()
    ) -> FTS5TokenizerDescriptor {
        return tokenizerDescriptor(arguments: options.arguments)
    }

    // MARK: 核心分词入口

    /// FTS5 调用此方法对文本进行分词（索引时和查询时均调用）。
    ///
    /// - Parameters:
    ///   - context:       透传给 `tokenCallback` 的不透明指针
    ///   - tokenization:  分词目的（文档索引 / 查询 / 自动补全）
    ///   - pText:         待分词的 UTF-8 字节指针（可能不以 `\0` 结尾）
    ///   - nText:         字节数
    ///   - tokenCallback: 每发现一个 token 时调用的回调函数
    /// - Returns: `SQLITE_OK` 或 SQLite 错误码
    public func tokenize(
        context: UnsafeMutableRawPointer?,
        tokenization: FTS5Tokenization,
        pText: UnsafePointer<CChar>?,
        nText: CInt,
        tokenCallback: @escaping FTS5TokenCallback
    ) -> CInt {
        guard let pText, nText > 0 else { return SQLITE_OK }

        // 从原始字节构建 Swift String（pText 可能不以 \0 结尾，必须使用 nText）
        let byteCount = Int(nText)
        guard let text = String(
            data: Data(bytes: pText, count: byteCount),
            encoding: .utf8
        ) else { return SQLITE_OK }

        // isQuery=true 时（MATCH 查询分词），末字不作为新位置独立 token 发出，
        // 以避免产生多余的 implicit AND 约束破坏 bigram 命中。
        let isQuery = tokenization.contains(.query)
        return tokenizeText(text, isQuery: isQuery, callback: tokenCallback, context: context)
    }

    // MARK: 内部：主分词流程

    /// 遍历文本，将字符分类为 CJK 段和非 CJK 段，分别处理后发出 token。
    ///
    /// - Parameter isQuery: `true` 表示此次为 MATCH 查询分词，末字不额外占用新 FTS5 位置。
    private func tokenizeText(
        _ text: String,
        isQuery: Bool,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return SQLITE_OK }

        // 预计算所有 scalar 的 UTF-8 字节起始偏移（O(n)，避免内层循环重复计算）
        let byteOffsets = CJKUnicode.computeByteOffsets(of: scalars)

        var i = 0
        // 非 CJK 字符缓冲区（收集一段非 CJK 字符后统一处理）
        var nonCJKStart = 0      // 当前非 CJK 段的起始 scalar 下标
        var nonCJKCount = 0     // 当前非 CJK 段的 scalar 数量

        while i < scalars.count {
            if CJKUnicode.isCJK(scalars[i]) {
                // 先 flush 之前积累的非 CJK 段
                if nonCJKCount > 0 {
                    let rc = flushNonCJK(
                        scalars: scalars,
                        start: nonCJKStart,
                        count: nonCJKCount,
                        byteOffsets: byteOffsets,
                        callback: callback,
                        context: context
                    )
                    nonCJKCount = 0
                    guard rc == SQLITE_OK else { return rc }
                }

                // 找到 CJK 段的结束位置（下一个非 CJK 字符前）
                let cjkStart = i
                while i < scalars.count && CJKUnicode.isCJK(scalars[i]) { i += 1 }

                // 发出 CJK 段的 bigram + unigram token
                let rc = emitCJKSegment(
                    scalars: scalars,
                    start: cjkStart,
                    end: i,
                    byteOffsets: byteOffsets,
                    isQuery: isQuery,
                    callback: callback,
                    context: context
                )
                guard rc == SQLITE_OK else { return rc }

            } else {
                // 非 CJK 字符：加入缓冲区
                if nonCJKCount == 0 { nonCJKStart = i }
                nonCJKCount += 1
                i += 1
            }
        }

        // flush 末尾剩余的非 CJK 段
        if nonCJKCount > 0 {
            let rc = flushNonCJK(
                scalars: scalars,
                start: nonCJKStart,
                count: nonCJKCount,
                byteOffsets: byteOffsets,
                callback: callback,
                context: context
            )
            guard rc == SQLITE_OK else { return rc }
        }

        return SQLITE_OK
    }

    // MARK: 内部：CJK 段处理 — Bigram + Unigram

    /// 对 `scalars[start..<end]` 区间的 CJK 字符段发出 bigram（主）+ unigram（co-located）。
    ///
    /// **文档索引模式（isQuery=false）位置规则：**
    /// - 每对相邻字符构成一个 bigram，各自占据独立的 FTS5 位置
    /// - 对应的 unigram 与该 bigram 共享同一位置（`FTS5_TOKEN_COLOCATED`）
    /// - 最后一个字符单独占据最后一个位置（保证 phrase search 末字锚点正确）
    ///
    /// **查询分词模式（isQuery=true）位置规则：**
    /// - 末字不再作为新位置独立发出；改为附在最后一个 bigram 的 co-located 位置上
    /// - 这样 FTS5 不会把末字解读为额外的 implicit AND 约束，bigram 查询可正确命中
    ///
    /// 参考：SQLite FTS5 Synonym Support（方法 3）文档：
    /// "it is important that the tokenizer only provide synonyms when
    ///  tokenizing document text, not query text"
    private func emitCJKSegment(
        scalars: [Unicode.Scalar],
        start: Int,
        end: Int,
        byteOffsets: [Int],
        isQuery: Bool,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let length = end - start
        guard length > 0 else { return SQLITE_OK }

        if length == 1 {
            // 单个 CJK 字符：直接发出 unigram（主 token，新位置）
            return emitString(
                String(scalars[start]),
                iStart: byteOffsets[start],
                iEnd: byteOffsets[start + 1],
                flags: 0,
                callback: callback,
                context: context
            )
        }

        // 多个 CJK 字符：发出 bigram 序列
        for k in start..<end {
            let hasNext = (k + 1 < end)

            if hasNext {
                // ── 主 token：bigram（占据新的 FTS5 位置）────────────────
                let bigram = String(scalars[k]) + String(scalars[k + 1])
                let rc = emitString(
                    bigram,
                    iStart: byteOffsets[k],
                    iEnd: byteOffsets[k + 2],
                    flags: 0,  // 不加 COLOCATED → FTS5 自动递增位置
                    callback: callback,
                    context: context
                )
                guard rc == SQLITE_OK else { return rc }

                // ── co-located：当前字 unigram（与上方 bigram 同位置）────
                // 仅在文档索引模式下发出：query 模式下不发出任何 unigram（包括 co-located），
                // 否则 FTS5 会把 co-located 当作 bigram 的 synonym 查询，
                // 导致 "北清" 命中任何含 "北" 的文档（假阳性）。
                if options.emitUnigrams && !isQuery {
                    let rc2 = emitString(
                        String(scalars[k]),
                        iStart: byteOffsets[k],
                        iEnd: byteOffsets[k + 1],
                        flags: FTS5_TOKEN_COLOCATED,
                        callback: callback,
                        context: context
                    )
                    guard rc2 == SQLITE_OK else { return rc2 }
                }

                // ── query 模式：末字直接跳过（不发出任何 token）────────
                // 末字在 query 模式下既不能作为新位置（会产生 AND 约束），
                // 也不能作为 co-located（会产生 synonym 误命中）。直接跳过。
            } else {
                // ── 最后一个字符（文档索引模式）：单独发出 unigram（新位置）────
                // query 模式下已在上一轮迭代的 bigram co-located 处处理，此处跳过。
                if !isQuery {
                    let rc = emitString(
                        String(scalars[k]),
                        iStart: byteOffsets[k],
                        iEnd: byteOffsets[k + 1],
                        flags: 0,
                        callback: callback,
                        context: context
                    )
                    guard rc == SQLITE_OK else { return rc }
                }
            }
        }

        return SQLITE_OK
    }

    // MARK: 内部：非 CJK 段处理 — Word Splitting + Case Folding

    /// 对 `scalars[start..<start+count]` 区间的非 CJK 字符段进行分词。
    ///
    /// 算法：
    /// 1. 按非词字符（空格、标点等）切分出 word runs
    /// 2. 若 `options.caseFolding == true`，对每个 word 进行小写折叠
    /// 3. 每个 word 发出为一个新的 FTS5 位置
    ///
    /// 支持 Unicode 全范围的字母和数字（通过 `Unicode.Scalar.Properties`），
    /// 与 unicode61 tokenizer 的非 CJK 行为高度兼容。
    private func flushNonCJK(
        scalars: [Unicode.Scalar],
        start: Int,
        count: Int,
        byteOffsets: [Int],
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let end = start + count
        var wordScalars: [Unicode.Scalar] = []
        wordScalars.reserveCapacity(32)
        var wordByteStart = 0

        for k in start..<end {
            let scalar = scalars[k]

            if CJKUnicode.isWordChar(scalar) {
                if wordScalars.isEmpty { wordByteStart = byteOffsets[k] }
                wordScalars.append(scalar)
            } else {
                // 遇到分隔符：flush 已积累的 word
                if !wordScalars.isEmpty {
                    let rc = emitWordToken(
                        wordScalars,
                        byteStart: wordByteStart,
                        byteEnd: byteOffsets[k],
                        callback: callback,
                        context: context
                    )
                    wordScalars.removeAll(keepingCapacity: true)
                    guard rc == SQLITE_OK else { return rc }
                }
            }
        }

        // flush 末尾剩余的 word
        if !wordScalars.isEmpty {
            return emitWordToken(
                wordScalars,
                byteStart: wordByteStart,
                byteEnd: byteOffsets[end],
                callback: callback,
                context: context
            )
        }

        return SQLITE_OK
    }

    /// 将一个非 CJK word（scalar 数组）发出为单个 FTS5 token。
    private func emitWordToken(
        _ wordScalars: [Unicode.Scalar],
        byteStart: Int,
        byteEnd: Int,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let raw = String(String.UnicodeScalarView(wordScalars))
        let token = options.caseFolding ? raw.lowercased() : raw
        return emitString(
            token,
            iStart: byteStart,
            iEnd: byteEnd,
            flags: 0,
            callback: callback,
            context: context
        )
    }

    // MARK: 底层：调用 FTS5 tokenCallback

    /// 将一个 token 字符串通过 FTS5 回调发出。
    ///
    /// - Parameters:
    ///   - string:  token 字符串（UTF-8）
    ///   - iStart:  该 token 在原始输入文本中的 UTF-8 起始字节偏移（用于高亮/片段）
    ///   - iEnd:    该 token 在原始输入文本中的 UTF-8 结束字节偏移（exclusive）
    ///   - flags:   `0` 表示新位置；`FTS5_TOKEN_COLOCATED` 表示与上一 token 同位置
    @inline(__always)
    private func emitString(
        _ string: String,
        iStart: Int,
        iEnd: Int,
        flags: CInt,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        // 使用 ContiguousArray<UInt8> 以避免 withCString 对 NUL 结尾的隐式假设，
        // 并通过 utf8.count 得到正确的字节长度（lowercased() 后长度可能变化）。
        let utf8 = Array(string.utf8)
        return utf8.withUnsafeBytes { buf in
            buf.withMemoryRebound(to: CChar.self) { cBuf in
                callback(context, flags, cBuf.baseAddress, CInt(utf8.count), CInt(iStart), CInt(iEnd))
            }
        }
    }
}
