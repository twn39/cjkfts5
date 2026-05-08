# GRDB 7.x 兼容性说明

## 依赖的 GRDB API 清单

`cjkfts5` 对 GRDB 的依赖**极度克制**，仅使用 FTS5 Tokenizer 的核心协议，不依赖任何查询 DSL 或记录类型。

### 核心接口（`CJKTokenizer.swift`）

| API | GRDB 类型 | 用途 | 自 GRDB 版本 |
|-----|-----------|------|-------------|
| `FTS5CustomTokenizer` | protocol | 实现自定义 tokenizer 的基础协议 | 6.x+ |
| `FTS5Tokenization` | struct | 判断当前是 `.query` 还是 `.document` 分词 | 6.x+ |
| `FTS5TokenCallback` | typealias | 向 FTS5 发出 token 的回调签名 | 7.x（`@escaping` 要求） |
| `FTS5TokenizerDescriptor` | struct | `t.tokenizer = ...` 赋值的描述符类型 | 6.x+ |
| `FTS5_TOKEN_COLOCATED` | CInt 常量 | 标记 co-located synonym token | SQLite 原生 |
| `Database` | class | `init(db:arguments:)` 参数类型 | 6.x+ |

### 关键变更：GRDB 7.x 相对 6.x 的差异

| 变更 | 影响 |
|------|------|
| `FTS5TokenCallback` 改为 `@escaping` | `tokenize()` 中 callback 必须声明 `@escaping` |
| `nText` 参数类型改为 `CInt` | 调用 callback 时需显式转换 `CInt(...)` |
| SPM 目标改为 `GRDBSQLite` 模块 | 需 `#if canImport(GRDBSQLite)` 条件导入 |

> 以上变更已在当前实现中全部适配。

---

## 兼容性保障策略

### 1. 最小化 API 依赖面

库仅依赖 `FTS5CustomTokenizer` 协议和 C 层 SQLite 常量，不依赖：
- GRDB 的查询构建器（`QueryInterface`）
- 记录系统（`Record`、`Codable`、`DatabaseValueConvertible`）
- 迁移系统（`DatabaseMigrator`）
- 响应式扩展（`ValueObservation`、Combine 集成）

这使得 GRDB 内部重构对本库的影响面极小。

### 2. CI 矩阵测试

`.github/workflows/ci.yml` 对以下组合进行全量测试：

```
Swift:  5.9 × 5.10 × 6.0
GRDB:   7.0.0 × 7.3.0 × 7.5.0 × 7.10.0
────────────────────────────────────────
总计：  12 个矩阵组合
```

每个组合独立 Build + `swift test --parallel`。

### 3. 版本兼容性记录

| GRDB 版本 | 测试状态 | 备注 |
|-----------|---------|------|
| 7.0.0 | ✅ 通过 | 首个支持版本 |
| 7.3.0 | ✅ 通过 | — |
| 7.5.0 | ✅ 通过 | — |
| 7.10.0 | ✅ 通过 | 开发时验证版本 |
| 8.x.x | ❌ 不支持 | 待评估，需重新适配 |

> 表格随 CI 结果持续更新。

### 4. 升级 GRDB 时的检查清单

当 GRDB 发布新 7.x minor 版本时，执行以下验证：

- [ ] `FTS5CustomTokenizer` 协议签名无变化
- [ ] `FTS5Tokenization.query` 成员依然存在
- [ ] `FTS5TokenCallback` 类型签名无变化
- [ ] `@testable import GRDB` 可正常编译
- [ ] 42 个单元测试全部通过
- [ ] `Package.resolved` 中更新锁定版本

---

## 常见不兼容场景与预防

### 场景 A：`FTS5TokenCallback` 签名变化

**风险**：GRDB 修改回调参数顺序或类型。

**预防**：`tokenize()` 方法严格按协议声明的 `tokenCallback` 参数类型调用，编译器类型检查会在升级时立即报错。

### 场景 B：`GRDBSQLite` 模块移除或更名

**风险**：SPM 模块结构调整导致 `import GRDBSQLite` 失败。

**预防**：使用 `#if canImport(GRDBSQLite)` 条件编译，同时保留 `#elseif canImport(SQLite3)` 回退：

```swift
#if canImport(GRDBSQLite)
import GRDBSQLite   // SPM 路径
#elseif canImport(SQLite3)
import SQLite3      // Xcode / CocoaPods 路径
#endif
```

### 场景 C：`FTS5CustomTokenizer` 新增必要协议成员

**风险**：GRDB 在协议里添加新的 `required` 方法。

**预防**：CI 会在编译阶段立即报错，无法静默失败。

---

*最后更新：2026-05-08*
