# CJKTokenizer 设计文档与关键问题分析

> 版本：1.1 · 与当前零拷贝实现同步 · 原 1.0（2026-05-08）关键假阳性分析保留  

配套契约：

- [TOKENIZATION_PROFILE.md](TOKENIZATION_PROFILE.md) — profile / FTS5 argument 契约  
- [GRDB_COMPATIBILITY.md](GRDB_COMPATIBILITY.md) — GRDB 集成陷阱  

---

## 目录

1. [整体架构](#1-整体架构)
2. [Token 发出策略（Bigram + Unigram）](#2-token-发出策略bigram--unigram)
3. [关键问题：文档分词 vs 查询分词的语义差异](#3-关键问题文档分词-vs-查询分词的语义差异)
4. [Bug 根因三层链式分析](#4-bug-根因三层链式分析)
5. [修复方案（现行）](#5-修复方案现行)
6. [停用词与位置晋升](#6-停用词与位置晋升)
7. [性能架构](#7-性能架构)
8. [工程陷阱备忘](#8-工程陷阱备忘)
9. [测试与验证](#9-测试与验证)

---

## 1. 整体架构

```
SQLite FTS5
    │  xTokenize(flags, pText, nText, xToken)
    ▼
CJKTokenizer.tokenize(context:tokenization:pText:nText:tokenCallback:)
    │
    ├─ isQuery = tokenization.contains(.query)
    │
    └─ tokenizeBytes(UnsafeRawBufferPointer, pText, isQuery, …)   // 零拷贝主循环
            │
            ├─ TokenNormalizer.decodeFoldedCodepoint  // UTF-8 + 可选宽度折叠/浊点合成
            │
            ├─ CJK 滑动窗口 (cjk0/1/2, cp0/1/2)
            │       └─ emitCJKPosition → bigram / colocated unigram / 停用词晋升
            │
            └─ 非 CJK word 区间
                    └─ emitWordToken → 可选折叠 + StopwordSet 过滤
```

| 文件 | 职责 |
|---|---|
| `CJKTokenizer.swift` | FTS5 回调、流式主循环、CJK 发射、停用词门控 |
| `TokenNormalizer.swift` | 规范化 SSOT（Latin + CJK 宽度） |
| `CJKUnicodeHelper.swift` | `isCJK` / decode / foldWidth 表 |
| `CJKTokenizerOptions.swift` | 选项 + FTS5 argument 编解码 |
| `StopwordSet.swift` | 单码点 O(1) + 多字节二分查找 |
| `StopwordPresets.swift` | 内置 en / zh / cjkCommon |
| `CJKIntegration.swift` | `.cjk()` / `addCJKTokenizer()` |

依赖方向：

```text
CJKIntegration → CJKTokenizer → TokenNormalizer / StopwordSet / CJKUnicode
                      ↑
             CJKTokenizerOptions ← StopwordPresets
```

无文件级循环导入。

---

## 2. Token 发出策略（Bigram + Unigram）

### 2.1 文档索引模式（`FTS5_TOKENIZE_DOCUMENT`）

对 CJK 字符串 `"清华大学"`（`emitUnigrams = true`）：

```
pos 0  ─── bigram  "清华"  (flags=0)
pos 0  ─── unigram "清"    (flags=COLOCATED)
pos 1  ─── bigram  "华大"  (flags=0)
pos 1  ─── unigram "华"    (flags=COLOCATED)
pos 2  ─── bigram  "大学"  (flags=0)
pos 2  ─── unigram "大"    (flags=COLOCATED)
pos 3  ─── unigram "学"    (flags=0，段末独立位置)
```

### 2.2 查询分词模式（`FTS5_TOKENIZE_QUERY`）

```
pos 0  ─── bigram  "清华"  (flags=0)     // 默认不发 colocated unigram
pos 1  ─── bigram  "华大"  (flags=0)
pos 2  ─── bigram  "大学"  (flags=0)
// 末字 "学" 不单独占新位置
```

**例外：** 当 bigram 被停用词过滤且 `emitUnigrams == true` 时，**query 与 document 均会将首字 unigram 晋升为主 token**（见 §6），避免 phrase 位置空洞。

### 2.3 `emitUnigrams = false`

- 不发 colocated 首字 unigram  
- 段末字在 **document** 仍可作独立位置（尾字索引 / phrase 尾部需要时由实现保留）  
- 单字查询通常无法命中（契约见 TOKENIZATION_PROFILE）

---

## 3. 关键问题：文档分词 vs 查询分词的语义差异

### 3.1 SQLite FTS5 Synonym Support

[§7.1.1 Synonym Support](https://www.sqlite.org/fts5.html#synonym_support)：

> When using methods (2) or (3), … only provide synonyms when tokenizing **document text** or **query text**, **not both**.

本库采用 **方法 (3)**：document 侧写 colocated unigram；query 侧默认精确匹配 bigram。

### 3.2 `FTS5_TOKEN_COLOCATED` 在两种上下文的含义

| 场景 | 效果 |
|---|---|
| 文档索引 | 该位置额外存储同义 token |
| 查询分词 | 该查询位置增加 OR 候选（易导致假阳性） |

因此 **不能在 query 侧无条件发出 colocated unigram**。

---

## 4. Bug 根因三层链式分析

### 现象

`testBigramSearch`：查询 `"北清"` 误命中文档 `"北京清华大学"`。

### 第一层：`matchingAnyTokenIn` 的辅助分词

GRDB 用 **ascii** tokenizer 拆 query 字符串；纯 CJK 常变成单一 raw token，再由 **表的 cjk tokenizer** 做 query 分词。

### 第二层：旧实现 query 也发 colocated unigram

```
query "北清"（错误旧逻辑）:
  pos0: "北清" + COLOCATED "北"
  pos1: "清"
→ 被解读为 ("北清" OR "北") AND "清"
```

### 第三层：假阳性

文档含 colocated `"北"`、`"清"` 等 → AND 成立 → 误命中。

---

## 5. 修复方案（现行）

### 原则

1. Query 默认 **不发** colocated unigram（`emitUni = emitUnigrams && !isQuery`）。  
2. Query **不**把段末字作为新位置独立 token。  
3. Document 保持 bigram + colocated unigram + 末字位置。  
4. 停用词 bigram 过滤时 **两侧均可晋升 unigram**（与纯 synonym 规则的局部例外，专用于位置对齐）。

### 实现锚点（`CJKTokenizer.swift`）

```swift
let isQuery = tokenization.contains(.query)
// 主循环 / flushCJK:
let emitUni = (options.emitUnigrams && !isQuery)
    || (isBigramStopword(cp0: cp0, cp1: cp1) && options.emitUnigrams)
```

零拷贝路径：`tokenize` → `tokenizeBytes`，CJK 优先 `emitRaw` 子指针；折叠时栈上 UTF-8 编码发射。

---

## 6. 停用词与位置晋升

1. 建表时 `StopwordSet` 用与 emit 相同的 `TokenNormalizer` 规范化。  
2. 热路径：  
   - **单 Unicode 码点**停用词 → `Set<UInt32>` O(1)  
   - **多码点**词 → 扁平字节 + 二分  
   - 若无「含非 ASCII 的多码点停用词」，CJK **bigram** 停用检查可直接跳过（`cjkCommon` 下英文停用词不影响 CJK bigram 探测）。  
3. Bigram 命中停用词且 unigram 非停用 → 晋升 unigram 为主 token（flags=0）。  
4. Bigram 与 unigram 皆停用 → 该位置不发射。

---

## 7. 性能架构

| 路径 | 策略 |
|---|---|
| 入口 | `UnsafeRawBufferPointer` 引用 `pText`，无 `Data`/`String` 全量拷贝 |
| CJK | 3 槽滑动窗口；未折叠 → 子指针；折叠 → 栈缓冲 UTF-8 |
| ASCII 词 | 小写折叠栈分配；已全小写零拷贝 |
| 非 ASCII Latin | `String` + `TokenNormalizer`（允许堆分配） |
| 停用词 | 单码点 O(1)；多字节二分；CJK bigram 可按标志短路 |
| 线程 | 实例无共享可变状态（options + 不可变 StopwordSet），可并发 `xTokenize` |

基准复现见仓库 [benchmark_results.md](../benchmark_results.md) 与 `TokenizerBenchmarkTests`。

---

## 8. 工程陷阱备忘

### 陷阱 1：`matchingAnyTokenIn` 用 ASCII tokenizer

对中文 OR 语义需手动构造 raw pattern。详见 GRDB_COMPATIBILITY §3.2。

### 陷阱 2：`init(db:arguments:)` 含 tokenizer 名

只用 `contains` / 键扫描，勿用绝对下标。见 GRDB_COMPATIBILITY §3.1。

### 陷阱 3：Phrase 与末字位置

Phrase `"清华大学"` 依赖连续位置上的 bigram 序列；document 末字独立位置服务单字检索，不是 phrase 中间位置的替代。

### 陷阱 4：改 tokenizer 语义必须重索引

见 TOKENIZATION_PROFILE §5。

### 陷阱 5：测试 message 中的弯引号

Swift 字符串内嵌中文弯引号易导致编译截断；断言 message 避免嵌套 `"`。

---

## 9. 测试与验证

| 区域 | 文件 / 类型 |
|---|---|
| 搜索 / phrase / 边界 | `CJKTokenizerTests.swift` 及拆分套件 |
| Token 金标 / options 往返 | `CJKTokenGoldenTests.swift` |
| 停用词晋升 / phrase | `CJKStopwordTests` / golden |
| Unicode 范围与解码 | `CJKUnicodeHelperTests` |
| 折叠 | `CJKUnicodeFoldingTests` / `CJKWidthAndDiacriticTests` |
| 并发与零分配 | `CJKPerformanceTests`（Release 断言） |
| 吞吐基准 | `TokenizerBenchmarkTests.testCompleteBenchmarkSuite` |

关键回归：

| 测试意图 | 断言要点 |
|---|---|
| 非相邻 bigram | `"北清"` 不命中 `"北京清华大学"` |
| query 无假阳性 synonym | query token 无多余 colocated unigram |
| 单字检索 | document unigram 仍可 `matchingAnyTokenIn("清")` |
| 停用词 phrase | 晋升后 phrase 位置不断裂 |
| options 往返 | flags + 转义停用词 + preset 短编码 |
