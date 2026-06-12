// CJKUnicodeHelper.swift
// cjkfts5
//
// CJK Unicode 范围判断与 UTF-8 零拷贝工具

import Foundation

// MARK: - CJK Unicode 范围判断

/// CJK 字符判断工具命名空间
enum CJKUnicode {

    // MARK: 是否是 CJK 字符

    /// 判断一个 Unicode scalar 是否属于 CJK 表意文字、假名或韩文范围。
    ///
    /// 覆盖范围（按 Unicode 15.1 标准，共约 107,200+ 字符）：
    ///
    /// **CJK 统一汉字（BMP + TIP）：**
    /// - `U+4E00–U+9FFF`     CJK 统一汉字（~20,992字，中文/日文汉字，最常用）
    /// - `U+3400–U+4DBF`     CJK 扩展 A（~6,592字，Unicode 3.0）
    /// - `U+F900–U+FAFF`     CJK 兼容汉字（~512字）
    /// - `U+20000–U+2A6DF`   CJK 扩展 B（~42,720字，Unicode 3.1，生僻字）
    /// - `U+2A700–U+2B73F`   CJK 扩展 C（~4,149字，Unicode 6.0）
    /// - `U+2B740–U+2B81F`   CJK 扩展 D（~222字，Unicode 6.3）
    /// - `U+2B820–U+2CEAF`   CJK 扩展 E（~5,762字，Unicode 8.0）
    /// - `U+2CEB0–U+2EBEF`   CJK 扩展 F（~7,473字，Unicode 10.0）
    /// - `U+2EBF0–U+2EE5F`   CJK 扩展 I（~622字，Unicode 15.1）
    /// - `U+30000–U+3134F`   CJK 扩展 G（~4,939字，Unicode 13.0）
    /// - `U+31350–U+323AF`   CJK 扩展 H（~4,192字，Unicode 15.0）✦ 新增
    ///
    /// **日文假名（BMP）：**
    /// - `U+3040–U+309F`     Hiragana（平假名）
    /// - `U+30A0–U+30FF`     Katakana（片假名）
    /// - `U+31F0–U+31FF`     Katakana Phonetic Extensions（爱努语片假名）
    ///
    /// **日文假名（SMP，历史/扩展字符）：**
    /// - `U+1B000–U+1B0FF`   Katakana Supplement（~256字，Unicode 6.0）✦ 新增
    /// - `U+1AFF0–U+1AFFF`   Kana Extended-B（台湾假名，Unicode 14.0）✦ 新增
    /// - `U+1B100–U+1B12F`   Kana Extended-A（变体假名/Hentaigana，Unicode 10.0）✦ 新增
    /// - `U+1B130–U+1B16F`   Small Kana Extension（小型假名扩展，Unicode 12.0）✦ 新增
    ///
    /// **韩文：**
    /// - `U+AC00–U+D7AF`     Hangul Syllables（韩文音节，~11,172字）
    /// - `U+1100–U+11FF`     Hangul Jamo（韩文字母）
    /// - `U+3130–U+318F`     Hangul Compatibility Jamo（韩文兼容字母）
    @inline(__always)
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value

        // ── 热路径：最高频范围优先，减少分支预测失败 ──────────────────────────
        if v >= 0x4E00  && v <= 0x9FFF { return true }   // CJK 统一汉字（最常用）
        if v >= 0xAC00  && v <= 0xD7AF { return true }   // 韩文音节

        // 平假名 U+3040–U+309F 与片假名 U+30A0–U+30FF 连续，合并为一次判断
        if v >= 0x3040  && v <= 0x30FF { return true }   // 平假名 + 片假名

        // ── 次热路径：BMP 补充范围 ─────────────────────────────────────────
        if v >= 0x3400  && v <= 0x4DBF { return true }   // CJK 扩展 A
        if v >= 0xF900  && v <= 0xFAFF { return true }   // CJK 兼容汉字
        if v >= 0x1100  && v <= 0x11FF { return true }   // 韩文 Jamo
        if v >= 0x3130  && v <= 0x318F { return true }   // 韩文兼容 Jamo
        if v >= 0x31F0  && v <= 0x31FF { return true }   // 片假名扩展（爱努语）

