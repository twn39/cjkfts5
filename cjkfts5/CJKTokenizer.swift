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
// ## 性能架构（零拷贝直通设计）
//
// 直接操作 SQLite 传入的 pText 原始 UTF-8 字节，避免任何中间拷贝：
//
// 1. 入口层：跳过 Data+String 构造，以 UnsafeRawBufferPointer 直接引用 pText
// 2. 迭代层：leading-byte UTF-8 解码，流式维护 bytePos，无全量数组分配
// 3. CJK 发射层：直接传 pText 子指针给 xToken 回调（零拷贝，零分配）
// 4. 非CJK ASCII 路径：栈上缓冲区大小写折叠（零堆分配）
// 5. 非CJK Unicode 路径：withCString（1次分配/词，较之前减少1次）
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
    /// 零拷贝设计：直接将 pText 作为 UnsafeRawBufferPointer 引用，
    /// 不构造任何中间 Data/String/Array，CJK token 直接以子指针发出。
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

        // 将 pText 重解释为字节缓冲区，零拷贝，零分配
        // pText 在整个 xTokenize 调用期间由 SQLite 保证有效
        let byteCount = Int(nText)
        let rawBytes = UnsafeRawBufferPointer(start: pText, count: byteCount)

        // isQuery=true 时（MATCH 查询分词），末字不作为新位置独立 token 发出，
        // 以避免产生多余的 implicit AND 约束破坏 bigram 命中。
        let isQuery = tokenization.contains(.query)
        return tokenizeBytes(
            rawBytes,
            pText: pText,
            isQuery: isQuery,
            callback: tokenCallback,
            context: context
        )
    }

    // MARK: 内部：主分词流程（零拷贝）

    /// 直接在原始 UTF-8 字节上迭代，流式维护字节位置，无全量数组分配。
    ///
    /// - Parameter pText: 原始 C 指针，用于 CJK token 发射时的子指针计算
    /// - Parameter isQuery: `true` 表示此次为 MATCH 查询分词，末字不额外占用新 FTS5 位置
    private func tokenizeBytes(
        _ bytes: UnsafeRawBufferPointer,
        pText: UnsafePointer<CChar>,
        isQuery: Bool,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        guard !bytes.isEmpty else { return SQLITE_OK }

        var bytePos = 0

        // 非 CJK 段累积：记录段的字节起止和 scalar 序列
        var nonCJKByteStart = 0
        var nonCJKScalars = ContiguousArray<Unicode.Scalar>()
        nonCJKScalars.reserveCapacity(64)

        // CJK 段：记录每个 scalar 的起始字节偏移（段内局部数组，较小）
        var cjkByteStarts = ContiguousArray<Int>()
        cjkByteStarts.reserveCapacity(128)

        while bytePos < bytes.count {
            guard let (scalar, scalarLen) = CJKUnicode.decodeScalar(bytes, at: bytePos) else {
                // 无效 UTF-8 字节：跳过，视作分隔符
                if !nonCJKScalars.isEmpty {
                    let rc = flushNonCJK(
                        scalars: nonCJKScalars,
                        byteStart: nonCJKByteStart,
                        byteEnd: bytePos,
                        pText: pText,
                        callback: callback,
                        context: context
                    )
                    nonCJKScalars.removeAll(keepingCapacity: true)
                    guard rc == SQLITE_OK else { return rc }
                }
                bytePos += 1
                continue
            }

            if CJKUnicode.isCJK(scalar) {
                // ── 进入 CJK 字符 ────────────────────────────────────────────

                // 先 flush 已积累的非 CJK 段
                if !nonCJKScalars.isEmpty {
                    let rc = flushNonCJK(
                        scalars: nonCJKScalars,
                        byteStart: nonCJKByteStart,
                        byteEnd: bytePos,
                        pText: pText,
                        callback: callback,
                        context: context
                    )
                    nonCJKScalars.removeAll(keepingCapacity: true)
                    guard rc == SQLITE_OK else { return rc }
                }

                // 收集连续 CJK 段
                cjkByteStarts.removeAll(keepingCapacity: true)
                var curPos = bytePos
                while curPos < bytes.count,
                      let (s, sLen) = CJKUnicode.decodeScalar(bytes, at: curPos),
                      CJKUnicode.isCJK(s) {
                    cjkByteStarts.append(curPos)
                    curPos += sLen
                }
                // curPos 现在指向段结尾（下一个非 CJK 字节）

                // 发出 CJK 段（直接用 pText 子指针，零拷贝）
                let rc = emitCJKSegment(
                    byteStarts: cjkByteStarts,
                    segByteEnd: curPos,
                    pText: pText,
                    isQuery: isQuery,
                    callback: callback,
                    context: context
                )
                guard rc == SQLITE_OK else { return rc }

                bytePos = curPos

            } else {
                // ── 非 CJK 字符 ──────────────────────────────────────────────
                if nonCJKScalars.isEmpty { nonCJKByteStart = bytePos }
                nonCJKScalars.append(scalar)
                bytePos += scalarLen
            }
        }

        // flush 末尾剩余的非 CJK 段
        if !nonCJKScalars.isEmpty {
            let rc = flushNonCJK(
                scalars: nonCJKScalars,
                byteStart: nonCJKByteStart,
                byteEnd: bytePos,
                pText: pText,
                callback: callback,
                context: context
            )
            guard rc == SQLITE_OK else { return rc }
        }

        return SQLITE_OK
    }

    // MARK: 内部：CJK 段处理 — 零拷贝 Bigram + Unigram

    /// 对一个 CJK 段发出 bigram（主）+ unigram（co-located）token。
    ///
    /// 所有 token 均以 `pText` 子指针直接传给回调，**零拷贝，零分配**。
    ///
    /// - Parameter byteStarts: 段内每个 scalar 的字节起始偏移（ContiguousArray）
    /// - Parameter segByteEnd: 段末尾的字节偏移（最后一个 scalar 结束后）
    /// - Parameter pText:      原始 UTF-8 字节指针（xTokenize 期间始终有效）
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
        byteStarts: ContiguousArray<Int>,
        segByteEnd: Int,
        pText: UnsafePointer<CChar>,
        isQuery: Bool,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let count = byteStarts.count
        guard count > 0 else { return SQLITE_OK }

        if count == 1 {
            // 单个 CJK 字符：直接发出 unigram（主 token，新位置），零拷贝
            return emitRaw(
                pText: pText,
                byteStart: byteStarts[0],
                byteEnd: segByteEnd,
                flags: 0,
                callback: callback,
                context: context
            )
        }

        // 多个 CJK 字符：发出 bigram 序列
        for k in 0..<count {
            let hasNext = (k + 1 < count)

            if hasNext {
                // ── 主 token：bigram（占据新的 FTS5 位置），零拷贝 ────────────
                // bigram 字节范围：byteStarts[k] ..< byteStarts[k+2]（或 segByteEnd）
                let bigramEnd = (k + 2 < count) ? byteStarts[k + 2] : segByteEnd
                let rc = emitRaw(
                    pText: pText,
                    byteStart: byteStarts[k],
                    byteEnd: bigramEnd,
                    flags: 0,
                    callback: callback,
                    context: context
                )
                guard rc == SQLITE_OK else { return rc }

                // ── co-located：当前字 unigram（与上方 bigram 同位置），零拷贝 ──
                // 仅在文档索引模式下发出：query 模式下不发出任何 unigram（包括 co-located），
                // 否则 FTS5 会把 co-located 当作 bigram 的 synonym 查询，
                // 导致 "北清" 命中任何含 "北" 的文档（假阳性）。
                if options.emitUnigrams && !isQuery {
                    let rc2 = emitRaw(
                        pText: pText,
                        byteStart: byteStarts[k],
                        byteEnd: byteStarts[k + 1],
                        flags: FTS5_TOKEN_COLOCATED,
                        callback: callback,
                        context: context
                    )
                    guard rc2 == SQLITE_OK else { return rc2 }
                }

                // ── query 模式：末字直接跳过（不发出任何 token）────────────────
                // 末字在 query 模式下既不能作为新位置（会产生 AND 约束），
                // 也不能作为 co-located（会产生 synonym 误命中）。直接跳过。

            } else {
                // ── 最后一个字符（文档索引模式）：单独发出 unigram（新位置），零拷贝 ──
                // query 模式下已在上一轮迭代的 bigram co-located 处处理，此处跳过。
                if !isQuery {
                    let rc = emitRaw(
                        pText: pText,
                        byteStart: byteStarts[k],
                        byteEnd: segByteEnd,
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

    /// 对非 CJK 字符段进行分词：按非词字符切分，可选小写折叠后发出。
    ///
    /// 各路径内存策略（详见 `emitWordToken`）：
    /// - `caseFolding=false`：零拷贝，直传 pText 子指针（零分配）
    /// - `caseFolding=true`，纯 ASCII 全小写：零拷贝，直传 pText 子指针（零分配）
    /// - `caseFolding=true`，纯 ASCII 含大写：`withUnsafeTemporaryAllocation`，优先栈分配
    /// - `caseFolding=true`，含非 ASCII Unicode：`lowercased()` + `withCString`（1次分配/词）
    private func flushNonCJK(
        scalars: ContiguousArray<Unicode.Scalar>,
        byteStart: Int,
        byteEnd: Int,
        pText: UnsafePointer<CChar>,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        // 用字节偏移追踪当前词的起止
        var wordByteStart = byteStart
        var wordByteEnd = byteStart
        // 当前词的 scalar 序列（用于 Unicode 大小写折叠路径）
        var wordScalars = ContiguousArray<Unicode.Scalar>()
        wordScalars.reserveCapacity(32)
        var inWord = false

        // 重新扫描 scalars，同步计算字节偏移
        var curByte = byteStart
        for scalar in scalars {
            // scalar 字节长：直接由 scalar.value 范围决定，无需访问原始字节
            let sLen: Int
            switch scalar.value {
            case 0x0000...0x007F: sLen = 1
            case 0x0080...0x07FF: sLen = 2
            case 0x0800...0xFFFF: sLen = 3
            default:              sLen = 4
            }

            if CJKUnicode.isWordChar(scalar) {
                if !inWord {
                    wordByteStart = curByte
                    wordScalars.removeAll(keepingCapacity: true)
                    inWord = true
                }
                wordScalars.append(scalar)
                wordByteEnd = curByte + sLen
            } else {
                // 分隔符：flush 当前词
                if inWord {
                    let rc = emitWordToken(
                        scalars: wordScalars,
                        byteStart: wordByteStart,
                        byteEnd: wordByteEnd,
                        pText: pText,
                        callback: callback,
                        context: context
                    )
                    inWord = false
                    guard rc == SQLITE_OK else { return rc }
                }
            }
            curByte += sLen
        }

        // flush 末尾剩余的词
        if inWord {
            return emitWordToken(
                scalars: wordScalars,
                byteStart: wordByteStart,
                byteEnd: wordByteEnd,
                pText: pText,
                callback: callback,
                context: context
            )
        }

        return SQLITE_OK
    }

    /// 将一个非 CJK word 发出为单个 FTS5 token。
    ///
    /// **内存策略（按路径）：**
    /// - `caseFolding=false`：零拷贝，直传 pText 子指针（零分配）
    /// - 纯 ASCII，全小写：零拷贝，直传 pText 子指针（零分配）
    /// - 纯 ASCII，含大写：`withUnsafeTemporaryAllocation`，优先栈分配，无 memset
    /// - 含非 ASCII Unicode：`lowercased()` + `withCString`（1 次堆分配/词，不可避免）
    ///
    /// **核心洞察：**
    /// - ASCII 每字符恰好 1 字节，故 `wordLen == scalars.count` ⟺ 纯 ASCII（O(1) 检测）
    /// - 对纯 ASCII 词，`pText[byteStart + i]` 的字节值等于 `scalars[i].value`，
    ///   因此可完全绕过 scalars，直接操作 pText 原始字节，消除多余的「字节→标量→字节」往返。
    private func emitWordToken(
        scalars: ContiguousArray<Unicode.Scalar>,
        byteStart: Int,
        byteEnd: Int,
        pText: UnsafePointer<CChar>,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        guard !scalars.isEmpty else { return SQLITE_OK }

        // 路径 1：无大小写折叠 → 直传 pText 子指针，零分配、零拷贝
        if !options.caseFolding {
            return emitRaw(
                pText: pText,
                byteStart: byteStart,
                byteEnd: byteEnd,
                flags: 0,
                callback: callback,
                context: context
            )
        }

        let wordLen = byteEnd - byteStart

        // ── ASCII 恒等式：ASCII 每字符恰好 1 字节 ────────────────────────────────
        // wordLen == scalars.count  ⟺  所有字符均为 ASCII（O(1)，无需 allSatisfy 遍历）
        // 对纯 ASCII 词，pText 字节值即 scalar value，可完全绕过 scalars 直接操作 pText。
        // ─────────────────────────────────────────────────────────────────────────
        if wordLen == scalars.count {
            // 路径 2：纯 ASCII，直接扫描 pText 字节

            // 步骤 ①：扫描原始字节，检测是否含大写字母（A–Z = 0x41–0x5A）
            var hasUpper = false
            for i in byteStart..<byteEnd {
                if UInt8(bitPattern: pText[i]) >= 0x41 && UInt8(bitPattern: pText[i]) <= 0x5A {
                    hasUpper = true
                    break
                }
            }

            // 步骤 ②a：全小写 → 直传 pText 子指针，零分配、零拷贝
            if !hasUpper {
                return emitRaw(
                    pText: pText,
                    byteStart: byteStart,
                    byteEnd: byteEnd,
                    flags: 0,
                    callback: callback,
                    context: context
                )
            }

            // 步骤 ②b：含大写 → withUnsafeTemporaryAllocation（小容量优先栈分配）
            // 缓冲区未初始化（无 memset），循环写入全部 wordLen 字节后传给回调
            return withUnsafeTemporaryAllocation(of: CChar.self, capacity: wordLen) { buf in
                for i in 0..<wordLen {
                    let b = UInt8(bitPattern: pText[byteStart + i])
                    // A–Z (0x41–0x5A) → a–z：置第 5 位（| 0x20）
                    buf[i] = CChar(bitPattern: (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b)
                }
                return callback(
                    context, 0,
                    buf.baseAddress,
                    CInt(wordLen),
                    CInt(byteStart),
                    CInt(byteEnd)
                )
            }
        }

        // 路径 3：含非 ASCII Unicode → 必须调用 lowercased()（Unicode 折叠规则复杂）
        // withCString 比 Array(string.utf8) 少一次 String 构造，已是该路径最优
        let raw = String(String.UnicodeScalarView(scalars))
        let token = raw.lowercased()
        return token.withCString { cStr in
            callback(
                context, 0,
                cStr,
                CInt(token.utf8.count),
                CInt(byteStart),
                CInt(byteEnd)
            )
        }
    }

    // MARK: 底层：零拷贝 token 发射

    /// 将 `pText[byteStart..<byteEnd]` 直接作为 token 传给 FTS5 回调。
    ///
    /// **零拷贝，零分配**：直接传 pText 的子指针。
    /// SQLite 保证 `pToken` 只需在 `xToken` 返回前有效，而 `pText` 在整个
    /// `xTokenize` 调用期间有效，因此此操作完全合规。
    ///
    /// - Parameters:
    ///   - pText:     原始 UTF-8 字节指针（由 SQLite 在 xTokenize 调用期间管理）
    ///   - byteStart: token 在 pText 中的起始字节偏移
    ///   - byteEnd:   token 在 pText 中的结束字节偏移（exclusive）
    ///   - flags:     `0` 表示新位置；`FTS5_TOKEN_COLOCATED` 表示与上一 token 同位置
    @inline(__always)
    private func emitRaw(
        pText: UnsafePointer<CChar>,
        byteStart: Int,
        byteEnd: Int,
        flags: CInt,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        return callback(
            context,
            flags,
            pText.advanced(by: byteStart),
            CInt(byteEnd - byteStart),
            CInt(byteStart),
            CInt(byteEnd)
        )
    }
}
