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
// 直接操作 SQLite 传入 of pText 原始 UTF-8 字节，避免任何中间拷贝：
//
// 1. 入口层：跳过 Data+String 构造，以 UnsafeRawBufferPointer 直接引用 pText
// 2. 迭代层：leading-byte UTF-8 解码，流式维护 bytePos，无全量数组分配
// 3. CJK 发射层：使用 3 元素滑动窗口在栈上流式生成并传子指针给 xToken 回调（零拷贝，零分配）。
//    若触发宽度折叠（如半角片假名），则利用栈上临时 Tuple 缓存区进行 UTF-8 字节编码发射，仍保持零堆分配。
// 4. 非CJK ASCII 路径：栈上缓冲区大小写折叠（零堆分配）
// 5. 非CJK Unicode 路径：直接从指针解码构造 String + lowercased（1次堆分配）
//
// ## 线程安全
//
// CJKTokenizer 是无状态 of（所有操作基于函数参数，无共享可变状态），
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
/// config.addCJKTokenizer()
/// let dbQueue = try DatabaseQueue(path: path, configuration: config)
///
/// // 2. 建立 FTS5 虚拟表
/// try dbQueue.write { db in
///     try db.create(virtualTable: "documents", using: FTS5()) { t in
///         t.tokenizer = .cjk()
///         t.column("content")
///     }
/// }
/// ```
public final class CJKTokenizer: FTS5CustomTokenizer {

    // MARK: FTS5CustomTokenizer 必要属性

    /// FTS5 tokenizer 名称，在 CREATE VIRTUAL TABLE 中引用
    public static let name = "cjk"

    // MARK: 配置

    private let options: CJKTokenizerOptions
    private let stopwordSet: StopwordSet?

    // MARK: 初始化