        // ── SMP：日文假名扩展区块 ──────────────────────────────────────────────
        // 注：SMP 字符 UTF-8 编码为 4 字节，在文本中出现频率较低
        // 四个区块在地址空间上不连续，分别检查
        if v >= 0x1AFF0 && v <= 0x1AFFF { return true }   // Kana Extended-B（台湾假名，Unicode 14.0）
        if v >= 0x1B000 && v <= 0x1B16F { return true }   // Katakana Supplement + Kana Ext-A + Small Kana
        //   U+1B000–U+1B0FF  Katakana Supplement（~256字，Unicode 6.0）
        //   U+1B100–U+1B12F  Kana Extended-A（变体假名 Hentaigana，Unicode 10.0）
        //   U+1B130–U+1B16F  Small Kana Extension（小型假名，Unicode 12.0）
        //   三块地址连续，合并为一次区间判断，避免多余分支

        // ── SMP：CJK 扩展 B–I、扩展 G、扩展 H ──────────────────────────────────
        if v >= 0x20000 && v <= 0x2A6DF { return true }   // CJK 扩展 B（Unicode 3.1）
        if v >= 0x2A700 && v <= 0x2B73F { return true }   // CJK 扩展 C（Unicode 6.0）
        if v >= 0x2B740 && v <= 0x2B81F { return true }   // CJK 扩展 D（Unicode 6.3）
        if v >= 0x2B820 && v <= 0x2CEAF { return true }   // CJK 扩展 E（Unicode 8.0）
        if v >= 0x2CEB0 && v <= 0x2EBEF { return true }   // CJK 扩展 F（Unicode 10.0）
        if v >= 0x2EBF0 && v <= 0x2EE5F { return true }   // CJK 扩展 I（Unicode 15.1）
        if v >= 0x30000 && v <= 0x3134F { return true }   // CJK 扩展 G（Unicode 13.0）
        if v >= 0x31350 && v <= 0x323AF { return true }   // CJK 扩展 H（Unicode 15.0）

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

    // MARK: UTF-8 零拷贝工具

    /// 从 UTF-8 leading byte 直接读出该 scalar 的字节长度，O(1)，零分配。
    ///
    /// 对于无效的 continuation byte（0x80–0xBF）或超范围字节，返回 1 以便逐字节跳过。
    @inline(__always)
    static func utf8ScalarLength(leadingByte b: UInt8) -> Int {
        switch b {
        case 0x00...0x7F: return 1   // ASCII（1 字节）
        case 0xC2...0xDF: return 2   // 2 字节序列
        case 0xE0...0xEF: return 3   // 3 字节序列（含全部常用 CJK BMP 字符）
        case 0xF0...0xF4: return 4   // 4 字节序列（SMP，CJK 扩展 B-G）
        default:          return 1   // 无效字节/continuation byte：跳过
        }
    }

