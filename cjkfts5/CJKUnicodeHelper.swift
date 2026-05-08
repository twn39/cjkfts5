// CJKUnicodeHelper.swift
// cjkfts5
//
// CJK Unicode 范围判断与字节偏移工具

import Foundation

// MARK: - CJK Unicode 范围判断

/// CJK 字符判断工具命名空间
enum CJKUnicode {

    // MARK: 是否是 CJK 字符

    /// 判断一个 Unicode scalar 是否属于 CJK 表意文字或 CJK 注音字母范围。
    ///
    /// 覆盖范围：
    /// - `U+4E00–U+9FFF`   CJK 统一汉字（中文、日文汉字，最常用）
    /// - `U+3400–U+4DBF`   CJK 统一汉字扩展 A
    /// - `U+20000–U+2A6DF` CJK 统一汉字扩展 B（生僻字）
    /// - `U+F900–U+FAFF`   CJK 兼容汉字
    /// - `U+3040–U+309F`   Hiragana（日文平假名）
    /// - `U+30A0–U+30FF`   Katakana（日文片假名）
    /// - `U+AC00–U+D7AF`   Hangul Syllables（韩文音节）
    @inline(__always)
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // 热路径：最高频范围优先判断，减少分支预测失败
        if v >= 0x4E00 && v <= 0x9FFF { return true }   // CJK 统一汉字（最常用）
        if v >= 0xAC00 && v <= 0xD7AF { return true }   // 韩文音节
        if v >= 0x3040 && v <= 0x30FF { return true }   // 平/片假名（连续范围合并判断）
        if v >= 0x3400 && v <= 0x4DBF { return true }   // CJK 扩展 A
        if v >= 0xF900 && v <= 0xFAFF { return true }   // CJK 兼容汉字
        if v >= 0x20000 && v <= 0x2A6DF { return true } // CJK 扩展 B
        return false
    }

    // MARK: 是否是词字符（用于非 CJK 段的 word splitting）

    /// 判断是否是"词字符"（字母或数字），用于非 CJK 段的 token 切分。
    ///
    /// 注意：使用 `Unicode.Scalar.Properties.isAlphabetic` 而非 ASCII 检查，
    /// 支持 Latin、Cyrillic、Arabic 等多种拉丁扩展字符（ü, é, Ñ 等）。
    @inline(__always)
    static func isWordChar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isAlphabetic { return true }
        let v = scalar.value
        // ASCII 数字 0–9
        if v >= 0x0030 && v <= 0x0039 { return true }
        // 全角数字０–９
        if v >= 0xFF10 && v <= 0xFF19 { return true }
        return false
    }

    // MARK: 字节偏移计算

    /// 预计算 Unicode.Scalar 数组中每个字符的 UTF-8 起始字节偏移。
    ///
    /// 返回长度为 `scalars.count + 1` 的数组：
    /// - `offsets[i]`   = 第 i 个 scalar 的 UTF-8 起始字节偏移
    /// - `offsets[n]`   = 整个字符串的总 UTF-8 字节长度
    ///
    /// - Complexity: O(n)，避免在内层循环重复计算偏移
    static func computeByteOffsets(of scalars: [Unicode.Scalar]) -> [Int] {
        var offsets = [Int](repeating: 0, count: scalars.count + 1)
        var pos = 0
        for (i, scalar) in scalars.enumerated() {
            offsets[i] = pos
            pos += scalar.utf8.count
        }
        offsets[scalars.count] = pos
        return offsets
    }
}
