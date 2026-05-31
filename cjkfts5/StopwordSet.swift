// StopwordSet.swift
// cjkfts5
//
// 停用词检索容器（扁平连续内存与二分查找方案）

import Foundation

/// 高性能的停用词容器
///
/// 内部采用一整块连续字节排铺存储所有已规范化停用词的 UTF-8 字节，
/// 并通过有序的偏移量范围结构体数组进行零堆内存分配的二分查找检索。
public struct StopwordSet: Sendable {
    
    // 区间结构体，替代元组以原生支持 Sendable
    private struct WordRange: Sendable {
        let offset: Int
        let length: Int
    }
    
    // 扁平化的连续字节缓冲区，存储所有停用词的规范化 UTF-8 编码
    private let flatBytes: [UInt8]
    // 指向 flatBytes 中各个停用词偏移量和长度的索引数组，按照字节字典序排序
    private let ranges: [WordRange]

    /// 根据传入的原始停用词集合和分词器选项，进行规范化、去重、排序并扁平化构建容器
    public init(stopwords: Set<String>, options: CJKTokenizerOptions) {
        // 对停用词进行规范化折叠（宽度、大小写、变音符折叠都对齐分词器行为）
        let normalizedWords = stopwords.map { word -> [UInt8] in
            let folded = StopwordSet.normalizeWord(word, options: options)
            return Array(folded.utf8)
        }

        // 去重以减少数据体量
        let uniqueNormalizedWords = Set(normalizedWords)

        // 按照 UTF-8 字节的字典序进行精确排序
        var sortedWords = Array(uniqueNormalizedWords)
        sortedWords.sort { lhs, rhs in
            let minLen = min(lhs.count, rhs.count)
            for i in 0..<minLen {
                if lhs[i] != rhs[i] {
                    return lhs[i] < rhs[i]
                }
            }
            return lhs.count < rhs.count
        }

        // 平铺构建
        var bytes: [UInt8] = []
        var wordRanges: [WordRange] = []
        bytes.reserveCapacity(sortedWords.reduce(0) { $0 + $1.count })
        wordRanges.reserveCapacity(sortedWords.count)

        for word in sortedWords {
            let offset = bytes.count
            bytes.append(contentsOf: word)
            wordRanges.append(WordRange(offset: offset, length: word.count))
        }

        self.flatBytes = bytes
        self.ranges = wordRanges
    }

    /// 高性能、100% 零堆内存分配地检测目标 UTF-8 字节切片是否为停用词
    @inline(__always)
    public func contains(_ target: UnsafeBufferPointer<UInt8>) -> Bool {
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

    /// 针对原始指针的便捷查询包装
    @inline(__always)
    public func contains(_ bytes: UnsafePointer<CChar>, count: Int) -> Bool {
        return bytes.withMemoryRebound(to: UInt8.self, capacity: count) { ptr in
            let buffer = UnsafeBufferPointer(start: ptr, count: count)
            return contains(buffer)
        }
    }

    /// 针对 UInt8 原始指针的便捷查询包装
    @inline(__always)
    public func contains(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        let buffer = UnsafeBufferPointer(start: bytes, count: count)
        return contains(buffer)
    }

    // MARK: - 内部辅助方法

    /// 规范化非 CJK 单词。该方法的折叠逻辑必须与分词器 emit 逻辑 100% 保持一致。
    public static func normalizeWord(_ word: String, options: CJKTokenizerOptions) -> String {
        var token = word
        if options.widthFolding {
            token = token.precomposedStringWithCompatibilityMapping
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