    /// 从 `bytes` 的 `offset` 位置解码一个 Unicode scalar，返回 `(scalar, 字节长度)`。
    ///
    /// 严格符合 **RFC 3629 §4** 的合规 UTF-8 解码器。
    /// 对以下所有非法序列均返回 `nil`，调用方应将 `offset` 前进 1 字节后继续：
    ///
    /// - **Overlong 编码**：用多字节表示本可用更短序列表达的码点
    ///   - 2 字节序列：leading byte 0xC0/0xC1 已被 switch 排除（default 分支）
    ///   - 3 字节序列：b0==0xE0 时 b1 必须 ≥ 0xA0（否则 codepoint < U+0800）
    ///   - 4 字节序列：b0==0xF0 时 b1 必须 ≥ 0x90（否则 codepoint < U+10000）
    /// - **UTF-16 代理对**：b0==0xED 时 b1 必须 < 0xA0（否则落入 U+D800–U+DFFF）
    /// - **超 Unicode 上限**：b0==0xF4 时 b1 必须 ≤ 0x8F（否则 codepoint > U+10FFFF）
    /// - **截断序列**：字节数不足时
    /// - **无效 continuation byte**：非 0x80–0xBF
    ///
    /// **验证策略**：对四个特殊 leading byte（0xE0 / 0xED / 0xF0 / 0xF4）在
    /// *读取* continuation byte 时直接应用区间约束，而非解码后再做 value 范围检查。
    /// 这样可以在字节层面彻底拒绝非法序列，避免任何中间值被误处理。
    ///
    /// RFC 3629 §4 合规约束速查表：
    ///
    /// ```
    /// Leading Byte │ b1 合法区间   │ 原因
    /// ─────────────┼──────────────┼──────────────────────────────────────────
    /// 0xE0         │ 0xA0–0xBF    │ 防止 Overlong（< U+0800 应用 2 字节表达）
    /// 0xED         │ 0x80–0x9F    │ 防止代理对 U+D800–U+DFFF
    /// 0xF0         │ 0x90–0xBF    │ 防止 Overlong（< U+10000 应用 3 字节表达）
    /// 0xF4         │ 0x80–0x8F    │ 防止超 U+10FFFF（Unicode 上限）
    /// 其余          │ 0x80–0xBF    │ 标准 continuation byte 范围
    /// ```
    @inline(__always)
    static func decodeScalar(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> (Unicode.Scalar, Int)? {
        guard offset < bytes.count else { return nil }
        let b0 = bytes[offset]

        switch b0 {

        // ── 1 字节：ASCII U+0000–U+007F ──────────────────────────────────────
        case 0x00...0x7F:
            return (Unicode.Scalar(b0), 1)

        // ── 2 字节：U+0080–U+07FF ─────────────────────────────────────────────
        // leading byte 0xC0/0xC1 被 default 分支捕获，此处从 0xC2 开始，
        // 因此 2 字节路径天然排除了所有 Overlong（< U+0080 的码点）。
        case 0xC2...0xDF:
            guard offset + 1 < bytes.count else { return nil }
            let b1 = bytes[offset + 1]
            // b1 必须是合法 continuation byte：10xxxxxx
            guard b1 & 0xC0 == 0x80 else { return nil }
            let v = UInt32(b0 & 0x1F) << 6 | UInt32(b1 & 0x3F)
            // Unicode.Scalar(_:) 对代理对和超范围返回 nil，双重保险
            guard let s = Unicode.Scalar(v) else { return nil }
            return (s, 2)

        // ── 3 字节：U+0800–U+FFFF（BMP，不含代理对）────────────────────────────
        case 0xE0...0xEF:
            guard offset + 2 < bytes.count else { return nil }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]

            // ① b2 必须先验证（避免越界读）
            guard b2 & 0xC0 == 0x80 else { return nil }

            // ② b1 的合法区间取决于 b0：
            switch b0 {
            case 0xE0:
                // b0==E0：b1 必须 ≥ 0xA0，防止 Overlong（U+0000–U+07FF 应使用 ≤2 字节）
                // 合法区间：0xA0–0xBF（RFC 3629 §4 Row 3）
                guard b1 >= 0xA0 && b1 <= 0xBF else { return nil }
            case 0xED:
                // b0==ED：b1 必须 ≤ 0x9F，防止代理对 U+D800–U+DFFF
                // U+D800 → ED A0 80；b1==0xA0 开始即为代理对（RFC 3629 §4 Row 4）
                // 合法区间：0x80–0x9F
                guard b1 >= 0x80 && b1 <= 0x9F else { return nil }
            default:
                // 其余 leading byte（0xE1–0xEC, 0xEE–0xEF）：b1 只需是合法 continuation byte
                guard b1 & 0xC0 == 0x80 else { return nil }
            }

            let v = UInt32(b0 & 0x0F) << 12 | UInt32(b1 & 0x3F) << 6 | UInt32(b2 & 0x3F)
            // 经过上方约束，v 必然在 U+0800–U+FFFF 且不含代理对，
            // Unicode.Scalar(_:) 此时不应失败，但保留作最终防线
            guard let s = Unicode.Scalar(v) else { return nil }
            return (s, 3)

        // ── 4 字节：U+10000–U+10FFFF（SMP）──────────────────────────────────────
        case 0xF0...0xF4:
            guard offset + 3 < bytes.count else { return nil }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            let b3 = bytes[offset + 3]

            // ① b2、b3 先验证
            guard b2 & 0xC0 == 0x80, b3 & 0xC0 == 0x80 else { return nil }

            // ② b1 的合法区间取决于 b0：
            switch b0 {
            case 0xF0:
                // b0==F0：b1 必须 ≥ 0x90，防止 Overlong（U+0000–U+FFFF 应使用 ≤3 字节）
                // U+10000 → F0 90 80 80；b1==0x90 是最低合法值（RFC 3629 §4 Row 5）
                // 合法区间：0x90–0xBF
                guard b1 >= 0x90 && b1 <= 0xBF else { return nil }
            case 0xF4:
                // b0==F4：b1 必须 ≤ 0x8F，防止超出 Unicode 上限 U+10FFFF
                // U+10FFFF → F4 8F BF BF；b1==0x90 起即超出范围（RFC 3629 §4 Row 8）
                // 合法区间：0x80–0x8F
                guard b1 >= 0x80 && b1 <= 0x8F else { return nil }
            default:
                // 0xF1–0xF3：b1 只需是合法 continuation byte
                guard b1 & 0xC0 == 0x80 else { return nil }
            }

            let v = UInt32(b0 & 0x07) << 18 | UInt32(b1 & 0x3F) << 12
                  | UInt32(b2 & 0x3F) << 6  | UInt32(b3 & 0x3F)
            // 经过上方约束，v 必然在 U+10000–U+10FFFF
            guard let s = Unicode.Scalar(v) else { return nil }
            return (s, 4)

        // ── 无效字节 ──────────────────────────────────────────────────────────
        // 0x80–0xBF：孤立的 continuation byte
        // 0xC0–0xC1：Overlong 2 字节序列的 leading byte（< U+0080 应用 1 字节）
        // 0xF5–0xFF：超出 RFC 3629 定义范围
        default:
            return nil
        }
    }

