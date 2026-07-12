# Tokenization Profile 契约

本文定义 **cjkfts5** 的分词配置契约：默认行为、命名 profile、FTS5 参数 wire format，以及变更时的兼容性要求。

> **稳定性承诺：** 同一 major 版本内，已文档化的 profile 语义与 argument 关键字不得静默改变含义。新增开关须向后兼容（缺省 = 旧行为）。

---

## 1. 命名 Profile

| Profile | API | emitUnigrams | case / width / diacritic fold | stopwords |
|---|---|---|---|---|
| **Default** | `CJKTokenizerOptions()` / `.cjk()` | `true` | 全部 `true` | **无** |
| **Recommended** | `.recommended` / `.cjk(options: .recommended)` | `true` | 全部 `true` | `StopwordPresets.cjkCommon` |
| **Minimal index** | `.minimalIndex` | `false` | 全部 `true` | 无 |
| **Strict match** | `.strictMatch` | `true` | 全部 `false` | 无 |

说明：

- **Default** 适合需要最大召回、自行管理停用词的调用方。  
- **Recommended** 适合中英混合全文检索「开箱即用」。  
- **Minimal index** 约减小 unigram 索引体积，**单字查询不再命中**。  
- **Strict match** 关闭所有折叠，全半角 / 大小写 / 变音符均严格区分。

自定义：

```swift
var opts = CJKTokenizerOptions.recommended
opts.emitUnigrams = false
t.tokenizer = .cjk(options: opts)
```

---

## 2. Document vs Query 语义（契约）

采用 FTS5 synonym **方法 (3)**：同义词只在 **document** 侧以 colocated unigram 形式写入。

| 规则 | Document | Query |
|---|---|---|
| CJK bigram 主 token | 发出 | 发出 |
| colocated unigram（首字） | `emitUnigrams == true` 时发出 | **默认不发出** |
| 段末单字独立位置 | 发出（除非是停用词） | **不发出** |
| bigram 为停用词时的 unigram 晋升 | 发出为主 token（flags=0） | **同样晋升**（保证 phrase 位置对齐） |
| 非 CJK 词 | 按分隔符切分 + 可选折叠 | 同左 |

索引与查询必须使用 **同一 tokenizer 名称与同一 options**（由 FTS5 表定义固定）。

---

## 3. FTS5 Argument Wire Format

`CJKTokenizerOptions.arguments` 生成的参数列表（**不含** tokenizer 名 `cjk`；GRDB 可能在 `init` 前额外插入名称——解析时只用 `contains` / 键值对扫描）。

### 3.1 开关（缺省 = 启用对应能力）

| Argument token | 含义 |
|---|---|
| `no_unigram` | `emitUnigrams = false` |
| `no_case_fold` | `caseFolding = false` |
| `no_width_fold` | `widthFolding = false` |
| `no_diacritic_fold` | `diacriticFolding = false` |

未出现上述 token ⇒ 对应能力为 **true**。

### 3.2 停用词

**预设（优先、紧凑）：**

```
stopwords_preset <id>
```

| id | 词表 |
|---|---|
| `en` / `english` | `StopwordPresets.english` |
| `zh` / `chinese` / `cn` | `StopwordPresets.chinese` |
| `en+zh` / `zh+en` / `cjk` / `common` | `StopwordPresets.cjkCommon` |

**自定义列表：**

```
stopwords <encoded>
```

- 词之间用 `,` 分隔  
- 词内 `,` 与 `\` 转义为 `\,` / `\\`  
- 词在编入参数前会按当前 folding 选项规范化（与 emit 路径一致）

预设与自定义可同时出现时，解码侧会 **并集**。

### 3.3 往返

```swift
let opts: CJKTokenizerOptions = …
let restored = CJKTokenizerOptions(arguments: opts.arguments)
// flags 与 stopwords 集合语义相等
```

Golden 测试见 `TokenizerOptionsCodecTests`。

---

## 4. 规范化单一事实来源

| 场景 | 实现 |
|---|---|
| 非 CJK token 发射 | `TokenNormalizer.normalizeWord` / ASCII 热路径 |
| 停用词建表 | `StopwordSet` → `TokenNormalizer.normalizeWord` |
| CJK 宽度折叠 / 半角浊点 | `TokenNormalizer.decodeFoldedCodepoint` + `CJKUnicode.foldWidth` |

**禁止**在分词器内再复制一套 folding 逻辑。

---

## 5. 变更与重索引

以下变更会使 **已有 FTS 索引与新查询不兼容**，必须重建虚拟表并重灌数据：

- 修改 Default / Recommended 的默认 flags 或预设词表内容  
- 修改 Unicode `isCJK` 范围导致切段边界变化  
- 修改 bigram/unigram/query 发出规则  
- 修改 stopword 晋升规则  

仅新增 **opt-in** 开关且默认关闭时，可不重索引。

---

## 6. 相关文档

- [FTS5_TOKENIZER_DESIGN.md](FTS5_TOKENIZER_DESIGN.md) — 算法与历史假阳性分析  
- [GRDB_COMPATIBILITY.md](GRDB_COMPATIBILITY.md) — GRDB 集成与陷阱  
- 仓库根目录 [benchmark_results.md](../benchmark_results.md) — 性能基线（Release 复现）  