    /// SQLite 实例化 tokenizer 时调用。
    /// `arguments` 来自 `tokenizerDescriptor(options:)` 编码的参数字符串。
    public required init(db: Database, arguments: [String]) throws {
        let opts = CJKTokenizerOptions(arguments: arguments)
        self.options = opts
        if let stopwords = opts.stopwords, !stopwords.isEmpty {
            self.stopwordSet = StopwordSet(stopwords: stopwords, options: opts)
        } else {
            self.stopwordSet = nil
        }
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
    ///   - pText:         待分词 of UTF-8 字节指针（可能不以 `\0` 结尾）
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

        // CJK 滑动窗口状态 (栈上分配)
        var cjk0 = -1
        var cjk1 = -1
        var cjk2 = -1

        // 折叠后的码点 (用于 CJK 位置判定与 Bigram 拼接)
        var cp0: UInt32 = 0
        var cp1: UInt32 = 0
        var cp2: UInt32 = 0

        // 原始解码码点 (用于比对 cp，判断是否发生了折叠，从而选择栈分配发射还是 emitRaw 直发)
        var orig0: UInt32 = 0
        var orig1: UInt32 = 0
        var orig2: UInt32 = 0

        var cjkCount = 0
        var inCJK = false

        // 非 CJK 单词状态 (栈上分配)
        var inWord = false
        var wordStart = 0
        var wordEnd = 0
        var wordIsPureASCII = true

        while bytePos < bytes.count {
            guard let (foldedCp, originalCp, consumed) = TokenNormalizer.decodeFoldedCodepoint(
                bytes,
                at: bytePos,
                widthFolding: options.widthFolding
            ) else {
                // 无效 UTF-8 字节：视作分隔符，先 Flush 已有区间
                if inCJK {
                    let rc = flushCJK(
                        cjkCount: &cjkCount,
                        inCJK: &inCJK,
                        cjk0: cjk0,
                        cjk1: cjk1,
                        cp0: cp0,
                        cp1: cp1,
                        orig0: orig0,
                        orig1: orig1,
                        segEnd: bytePos,
                        pText: pText,
                        isQuery: isQuery,
                        callback: callback,
                        context: context
                    )
                    guard rc == SQLITE_OK else { return rc }
                }
                if inWord {
                    let rc = emitWordToken(byteStart: wordStart, byteEnd: wordEnd, isPureASCII: wordIsPureASCII, pText: pText, callback: callback, context: context)
                    guard rc == SQLITE_OK else { return rc }
                    inWord = false
                }
                bytePos += 1
                continue
            }

            if CJKUnicode.isCJKCodepoint(foldedCp) {
                // ── 进入 CJK 区间 ──────────────────────────────────────────
                if inWord {
                    let rc = emitWordToken(byteStart: wordStart, byteEnd: wordEnd, isPureASCII: wordIsPureASCII, pText: pText, callback: callback, context: context)
                    guard rc == SQLITE_OK else { return rc }
                    inWord = false
                }
                if !inCJK {
                    inCJK = true
                    cjkCount = 0
                }

                // 流式喂入滑动窗口
                if cjkCount == 0 {
                    cjk0 = bytePos
                    cp0 = foldedCp
                    orig0 = originalCp
                    cjkCount = 1
                } else if cjkCount == 1 {
                    cjk1 = bytePos
                    cp1 = foldedCp
                    orig1 = originalCp
                    cjkCount = 2
                } else if cjkCount == 2 {
                    cjk2 = bytePos
                    cp2 = foldedCp
                    orig2 = originalCp
                    cjkCount = 3

                    // 发射当前位置 bigram（+ 可选 colocated unigram / 停用词晋升）
                    // bigram 被过滤时，即使 isQuery 也必须允许 unigram 晋升，保证 phrase 位置对齐
                    let emitUni = (options.emitUnigrams && !isQuery)
                        || (isBigramStopword(cp0: cp0, cp1: cp1) && options.emitUnigrams)
                    let rc = emitCJKPosition(
                        cp0: cp0, cp1: cp1,
                        orig0: orig0, orig1: orig1,
                        byteStart0: cjk0, byteStart1: cjk1, byteEnd: cjk2,
                        emitColocatedUnigram: emitUni,
                        pText: pText,
                        callback: callback,
                        context: context
                    )
                    guard rc == SQLITE_OK else { return rc }

                    // 滑动
                    cjk0 = cjk1
                    cp0 = cp1
                    orig0 = orig1

                    cjk1 = cjk2
                    cp1 = cp2
                    orig1 = orig2

                    cjkCount = 2
                }
            } else {
                // ── 非 CJK 区间 ──────────────────────────────────────────
                if inCJK {
                    let rc = flushCJK(
                        cjkCount: &cjkCount,
                        inCJK: &inCJK,
                        cjk0: cjk0,
                        cjk1: cjk1,
                        cp0: cp0,
                        cp1: cp1,
                        orig0: orig0,
                        orig1: orig1,
                        segEnd: bytePos,
                        pText: pText,
                        isQuery: isQuery,
                        callback: callback,
                        context: context
                    )
                    guard rc == SQLITE_OK else { return rc }
                }

                if CJKUnicode.isWordCodepoint(foldedCp) {
                    if !inWord {
                        inWord = true
                        wordStart = bytePos
                        wordEnd = bytePos + consumed
                        // 原始码点判定 pure ASCII，保证全角字符走 Unicode 规范化路径
                        wordIsPureASCII = (originalCp <= 127)
                    } else {
                        wordEnd = bytePos + consumed
                        if originalCp > 127 {
                            wordIsPureASCII = false
                        }
                    }
                } else {
                    // 遇到空格/标点分隔符
                    if inWord {
                        let rc = emitWordToken(byteStart: wordStart, byteEnd: wordEnd, isPureASCII: wordIsPureASCII, pText: pText, callback: callback, context: context)
                        guard rc == SQLITE_OK else { return rc }
                        inWord = false
                    }
                }
            }
            bytePos += consumed
        }

        // ── 循环结束，Flush 剩余状态 ────────────────────────────────────
        if inCJK {
            let segEnd = bytePos
            let rc = flushCJK(
                cjkCount: &cjkCount,
                inCJK: &inCJK,
                cjk0: cjk0,
                cjk1: cjk1,
                cp0: cp0,
                cp1: cp1,
                orig0: orig0,
                orig1: orig1,
                segEnd: segEnd,
                pText: pText,
                isQuery: isQuery,
                callback: callback,
                context: context
            )
            guard rc == SQLITE_OK else { return rc }
        }
        if inWord {
            let rc = emitWordToken(byteStart: wordStart, byteEnd: wordEnd, isPureASCII: wordIsPureASCII, pText: pText, callback: callback, context: context)
            guard rc == SQLITE_OK else { return rc }
            inWord = false
        }

        return SQLITE_OK
    }