    // MARK: - UInt32 快速重载（热路径优化，避免 Unicode.Scalar 实例化开销）

    /// 基于 UInt32 原始码点直接解码 UTF-8 字节，避免 Unicode.Scalar 实例化校验
    @inline(__always)
    static func decodeCodepoint(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> (UInt32, Int)? {
        guard offset < bytes.count else { return nil }
        let b0 = bytes[offset]

        switch b0 {

        // ── 1 字节：ASCII U+0000–U+007F ──────────────────────────────────────
        case 0x00...0x7F:
            return (UInt32(b0), 1)

        // ── 2 字节：U+0080–U+07FF ─────────────────────────────────────────────
        case 0xC2...0xDF:
            guard offset + 1 < bytes.count else { return nil }
            let b1 = bytes[offset + 1]
            guard b1 & 0xC0 == 0x80 else { return nil }
            let v = UInt32(b0 & 0x1F) << 6 | UInt32(b1 & 0x3F)
            return (v, 2)

        // ── 3 字节：U+0800–U+FFFF ────────────────────────────────────────────
        case 0xE0...0xEF:
            guard offset + 2 < bytes.count else { return nil }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            guard b2 & 0xC0 == 0x80 else { return nil }

            switch b0 {
            case 0xE0:
                guard b1 >= 0xA0 && b1 <= 0xBF else { return nil }
            case 0xED:
                guard b1 >= 0x80 && b1 <= 0x9F else { return nil }
            default:
                guard b1 & 0xC0 == 0x80 else { return nil }
            }

            let v = UInt32(b0 & 0x0F) << 12 | UInt32(b1 & 0x3F) << 6 | UInt32(b2 & 0x3F)
            return (v, 3)

        // ── 4 字节：U+10000–U+10FFFF ──────────────────────────────────────────
        case 0xF0...0xF4:
            guard offset + 3 < bytes.count else { return nil }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            let b3 = bytes[offset + 3]
            guard b2 & 0xC0 == 0x80, b3 & 0xC0 == 0x80 else { return nil }

            switch b0 {
            case 0xF0:
                guard b1 >= 0x90 && b1 <= 0xBF else { return nil }
            case 0xF4:
                guard b1 >= 0x80 && b1 <= 0x8F else { return nil }
            default:
                guard b1 & 0xC0 == 0x80 else { return nil }
            }

            let v = UInt32(b0 & 0x07) << 18 | UInt32(b1 & 0x3F) << 12
                  | UInt32(b2 & 0x3F) << 6  | UInt32(b3 & 0x3F)
            return (v, 4)

        default:
            return nil
        }
    }

    /// 基于 UInt32 码点的 CJK 范围快速判断
    @inline(__always)
    static func isCJKCodepoint(_ v: UInt32) -> Bool {
        // ── 热路径：最高频范围优先 ──────────────────────────────────────────
        if v >= 0x4E00  && v <= 0x9FFF { return true }   // CJK 统一汉字
        if v >= 0xAC00  && v <= 0xD7AF { return true }   // 韩文音节
        if v >= 0x3040  && v <= 0x30FF { return true }   // 平假名 + 片假名

        // ── 次热路径：BMP 补充范围 ─────────────────────────────────────────
        if v >= 0x3400  && v <= 0x4DBF { return true }   // CJK 扩展 A
        if v >= 0xF900  && v <= 0xFAFF { return true }   // CJK 兼容汉字
        if v >= 0x1100  && v <= 0x11FF { return true }   // 韩文 Jamo
        if v >= 0x3130  && v <= 0x318F { return true }   // 韩文兼容 Jamo
        if v >= 0x31F0  && v <= 0x31FF { return true }   // 片假名扩展

        // ── SMP 日文和 CJK 扩展区块 ──────────────────────────────────────────
        if v >= 0x1AFF0 && v <= 0x1AFFF { return true }
        if v >= 0x1B000 && v <= 0x1B16F { return true }
        if v >= 0x20000 && v <= 0x2A6DF { return true }   // CJK 扩展 B
        if v >= 0x2A700 && v <= 0x2B73F { return true }   // CJK 扩展 C
        if v >= 0x2B740 && v <= 0x2B81F { return true }   // CJK 扩展 D
        if v >= 0x2B820 && v <= 0x2CEAF { return true }   // CJK 扩展 E
        if v >= 0x2CEB0 && v <= 0x2EBEF { return true }   // CJK 扩展 F
        if v >= 0x2EBF0 && v <= 0x2EE5F { return true }   // CJK 扩展 I
        if v >= 0x30000 && v <= 0x3134F { return true }   // CJK 扩展 G
        if v >= 0x31350 && v <= 0x323AF { return true }   // CJK 扩展 H

        return false
    }

    /// 基于 UInt32 码点的词字符判断（热路径 ASCII 快速通过）
    @inline(__always)
    static func isWordCodepoint(_ v: UInt32) -> Bool {
        if v <= 127 {
            // ASCII 字母: a-z, A-Z
            if (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) { return true }
            // ASCII 数字: 0-9
            if v >= 0x30 && v <= 0x39 { return true }
            return false
        }
        // 全角数字０–９
        if v >= 0xFF10 && v <= 0xFF19 { return true }
        // 非 ASCII 且非常用 CJK 字符时，安全转换为 Scalar 检查 properties.isAlphabetic
        guard let s = Unicode.Scalar(v) else { return false }
        return s.properties.isAlphabetic
    }

    // MARK: - 片假名全半角折叠静态表与折叠方法

    private static let katakanaFoldTable: [UInt32] = [
        0x3002, 0x300C, 0x300D, 0x3001, 0x30FB, 0x30F2, 0x30A1, 0x30A3, // FF61 - FF68
        0x30A5, 0x30A7, 0x30A9, 0x30E3, 0x30E5, 0x30E7, 0x30C3, 0x30FC, // FF69 - FF70
        0x30A2, 0x30A4, 0x30A6, 0x30A8, 0x30AA, 0x30AB, 0x30AD, 0x30AF, // FF71 - FF78
        0x30B1, 0x30B3, 0x30B5, 0x30B7, 0x30B9, 0x30BB, 0x30BD, 0x30BF, // FF79 - FF80
        0x30C1, 0x30C4, 0x30C6, 0x30C8, 0x30CA, 0x30CB, 0x30CC, 0x30CD, // FF81 - FF88
        0x30CE, 0x30CF, 0x30D2, 0x30D5, 0x30D8, 0x30DB, 0x30DE, 0x30DF, // FF89 - FF96
        0x30E0, 0x30E1, 0x30E2, 0x30E4, 0x30E6, 0x30E8, 0x30E9, 0x30EA, // FF97 - FF9E
        0x30EB, 0x30EC, 0x30ED, 0x30EF, 0x30F3, 0x309B, 0x309C          // FF99 - FF9F
    ]

    /// 基于 UInt32 码点进行全半角折叠（全角 ASCII -> 半角，半角片假名 -> 全角）
    @inline(__always)
    static func foldWidth(_ v: UInt32) -> UInt32 {
        // 1. 全角 ASCII (U+FF01-U+FF5E) -> 半角 ASCII (U+0021-U+007E)
        if v >= 0xFF01 && v <= 0xFF5E {
            return v - 0xFF01 + 0x0021
        }
        // 全角空格 (U+3000) -> 半角空格 (U+0020)
        if v == 0x3000 {
            return 0x0020
        }
        // 2. 半角片假名 (U+FF61-U+FF9F) -> 全角片假名
        if v >= 0xFF61 && v <= 0xFF9F {
            let idx = Int(v - 0xFF61)
            return katakanaFoldTable[idx]
        }
        return v
    }

    /// 判断字符是否是半角片假名或需要折叠的片假名符号
    @inline(__always)
    static func isHalfWidthKatakana(_ v: UInt32) -> Bool {
        return v >= 0xFF61 && v <= 0xFF9F
    }
}
