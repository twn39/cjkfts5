// StopwordSet.swift
// cjkfts5
//
// 停用词检索容器：单码点 O(1) + 多字节二分查找

import Foundation

/// 高性能的停用词容器
///
/// 规范化后的词按形态分流：
/// - **单 Unicode 码点**（常见中文停用词）：`Set<UInt32>` 常数时间查询，避免每次 UTF-8 编码 + 二分
/// - **多码点词**（英文停用词、多字中文）：扁平 UTF-8 字节 + 有序区间二分
///
/// 另缓存 `hasNonASCIIMultiByte`：当多码点表中不存在非 ASCII 词时，CJK bigram 停用检查可直接短路
///（`cjkCommon` 预设下英文表不会误伤 CJK bigram 热路径）。
public struct StopwordSet: Sendable {

    private struct WordRange: Sendable {
        let offset: Int
        let length: Int
    }

    /// 规范化后恰好一个 Unicode scalar 的停用词码点
    private let singleCodepoints: Set<UInt32>
    /// 多码点词的扁平 UTF-8
    private let flatBytes: [UInt8]
    private let ranges: [WordRange]
    /// 多码点表中是否存在任一非 ASCII 字节（用于 CJK bigram 短路）
    private let hasNonASCIIMultiByte: Bool

    /// 根据传入的原始停用词集合和分词器选项，进行规范化、去重并构建容器
    public init(stopwords: Set<String>, options: CJKTokenizerOptions) {
        var singles: Set<UInt32> = []
        var multiByteWords: [[UInt8]] = []
        singles.reserveCapacity(stopwords.count)
        multiByteWords.reserveCapacity(stopwords.count)

        for word in stopwords {
            let folded = TokenNormalizer.normalizeWord(word, options: options)
            var scalars = folded.unicodeScalars.makeIterator()
            guard let first = scalars.next() else { continue }
            if scalars.next() == nil {
                singles.insert(first.value)
            } else {
                multiByteWords.append(Array(folded.utf8))
            }
        }

        // 多码点词去重 + 字节序排序
        let uniqueMulti = Array(Set(multiByteWords)).sorted { lhs, rhs in
            let minLen = min(lhs.count, rhs.count)
            for i in 0..<minLen {
                if lhs[i] != rhs[i] {
                    return lhs[i] < rhs[i]
                }
            }
            return lhs.count < rhs.count
        }

        var bytes: [UInt8] = []
        var wordRanges: [WordRange] = []
        bytes.reserveCapacity(uniqueMulti.reduce(0) { $0 + $1.count })
        wordRanges.reserveCapacity(uniqueMulti.count)

        var nonASCII = false
        for word in uniqueMulti {
            if !nonASCII, word.contains(where: { $0 > 127 }) {
                nonASCII = true
            }
            let offset = bytes.count
            bytes.append(contentsOf: word)
            wordRanges.append(WordRange(offset: offset, length: word.count))
        }

        self.singleCodepoints = singles
        self.flatBytes = bytes
        self.ranges = wordRanges
        self.hasNonASCIIMultiByte = nonASCII
    }

    /// 是否存在任何停用词（单码点或多码点）
    public var isEmpty: Bool {
        singleCodepoints.isEmpty && ranges.isEmpty
    }

    /// 多码点停用词表中是否含非 ASCII（CJK bigram 探测前可短路）
    @inline(__always)
    public var mayContainCJKMultiCodepointStopwords: Bool {
        hasNonASCIIMultiByte
    }

    /// 单码点停用词 O(1) 查询（CJK unigram 热路径）
    @inline(__always)
    public func containsCodepoint(_ codepoint: UInt32) -> Bool {
        singleCodepoints.contains(codepoint)
    }

    /// 高性能、零堆分配地检测目标 UTF-8 字节切片是否为停用词
    @inline(__always)
    public func contains(_ target: UnsafeBufferPointer<UInt8>) -> Bool {
        // 快速路径：解码为单码点时走 Set
        if let cp = decodeSingleCodepoint(target), singleCodepoints.contains(cp) {
            return true
        }
        return multiByteContains(target)
    }

    @inline(__always)
    public func contains(_ bytes: UnsafePointer<CChar>, count: Int) -> Bool {
        bytes.withMemoryRebound(to: UInt8.self, capacity: count) { ptr in
            contains(UnsafeBufferPointer(start: ptr, count: count))
        }
    }

    @inline(__always)
    public func contains(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        contains(UnsafeBufferPointer(start: bytes, count: count))
    }

    /// 规范化非 CJK 单词。委托给 `TokenNormalizer`。
    public static func normalizeWord(_ word: String, options: CJKTokenizerOptions) -> String {
        TokenNormalizer.normalizeWord(word, options: options)
    }

    // MARK: - Internal

    @inline(__always)
    private func multiByteContains(_ target: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !ranges.isEmpty else { return false }
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = ranges[mid]
            let cmp = compare(target: target, offset: range.offset, length: range.length)
            if cmp == 0 {
                return true
            } else if cmp < 0 {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return false
    }

    /// 若 buffer 恰好为一个合法 UTF-8 码点则返回该码点，否则 nil
    @inline(__always)
    private func decodeSingleCodepoint(_ target: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard let first = target.first else { return nil }
        let len: Int
        let cp: UInt32
        if first < 0x80 {
            len = 1
            cp = UInt32(first)
        } else if first < 0xE0 {
            guard target.count >= 2, first >= 0xC2 else { return nil }
            len = 2
            cp = (UInt32(first & 0x1F) << 6) | UInt32(target[1] & 0x3F)
        } else if first < 0xF0 {
            guard target.count >= 3 else { return nil }
            len = 3
            cp = (UInt32(first & 0x0F) << 12)
                | (UInt32(target[1] & 0x3F) << 6)
                | UInt32(target[2] & 0x3F)
        } else if first < 0xF8 {
            guard target.count >= 4 else { return nil }
            len = 4
            cp = (UInt32(first & 0x07) << 18)
                | (UInt32(target[1] & 0x3F) << 12)
                | (UInt32(target[2] & 0x3F) << 6)
                | UInt32(target[3] & 0x3F)
        } else {
            return nil
        }
        guard target.count == len else { return nil }
        return cp
    }

    @inline(__always)
    private func compare(target: UnsafeBufferPointer<UInt8>, offset: Int, length: Int) -> Int {
        let minLen = min(target.count, length)
        for i in 0..<minLen {
            let tByte = target[i]
            let sByte = flatBytes[offset + i]
            if tByte < sByte { return -1 }
            if tByte > sByte { return 1 }
        }
        if target.count < length { return -1 }
        if target.count > length { return 1 }
        return 0
    }
}
