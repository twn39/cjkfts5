# CJKTokenizer 设计文档与关键问题分析

> 版本：1.0 · 日期：2026-05-08 · 作者：工程分析记录

---

## 目录

1. [整体架构](#1-整体架构)
2. [Token 发出策略（Bigram + Unigram）](#2-token-发出策略bigram--unigram)
3. [关键问题：文档分词 vs 查询分词的语义差异](#3-关键问题文档分词-vs-查询分词的语义差异)
4. [Bug 根因三层链式分析](#4-bug-根因三层链式分析)
5. [修复方案](#5-修复方案)
6. [修复前后行为对比](#6-修复前后行为对比)
7. [测试用例与验证](#7-测试用例与验证)
8. [工程陷阱备忘](#8-工程陷阱备忘)

---

## 1. 整体架构

```
SQLite FTS5
    │
    │  xTokenize(flags, pText, nText, xToken)
    ▼
CJKTokenizer.tokenize(context:tokenization:pText:nText:tokenCallback:)
    │
    ├─ isQuery = tokenization.contains(.query)
    │
    ├─ tokenizeText(_:isQuery:)
    │       │
    │       ├─ CJK 字符段 → emitCJKSegment(isQuery:)
    │       │       ├─ 文档模式：bigram(主) + unigram(co-located) + 末字(新位置)
    │       │       └─ Query 模式：bigram(主) only — 全部 unigram 抑制
    │       │
    │       └─ 非 CJK 段 → flushNonCJK()
    │               └─ 按分隔符切词 + case folding
    │
    └─ emitString(_:flags:) → tokenCallback(context, tflags, ptr, len, iStart, iEnd)
```

---

## 2. Token 发出策略（Bigram + Unigram）

### 2.1 文档索引模式（`FTS5_TOKENIZE_DOCUMENT`）

对 CJK 字符串 `"清华大学"` 发出如下 token 流：

```
文档: 清华大学

pos 0  ─── bigram  "清华"  (flags=0,          主 token，新位置)
pos 0  ─── unigram "清"    (flags=COLOCATED,  同义词，同一位置)
pos 1  ─── bigram  "华大"  (flags=0,          主 token，新位置)
pos 1  ─── unigram "华"    (flags=COLOCATED,  同义词，同一位置)
pos 2  ─── bigram  "大学"  (flags=0,          主 token，新位置)
pos 2  ─── unigram "大"    (flags=COLOCATED,  同义词，同一位置)
pos 3  ─── unigram "学"    (flags=0,          末字，单独新位置)
```

`FTS5_TOKEN_COLOCATED` 表示与上一个 token **共享同一 FTS5 位置**，FTS5 把它存储为该位置 token 的「同义词」（synonym）。

### 2.2 查询分词模式（`FTS5_TOKENIZE_QUERY`）

**同样的 `"清华大学"` 在 query 分词时**，只发出 bigram：

```
query: 清华大学

pos 0  ─── bigram  "清华"  (flags=0)
pos 1  ─── bigram  "华大"  (flags=0)
pos 2  ─── bigram  "大学"  (flags=0)
（末字 "学" 不发出——query 模式省略末字）
```

**为什么 query 模式完全不发出 unigram？** 见下节。

---

## 3. 关键问题：文档分词 vs 查询分词的语义差异

### 3.1 SQLite FTS5 Synonym Support 文档规定

SQLite 官方文档 [§7.1.1 Synonym Support](https://www.sqlite.org/fts5.html#synonym_support) 明确说明：

> "When using methods (2) or (3), it is important that the tokenizer only provide synonyms when tokenizing **document text** (method 3) or **query text** (method 2), **not both**."

本库采用**方法 (3)**：在文档中同时发出 bigram 和 unigram，query 端不发出额外 synonym，让 bigram 精确匹配。

如果 query 分词时**也**发出 co-located unigram，FTS5 会把它们当作该 bigram 的**等效搜索词**，导致假阳性（见下节）。

### 3.2 `FTS5_TOKEN_COLOCATED` 的精确语义

| 场景 | `xToken(COLOCATED)` 的作用 |
|------|--------------------------|
| 文档索引 | 在该 FTS5 位置额外存储一个等效 token |
| 查询分词 | 为该查询位置增加一个 OR 候选词（synonym search） |

这是**同一个机制在两种上下文的不同表现**，不能用同一套逻辑处理。

---

## 4. Bug 根因三层链式分析

### Bug 现象

`testBigramSearch` 失败：查询 `"北清"` 意外命中了文档 `"北京清华大学"`。

### 第一层：`FTS5Pattern(matchingAnyTokenIn:)` 的分词器

```swift
// GRDB 源码 FTS5.swift:113
static func tokenize(query string: String) throws -> [String] {
    try DatabaseQueue().inDatabase { db in
        try db.makeTokenizer(.ascii()).tokenize(query: string).compactMap {
            $0.flags.contains(.colocated) ? nil : $0.token
        }
    }
}
```

`matchingAnyTokenIn("北清")` 使用**内置 ascii tokenizer**，把 `"北清"` 当作**一个整体 token**（非 ASCII 字符在 ascii tokenizer 里均为 token 字符），产生 rawPattern `北清`（1 个 token）。

### 第二层：FTS5 用表的 CJK Tokenizer 对 query pattern 再次分词

FTS5 执行 `MATCH '北清'` 时，用 `docs` 表自己的 tokenizer（cjk）对 `"北清"` 做 **query tokenization**：

**修复前的行为（错误）：**

```
query 分词 "北清"（旧逻辑，没有区分 query/document）:

pos 0  ─── bigram  "北清"   (flags=0)          ← 正确
pos 0  ─── unigram "北"     (flags=COLOCATED)  ← ❌ 变成 bigram "北清" 的同义词
pos 1  ─── unigram "清"     (flags=0)          ← ❌ 额外的 AND 约束
```

FTS5 把上述 token 流解读为：

```
("北清" OR "北") AND "清"
```

**等效 SQL：**

```sql
docs MATCH '("北清" OR "北") AND "清"'
```

### 第三层：假阳性命中

文档 `"北京清华大学"` 的索引包含：
- pos 0: `"北京"`（bigram），`"北"`（co-located unigram）
- pos 1: `"京清"`（bigram），`"京"`（co-located unigram）
- pos 2: `"清华"`（bigram），`"清"`（co-located unigram）
- ……

查询 `("北清" OR "北") AND "清"` 的匹配过程：
- `"北清"` → 索引中不存在 ✗
- `"北"` → 存在于 pos 0（co-located） ✓  → 第一个子句成立！
- `"清"` → 存在于 pos 2（co-located） ✓  → 第二个子句成立！
- **AND 两个子句都成立 → 命中！（假阳性）**

---

## 5. 修复方案

### 核心原则

> **Query 分词只发出 bigram，完全抑制所有 unigram（包括 co-located）。**

参考：SQLite FTS5 方法 (3)——文档端发出所有同义词，query 端精确匹配。

### 代码变更（`CJKTokenizer.swift`）

**1. `tokenize()` — 提取 isQuery 标志传递给内部方法**

```swift
public func tokenize(
    context: UnsafeMutableRawPointer?,
    tokenization: FTS5Tokenization,
    pText: UnsafePointer<CChar>?,
    nText: CInt,
    tokenCallback: @escaping FTS5TokenCallback
) -> CInt {
    // ...
    let isQuery = tokenization.contains(.query)   // ← 新增
    return tokenizeText(text, isQuery: isQuery, callback: tokenCallback, context: context)
}
```

**2. `emitCJKSegment()` — 两种模式的 token 发出逻辑**

```swift
private func emitCJKSegment(
    scalars: [Unicode.Scalar],
    start: Int, end: Int,
    byteOffsets: [Int],
    isQuery: Bool,               // ← 新增参数
    callback: @escaping FTS5TokenCallback,
    context: UnsafeMutableRawPointer?
) -> CInt {
    // ...
    for k in start..<end {
        let hasNext = (k + 1 < end)

        if hasNext {
            // ① 始终发出 bigram（主 token，新位置）
            emit bigram(scalars[k], scalars[k+1])

            // ② co-located unigram：仅文档模式发出
            //    query 模式中 co-located 会变成 bigram 的同义词，导致假阳性
            if options.emitUnigrams && !isQuery {
                emit unigram(scalars[k], flags: COLOCATED)
            }

            // ③ 末字（最后一对）：query 模式直接跳过
            //    不能作为新位置（implicit AND 约束）
            //    不能作为 co-located（synonym 假阳性）
            // [query 模式下：什么都不做，直接进入下一轮循环后的 else 分支跳过]

        } else {
            // ④ 末字：仅文档模式发出新位置 unigram
            if !isQuery {
                emit unigram(scalars[k], flags: 0)   // 新位置，phrase search 末字锚点
            }
        }
    }
}
```

### 修复的两个假阳性来源

| 问题 | 修复前 | 修复后 |
|------|--------|--------|
| Co-located unigram | query 时发出 → 变成 bigram 同义词 | `!isQuery` 条件，query 时不发 |
| 末字新位置 unigram | query 时发出 → 变成额外 AND 约束 | `!isQuery` 条件，query 时跳过 |

---

## 6. 修复前后行为对比

### 场景：查询 `"北清"`（非相邻字符，应无命中）

**文档 `"北京清华大学"` 的索引（不变）：**

```
pos 0: "北京" [+ "北" co-located]
pos 1: "京清" [+ "京" co-located]
pos 2: "清华" [+ "清" co-located]
pos 3: "华大" [+ "华" co-located]
pos 4: "大学" [+ "大" co-located]
pos 5: "学"   (末字)
```

| | 修复前（query 分词 "北清"） | 修复后 |
|---|---|---|
| 发出 token | pos0:"北清", pos0:"北"(COLOC), pos1:"清" | pos0:"北清" |
| FTS5 解读 | `("北清" OR "北") AND "清"` | `"北清"` |
| 命中？ | ✅ **假阳性命中**（"北" 和 "清" 都在索引里） | ❌ **正确地不命中** |

### 场景：查询 `"清华"`（正确 bigram，应命中）

| | 修复前 | 修复后 |
|---|---|---|
| 发出 token | pos0:"清华", pos0:"清"(COLOC), pos1:"华" | pos0:"清华" |
| FTS5 解读 | `("清华" OR "清") AND "华"` | `"清华"` |
| 命中？ | ✅ 命中（但逻辑有误） | ✅ **正确命中** |

> 注意：修复前的 `"清华"` 查询恰好也命中了（因为文档里 "清" 和 "华" 的 co-located 都存在），但这是侥幸，不是正确的原因。

### 场景：`no_unigram` 模式下查询 `"清华"`

文档 `"清华大学"` 以 `no_unigram` 索引时：

```
pos 0: "清华"
pos 1: "华大"
pos 2: "大学"
pos 3: "学"   (末字，无论 emitUnigrams 如何，末字都发出)
```

| | 修复前 | 修复后 |
|---|---|---|
| query 分词 "清华" | pos0:"清华", pos1:"华" | pos0:"清华" |
| FTS5 解读 | `"清华" AND "华"` | `"清华"` |
| 索引中有 "华" token？ | ❌ no_unigram 模式不存在 | — |
| 命中？ | ❌ **正确的 bigram 却无法命中** | ✅ **正确命中** |

---

## 7. 测试用例与验证

所有 15 个单元测试均通过：

```
✅ testBigramSearch         — bigram 命中 + 非相邻字符不命中
✅ testCJKRangeDetection    — Unicode 范围覆盖正确性
✅ testEmptyDocument        — 空文档边界
✅ testJapaneseHiragana     — 平假名支持
✅ testJapaneseKatakana     — 片假名支持
✅ testKoreanHangul         — 韩文支持
✅ testLongChineseText      — 长文本分词
✅ testMixedCJKAndASCII     — 中英混合文本
✅ testNoUnigramOption      — no_unigram 模式下 bigram 仍命中
✅ testPhraseSearch         — phrase match 正确性
✅ testPunctuationOnlyDocument — 纯标点边界
✅ testSingleCharacterSearch   — 单字 unigram 查询
✅ testSingleCharDocument      — 单字文档
✅ testTwoCharDocument         — 双字文档
✅ testWhitespaceOnlyDocument  — 纯空白边界
```

**关键测试覆盖矩阵：**

| 测试 | 覆盖的核心正确性 |
|------|----------------|
| `testBigramSearch` 第 93 行 | `"北清"` 非相邻字符 → 不命中（修复假阳性） |
| `testNoUnigramOption` 第 250 行 | no_unigram + bigram query → 命中（修复 AND 约束） |
| `testSingleCharacterSearch` | unigram 查询仍然有效（文档端 co-located 正常索引） |
| `testPhraseSearch` | phrase 位置序列正确性（修复不破坏 phrase match） |

---

## 8. 工程陷阱备忘

### 陷阱 1：`FTS5Pattern(matchingAnyTokenIn:)` 用 ASCII tokenizer，不是表的 tokenizer

```swift
// FTS5.swift 内部实现
static func tokenize(query string: String) throws -> [String] {
    try db.makeTokenizer(.ascii()).tokenize(query: string)  // ← 始终用 ascii
}
```

**影响**：对中文查询字符串，ascii tokenizer 把所有字符当一个整体 token。这意味着：
- `matchingAnyTokenIn("清华")` → rawPattern `"清华"` → FTS5 再用 cjk tokenizer 分词
- `matchingAnyTokenIn("清")` → rawPattern `"清"` → 一个 token，再分词还是 `"清"`

对中文来说，`matchingAnyTokenIn` 和 `FTS5Pattern(rawPattern:)` **实际上等价**。如需构造 OR 查询，应手动拆分再组合 rawPattern。

### 陷阱 2：GRDB 的 `init(db:arguments:)` 接收包含 tokenizer 名的参数数组

根据 `FTS5CustomTokenizer.swift` 第 126-133 行的 C 层封装，GRDB 把 C 层的 `azArg[]`（包含 tokenizer 名 `azArg[0]`）全部传给了 `init(db:arguments:)`。

所以实际接收到的是 `["cjk", "no_unigram"]` 而非 `["no_unigram"]`。

**注意**：`contains("no_unigram")` 仍然正确工作，但如果用下标访问要注意偏移。

> 与 SQLite 官方文档（v2 API）不同：官方文档说 azArg 不含 tokenizer 名。这是 GRDB 对旧版 fts5_tokenizer（非 v2）的封装行为。

### 陷阱 3：FTS5 phrase query 对末字位置的要求

Phrase query `"清华大学"` 要求文档中存在：

```
位置 N+0: "清华" 或其 co-located 同义词
位置 N+1: "华大" 或其 co-located 同义词
位置 N+2: "大学" 或其 co-located 同义词
```

**文档端**的末字 `"学"` 作为 `pos 3` 的独立 unigram 发出，是为了：
1. 让 phrase `"大学"` 在文档中有正确的结尾位置（FTS5 通过位置号验证相邻关系）
2. 让单字查询 `"学"` 可以命中

如果末字不发出，`"大学"` 的 phrase 匹配不受影响（因为 `"大学"` bigram 已经在 pos 2 了），但 `matchingAnyTokenIn("学")` 无法命中。

### 陷阱 4：测试文件中的中文弯引号导致编译错误

原测试文件中 XCTAssert 的 message 参数使用了中文全角引号（`"` U+201C / `"` U+201D），`sed` 替换后变成裸双引号 `"`，导致 Swift 字符串截断为语法错误。

**修复方式**：用 Python 直接字节替换，将含嵌套引号的 message 字符串改为用方括号 `[]` 包裹关键词：

```python
# 修复前（编译错误）：
'"单字"清"应能命中"清华大学""'  # 4个双引号，字符串被截断

# 修复后（正确）：
'"单字[清]应能命中[清华大学]"'  # 清晰的方括号，无歧义
```

---

*文档生成于 2026-05-08，对应 cjkfts5 v1.0*
