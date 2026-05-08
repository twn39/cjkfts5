# cjkfts5 — 通用 CJK FTS5 分词库

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%20|%20macOS-blue)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

基于 **Bigram + Unigram 混合策略** 的通用 CJK（中文/日文/韩文）FTS5 分词器，专为 [GRDB](https://github.com/groue/GRDB.swift) 设计。

## 特性

- 🚀 **零依赖** — 纯 Swift 实现，无 C++ / 词典文件
- ⚡️ **零初始化延迟** — 无状态设计，实例化即用
- 🌏 **真正通用的 CJK 覆盖** — 中文（简/繁）、日文（汉字/假名）、韩文（谚文）
- ✅ **完美 Token 对称性** — 索引和查询使用完全相同的分词逻辑
- 🔍 **正确的短语匹配** — bigram 按序列位置发出，`matchingPhrase` 语义正确
- 🔒 **线程安全** — 无共享可变状态，并发调用无需加锁
- 🔧 **可配置** — 支持 `no_unigram`、`no_case_fold` 等选项

## 算法

对 CJK 字符段采用 Bigram（主）+ Unigram（co-located）混合策略：

```
文档："清华大学"
发出：
  pos 0 → bigram "清华"（主），unigram "清"（co-located）
  pos 1 → bigram "华大"（主），unigram "华"（co-located）
  pos 2 → bigram "大学"（主），unigram "大"（co-located）
  pos 3 → unigram "学"（独立位置）

搜索 "清"       → ✅ 命中（unigram @pos0）
搜索 "清华"     → ✅ 命中（bigram @pos0）
搜索 "清华大学" → ✅ phrase："清华"@0 "华大"@1 "大学"@2 连续
搜索 "北京大学" → ❌ 正确地不命中（"京大" bigram 不存在于此文档）
```

## 快速开始

### 1. 注册分词器

```swift
import GRDB
import cjkfts5

var config = Configuration()
config.prepareDatabase { db in
    db.add(tokenizer: CJKTokenizer.self)
}
let dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
```

### 2. 建立 FTS5 虚拟表

```swift
try dbQueue.write { db in
    try db.create(virtualTable: "documents", using: FTS5()) { t in
        t.tokenizer = CJKTokenizer.tokenizerDescriptor()
        t.column("title")
        t.column("body")
    }
}
```

### 3. 索引与搜索

```swift
// 插入（无需任何预处理）
try db.execute(sql: "INSERT INTO documents(title, body) VALUES (?, ?)",
               arguments: ["清华大学", "中国顶尖学府之一"])

// 精确短语搜索
let phrasePattern = FTS5Pattern(matchingPhrase: "清华大学")
let docs = try Document.matching(phrasePattern).fetchAll(db)

// 任意词搜索
let anyPattern = FTS5Pattern(matchingAnyTokenIn: "清华 北京")
let docs2 = try Document.matching(anyPattern).fetchAll(db)
```

## 配置选项

```swift
// 默认配置（推荐）
t.tokenizer = CJKTokenizer.tokenizerDescriptor()

// 关闭单字 unigram（减小约 30% 索引体积，但单字查询失效）
let opts = CJKTokenizerOptions(emitUnigrams: false)
t.tokenizer = CJKTokenizer.tokenizerDescriptor(options: opts)

// 关闭大小写折叠（大小写敏感搜索）
let opts2 = CJKTokenizerOptions(caseFolding: false)
t.tokenizer = CJKTokenizer.tokenizerDescriptor(options: opts2)
```

## 覆盖的 Unicode 范围

| 范围 | 描述 |
|---|---|
| U+4E00–U+9FFF | CJK 统一汉字（中文/日文汉字，最常用）|
| U+3400–U+4DBF | CJK 统一汉字扩展 A |
| U+20000–U+2A6DF | CJK 统一汉字扩展 B（生僻字）|
| U+F900–U+FAFF | CJK 兼容汉字 |
| U+3040–U+309F | 平假名 Hiragana |
| U+30A0–U+30FF | 片假名 Katakana |
| U+AC00–U+D7AF | 韩文音节 Hangul |

## 性能

| 指标 | CJKTokenizer | jieba Tokenizer | SQLite Trigram |
|---|---|---|---|
| 初始化延迟 | **0 ms** | 100-300 ms | 0 ms |
| 包体积增量 | **0 MB** | 5.5 MB | 0 MB |
| 索引复杂度 | **O(n)** | O(n·dict) | O(n) |
| 最小可命中查询长度 | **1 字** | 取决于分词 | **3 字** |
| 线程安全 | **天然** | 需 mutex | 天然 |

## 与工业界标准对齐

本库采用与以下系统相同的 CJK 处理策略：

- **Elasticsearch CJKAnalyzer**
- **Apache Lucene CJKBigramFilter**
- **Apache Solr CJKAnalyzer**

## 文件结构

```
cjkfts5/
├── cjkfts5/
│   ├── CJKTokenizer.swift           # 核心分词器（FTS5CustomTokenizer）
│   ├── CJKTokenizerOptions.swift    # 配置选项类型
│   └── CJKUnicodeHelper.swift       # Unicode 范围判断 & 字节偏移工具
├── cjkfts5Tests/
│   └── CJKTokenizerTests.swift      # 完整单元测试套件（15 个用例）
└── docs/
    └── FTS5_TOKENIZER_DESIGN.md     # 深度技术文档：设计分析 & 关键问题
```

## 技术文档

深度设计分析（含 FTS5 query/document 语义差异、假阳性 Bug 根因、修复方案对比）：

📄 [docs/FTS5_TOKENIZER_DESIGN.md](docs/FTS5_TOKENIZER_DESIGN.md)
