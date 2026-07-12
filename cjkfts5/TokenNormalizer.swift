// TokenNormalizer.swift
// cjkfts5
//
// 分词发射与停用词建表共用的规范化入口（单一事实来源）

import Foundation

/// 将折叠/规范化策略集中在一处，保证：
/// - 非 CJK token 发射
/// - 停用词集合构建
/// - CJK 码点宽度折叠（含半角浊点合成）
/// 三者语义一致。
enum TokenNormalizer {

    // MARK: - Latin / 通用词规范化

    /// 规范化完整词字符串（用于非 CJK emit 与停用词建表）。
    ///
    /// 顺序：
    /// 1. 可选：按码点 `foldWidth`（与 CJK 热路径同一张表）
    /// 2. 可选：NFKC 兼容分解（处理连字等 foldWidth 未覆盖的兼容形态）
    /// 3. 可选：变音符 / 大小写折叠（`String.folding`）
    @inline(__always)
    static func normalizeWord(_ word: String, options: CJKTokenizerOptions) -> String {
        var token = word

        if options.widthFolding {
            token = foldWidthString(token)
            // foldWidth 已处理全角 ASCII / 半角片假名；NFKC 覆盖其余兼容字符
            let nfkc = token.precomposedStringWithCompatibilityMapping
            if nfkc != token {
                token = nfkc
            }
        }

        var compareOptions: String.CompareOptions = []
        if options.diacriticFolding {
            compareOptions.insert(.diacriticInsensitive)
        }
        if options.caseFolding {
            compareOptions.insert(.caseInsensitive)
        }
        if !compareOptions.isEmpty {
            token = token.folding(options: compareOptions, locale: nil)
        }
        return token
    }

    /// 对字符串逐码点应用 `CJKUnicode.foldWidth`。
    @inline(__always)
    static func foldWidthString(_ string: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(string.unicodeScalars.count)
        for s in string.unicodeScalars {
            let folded = CJKUnicode.foldWidth(s.value)
            if let us = Unicode.Scalar(folded) {
                scalars.append(us)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: - CJK 码点折叠（含半角浊点）

    /// 在 `bytes[offset]` 处解码一个 scalar，并按选项做宽度折叠；
    /// 若启用宽度折叠且为「半角片假名 + 半角浊点/半浊点」，则合成单个全角浊音/半浊音码点。
    ///
    /// - Returns: `(foldedCp, originalFirstCp, consumedBytes)`；解码失败返回 `nil`。
    @inline(__always)
    static func decodeFoldedCodepoint(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        widthFolding: Bool
    ) -> (folded: UInt32, original: UInt32, consumed: Int)? {
        guard let (codepoint, len) = CJKUnicode.decodeCodepoint(bytes, at: offset) else {
            return nil
        }

        guard widthFolding else {
            return (codepoint, codepoint, len)
        }

        // 半角片假名基字 + 后随半角浊点 (FF9E) / 半浊点 (FF9F)
        if CJKUnicode.isHalfWidthKatakanaBase(codepoint),
           offset + len < bytes.count,
           let (mark, markLen) = CJKUnicode.decodeCodepoint(bytes, at: offset + len),
           (mark == 0xFF9E || mark == 0xFF9F),
           let composed = CJKUnicode.composeHalfwidthKatakana(base: codepoint, mark: mark) {
            return (composed, codepoint, len + markLen)
        }

        let folded = CJKUnicode.foldWidth(codepoint)
        return (folded, codepoint, len)
    }
}
