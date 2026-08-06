# CJKTokenizer Complete Performance Benchmark Report

> **How to reproduce** (from package root):
> ```bash
> swift test -c release --filter TokenizerBenchmarkTests
> ```
> This file is overwritten by the test. Compare configurations **within the same run**.

- **Corpus Details**: Mixed Chinese/English text, 10 documents.
- **Corpus Size**: 0.01 MB (6760 bytes).
- **Platform**: 版本26.5.2（版号25F84） (10 Cores).
- **Build**: Debug (not comparable to Release; use `swift test -c release`)

---

## 维度 A：直接分词吞吐率 (Raw Tokenizer Throughput)
> 测量直接调用分词器进行分词的纯粹 CPU 吞吐性能（不含 SQLite 数据库写入开销）。

| 分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 0.48 | 13.37 |
| CJK (No Unigrams) | 0.47 | 13.83 |
| CJK (With Stopwords) | 0.74 | 8.66 |
| CJK (No Folding) | 0.46 | 13.96 |

## 维度 B：FTS5 数据库表写入与索引吞吐率 (FTS5 Indexing Throughput)
> 测量在真实 SQLite 事务中，批量插入并建立 FTS5 索引的端到端吞吐性能（含数据库 I/O 与 FTS5 树更新）。

| 虚拟表分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 0.83 | 7.76 |
| CJK (No Unigrams) | 0.75 | 8.56 |
| CJK (With Stopwords) | 1.05 | 6.16 |
| SQLite unicode61 | 0.28 | 22.86 |
| SQLite trigram | 0.36 | 18.16 |

*(测试结果在运行时自动计算生成)*
