# cjkfts5 — 通用 CJK FTS5 分词库

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange)](https://swift.org)
[![GRDB](https://img.shields.io/badge/GRDB-7.x-blue)](https://github.com/groue/GRDB.swift)
[![Platform](https://img.shields.io/badge/Platform-iOS%2016%2B%20%7C%20macOS%2013%2B-blue)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![CI](https://github.com/twn39/cjkfts5/actions/workflows/ci.yml/badge.svg)](https://github.com/twn39/cjkfts5/actions/workflows/ci.yml)

基于 **Bigram + Unigram 混合策略** 的通用 CJK（中文/日文/韩文）FTS5 分词器，专为 [GRDB](https://github.com/groue/GRDB.swift) 设计。

## 特性

- 🚀 **零依赖** — 纯 Swift 实现，无 C++ / 词典文件
- ⚡️ **零初始化延迟** — 无状态设计，实例化即用
- 🌏 **真正通用的 CJK 覆盖** — 中文（简/繁，含扩展 A-I、扩展 H）、日文（汉字/假名/SMP 补充假名块）、韩文（谚文）
- ✅ **完美 Token 对称性** — 索引和查询使用完全相同的分词逻辑
- 🔍 **正确的短语匹配** — bigram 按序列位置发出，`matchingPhrase` 语义正确
- 🔒 **线程安全** — 无共享可变状态，并发调用无需加锁
- 🔧 **停用词过滤 (Stopwords)** — 100% 零堆分配的高性能过滤，支持位置自适应晋升机制，防止 Phrase 搜索位置错位
- ⚙️ **可配置** — 支持 `no_unigram`、`no_case_fold`、`no_width_fold`、`no_diacritic_fold` 等选项

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

## 安装

### Swift Package Manager

在 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/twn39/cjkfts5.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "cjkfts5", package: "cjkfts5"),
        ]
    ),
]
```

或通过 **Xcode → File → Add Package Dependencies** 搜索：

```
https://github.com/twn39/cjkfts5.git
```

## 快速开始

### 1. 注册分词器

```swift
import GRDB
import cjkfts5

var config = Configuration()
config.addCJKTokenizer()                  // 一行完成注册
let dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
```

### 2. 建立 FTS5 虚拟表

```swift
try dbQueue.write { db in
    try db.create(virtualTable: "documents", using: FTS5()) { t in
        // 推荐：全折叠 + 中英文常用停用词（裸 .cjk() 默认不过滤停用词）
        t.tokenizer = .cjk(options: .recommended)
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

> **默认行为：** `.cjk()` / `CJKTokenizerOptions()` 开启全折叠（大小写 / 宽度 / 变音符），**不会**启用停用词。  
> 需要中英文常用停用词时请使用 `.recommended` 或 `StopwordPresets`。

```swift
// 默认：全折叠，无停用词
t.tokenizer = .cjk()

// 推荐：全折叠 + 中英文常用停用词
t.tokenizer = .cjk(options: .recommended)

// 完整 options 对象（扩展新开关时优先走此入口）
var opts = CJKTokenizerOptions()
opts.emitUnigrams = false
opts.stopwords = StopwordPresets.chinese
t.tokenizer = .cjk(options: opts)

// 便捷参数：自定义停用词
t.tokenizer = .cjk(stopwords: ["的", "关于", "the"])

// 关闭单字 unigram（减小约 30% 索引体积，但单字查询失效）
t.tokenizer = .cjk(emitUnigrams: false)

// 关闭大小写折叠（大小写敏感搜索）
t.tokenizer = .cjk(caseFolding: false)

// 关闭宽度折叠（全半角隔离）
t.tokenizer = .cjk(widthFolding: false)

// 调试分词结果
let tokenizer = try db.makeTokenizer(.cjk())
let tokens = try tokenizer.tokenize(document: "清华大学 Hello")
// → [("清华", []), ("华大", []), ("大学", []), ("学", []), ("hello", [])]
```

### 停用词预设

| API | 含义 |
|---|---|
| `StopwordPresets.english` | 英文常用停用词 |
| `StopwordPresets.chinese` | 中文常用停用词 |
| `StopwordPresets.cjkCommon` | 中英文并集 |
| `CJKTokenizerOptions.recommended` | 默认折叠 + `cjkCommon` |

兼容别名：`CJKTokenizerOptions.englishStopwords` / `.chineseStopwords` 仍可用。

## 覆盖的 Unicode 范围

| 范围 | 描述 |
|---|---|
| U+4E00–U+9FFF | CJK 统一汉字（中文/日文汉字，最常用）|
| U+3400–U+4DBF | CJK 统一汉字扩展 A |
| U+20000–U+2EE5F | CJK 统一汉字扩展 B–I（含扩展 C, D, E, F, I 生僻字，Unicode 15.1）|
| U+30000–U+323AF | CJK 统一汉字扩展 G–H（含扩展 H，Unicode 15.0）|
| U+F900–U+FAFF | CJK 兼容汉字 |
| U+3040–U+30FF | 平假名 Hiragana / 片假名 Katakana |
| U+31F0–U+31FF | 片假名拼音扩展（爱努语） |
| U+1B000–U+1B16F | SMP 假名补充块（Katakana Supplement / Kana Ext-A / Small Kana）|
| U+1AFF0–U+1AFFF | Kana Extended-B（台湾假名）|
| U+AC00–U+D7AF | 韩文音节 Hangul Syllables |
| U+1100–U+11FF / U+3130–U+318F | 韩文 Jamo / 韩文兼容 Jamo |

## 性能

### 1. 架构特性对比
| 指标 | CJKTokenizer | jieba Tokenizer | SQLite Trigram |
|---|---|---|---|
| 初始化延迟 | **0 ms** | 100-300 ms | 0 ms |
| 包体积增量 | **0 MB** | 5.5 MB | 0 MB |
| 索引复杂度 | **O(n)** | O(n·dict) | O(n) |
| 最小可命中查询长度 | **1 字** | 取决于分词 | **3 字** |
| 线程安全 | **天然** | 需 mutex | 天然 |
| 内存热路径分配数 | **0 次 (100% 零堆分配)** | 频繁 malloc | 0 次 |

### 2. 吞吐性能基准测试 (Release 模式)
我们在 macOS (10 Cores) 下，使用 **3.24 MB (3,393,890 字节)** 的中英混合语料库，对分词及 FTS5 写入性能进行了全面基准测试。详见完整报告：[benchmark_results.md](benchmark_results.md)。

#### 维度 A：直接分词吞吐率 (Raw Tokenizer Throughput)
> 测量直接调用分词器进行分词的纯粹 CPU 吞吐性能（不含 SQLite 数据库写入开销）。

| 分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 21.50 | **150.51** |
| CJK (No Unigrams) | 19.96 | **162.13** |
| CJK (With Stopwords) | 49.35 | **65.58** |
| CJK (No Folding) | 21.54 | **150.24** |

#### 维度 B：FTS5 数据库表写入与索引吞吐率 (FTS5 Indexing Throughput)
> 测量在真实 SQLite 事务中，批量插入并建立 FTS5 索引的端到端吞吐性能（含数据库 I/O 与 FTS5 树更新）。

| 虚拟表分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| **CJK (Default)** | 108.17 | **29.92** |
| **CJK (No Unigrams)** | 75.31 | **42.98** |
| **CJK (With Stopwords)** | 122.57 | **26.41** |
| **SQLite unicode61** (内置) | 69.09 | **46.85** |
| **SQLite trigram** (内置) | 136.84 | **23.65** |

*注：`CJKTokenizer (Default)` 在保证中日韩精确短语检索与 1 字索引的前提下，写入吞吐速率仍显著超越了 SQLite 官方内置的 `trigram` 分词器（**23.65 MB/s**）。*

## 与工业界标准对齐

本库采用与以下系统相同的 CJK 处理策略：

- **Elasticsearch CJKAnalyzer**
- **Apache Lucene CJKBigramFilter**
- **Apache Solr CJKAnalyzer**

## 文件结构

```
cjkfts5/
├── cjkfts5/                 # TokenNormalizer / StopwordPresets / CJKTokenizer / …
│   ├── CJKTokenizer.swift           # 核心分词器（FTS5CustomTokenizer）
│   ├── CJKTokenizerOptions.swift    # 配置选项类型
│   ├── CJKUnicodeHelper.swift       # Unicode 范围判断 & 字节偏移工具
│   ├── StopwordSet.swift            # 停用词扁平连续内存与二分查找容器
│   └── CJKIntegration.swift         # GRDB 集成便捷 API（.cjk()、addCJKTokenizer()）
├── cjkfts5Tests/
│   ├── CJKTokenizerTests.swift      # 基础基类与分词核心搜索测试
│   ├── CJKUnicodeFoldingTests.swift  # 大小写折叠集成测试
│   ├── CJKUnicodeHelperTests.swift   # Unicode 范围及编解码单元测试
│   ├── CJKWidthAndDiacriticTests.swift # 宽度与变音符折叠集成测试
│   ├── CJKStopwordTests.swift       # 停用词过滤与位置晋升集成测试
│   └── CJKPerformanceTests.swift    # 多线程并发与零堆分配性能回归测试
├── .github/workflows/
│   └── ci.yml                       # CI 矩阵：Swift 5.9/5.10/6.0 × GRDB 7.x
└── docs/
    ├── FTS5_TOKENIZER_DESIGN.md     # 深度技术文档：设计分析 & 关键问题
    └── GRDB_COMPATIBILITY.md        # GRDB 7.x 兼容性说明 & 升级检查清单
```

## 技术文档

- 📄 [FTS5 分词器设计分析](docs/FTS5_TOKENIZER_DESIGN.md) — query/document 语义差异、假阳性 Bug 根因、修复方案对比
- 📄 [GRDB 7.x 兼容性说明](docs/GRDB_COMPATIBILITY.md) — API 依赖清单、版本记录、升级检查清单

## 许可证

[MIT](LICENSE) © 2026 twn39
