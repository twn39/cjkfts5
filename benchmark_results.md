# CJKTokenizer Complete Performance Benchmark Report

- **Corpus Details**: Mixed Chinese/English text, 5000 documents.
- **Corpus Size**: 3.24 MB (3393890 bytes).
- **Platform**: 版本26.3（版号25D125） (10 Cores).

---

## 维度 A：直接分词吞吐率 (Raw Tokenizer Throughput)
> 测量直接调用分词器进行分词的纯粹 CPU 吞吐性能（不含 SQLite 数据库写入开销）。

| 分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 21.50 | 150.51 |
| CJK (No Unigrams) | 19.96 | 162.13 |
| CJK (With Stopwords) | 49.35 | 65.58 |
| CJK (No Folding) | 21.54 | 150.24 |

## 维度 B：FTS5 数据库表写入与索引吞吐率 (FTS5 Indexing Throughput)
> 测量在真实 SQLite 事务中，批量插入并建立 FTS5 索引的端到端吞吐性能（含数据库 I/O 与 FTS5 树更新）。

| 虚拟表分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 108.17 | 29.92 |
| CJK (No Unigrams) | 75.31 | 42.98 |
| CJK (With Stopwords) | 122.57 | 26.41 |
| SQLite unicode61 | 69.09 | 46.85 |
| SQLite trigram | 136.84 | 23.65 |

*(测试结果在运行时自动计算生成)*