    /// 将一个非 CJK word 发出为单个 FTS5 token。
    ///
    /// **内存策略（按路径）：**
    /// - `caseFolding=false`：零拷贝，直传 pText 子指针（零分配）
    /// - `isPureASCII=true`，全小写：零拷贝，直传 pText 子指针（零分配）
    /// - `isPureASCII=true`，含大写：`withUnsafeTemporaryAllocation`，优先栈分配，无 heap 分配
    /// - `isPureASCII=false`（含非 ASCII）：直接通过 C 指针范围解码为 String + 可选 NFKC 折叠 + `lowercased()` + `withCString`（1 次堆分配）
    private func emitWordToken(
        byteStart: Int,
        byteEnd: Int,
        isPureASCII: Bool,
        pText: UnsafePointer<CChar>,
        callback: @escaping FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let wordLen = byteEnd - byteStart
        guard wordLen > 0 else { return SQLITE_OK }

        // 路径 1：所有折叠选项均禁用 → 直传 pText 子指针，零分配、零拷贝
        if !options.caseFolding && !options.widthFolding && !options.diacriticFolding {
            if let stopwordSet, stopwordSet.contains(pText.advanced(by: byteStart), count: wordLen) {
                return SQLITE_OK
            }
            return emitRaw(
                pText: pText,
                byteStart: byteStart,
                byteEnd: byteEnd,
                flags: 0,
                callback: callback,
                context: context
            )
        }

        if isPureASCII {
            // 路径 2：纯 ASCII，直接扫描 pText 字节
            if !options.caseFolding {
                // 纯 ASCII 且无需大小写折叠时，无须任何宽度或变音符映射，直接传出
                if let stopwordSet, stopwordSet.contains(pText.advanced(by: byteStart), count: wordLen) {
                    return SQLITE_OK
                }
                return emitRaw(
                    pText: pText,
                    byteStart: byteStart,
                    byteEnd: byteEnd,
                    flags: 0,
                    callback: callback,
                    context: context
                )
            }

            var hasUpper = false
            for i in byteStart..<byteEnd {
                if UInt8(bitPattern: pText[i]) >= 0x41 && UInt8(bitPattern: pText[i]) <= 0x5A {
                    hasUpper = true
                    break
                }
            }

            // 步骤 ①：全小写 → 直传 pText 子指针，零分配、零拷贝
            if !hasUpper {
                if let stopwordSet, stopwordSet.contains(pText.advanced(by: byteStart), count: wordLen) {
                    return SQLITE_OK
                }
                return emitRaw(
                    pText: pText,
                    byteStart: byteStart,
                    byteEnd: byteEnd,
                    flags: 0,
                    callback: callback,
                    context: context
                )
            }

            // 步骤 ②：含大写 → withUnsafeTemporaryAllocation（小容量优先栈分配，无 heap 分配）
            return withUnsafeTemporaryAllocation(of: CChar.self, capacity: wordLen) { buf in
                for i in 0..<wordLen {
                    let b = UInt8(bitPattern: pText[byteStart + i])
                    buf[i] = CChar(bitPattern: (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b)
                }
                if let stopwordSet, stopwordSet.contains(buf.baseAddress!, count: wordLen) {
                    return SQLITE_OK
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

        // 路径 3：含非 ASCII Unicode → 解码并根据选项组合折叠与转换（1次堆分配）
        let rawStart = UnsafeRawPointer(pText).advanced(by: byteStart)
        let byteSlice = UnsafeRawBufferPointer(start: rawStart, count: wordLen)
        let raw = String(decoding: byteSlice, as: UTF8.self)

        let token = TokenNormalizer.normalizeWord(raw, options: options)

        if let stopwordSet {
            let isStop = token.utf8.withContiguousStorageIfAvailable { buf in
                stopwordSet.contains(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
            } ?? false
            if isStop {
                return SQLITE_OK
            }
        }

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

    // MARK: 底层：零拷贝 / 栈上临时发射

    /// 将 `pText[byteStart..<byteEnd]` 直接作为 token 传给 FTS5 回调。
    ///
    /// **零拷贝，零分配**：直接传 pText 的子指针。
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

    /// 将两个折叠后的 CJK 码点在栈上编码为 UTF-8 并发射（零堆分配）
    @inline(__always)
    private func emitFoldedBigram(
        cp0: UInt32,
        cp1: UInt32,
        byteStart: Int,
        byteEnd: Int,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        return withUnsafeMutablePointer(to: &buf) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
            let len0 = encodeUTF8(cp0, into: rawPtr)
            let len1 = encodeUTF8(cp1, into: rawPtr.advanced(by: len0))
            let totalLen = len0 + len1
            let cStr = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: CChar.self)
            return callback(context, 0, cStr, CInt(totalLen), CInt(byteStart), CInt(byteEnd))
        }
    }

    /// 将单个折叠后的 CJK 码点在栈上编码为 UTF-8 并发射（零堆分配）
    @inline(__always)
    private func emitFoldedUnigram(
        cp: UInt32,
        flags: CInt,
        byteStart: Int,
        byteEnd: Int,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        return withUnsafeMutablePointer(to: &buf) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
            let totalLen = encodeUTF8(cp, into: rawPtr)
            let cStr = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: CChar.self)
            return callback(context, flags, cStr, CInt(totalLen), CInt(byteStart), CInt(byteEnd))
        }
    }

    /// 在栈上直接将码点编码为 UTF-8
    @inline(__always)
    private func encodeUTF8(_ v: UInt32, into buffer: UnsafeMutablePointer<UInt8>) -> Int {
        if v <= 0x7F {
            buffer[0] = UInt8(v)
            return 1
        } else if v <= 0x7FF {
            buffer[0] = UInt8(0xC0 | (v >> 6))
            buffer[1] = UInt8(0x80 | (v & 0x3F))
            return 2
        } else if v <= 0xFFFF {
            buffer[0] = UInt8(0xE0 | (v >> 12))
            buffer[1] = UInt8(0x80 | ((v >> 6) & 0x3F))
            buffer[2] = UInt8(0x80 | (v & 0x3F))
            return 3
        } else {
            buffer[0] = UInt8(0xF0 | (v >> 18))
            buffer[1] = UInt8(0x80 | ((v >> 12) & 0x3F))
            buffer[2] = UInt8(0x80 | ((v >> 6) & 0x3F))
            buffer[3] = UInt8(0x80 | (v & 0x3F))
            return 4
        }
    }

    // MARK: - CJK 位置发射（主循环与 flush 共用）

    /// 在一个 FTS5 位置上发射 bigram（主 token）及可选 colocated unigram，并处理停用词过滤/晋升。
    ///
    /// - Parameters:
    ///   - byteStart0: 第一字起始字节
    ///   - byteStart1: 第二字起始字节（亦即第一字结束）
    ///   - byteEnd: bigram 结束字节（第二字结束 / 下一字起始）
    ///   - emitColocatedUnigram: 是否尝试发射第一字 unigram（含 query 模式下 bigram 被过滤时的晋升）
    @inline(__always)
    private func emitCJKPosition(
        cp0: UInt32,
        cp1: UInt32,
        orig0: UInt32,
        orig1: UInt32,
        byteStart0: Int,
        byteStart1: Int,
        byteEnd: Int,
        emitColocatedUnigram: Bool,
        pText: UnsafePointer<CChar>,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        let bigramStop = isBigramStopword(cp0: cp0, cp1: cp1)
        let unigramStop = emitColocatedUnigram ? isUnigramStopword(cp: cp0) : true

        if bigramStop && unigramStop {
            return SQLITE_OK
        }

        if bigramStop {
            // Bigram 过滤 → 晋升 Unigram 为主 token（flags=0）
            return emitCJKUnigram(
                cp: cp0, orig: orig0,
                byteStart: byteStart0, byteEnd: byteStart1,
                flags: 0,
                pText: pText, callback: callback, context: context
            )
        }

        if unigramStop {
            // 仅 bigram
            return emitCJKBigram(
                cp0: cp0, cp1: cp1, orig0: orig0, orig1: orig1,
                byteStart: byteStart0, byteEnd: byteEnd,
                pText: pText, callback: callback, context: context
            )
        }

        // bigram + colocated unigram
        let rc1 = emitCJKBigram(
            cp0: cp0, cp1: cp1, orig0: orig0, orig1: orig1,
            byteStart: byteStart0, byteEnd: byteEnd,
            pText: pText, callback: callback, context: context
        )
        guard rc1 == SQLITE_OK else { return rc1 }
        return emitCJKUnigram(
            cp: cp0, orig: orig0,
            byteStart: byteStart0, byteEnd: byteStart1,
            flags: FTS5_TOKEN_COLOCATED,
            pText: pText, callback: callback, context: context
        )
    }

    @inline(__always)
    private func emitCJKBigram(
        cp0: UInt32, cp1: UInt32,
        orig0: UInt32, orig1: UInt32,
        byteStart: Int, byteEnd: Int,
        pText: UnsafePointer<CChar>,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        if orig0 != cp0 || orig1 != cp1 {
            return emitFoldedBigram(cp0: cp0, cp1: cp1, byteStart: byteStart, byteEnd: byteEnd, callback: callback, context: context)
        }
        return callback(context, 0, pText.advanced(by: byteStart), CInt(byteEnd - byteStart), CInt(byteStart), CInt(byteEnd))
    }

    @inline(__always)
    private func emitCJKUnigram(
        cp: UInt32, orig: UInt32,
        byteStart: Int, byteEnd: Int,
        flags: CInt,
        pText: UnsafePointer<CChar>,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        if orig != cp {
            return emitFoldedUnigram(cp: cp, flags: flags, byteStart: byteStart, byteEnd: byteEnd, callback: callback, context: context)
        }
        return callback(context, flags, pText.advanced(by: byteStart), CInt(byteEnd - byteStart), CInt(byteStart), CInt(byteEnd))
    }

    // MARK: - 停用词过滤辅助方法

    @inline(__always)
    private func isUnigramStopword(cp: UInt32) -> Bool {
        // 单码点停用词走 Set O(1)，避免每次 UTF-8 编码 + 全表二分
        stopwordSet?.containsCodepoint(cp) ?? false
    }

    @inline(__always)
    private func isBigramStopword(cp0: UInt32, cp1: UInt32) -> Bool {
        guard let stopwordSet else { return false }
        // cjkCommon 等「英文多码点 + 中文单码点」预设下，多码点表无非 ASCII：
        // CJK bigram 不可能命中，直接短路（显著降低 With Stopwords 热路径开销）
        guard stopwordSet.mayContainCJKMultiCodepointStopwords else { return false }
        var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        return withUnsafeMutablePointer(to: &buf) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
            let len0 = encodeUTF8(cp0, into: rawPtr)
            let len1 = encodeUTF8(cp1, into: rawPtr.advanced(by: len0))
            let totalLen = len0 + len1
            return stopwordSet.contains(UnsafePointer(rawPtr), count: totalLen)
        }
    }

    @inline(__always)
    private func flushCJK(
        cjkCount: inout Int,
        inCJK: inout Bool,
        cjk0: Int,
        cjk1: Int,
        cp0: UInt32,
        cp1: UInt32,
        orig0: UInt32,
        orig1: UInt32,
        segEnd: Int,
        pText: UnsafePointer<CChar>,
        isQuery: Bool,
        callback: FTS5TokenCallback,
        context: UnsafeMutableRawPointer?
    ) -> CInt {
        if cjkCount == 1 {
            if !isUnigramStopword(cp: cp0) {
                let rc = emitCJKUnigram(
                    cp: cp0, orig: orig0,
                    byteStart: cjk0, byteEnd: segEnd,
                    flags: 0,
                    pText: pText, callback: callback, context: context
                )
                guard rc == SQLITE_OK else { return rc }
            }
        } else if cjkCount == 2 {
            let emitUni = options.emitUnigrams && !isQuery
            let rc = emitCJKPosition(
                cp0: cp0, cp1: cp1,
                orig0: orig0, orig1: orig1,
                byteStart0: cjk0, byteStart1: cjk1, byteEnd: segEnd,
                emitColocatedUnigram: emitUni,
                pText: pText,
                callback: callback,
                context: context
            )
            guard rc == SQLITE_OK else { return rc }

            // 文档模式：末字作为独立位置 unigram
            if !isQuery && !isUnigramStopword(cp: cp1) {
                let rc3 = emitCJKUnigram(
                    cp: cp1, orig: orig1,
                    byteStart: cjk1, byteEnd: segEnd,
                    flags: 0,
                    pText: pText, callback: callback, context: context
                )
                guard rc3 == SQLITE_OK else { return rc3 }
            }
        }

        cjkCount = 0
        inCJK = false
        return SQLITE_OK
    }
}
