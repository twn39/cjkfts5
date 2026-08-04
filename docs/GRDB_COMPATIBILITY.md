# GRDB 7.x 兼容性说明

> 适用于 **cjkfts5** 与 **GRDB 7.10+**（`Package.swift` 声明 `.upToNextMajor(from: "7.10.0")`，`swift-tools-version: 6.1`）。

---

## 1. 依赖与平台

| 项 | 要求 |
|---|---|
| Swift tools | 6.1+ |
| GRDB | 7.10+（CI 矩阵覆盖 7.10.0 / 7.11.1） |
| 平台 | iOS 16+ / macOS 13+ |
| 产品 | 单一 library target `cjkfts5` |

消费者 `Package.swift` 示例：

```swift
.package(url: "https://github.com/twn39/cjkfts5.git", from: "1.0.0"),
// …
.product(name: "cjkfts5", package: "cjkfts5"),
.product(name: "GRDB", package: "GRDB.swift"),
```

---

## 2. 集成 API 清单

| API | 模块位置 | 说明 |
|---|---|---|
| `Configuration.addCJKTokenizer()` | `CJKIntegration.swift` | 在 `prepareDatabase` 中 `db.add(tokenizer: CJKTokenizer.self)` |
| `FTS5TokenizerDescriptor.cjk()` | 同上 | 默认 options（全折叠、**无**停用词） |
| `FTS5TokenizerDescriptor.cjk(options:)` | 同上 | 推荐入口，传入完整 `CJKTokenizerOptions` |
| `CJKTokenizer` | `CJKTokenizer.swift` | `FTS5CustomTokenizer`，`name == "cjk"` |
| `db.makeTokenizer(.cjk())` | GRDB | 调试分词：`tokenize(document:)` / `tokenize(query:)` |

典型建表：

```swift
var config = Configuration()
config.addCJKTokenizer()
let dbQueue = try DatabaseQueue(path: path, configuration: config)

try dbQueue.write { db in
    try db.create(virtualTable: "documents", using: FTS5()) { t in
        t.tokenizer = .cjk(options: .recommended)
        t.column("content")
    }
}
```

`DatabasePool` 同样安全：每个连接都会执行 `prepareDatabase`。

---

## 3. GRDB / FTS5 行为陷阱

### 3.1 `init(db:arguments:)` 参数含 tokenizer 名

GRDB 将 C 层 `azArg[]`（**包含** tokenizer 名作为首元素）传给 `FTS5CustomTokenizer.init(db:arguments:)`。

实际可能收到：`["cjk", "no_unigram"]`，而非仅 `["no_unigram"]`。

**cjkfts5 对策：** 选项解析一律用 `arguments.contains("no_unigram")` 等，**禁止**用固定下标假设「第 0 项是第一个开关」。

> 与 SQLite 官方 v2 tokenizer API 文档（`azArg` 不含名称）可能不一致，以 GRDB 封装行为为准。

### 3.2 `FTS5Pattern(matchingAnyTokenIn:)` 使用 ASCII tokenizer

GRDB 在构造 `matchingAnyTokenIn` 时用 **内置 ascii** 分词，不是表上的 `cjk`。

对纯 CJK 查询串，ascii 往往把整串当作一个 token，再由 FTS5 用表 tokenizer 做 **query tokenization**。  
因此中文场景下 `matchingAnyTokenIn` 与 `rawPattern` 常表现接近；跨词 OR 需自行构造 raw pattern。

**phrase** 查询请用 `FTS5Pattern(matchingPhrase:)`。

### 3.3 Document vs Query 分词

表 tokenizer 在索引与 `MATCH` 时都会调用 `xTokenize`，但 `FTS5Tokenization` 不同：

| 模式 | cjkfts5 行为摘要 |
|---|---|
| Document | bigram 主 token + 可选 colocated unigram；段末字独立位置 |
| Query | 默认不发 colocated unigram；末字不单独占新位置；**bigram 被停用词过滤时仍可晋升 unigram** |

详情见 [FTS5_TOKENIZER_DESIGN.md](FTS5_TOKENIZER_DESIGN.md) 与 [TOKENIZATION_PROFILE.md](TOKENIZATION_PROFILE.md)。

---

## 4. 升级检查清单

升级 **cjkfts5** 小版本 / 大版本时：

- [ ] 阅读 CHANGELOG：默认 options、预设停用词、Unicode 范围是否变更  
- [ ] **已有 FTS 索引**：tokenizer 语义变更后需 **重建虚拟表 / 重索引**  
- [ ] 确认 `Package.resolved` 中 GRDB 仍在 7.x  
- [ ] 跑 `swift test`（Release 零分配断言仅在 `-c release` 下有意义）  
- [ ] 若依赖 FTS5 argument 字符串落库，对照 [TOKENIZATION_PROFILE.md](TOKENIZATION_PROFILE.md) 的 wire format  

升级 **GRDB 7.x → 下一 major** 时：

- [ ] 检查 `FTS5CustomTokenizer` / `FTS5TokenizerDescriptor` / `add(tokenizer:)` 是否改签名  
- [ ] 复查 `matchingAnyTokenIn` / `matchingPhrase` 实现是否仍走 ascii 辅助分词  
- [ ] 在 CI 中增加目标 GRDB 版本矩阵  

---

## 5. CI 矩阵（仓库）

`.github/workflows/ci.yml`：

- Runner：`macos-15`，Xcode `latest-stable`（Swift 6.1+）  
- Swift tools：6.1  
- GRDB：7.10.0 / 7.11.1  
- `swift build -c release` + `swift test --parallel`  

---

## 6. 版本记录（摘要）

| 时段 | 说明 |
|---|---|
| 初版 | Bigram+Unigram、`FTS5CustomTokenizer`、GRDB 7 集成 |
| 后续 | 宽度/变音符折叠、停用词、`TokenNormalizer` 统一规范化、`StopwordPresets`、`.recommended` |
| 工具链 | 升级至 Swift tools 6.1 + GRDB 7.10+（GRDB ≥ 7.9 要求 tools 6.1） |
| 兼容策略 | GRDB 7.x 向上兼容；破坏性 tokenizer 语义变更走 semver major 并要求重索引 |
