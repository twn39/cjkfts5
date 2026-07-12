# CJKTokenizer Complete Performance Benchmark Report

> **How to reproduce** (from package root):
> ```bash
> swift test -c release --filter TokenizerBenchmarkTests
> ```
> This file is overwritten by the test. Compare configurations **within the same run**.
> Debug (`swift test` without `-c release`) numbers are not comparable to Release.

- **Corpus Details**: Mixed Chinese/English text, 5000 documents.
- **Corpus Size**: 3.24 MB (3393890 bytes).
- **Platform**: 版本26.3（版号25D125） (10 Cores).
- **Build**: Release (`swift test -c release`)

---

## 维度 A：直接分词吞吐率 (Raw Tokenizer Throughput)
> 测量直接调用分词器进行分词的纯粹 CPU 吞吐性能（不含 SQLite 数据库写入开销）。

| 分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 23.13 | 139.96 |
| CJK (No Unigrams) | 22.45 | 144.20 |
| CJK (With Stopwords) | 29.97 | **107.98** |
| CJK (No Folding) | 23.44 | 138.06 |

*Stopwords path improved via single-codepoint O(1) lookup + CJK bigram short-circuit when multi-byte table is ASCII-only (`cjkCommon`).*

## 维度 B：FTS5 数据库表写入与索引吞吐率 (FTS5 Indexing Throughput)
> 测量在真实 SQLite 事务中，批量插入并建立 FTS5 索引的端到端吞吐性能（含数据库 I/O 与 FTS5 树更新）。

| 虚拟表分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 104.98 | 30.83 |
| CJK (No Unigrams) | 79.22 | 40.86 |
| CJK (With Stopwords) | 101.20 | 31.98 |
| SQLite unicode61 | 65.87 | 49.13 |
| SQLite trigram | 126.95 | 25.50 |

*(测试结果在运行时自动计算生成)*
